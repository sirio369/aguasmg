-- =====================================================================================================
-- Projetos · HDD valas pela equipe de obras + "Esse avanço foi realizado ontem?" (2026-11-13)
--
-- 1) intervencao_avanco: `ts` passa a ser o MOMENTO DA EXECUÇÃO (o que Resumo/RDO/Consolidador/Vitrine já
--    leem como data do avanço). Colunas novas: `registrado_em` (quando foi lançado no app) e `retroativo`
--    (true = lançado no dia seguinte, com a hora informada). Linhas antigas: registrado_em = ts.
-- 2) app_proj_avanco_registrar ganha `p_executado_em` (opcional, default null = rito normal, ts = now()).
--    Só aceita data = ONTEM no fuso de Brasília. Drop + create (não deixa overload ambíguo); o app antigo
--    (sem o parâmetro) continua funcionando porque o parâmetro novo tem default.
-- 3) app_proj_estado_set: recusa gravar a árvore se uma "Vala N" das Valas de perfuração (HDD) que tinha
--    avanço (na árvore ou no log) sumir — a equipe de obras só remove vala sem avanço.
-- =====================================================================================================

-- 1) colunas novas
alter table "13 - projetos_obra".intervencao_avanco add column if not exists registrado_em timestamptz;
alter table "13 - projetos_obra".intervencao_avanco add column if not exists retroativo boolean not null default false;
update "13 - projetos_obra".intervencao_avanco set registrado_em = ts where registrado_em is null;
alter table "13 - projetos_obra".intervencao_avanco alter column registrado_em set default now();
alter table "13 - projetos_obra".intervencao_avanco alter column registrado_em set not null;

-- 2) registrar avanço com data de execução opcional (ontem)
drop function if exists public.app_proj_avanco_registrar(text,bigint,text,text,text,text,text,text,text,numeric,text,text,text[],text);
create function public.app_proj_avanco_registrar(p_kind text, p_gid bigint, p_iv_cod text, p_iv_local text, p_consorcio text,
  p_tipo text, p_caminho text, p_atividade text, p_sub text, p_valor numeric, p_unidade text, p_obs text default null,
  p_fotos text[] default '{}'::text[], p_equipe text default null, p_executado_em timestamptz default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', '13 - projetos_obra'
as $function$
declare v_id uuid := auth.uid(); v_nome text; v_row "13 - projetos_obra".intervencao_avanco; c jsonb;
  v_segs text[]; v_pth text[]; v_tipo text; v_arv jsonb; v_rea jsonb;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  if p_executado_em is not null and (p_executado_em at time zone 'America/Sao_Paulo')::date <> v_hoje - 1 then
    raise exception 'Avanço de ontem: a data de execução tem de ser %', to_char(v_hoje - 1, 'DD/MM/YYYY');
  end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then raise exception 'intervenção não encontrada'; end if;
  if not coalesce((c->'aberta'->>'4')::boolean, false) then raise exception 'a execução desta intervenção ainda não foi liberada'; end if;
  v_segs := string_to_array(coalesce(p_caminho, ''), ' › ');
  if v_segs[cardinality(v_segs)] = 'Recomposição de pavimento' then
    v_pth := v_segs[1:cardinality(v_segs)-1];
    select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
    select arv into v_arv from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
    v_rea := "13 - projetos_obra".proj_reat_no("13 - projetos_obra".proj_reat_filhos(v_tipo, v_arv, v_pth), 'rea');
    if v_rea is not null and coalesce((v_rea->>'ativo')::boolean, true)
       and not exists (select 1 from "13 - projetos_obra".proj_reaterro r
                        where r.kind = p_kind and r.gid = p_gid and r.status in ('aprovado','legado')
                          and r.bloco = "13 - projetos_obra".proj_reat_bloco_key(v_tipo, v_pth)) then
      raise exception 'Recomposição de pavimento travada: falta o ensaio de compactação do reaterro aprovado pela Qualidade';
    end if;
  end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  insert into "13 - projetos_obra".intervencao_avanco(kind,gid,iv_cod,iv_local,consorcio,tipo,caminho,atividade,sub,valor,unidade,obs,fotos,autor,autor_nome,equipe,ts,registrado_em,retroativo)
  values(p_kind,p_gid,p_iv_cod,p_iv_local,p_consorcio,p_tipo,p_caminho,p_atividade,p_sub,p_valor,p_unidade,p_obs,coalesce(p_fotos,'{}'),v_id,v_nome,coalesce(p_equipe,v_nome),
         coalesce(p_executado_em, now()), now(), p_executado_em is not null)
  returning * into v_row;
  return to_jsonb(v_row);
end $function$;
revoke all on function public.app_proj_avanco_registrar(text,bigint,text,text,text,text,text,text,text,numeric,text,text,text[],text,timestamptz) from public, anon;
grant execute on function public.app_proj_avanco_registrar(text,bigint,text,text,text,text,text,text,text,numeric,text,text,text[],text,timestamptz) to authenticated;

-- 3) gravar a árvore: não deixa sumir vala de perfuração com avanço
create or replace function public.app_proj_estado_set(p_kind text, p_gid bigint, p_arv jsonb, p_locked boolean default false, p_status text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', '13 - projetos_obra'
as $function$
declare v_id uuid := auth.uid(); v_eng boolean; v_lock_old boolean; v_leg boolean; v_lock boolean; v_falta text; v_nome text;
  v_tipo text; v_arv_old jsonb; v_bloq text; v_val_old jsonb; v_val_new jsonb; v_vala text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if p_kind not in ('ponto','linha') then raise exception 'kind inválido'; end if;
  v_eng := "13 - projetos_obra".proj_eng_pode(v_id);
  if not (v_eng or "13 - projetos_obra".proj_obras_pode(v_id)) then raise exception 'sem permissão (Projetos · Engenharia ou responsáveis de obras)'; end if;
  select locked, legado, arv into v_lock_old, v_leg, v_arv_old from "13 - projetos_obra".intervencao_estado where kind=p_kind and gid=p_gid;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  select b.rotulo into v_bloq
    from "13 - projetos_obra".proj_reat_blocos(v_tipo, p_arv) b
    left join "13 - projetos_obra".proj_reat_blocos(v_tipo, v_arv_old) o on o.bloco = b.bloco
   where coalesce((b.rea->>'ativo')::boolean, true)
     and coalesce((b.rec->>'p')::numeric, 0) > coalesce((o.rec->>'p')::numeric, 0)
     and not exists (select 1 from "13 - projetos_obra".proj_reaterro r
                      where r.kind = p_kind and r.gid = p_gid and r.bloco = b.bloco and r.status in ('aprovado','legado'))
   limit 1;
  if found then
    raise exception 'Recomposição de pavimento travada (%): falta o ensaio de compactação do reaterro aprovado pela Qualidade',
      coalesce(nullif(v_bloq, ''), 'vala da rede');
  end if;
  -- valas de perfuração (HDD): vala que sumiu da árvore não pode ter avanço (na árvore gravada ou no log)
  if jsonb_typeof(v_arv_old) = 'array' then
    select e->'f' into v_val_old from jsonb_array_elements(v_arv_old) e where e->>'c' = 'av_valas' limit 1;
    if jsonb_typeof(p_arv) = 'array' then
      select e->'f' into v_val_new from jsonb_array_elements(p_arv) e where e->>'c' = 'av_valas' limit 1;
    end if;
    if jsonb_typeof(v_val_old) = 'array' then
      select o->>'n' into v_vala
        from jsonb_array_elements(v_val_old) o
       where o->>'k' = 'g'
         and not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(v_val_new) = 'array' then v_val_new else '[]'::jsonb end) n
                          where n->>'n' = o->>'n')
         and (jsonb_path_exists(o, '$.** ? (@.p > 0 || @.exec > 0)')
              or exists (select 1 from "13 - projetos_obra".intervencao_avanco a
                          where a.kind = p_kind and a.gid = p_gid and a.etapa = 'av_valas'
                            and split_part(a.caminho, ' › ', 2) = o->>'n'))
       limit 1;
      if v_vala is not null then raise exception '% tem avanço lançado e não pode ser removida', v_vala; end if;
    end if;
  end if;
  v_lock := coalesce(v_lock_old, false);
  if v_eng and coalesce(p_locked, false) <> v_lock then
    if p_locked and not coalesce(v_leg, false) then
      v_falta := "13 - projetos_obra".proj_f1_falta(p_kind, p_gid);
      if v_falta is not null then raise exception 'Para liberar, anexe (com o tamanho da folha): %', v_falta; end if;
    end if;
    v_lock := coalesce(p_locked, false);
  end if;
  insert into "13 - projetos_obra".intervencao_estado(kind,gid,arv,locked,status,atualizado_por,liberado_em)
  values(p_kind,p_gid,p_arv,v_lock,p_status,v_id,case when v_lock then now() end)
  on conflict (kind,gid) do update set arv=excluded.arv, locked=excluded.locked, status=excluded.status,
    liberado_em = case when excluded.locked and not intervencao_estado.locked then now() else intervencao_estado.liberado_em end,
    atualizado_em=now(), atualizado_por=v_id;
  if v_lock <> coalesce(v_lock_old, false) then
    select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, por_uuid, por_nome)
    values (p_kind, p_gid, case when v_lock then 'liberado' else 'reaberto' end, v_id, v_nome);
  end if;
end $function$;
