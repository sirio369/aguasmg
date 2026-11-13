-- =====================================================================================================
-- Projetos · "É necessário ensaio de compactação?" após o reaterro 100% (2026-11-13)
--
-- Todo bloco Reaterro → Recomposição de pavimento (Vala N, Ramal N, Câmara, Caixa, Obra civil, Peça; raiz na VCA), ao
-- chegar o reaterro em 100%, pergunta a Obras se precisa de ensaio:
--   Sim → pipeline do ensaio de sempre (status 'aguardando' → Qualidade na pavqual);
--   Não → status novo 'dispensado' (evento 'nao' em pav_reaterro_evento) e a recomposição fica liberada.
-- Dispensado com a recomposição ainda em 0% pode voltar a pedir ensaio (Sim depois).
-- Legado: os blocos 'legado' cujo pavimento ainda NÃO foi lançado (recomposição 0%) deixam de ser legado e caem na
-- pergunta; os que já têm recomposição lançada seguem legado.
-- Ramais ganham Reaterro + Recomposição de pavimento no front (árvore) — o banco já trata qualquer grupo com o par.
-- =====================================================================================================

-- 1) status novo
alter table "13 - projetos_obra".proj_reaterro drop constraint proj_reaterro_status_check;
alter table "13 - projetos_obra".proj_reaterro add constraint proj_reaterro_status_check
  check (status = any (array['aguardando','aprovado','reprovado','legado','dispensado']));

-- 2) decisão de Obras (Sim = pede ensaio; Não = dispensa)
create or replace function public.app_proj_reaterro_decidir(p_kind text, p_gid bigint, p_bloco_caminho text, p_necessita boolean,
  p_lat numeric default null, p_lon numeric default null, p_precisao numeric default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid := auth.uid(); v_nome text; v_tipo text; v_arv jsonb; v_pth text[]; v_f jsonb; v_rea jsonb; v_rec jsonb; v_bloco text;
  r "13 - projetos_obra".proj_reaterro; c jsonb;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if p_necessita is null then raise exception 'responda se é necessário ensaio de compactação'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then raise exception 'intervenção não encontrada'; end if;
  if not coalesce((c->'aberta'->>'4')::boolean, false) then raise exception 'a execução desta intervenção ainda não foi liberada'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  select arv into v_arv from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  v_pth := case when coalesce(btrim(p_bloco_caminho),'') = '' then '{}'::text[] else string_to_array(p_bloco_caminho, ' › ') end;
  v_f := "13 - projetos_obra".proj_reat_filhos(v_tipo, v_arv, v_pth);
  v_rea := "13 - projetos_obra".proj_reat_no(v_f, 'rea'); v_rec := "13 - projetos_obra".proj_reat_no(v_f, 'rec');
  if v_rea is null or v_rec is null or coalesce((v_rea->>'ativo')::boolean, true) = false then
    raise exception 'este bloco não tem Reaterro → Recomposição de pavimento no escopo'; end if;
  if coalesce((v_rea->>'p')::numeric, 0) < 100 then raise exception 'o reaterro deste bloco ainda não chegou a 100%%'; end if;
  v_bloco := "13 - projetos_obra".proj_reat_bloco_key(v_tipo, v_pth);
  if v_bloco is null then raise exception 'etapa não reconhecida: %', v_pth[1]; end if;
  if p_precisao is not null and p_precisao > 50 then p_lat := null; p_lon := null; p_precisao := null; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  select * into r from "13 - projetos_obra".proj_reaterro where kind = p_kind and gid = p_gid and bloco = v_bloco for update;
  if found then
    if p_necessita and r.status = 'aguardando' then return to_jsonb(r); end if;
    if not p_necessita and r.status = 'dispensado' then return to_jsonb(r); end if;
    if p_necessita and r.status = 'dispensado' then   -- mudou de ideia: só enquanto o pavimento não foi lançado
      if coalesce((v_rec->>'p')::numeric, 0) > 0 then raise exception 'a recomposição deste bloco já foi lançada — não dá mais para pedir o ensaio'; end if;
      update "13 - projetos_obra".proj_reaterro set status = 'aguardando', status_em = now(), pedido_em = now(), pedido_por = v_id,
             pedido_nome = v_nome, ult_por = v_id, lat = coalesce(p_lat, lat), lon = coalesce(p_lon, lon), gps_precisao = coalesce(p_precisao, gps_precisao)
       where id = r.id returning * into r;
      insert into "8 - coleta_campo".pav_reaterro_evento (proj_reaterro_id, evento, por_uuid, por_nome) values (r.id, 'pedido', v_id, v_nome);
      return to_jsonb(r);
    end if;
    if r.status = 'reprovado' then raise exception 'o ensaio foi reprovado — informe quando o reaterro foi refeito'; end if;
    if r.status = 'aguardando' then raise exception 'o ensaio já foi pedido à Qualidade'; end if;
    raise exception 'a recomposição deste bloco já está liberada';
  end if;
  insert into "13 - projetos_obra".proj_reaterro (kind, gid, bloco, rotulo, status, status_em, pedido_em, pedido_por, pedido_nome, ult_por, lat, lon, gps_precisao)
  values (p_kind, p_gid, v_bloco, array_to_string(v_pth, ' › '), case when p_necessita then 'aguardando' else 'dispensado' end,
          now(), now(), v_id, v_nome, v_id, p_lat, p_lon, p_precisao)
  returning * into r;
  insert into "8 - coleta_campo".pav_reaterro_evento (proj_reaterro_id, evento, por_uuid, por_nome)
  values (r.id, case when p_necessita then 'pedido' else 'nao' end, v_id, v_nome);
  return to_jsonb(r);
end $function$;
revoke all on function public.app_proj_reaterro_decidir(text,bigint,text,boolean,numeric,numeric,numeric) from public, anon;
grant execute on function public.app_proj_reaterro_decidir(text,bigint,text,boolean,numeric,numeric,numeric) to authenticated;

-- 3a) trava da recomposição: "dispensado" libera como "aprovado"/"legado" (lançar avanço)
create or replace function public.app_proj_avanco_registrar(p_kind text, p_gid bigint, p_iv_cod text, p_iv_local text, p_consorcio text,
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
                        where r.kind = p_kind and r.gid = p_gid and r.status in ('aprovado','legado','dispensado')
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

-- 3b) idem ao gravar a árvore (mantém a guarda das valas com avanço)
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
                      where r.kind = p_kind and r.gid = p_gid and r.bloco = b.bloco and r.status in ('aprovado','legado','dispensado'))
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

-- 4) histórico do bloco e Resumo mostram a dispensa
create or replace function "13 - projetos_obra".proj_reat_hist(p_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(h.j order by h.em), '[]'::jsonb) from (
    select e.created_at em, jsonb_build_object('ev','ensaio','tentativa',e.tentativa,'resultado',e.resultado,'metodo',e.metodo,
      'gc_medido',e.gc_medido,'gc_exigido',e.gc_exigido,'obs',e.obs,'laudo',e.laudo,'foto1',e.foto1,'foto2',e.foto2,
      'dist_m',e.dist_ponto_m,'em',e.created_at,'por',coalesce(e.usuario_nome,e.usuario_email)) j
      from "8 - coleta_campo".pav_reaterro_ensaio e where e.proj_reaterro_id = p_id
    union all
    select v.em, jsonb_build_object('ev',case v.evento when 'nao' then 'dispensado' else v.evento end,'data',v.data,'em',v.em,'por',v.por_nome)
      from "8 - coleta_campo".pav_reaterro_evento v where v.proj_reaterro_id = p_id and v.evento in ('pedido','refeito','nao')
  ) h;
$function$;

create or replace function public.app_proj_eventos(p_de date default null::date, p_ate date default null::date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(z.j order by z.em desc, z.ord desc) from (
    select e.em, lpad(e.id::text, 12, '0') ord, jsonb_build_object('id',e.id,'kind',e.kind,'gid',e.gid,'iv',v.id,'projeto',v.projeto,
        'cidade',v.cidade,'consorcio',v.consorcio,'tipo',v.tipo,'chave',e.chave,
        'nome',"13 - projetos_obra".proj_etapa_nome(e.chave, m.nome, v.consorcio, v.cidade),'ator',m.ator,'natureza',m.natureza,
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
               case ev.evento when 'pedido' then 'ensaio_pedido' when 'nao' then 'ensaio_dispensado' else 'reaterro_refeito' end evento, 'obra' ator, null::text valor,
               case when ev.evento = 'refeito' then 'refeito em ' || to_char(ev.data, 'DD/MM/YYYY') end comentario, ev.por_nome por
          from "8 - coleta_campo".pav_reaterro_evento ev
         where ev.proj_reaterro_id is not null and ev.evento in ('pedido','refeito','nao')
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
end $function$;

-- 5) legado sem pavimento lançado volta para a pergunta (os com recomposição lançada seguem legado)
delete from "13 - projetos_obra".proj_reaterro r
 using "13 - projetos_obra".intervencao_estado e, "13 - projetos_obra".vw_iv v
 where r.status = 'legado' and e.kind = r.kind and e.gid = r.gid and v.kind = r.kind and v.gid = r.gid
   and not exists (select 1 from "8 - coleta_campo".pav_reaterro_evento ev where ev.proj_reaterro_id = r.id)
   and not exists (select 1 from "8 - coleta_campo".pav_reaterro_ensaio en where en.proj_reaterro_id = r.id)
   and exists (select 1 from "13 - projetos_obra".proj_reat_blocos(v.tipo, e.arv) b
                where b.bloco = r.bloco and coalesce((b.rec->>'p')::numeric, 0) = 0);
