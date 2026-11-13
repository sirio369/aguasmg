-- =====================================================================================================
-- Projetos · OS SIGOS da Recomposição de pavimento (2026-11-13)
--
-- O nó "Recomposição de pavimento" de cada bloco da árvore de execução ganha `sgos` (nº da OS SIGOS) e `sgos_em`
-- (quando foi digitada), gravados pelo app no próprio snapshot (app_proj_estado_set, sem RPC nova). Aqui:
--  1) vw_os_vinculo passa a listar essas OS (módulo 'projetos', campo 'OS da recomposição', ref = kind:gid:rótulo do
--     bloco) → selo/painel de Vínculos/suspeita igual aos outros campos; estado_app = 'executada' quando a recomposição
--     está em 100%. Divergências próprias (100% no app × SIGOS pendente; SIGOS executou × app < 100%); a regra antiga
--     de projetos fica só para a OS SIGOS da pré-obra.
--  2) app_sigos_os_corrigir aceita esse campo (troca o nº dentro da árvore, só no bloco do ref).
-- As duas trocas são feitas sobre a definição atual (pg_get_viewdef / pg_get_functiondef) e abortam se o trecho
-- esperado não for encontrado.
-- =====================================================================================================

-- helper: troca a OS da recomposição dentro do bloco p_pth (nomes; '{}' = raiz da VCA)
create or replace function "13 - projetos_obra".proj_rec_sgos_set(p_nos jsonb, p_pth text[], p_antes text, p_nova text)
 returns jsonb
 language plpgsql
 immutable
 set search_path to 'public'
as $function$
declare r jsonb := '[]'::jsonb; x jsonb;
begin
  if jsonb_typeof(p_nos) <> 'array' then return p_nos; end if;
  for x in select e from jsonb_array_elements(p_nos) e loop
    if coalesce(cardinality(p_pth), 0) = 0 then
      if x->>'k' = '%' and x->>'n' = 'Recomposição de pavimento' and btrim(coalesce(x->>'sgos', '')) = p_antes then
        x := x || jsonb_build_object('sgos', p_nova, 'sgos_em', to_jsonb(now()));
      end if;
    elsif x->>'n' = p_pth[1] and jsonb_typeof(x->'f') = 'array' then
      x := jsonb_set(x, '{f}', "13 - projetos_obra".proj_rec_sgos_set(x->'f', p_pth[2:], p_antes, p_nova));
    end if;
    r := r || jsonb_build_array(x);
  end loop;
  return r;
end $function$;
revoke all on function "13 - projetos_obra".proj_rec_sgos_set(jsonb,text[],text,text) from public, anon, authenticated;

-- 1) vínculo das OS
do $mig$
declare d text := pg_get_viewdef('"17 - sigos".vw_os_vinculo'::regclass);
  m1 text := E'UNION ALL\n         SELECT ''vrp''::text';
  m2 text := 'WHEN ((modulo = ''projetos''::text) AND (sit = ''executada''::text) AND (estado_app IS DISTINCT FROM ''concluida''::text))';
begin
  if position(m1 in d) = 0 or position(m2 in d) = 0 then raise exception 'vw_os_vinculo mudou — revisar a migração'; end if;
  if position('proj_reat_blocos' in d) > 0 then return; end if;   -- já aplicada
  d := replace(d, m1, E'UNION ALL\n         SELECT ''projetos''::text, ''OS da recomposição''::text, (((st.kind || '':''::text) || st.gid) || '':''::text) || b.rotulo,\n'
    || E'            NULL::text, iv.consorcio, btrim(b.rec ->> ''sgos''::text),\n'
    || E'            COALESCE(((b.rec ->> ''sgos_em''::text))::timestamp with time zone, st.atualizado_em),\n'
    || E'            (COALESCE(iv.id, ''''::text) || '' · ''::text) || COALESCE(NULLIF(b.rotulo, ''''::text), ''Vala da rede''::text),\n'
    || E'            CASE WHEN (COALESCE(((b.rec ->> ''p''::text))::numeric, (0)::numeric) >= (100)::numeric) THEN ''executada''::text ELSE NULL::text END\n'
    || E'           FROM ((\"13 - projetos_obra\".intervencao_estado st\n'
    || E'             JOIN \"13 - projetos_obra\".vw_iv iv ON (((iv.kind = st.kind) AND (iv.gid = st.gid))))\n'
    || E'             CROSS JOIN LATERAL \"13 - projetos_obra\".proj_reat_blocos(iv.tipo, st.arv) b(bloco, rotulo, rea, rec))\n'
    || E'          WHERE (btrim(COALESCE((b.rec ->> ''sgos''::text), ''''::text)) <> ''''::text)\n        ' || m1);
  d := replace(d, m2,
       'WHEN ((modulo = ''projetos''::text) AND (campo = ''OS da recomposição''::text) AND (estado_app = ''executada''::text) AND (sit = ANY (ARRAY[''pendente''::text, ''encerrada_sem_execucao''::text]))) THEN (''Recomposição 100% no AcquaHub, mas o SIGOS diz: ''::text || status_sigos) '
    || 'WHEN ((modulo = ''projetos''::text) AND (campo = ''OS da recomposição''::text) AND (sit = ''executada''::text) AND (estado_app IS NULL)) THEN ''SIGOS executou a recomposição, mas o AcquaHub não está em 100%''::text '
    || 'WHEN ((modulo = ''projetos''::text) AND (campo = ''OS SIGOS''::text) AND (sit = ''executada''::text) AND (estado_app IS DISTINCT FROM ''concluida''::text))');
  execute 'create or replace view "17 - sigos".vw_os_vinculo with (security_invoker = true) as ' || d;
end $mig$;

-- 2) correção de OS pelo painel de Vínculos
do $mig$
declare d text := pg_get_functiondef('public.app_sigos_os_corrigir'::regproc);
  m text := E'elsif p_mod = ''projetos'' then';
begin
  if position('proj_rec_sgos_set' in d) > 0 then return; end if;   -- já aplicada
  if position(m in d) = 0 then raise exception 'app_sigos_os_corrigir mudou — revisar a migração'; end if;
  d := replace(d, m,
       E'elsif p_mod = ''projetos'' and p_campo = ''OS da recomposição'' then\n'
    || E'    -- OS da recomposição mora no nó da árvore: ref = kind:gid:rótulo do bloco (nomes separados por " › "; vazio = raiz da VCA)\n'
    || E'    update "13 - projetos_obra".intervencao_estado e\n'
    || E'       set arv = "13 - projetos_obra".proj_rec_sgos_set(e.arv, case when substr(p_ref, length(split_part(p_ref, '':'', 1)) + length(split_part(p_ref, '':'', 2)) + 3) = '''' then ''{}''::text[]\n'
    || E'                   else string_to_array(substr(p_ref, length(split_part(p_ref, '':'', 1)) + length(split_part(p_ref, '':'', 2)) + 3), '' › '') end, v_antes, v_nova),\n'
    || E'           atualizado_em = now(), atualizado_por = v_uid\n'
    || E'     where e.kind = split_part(p_ref, '':'', 1) and e.gid::text = split_part(p_ref, '':'', 2)\n'
    || E'       and e.arv is distinct from "13 - projetos_obra".proj_rec_sgos_set(e.arv, case when substr(p_ref, length(split_part(p_ref, '':'', 1)) + length(split_part(p_ref, '':'', 2)) + 3) = '''' then ''{}''::text[]\n'
    || E'                   else string_to_array(substr(p_ref, length(split_part(p_ref, '':'', 1)) + length(split_part(p_ref, '':'', 2)) + 3), '' › '') end, v_antes, v_nova);\n'
    || '  ' || m);
  execute d;
end $mig$;
