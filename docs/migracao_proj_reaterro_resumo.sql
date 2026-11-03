-- Projetos · ensaio de reaterro (complemento do PR 4, 2026-11-03): achados do QA em produção
-- 1) o Resumo (app_proj_eventos) passa a trazer os eventos do ensaio de projeto: pedido, refeito, aprovado, reprovado
-- 2) a trava da Recomposição também vale ao gravar a árvore (app_proj_estado_set): uma chamada direta à API não consegue
--    subir o % da Recomposição de um bloco com Reaterro no escopo sem ensaio aprovado (ou legado).
-- Assinaturas iguais; app em cache continua funcionando.

-- blocos Reaterro → Recomposição de uma árvore (grupos ativos; '' = raiz, VCA)
create or replace function "13 - projetos_obra".proj_reat_blocos(p_tipo text, p_arv jsonb)
returns table(bloco text, rotulo text, rea jsonb, rec jsonb) language sql stable security definer set search_path to 'public' as $f$
  with recursive t as (
    select x.n node, array[x.n->>'n'] pth
      from jsonb_array_elements(case when jsonb_typeof(p_arv) = 'array' then p_arv else '[]'::jsonb end) x(n)
     where coalesce((x.n->>'ativo')::boolean, true)
    union all
    select c.n, t.pth || (c.n->>'n')
      from t cross join lateral jsonb_array_elements(t.node->'f') c(n)
     where jsonb_typeof(t.node->'f') = 'array' and coalesce((c.n->>'ativo')::boolean, true)
  ), g as (
    select pth, node->'f' filhos from t where jsonb_typeof(node->'f') = 'array'
    union all
    select '{}'::text[], p_arv where jsonb_typeof(p_arv) = 'array'
  )
  select "13 - projetos_obra".proj_reat_bloco_key(p_tipo, g.pth), array_to_string(g.pth, ' › '),
         "13 - projetos_obra".proj_reat_no(g.filhos, 'rea'), "13 - projetos_obra".proj_reat_no(g.filhos, 'rec')
    from g
   where "13 - projetos_obra".proj_reat_no(g.filhos, 'rea') is not null and "13 - projetos_obra".proj_reat_no(g.filhos, 'rec') is not null;
$f$;
revoke all on function "13 - projetos_obra".proj_reat_blocos(text,jsonb) from public, anon, authenticated;

-- árvore: só Engenharia ou responsáveis de obras; cadeado só pela Engenharia; Recomposição sem ensaio aprovado não sobe
create or replace function public.app_proj_estado_set(p_kind text, p_gid bigint, p_arv jsonb, p_locked boolean default false, p_status text default null)
returns void language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_eng boolean; v_lock_old boolean; v_leg boolean; v_lock boolean; v_falta text; v_nome text;
  v_tipo text; v_arv_old jsonb; v_bloq text;
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

-- Resumo: eventos do pipeline + do ensaio de reaterro de projeto (natureza 'ensaio'; eventos ensaio_pedido,
-- reaterro_refeito, ensaio_aprovado, ensaio_reprovado — nomes próprios p/ não somar com aprovado/reprovado de documento)
create or replace function public.app_proj_eventos(p_de date default null, p_ate date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(z.j order by z.em desc, z.ord desc) from (
    select e.em, lpad(e.id::text, 12, '0') ord, jsonb_build_object('id',e.id,'kind',e.kind,'gid',e.gid,'iv',v.id,'projeto',v.projeto,
        'cidade',v.cidade,'consorcio',v.consorcio,'tipo',v.tipo,'chave',e.chave,'nome',m.nome,'ator',m.ator,'natureza',m.natureza,
        'evento',e.evento,'valor',e.valor,'comentario',e.comentario,'por',e.por_nome,'em',e.em) j
      from (select * from "13 - projetos_obra".intervencao_etapa_evento x
             where x.evento <> 'legado'
               and (p_de is null or (x.em at time zone 'America/Sao_Paulo')::date >= p_de)
               and (p_ate is null or (x.em at time zone 'America/Sao_Paulo')::date <= p_ate)
             order by x.em desc limit 3000) e
      left join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
      left join "13 - projetos_obra".etapa_modelo m on m.tipo = v.tipo and m.chave = e.chave
    union all
    select q.em, q.ord, jsonb_build_object('id',q.ord,'kind',r.kind,'gid',r.gid,'iv',v.id,'projeto',v.projeto,'cidade',v.cidade,
        'consorcio',v.consorcio,'tipo',v.tipo,'chave','ensaio_reaterro',
        'nome','Ensaio de reaterro · ' || case when r.rotulo = '' then 'Vala da rede' else r.rotulo end,
        'ator',q.ator,'natureza','ensaio','evento',q.evento,'valor',q.valor,'comentario',q.comentario,'por',q.por,'em',q.em) j
      from (
        select ev.proj_reaterro_id rid, ev.em, 'ev' || lpad(ev.id::text, 10, '0') ord,
               case ev.evento when 'pedido' then 'ensaio_pedido' else 'reaterro_refeito' end evento, 'obra' ator, null::text valor,
               case when ev.evento = 'refeito' then 'refeito em ' || to_char(ev.data, 'DD/MM/YYYY') end comentario, ev.por_nome por
          from "8 - coleta_campo".pav_reaterro_evento ev
         where ev.proj_reaterro_id is not null and ev.evento in ('pedido','refeito')
        union all
        select en.proj_reaterro_id, en.created_at, 'en' || en.id::text, 'ensaio_' || en.resultado, 'qual', en.tentativa::text, en.obs,
               coalesce(en.usuario_nome, en.usuario_email)
          from "8 - coleta_campo".pav_reaterro_ensaio en
         where en.proj_reaterro_id is not null
      ) q
      join "13 - projetos_obra".proj_reaterro r on r.id = q.rid
      left join "13 - projetos_obra".vw_iv v on v.kind = r.kind and v.gid = r.gid
     where (p_de is null or (q.em at time zone 'America/Sao_Paulo')::date >= p_de)
       and (p_ate is null or (q.em at time zone 'America/Sao_Paulo')::date <= p_ate)
  ) z), '[]'::jsonb);
end $f$;
