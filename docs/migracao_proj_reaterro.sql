-- Projetos · ensaio de compactação do reaterro dentro do projeto (PR 4 do pipeline, 2026-11-02)
-- Todo bloco ativo da árvore de execução com "Reaterro…" + "Recomposição de pavimento" (Vala N, Câmara, Caixa, Obra civil,
-- Peça N; na VCA o bloco é a raiz) só libera a Recomposição depois do ensaio APROVADO pela Qualidade — a mesma esteira e o
-- mesmo formulário do pavimento (pavqual / pavqual_ens, docs/migracao_pav_reaterro.sql).
-- Fluxo: Obras pede (reaterro 100%) → Qualidade ensaia em campo → aprovado libera | reprovado → "Reaterro refeito em" → fila.
-- Legado: blocos que já tinham Recomposição lançada ou Reaterro 100% na virada ficam 'legado' (não travam).
-- Aditivo: tabela nova no schema 13; pav_reaterro_ensaio/evento ganham proj_reaterro_id (pav_id passa a aceitar nulo).
-- app_pav_qual_listar e as RPCs do pavimento não mudam; app_proj_avanco_registrar mantém a assinatura.

-- 1) pedido de ensaio: 1 por bloco da intervenção
create table if not exists "13 - projetos_obra".proj_reaterro (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('ponto','linha')),
  gid bigint not null,
  bloco text not null,                          -- chave estável: '<etapa_modelo.chave>[ › sub…]' ('' = raiz, VCA)
  rotulo text not null,                         -- caminho legível do bloco ('Valas de perfuração › Vala 1'; '' = raiz)
  status text not null check (status in ('aguardando','aprovado','reprovado','legado')),
  status_em timestamptz not null default now(),
  pedido_em timestamptz, pedido_por uuid, pedido_nome text,
  ult_por uuid,                                 -- quem mandou para a fila por último (pedido ou "refeito") — recebe o resultado
  lat numeric, lon numeric, gps_precisao numeric,
  unique (kind, gid, bloco));
alter table "13 - projetos_obra".proj_reaterro enable row level security;   -- deny-all: acesso só via RPC
revoke all on table "13 - projetos_obra".proj_reaterro from public, anon, authenticated;

-- 2) ensaios e eventos do pavimento passam a servir também ao projeto (exatamente um dos dois vínculos)
alter table "8 - coleta_campo".pav_reaterro_ensaio
  add column if not exists proj_reaterro_id uuid references "13 - projetos_obra".proj_reaterro(id);
alter table "8 - coleta_campo".pav_reaterro_ensaio alter column pav_id drop not null;
alter table "8 - coleta_campo".pav_reaterro_evento
  add column if not exists proj_reaterro_id uuid references "13 - projetos_obra".proj_reaterro(id);
alter table "8 - coleta_campo".pav_reaterro_evento alter column pav_id drop not null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pav_reaterro_ensaio_um_vinculo') then
    alter table "8 - coleta_campo".pav_reaterro_ensaio add constraint pav_reaterro_ensaio_um_vinculo
      check (num_nonnulls(pav_id, proj_reaterro_id) = 1);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pav_reaterro_evento_um_vinculo') then
    alter table "8 - coleta_campo".pav_reaterro_evento add constraint pav_reaterro_evento_um_vinculo
      check (num_nonnulls(pav_id, proj_reaterro_id) = 1);
  end if;
end $$;
alter table "8 - coleta_campo".pav_reaterro_evento drop constraint if exists pav_reaterro_evento_evento_check;
alter table "8 - coleta_campo".pav_reaterro_evento add constraint pav_reaterro_evento_evento_check
  check (evento in ('sim','nao','refeito','pedido'));
create unique index if not exists pav_reaterro_ensaio_proj_tent_uq
  on "8 - coleta_campo".pav_reaterro_ensaio (proj_reaterro_id, tentativa) where proj_reaterro_id is not null;
create index if not exists pav_reaterro_evento_proj_idx
  on "8 - coleta_campo".pav_reaterro_evento (proj_reaterro_id) where proj_reaterro_id is not null;

-- o aviso de resultado do pavimento ignora as linhas de projeto (estas avisam pelo trigger do proj_reaterro)
create or replace function "8 - coleta_campo".pav_trg_reaterro_resultado() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare r record;
begin
  if new.pav_id is null then return new; end if;
  select tipo_pavimento, os_sigos, consorcio, reaterro_resp_uuid into r from "8 - coleta_campo".pav_recomposicao where id = new.pav_id;
  perform "9 - suprimentos".sup_notificar(array[r.reaterro_resp_uuid], 'pavimento',
    case when new.resultado = 'aprovado' then '✅ Reaterro aprovado — crie a OS' else '❌ Reaterro reprovado — refazer' end,
    "8 - coleta_campo".pav_tipo_lbl(r.tipo_pavimento)
      || coalesce(' · OS origem ' || r.os_sigos, '')
      || ' · ' || case r.consorcio when 'ZA1004' then 'Contagem' when 'ZA0200' then 'Betim' else coalesce(r.consorcio,'—') end
      || case when new.resultado = 'reprovado' and nullif(btrim(new.obs),'') is not null then ' · ' || left(new.obs, 120) else '' end,
    case when new.resultado = 'aprovado' then 'pavprog_criacao' else 'pavprog_refazer' end, null);
  return new;
end $function$;

-- 3) helpers
-- chave estável do bloco a partir do caminho legível do grupo (nomes da árvore); '' = raiz; null = etapa não reconhecida
create or replace function "13 - projetos_obra".proj_reat_bloco_key(p_tipo text, p_pth text[])
returns text language sql stable security definer set search_path to 'public' as $f$
  select case when coalesce(cardinality(p_pth), 0) = 0 then ''
    else "13 - projetos_obra".proj_etapa_de_rotulo(p_tipo, p_pth[1])
         || case when cardinality(p_pth) > 1 then ' › ' || array_to_string(p_pth[2:], ' › ') else '' end end;
$f$;
-- filhos do grupo no caminho (topo casa pelo rótulo ou pela chave da etapa; abaixo, pelo nome). Raiz = a própria árvore.
create or replace function "13 - projetos_obra".proj_reat_filhos(p_tipo text, p_arv jsonb, p_pth text[])
returns jsonb language plpgsql stable security definer set search_path to 'public' as $f$
declare v_nos jsonb := p_arv; v_no jsonb; i int; v_ch text;
begin
  if jsonb_typeof(p_arv) <> 'array' then return null; end if;
  for i in 1 .. coalesce(cardinality(p_pth), 0) loop
    if i = 1 then
      v_ch := "13 - projetos_obra".proj_etapa_de_rotulo(p_tipo, p_pth[1]);
      select x into v_no from jsonb_array_elements(v_nos) x
       where x->>'n' = p_pth[1] or (v_ch is not null and (x->>'c' = v_ch or "13 - projetos_obra".proj_etapa_de_rotulo(p_tipo, x->>'n') = v_ch))
       order by (x->>'n' = p_pth[1]) desc limit 1;
    else
      select x into v_no from jsonb_array_elements(v_nos) x where x->>'n' = p_pth[i] limit 1;
    end if;
    if v_no is null or coalesce((v_no->>'ativo')::boolean, true) = false or jsonb_typeof(v_no->'f') <> 'array' then return null; end if;
    v_nos := v_no->'f';
  end loop;
  return v_nos;
end $f$;
-- nó "Reaterro…" (%) e "Recomposição de pavimento" (%) entre os filhos
create or replace function "13 - projetos_obra".proj_reat_no(p_filhos jsonb, p_qual text)
returns jsonb language sql immutable as $f$
  select x from jsonb_array_elements(case when jsonb_typeof(p_filhos) = 'array' then p_filhos else '[]'::jsonb end) x
   where x->>'k' = '%' and case p_qual when 'rea' then x->>'n' ilike 'Reaterro%' else x->>'n' = 'Recomposição de pavimento' end
   limit 1;
$f$;
-- histórico do pedido (pedido, ensaios, refeito), em ordem de tempo
create or replace function "13 - projetos_obra".proj_reat_hist(p_id uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $f$
  select coalesce(jsonb_agg(h.j order by h.em), '[]'::jsonb) from (
    select e.created_at em, jsonb_build_object('ev','ensaio','tentativa',e.tentativa,'resultado',e.resultado,'metodo',e.metodo,
      'gc_medido',e.gc_medido,'gc_exigido',e.gc_exigido,'obs',e.obs,'laudo',e.laudo,'foto1',e.foto1,'foto2',e.foto2,
      'dist_m',e.dist_ponto_m,'em',e.created_at,'por',coalesce(e.usuario_nome,e.usuario_email)) j
      from "8 - coleta_campo".pav_reaterro_ensaio e where e.proj_reaterro_id = p_id
    union all
    select v.em, jsonb_build_object('ev',v.evento,'data',v.data,'em',v.em,'por',v.por_nome)
      from "8 - coleta_campo".pav_reaterro_evento v where v.proj_reaterro_id = p_id and v.evento in ('pedido','refeito')
  ) h;
$f$;
-- rótulo curto p/ avisos e fila: "HDD AL 16 F03 · Vala 1"
create or replace function "13 - projetos_obra".proj_reat_lbl(p_kind text, p_gid bigint, p_rotulo text)
returns text language sql stable security definer set search_path to 'public' as $f$
  select upper(coalesce(v.tipo,'')) || ' ' || coalesce(nullif(v.id,''), v.projeto, '#' || p_gid)
    || ' · ' || case when coalesce(p_rotulo,'') = '' then 'Vala da rede'
                     when position(' › ' in p_rotulo) > 0 then substr(p_rotulo, position(' › ' in p_rotulo) + 3) else p_rotulo end
  from "13 - projetos_obra".vw_iv v where v.kind = p_kind and v.gid = p_gid;
$f$;
revoke all on function "13 - projetos_obra".proj_reat_bloco_key(text,text[]), "13 - projetos_obra".proj_reat_filhos(text,jsonb,text[]),
  "13 - projetos_obra".proj_reat_no(jsonb,text), "13 - projetos_obra".proj_reat_hist(uuid),
  "13 - projetos_obra".proj_reat_lbl(text,bigint,text) from public, anon, authenticated;

-- 4) avisos (trigger na tabela de negócio): na fila → Qualidade; resultado → quem pediu / mandou de volta
create or replace function "13 - projetos_obra".proj_trg_reaterro_aviso() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare v_lbl text; v_cid text;
begin
  v_lbl := coalesce("13 - projetos_obra".proj_reat_lbl(new.kind, new.gid, new.rotulo), 'Projeto');
  select case consorcio when 'ZA1004' then 'Contagem' when 'ZA0200' then 'Betim' else '—' end into v_cid
    from "13 - projetos_obra".vw_iv where kind = new.kind and gid = new.gid;
  if new.status = 'aguardando' and (tg_op = 'INSERT' or old.status is distinct from 'aguardando') then
    perform "9 - suprimentos".sup_notificar("8 - coleta_campo".pav_qualidade_uuids(), 'projetos',
      case when tg_op = 'UPDATE' and old.status = 'reprovado' then '🧪 Reaterro refeito — novo ensaio' else '🧪 Ensaio de reaterro a fazer' end,
      '📐 ' || v_lbl || ' · ' || coalesce(v_cid,'—'), 'pavqual', auth.uid());
  elsif tg_op = 'UPDATE' and old.status = 'aguardando' and new.status in ('aprovado','reprovado') then
    perform "9 - suprimentos".sup_notificar(array(select distinct u from unnest(array[new.pedido_por, new.ult_por]) u where u is not null),
      'projetos',
      case when new.status = 'aprovado' then '✅ Reaterro aprovado — recomposição liberada' else '❌ Reaterro reprovado — refazer' end,
      v_lbl || coalesce((select ' · ' || left(e.obs, 120) from "8 - coleta_campo".pav_reaterro_ensaio e
                          where e.proj_reaterro_id = new.id and new.status = 'reprovado' and nullif(btrim(e.obs),'') is not null
                          order by e.tentativa desc limit 1), ''),
      'pj:' || new.kind || ':' || new.gid, null);
  end if;
  return new;
end $function$;
drop trigger if exists proj_reaterro_aviso on "13 - projetos_obra".proj_reaterro;
create trigger proj_reaterro_aviso after insert or update of status on "13 - projetos_obra".proj_reaterro
  for each row execute function "13 - projetos_obra".proj_trg_reaterro_aviso();
revoke all on function "13 - projetos_obra".proj_trg_reaterro_aviso() from public, anon, authenticated;

-- 5) legado: na virada, bloco de intervenção legado com Recomposição lançada ou Reaterro 100% não trava
insert into "13 - projetos_obra".proj_reaterro (kind, gid, bloco, rotulo, status, status_em)
with recursive t as (
  select e.kind, e.gid, v.tipo, x.n node, array[x.n->>'n'] pth
    from "13 - projetos_obra".intervencao_estado e join "13 - projetos_obra".vw_iv v using (kind, gid)
    cross join lateral jsonb_array_elements(case when jsonb_typeof(e.arv) = 'array' then e.arv else '[]'::jsonb end) x(n)
   where coalesce(e.legado, false)
  union all
  select t.kind, t.gid, t.tipo, c.n, t.pth || (c.n->>'n')
    from t cross join lateral jsonb_array_elements(t.node->'f') c(n) where jsonb_typeof(t.node->'f') = 'array'
), g as (
  select kind, gid, tipo, pth, node->'f' filhos from t where jsonb_typeof(node->'f') = 'array'
  union all
  select e.kind, e.gid, v.tipo, '{}'::text[], e.arv
    from "13 - projetos_obra".intervencao_estado e join "13 - projetos_obra".vw_iv v using (kind, gid)
   where coalesce(e.legado, false) and jsonb_typeof(e.arv) = 'array'
)
select kind, gid, "13 - projetos_obra".proj_reat_bloco_key(tipo, pth), array_to_string(pth, ' › '), 'legado', now()
  from g
 where "13 - projetos_obra".proj_reat_no(filhos, 'rea') is not null and "13 - projetos_obra".proj_reat_no(filhos, 'rec') is not null
   and "13 - projetos_obra".proj_reat_bloco_key(tipo, pth) is not null
   and (coalesce(("13 - projetos_obra".proj_reat_no(filhos, 'rec')->>'p')::numeric, 0) > 0
        or coalesce(("13 - projetos_obra".proj_reat_no(filhos, 'rea')->>'p')::numeric, 0) >= 100)
on conflict (kind, gid, bloco) do nothing;

-- 6) RPCs
-- pedidos de 1 intervenção (tela projeto_det) — leitura liberada a quem vê o módulo
create or replace function public.app_proj_reaterro_listar(p_kind text, p_gid bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'bloco',r.bloco,'rotulo',r.rotulo,'status',r.status,
            'status_em',r.status_em,'pedido_em',r.pedido_em,'pedido_nome',r.pedido_nome,
            'hist',"13 - projetos_obra".proj_reat_hist(r.id)) order by r.rotulo), '[]'::jsonb)
            from "13 - projetos_obra".proj_reaterro r where r.kind = p_kind and r.gid = p_gid);
end $function$;

-- Obras pede o ensaio de 1 bloco (reaterro 100%, execução aberta). Idempotente enquanto aguarda.
create or replace function public.app_proj_reaterro_solicitar(p_kind text, p_gid bigint, p_bloco_caminho text,
  p_lat numeric default null, p_lon numeric default null, p_precisao numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid(); v_nome text; v_tipo text; v_arv jsonb; v_pth text[]; v_f jsonb; v_rea jsonb; v_bloco text;
  r "13 - projetos_obra".proj_reaterro; c jsonb;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then raise exception 'intervenção não encontrada'; end if;
  if not coalesce((c->'aberta'->>'4')::boolean, false) then raise exception 'a execução desta intervenção ainda não foi liberada'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  select arv into v_arv from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  v_pth := case when coalesce(btrim(p_bloco_caminho),'') = '' then '{}'::text[] else string_to_array(p_bloco_caminho, ' › ') end;
  v_f := "13 - projetos_obra".proj_reat_filhos(v_tipo, v_arv, v_pth);
  v_rea := "13 - projetos_obra".proj_reat_no(v_f, 'rea');
  if v_rea is null or "13 - projetos_obra".proj_reat_no(v_f, 'rec') is null or coalesce((v_rea->>'ativo')::boolean, true) = false then
    raise exception 'este bloco não tem Reaterro → Recomposição de pavimento no escopo'; end if;
  if coalesce((v_rea->>'p')::numeric, 0) < 100 then raise exception 'o reaterro deste bloco ainda não chegou a 100%%'; end if;
  v_bloco := "13 - projetos_obra".proj_reat_bloco_key(v_tipo, v_pth);
  if v_bloco is null then raise exception 'etapa não reconhecida: %', v_pth[1]; end if;
  select * into r from "13 - projetos_obra".proj_reaterro where kind = p_kind and gid = p_gid and bloco = v_bloco for update;
  if found then
    if r.status = 'aguardando' then return to_jsonb(r); end if;
    if r.status = 'reprovado' then raise exception 'o ensaio foi reprovado — informe quando o reaterro foi refeito'; end if;
    raise exception 'a recomposição deste bloco já está liberada';
  end if;
  if p_precisao is not null and p_precisao > 50 then p_lat := null; p_lon := null; p_precisao := null; end if;   -- GPS ruim não ajuda a achar o local
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  insert into "13 - projetos_obra".proj_reaterro (kind, gid, bloco, rotulo, status, status_em, pedido_em, pedido_por, pedido_nome, ult_por, lat, lon, gps_precisao)
  values (p_kind, p_gid, v_bloco, array_to_string(v_pth, ' › '), 'aguardando', now(), now(), v_id, v_nome, v_id, p_lat, p_lon, p_precisao)
  returning * into r;
  insert into "8 - coleta_campo".pav_reaterro_evento (proj_reaterro_id, evento, por_uuid, por_nome) values (r.id, 'pedido', v_id, v_nome);
  return to_jsonb(r);
end $function$;

-- reaterro reprovado foi refeito → volta para a fila da Qualidade
create or replace function public.app_proj_reaterro_refeito(p_id uuid, p_data date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid(); v_nome text; v_st text; v_ult timestamptz;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  if p_data is null then raise exception 'informe o dia em que o reaterro foi refeito'; end if;
  select status into v_st from "13 - projetos_obra".proj_reaterro where id = p_id for update;
  if not found then raise exception 'pedido de ensaio não encontrado'; end if;
  if v_st is distinct from 'reprovado' then raise exception 'o reaterro deste bloco não está reprovado'; end if;
  if p_data > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'data no futuro'; end if;
  select max(created_at) into v_ult from "8 - coleta_campo".pav_reaterro_ensaio where proj_reaterro_id = p_id;
  if p_data < (v_ult at time zone 'America/Sao_Paulo')::date then raise exception 'data anterior ao ensaio reprovado'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  update "13 - projetos_obra".proj_reaterro set status = 'aguardando', status_em = now(), ult_por = v_id where id = p_id;
  insert into "8 - coleta_campo".pav_reaterro_evento (proj_reaterro_id, evento, data, por_uuid, por_nome) values (p_id, 'refeito', p_data, v_id, v_nome);
  return 1;
end $function$;

-- Qualidade registra o ensaio do bloco (campo, pela fila offline: laudo/fotos já subidos). Idempotente por p_id.
create or replace function public.app_proj_reaterro_ensaio(p_id uuid, p_req_id uuid, p_resultado text, p_metodo text,
  p_gc_medido numeric, p_gc_exigido numeric, p_obs text, p_laudo text, p_foto1 text, p_foto2 text,
  p_lat numeric, p_lon numeric, p_precisao numeric, p_dispositivo text)
returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid(); v_email text := coalesce(auth.jwt()->>'email',''); v_nome text; r record; v_t int; v_geom geometry; v_dist numeric;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "8 - coleta_campo".pav_qualidade_pode(v_id) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "8 - coleta_campo".pav_reaterro_ensaio where id = p_id) then return p_id; end if;  -- reenvio da fila
  if p_resultado is null or p_resultado not in ('aprovado','reprovado') then raise exception 'informe o resultado (aprovado ou reprovado)'; end if;
  if nullif(btrim(p_metodo),'') is null then raise exception 'informe o método do ensaio'; end if;
  if nullif(p_laudo,'') is null then raise exception 'o laudo é obrigatório'; end if;
  if nullif(p_foto1,'') is null then raise exception 'a foto do ensaio é obrigatória'; end if;
  if p_resultado = 'reprovado' and nullif(btrim(p_obs),'') is null then raise exception 'descreva o motivo da reprovação'; end if;
  if (p_gc_medido is not null and (p_gc_medido <= 0 or p_gc_medido > 200)) or (p_gc_exigido is not null and (p_gc_exigido <= 0 or p_gc_exigido > 200)) then
    raise exception 'grau de compactação fora da faixa (0–200%%)'; end if;
  if p_lat is null or p_lon is null then raise exception 'coordenada obrigatória'; end if;
  if p_precisao is null or p_precisao > 15 then raise exception 'GPS sem precisão suficiente (≤ 15 m)'; end if;
  select kind, gid, status into r from "13 - projetos_obra".proj_reaterro where id = p_req_id for update;
  if not found then raise exception 'pedido de ensaio não encontrado'; end if;
  if r.status is distinct from 'aguardando' then raise exception 'este bloco não está aguardando ensaio de reaterro'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  select coalesce(max(tentativa),0)+1 into v_t from "8 - coleta_campo".pav_reaterro_ensaio where proj_reaterro_id = p_req_id;
  v_geom := st_setsrid(st_makepoint(p_lon, p_lat), 4326);
  select round(st_distance(st_transform(v_geom, 31983), g.geom)::numeric, 1) into v_dist from (
    select geom from "7 - setorizacao".intervencoes_pontuais where r.kind = 'ponto' and gid = r.gid
    union all select geom from "7 - setorizacao".intervencoes_lineares where r.kind = 'linha' and gid = r.gid) g;
  insert into "8 - coleta_campo".pav_reaterro_ensaio
    (id, pav_id, proj_reaterro_id, tentativa, resultado, metodo, gc_medido, gc_exigido, obs, laudo, foto1, foto2, lat, lon, gps_precisao, geom,
     dist_ponto_m, dispositivo, usuario_uuid, usuario_email, usuario_nome)
  values (p_id, null, p_req_id, v_t, p_resultado, btrim(p_metodo), p_gc_medido, p_gc_exigido, nullif(btrim(p_obs),''), p_laudo, p_foto1, nullif(p_foto2,''),
     p_lat, p_lon, p_precisao, v_geom, v_dist, p_dispositivo, v_id, v_email, v_nome);
  update "13 - projetos_obra".proj_reaterro set status = p_resultado, status_em = now() where id = p_req_id;
  return p_id;
end $function$;

-- fila da Qualidade (tela pavqual): pavimento (app_pav_qual_listar, sem mudança) + pedidos dos projetos
create or replace function public.app_qual_reaterro_fila(p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not "8 - coleta_campo".pav_qualidade_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object('pav', public.app_pav_qual_listar(p_consorcio), 'proj', (
    select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'kind',r.kind,'gid',r.gid,'bloco',r.bloco,'rotulo',r.rotulo,
             'lbl',"13 - projetos_obra".proj_reat_lbl(r.kind, r.gid, r.rotulo),'tipo',v.tipo,'projeto',v.projeto,'cod',v.id,'consorcio',v.consorcio,
             'status_em',r.status_em,'pedido_em',r.pedido_em,'pedido_nome',r.pedido_nome,
             'lat',coalesce(r.lat, st_y(p.pt)),'lon',coalesce(r.lon, st_x(p.pt)),
             'hist',"13 - projetos_obra".proj_reat_hist(r.id)) order by r.status_em), '[]'::jsonb)
      from "13 - projetos_obra".proj_reaterro r
      join "13 - projetos_obra".vw_iv v on v.kind = r.kind and v.gid = r.gid
      left join lateral (select st_transform(st_pointonsurface(g.geom), 4326) pt from (
          select geom from "7 - setorizacao".intervencoes_pontuais where r.kind = 'ponto' and gid = r.gid
          union all select geom from "7 - setorizacao".intervencoes_lineares where r.kind = 'linha' and gid = r.gid) g limit 1) p on true
     where r.status = 'aguardando' and (p_consorcio is null or v.consorcio = p_consorcio)));
end $function$;

-- trava no servidor: Recomposição de pavimento de bloco com Reaterro ativo só com ensaio aprovado (ou legado)
create or replace function public.app_proj_avanco_registrar(p_kind text, p_gid bigint, p_iv_cod text, p_iv_local text, p_consorcio text,
  p_tipo text, p_caminho text, p_atividade text, p_sub text, p_valor numeric, p_unidade text,
  p_obs text default null, p_fotos text[] default '{}'::text[], p_equipe text default null)
returns jsonb language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_nome text; v_row "13 - projetos_obra".intervencao_avanco; c jsonb;
  v_segs text[]; v_pth text[]; v_tipo text; v_arv jsonb; v_rea jsonb;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
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
  insert into "13 - projetos_obra".intervencao_avanco(kind,gid,iv_cod,iv_local,consorcio,tipo,caminho,atividade,sub,valor,unidade,obs,fotos,autor,autor_nome,equipe)
  values(p_kind,p_gid,p_iv_cod,p_iv_local,p_consorcio,p_tipo,p_caminho,p_atividade,p_sub,p_valor,p_unidade,p_obs,coalesce(p_fotos,'{}'),v_id,v_nome,coalesce(p_equipe,v_nome))
  returning * into v_row;
  return to_jsonb(v_row);
end $function$;

revoke all on function public.app_proj_reaterro_listar(text,bigint), public.app_proj_reaterro_solicitar(text,bigint,text,numeric,numeric,numeric),
  public.app_proj_reaterro_refeito(uuid,date),
  public.app_proj_reaterro_ensaio(uuid,uuid,text,text,numeric,numeric,text,text,text,text,numeric,numeric,numeric,text),
  public.app_qual_reaterro_fila(text) from public, anon;
grant execute on function public.app_proj_reaterro_listar(text,bigint), public.app_proj_reaterro_solicitar(text,bigint,text,numeric,numeric,numeric),
  public.app_proj_reaterro_refeito(uuid,date),
  public.app_proj_reaterro_ensaio(uuid,uuid,text,text,numeric,numeric,text,text,text,text,numeric,numeric,numeric,text),
  public.app_qual_reaterro_fila(text) to authenticated;
