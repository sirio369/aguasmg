-- Gestão de Pavimento: ENSAIO DE COMPACTAÇÃO DO REATERRO (equipe de Qualidade), por tipo. 2026-11-02.
-- Antes de lançar a OS da recomposição, o programador responde, por tipo, "Necessita ensaio de compactação do reaterro?".
--   Não        → segue para a criação da OS (como antes).
--   Sim        → o tipo entra na fila da Qualidade (tela pavqual); a OS fica travada até o ensaio ser aprovado.
--   Aprovado   → libera a criação da OS.
--   Reprovado  → "Reaterro a refazer" → o programador marca "Reaterro refeito em [data]" → volta pra fila (nova tentativa).
-- Ensaios e eventos são append-only (nada se apaga nem se altera). Avisos por trigger (sup_notificar):
--   entrou na fila → equipe da Qualidade · resultado → só quem pediu o ensaio (reaterro_resp_uuid).
-- ADITIVA: o app em produção (≤ v313) segue igual. A trava no banco (não lançar OS sem resposta / sem aprovação) está em
-- migracao_pav_reaterro_trava.sql — aplicar DEPOIS que o front v314 estiver no ar.
-- Idempotente.

-- 1) colunas na pav_recomposicao (1 linha por tipo)
alter table "8 - coleta_campo".pav_recomposicao
  add column if not exists reaterro_necessario boolean,      -- null = ainda não respondido
  add column if not exists reaterro_resp_em timestamptz,     -- quando respondeu
  add column if not exists reaterro_resp_por text,           -- quem respondeu (nome)
  add column if not exists reaterro_resp_uuid uuid,          -- quem respondeu = quem pediu o ensaio (recebe o aviso do resultado)
  add column if not exists reaterro_status text,             -- aguardando | reprovado | aprovado (só com reaterro_necessario)
  add column if not exists reaterro_status_em timestamptz;   -- início da situação atual (relógio da etapa)
do $$ begin
  if not exists (select 1 from pg_constraint where conname='pav_reaterro_status_ck') then
    alter table "8 - coleta_campo".pav_recomposicao add constraint pav_reaterro_status_ck check (
      coalesce(reaterro_necessario,false) = (reaterro_status is not null)
      and (reaterro_status is null or reaterro_status in ('aguardando','reprovado','aprovado')));
  end if;
end $$;
create index if not exists pav_recomposicao_reaterro_idx on "8 - coleta_campo".pav_recomposicao (reaterro_status) where reaterro_status is not null;

-- 2) ensaios (1 por tentativa) e eventos (sim / não / reaterro refeito) — append-only
create table if not exists "8 - coleta_campo".pav_reaterro_ensaio (
  id uuid primary key,                                        -- gerado no app (idempotência da fila offline)
  pav_id uuid not null references "8 - coleta_campo".pav_recomposicao(id),
  tentativa int not null,
  resultado text not null check (resultado in ('aprovado','reprovado')),
  metodo text not null,
  gc_medido numeric, gc_exigido numeric,                     -- grau de compactação (%), opcionais
  obs text,                                                   -- obrigatória na reprovação
  laudo text not null,                                        -- path no bucket fotos-campo (PDF ou foto)
  foto1 text not null, foto2 text,
  lat numeric not null, lon numeric not null, gps_precisao numeric,
  geom geometry(Point,4326),
  dist_ponto_m numeric,                                       -- distância até o ponto do pavimento
  dispositivo text,
  usuario_uuid uuid, usuario_email text, usuario_nome text,
  created_at timestamptz not null default now(),
  unique (pav_id, tentativa));
create index if not exists pav_reaterro_ensaio_pav_idx on "8 - coleta_campo".pav_reaterro_ensaio (pav_id);

create table if not exists "8 - coleta_campo".pav_reaterro_evento (
  id bigint generated always as identity primary key,
  pav_id uuid not null references "8 - coleta_campo".pav_recomposicao(id),
  evento text not null check (evento in ('sim','nao','refeito')),
  data date,                                                  -- 'refeito': dia em que o reaterro foi refeito
  em timestamptz not null default now(),
  por_uuid uuid, por_nome text);
create index if not exists pav_reaterro_evento_pav_idx on "8 - coleta_campo".pav_reaterro_evento (pav_id);

alter table "8 - coleta_campo".pav_reaterro_ensaio enable row level security;   -- deny-all: acesso só via RPC
alter table "8 - coleta_campo".pav_reaterro_evento enable row level security;
revoke all on table "8 - coleta_campo".pav_reaterro_ensaio, "8 - coleta_campo".pav_reaterro_evento from public, anon, authenticated;

create or replace function "8 - coleta_campo".pav_reaterro_sem_alterar() returns trigger language plpgsql as $function$
begin raise exception 'O histórico do ensaio de reaterro não pode ser alterado nem apagado'; end $function$;
drop trigger if exists pav_reaterro_ensaio_imutavel on "8 - coleta_campo".pav_reaterro_ensaio;
create trigger pav_reaterro_ensaio_imutavel before update or delete on "8 - coleta_campo".pav_reaterro_ensaio
  for each row execute function "8 - coleta_campo".pav_reaterro_sem_alterar();
drop trigger if exists pav_reaterro_ensaio_sem_truncate on "8 - coleta_campo".pav_reaterro_ensaio;
create trigger pav_reaterro_ensaio_sem_truncate before truncate on "8 - coleta_campo".pav_reaterro_ensaio
  for each statement execute function "8 - coleta_campo".pav_reaterro_sem_alterar();
drop trigger if exists pav_reaterro_evento_imutavel on "8 - coleta_campo".pav_reaterro_evento;
create trigger pav_reaterro_evento_imutavel before update or delete on "8 - coleta_campo".pav_reaterro_evento
  for each row execute function "8 - coleta_campo".pav_reaterro_sem_alterar();
drop trigger if exists pav_reaterro_evento_sem_truncate on "8 - coleta_campo".pav_reaterro_evento;
create trigger pav_reaterro_evento_sem_truncate before truncate on "8 - coleta_campo".pav_reaterro_evento
  for each statement execute function "8 - coleta_campo".pav_reaterro_sem_alterar();

-- 3) acesso da Qualidade: engrenagem perfil.qualidade_acesso (admin marca) + cargos Técnico de Qualidade / Coordenador de QSMSS
alter table public.perfil add column if not exists qualidade_acesso boolean default false;

create or replace function "8 - coleta_campo".pav_qualidade_pode(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $function$
  select exists (
    select 1 from public.perfil p
    left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id
    where p.id = p_uid and coalesce(p.ativo, true)
      and (p.funcao = 'admin' or coalesce(p.qualidade_acesso, false)
           or c.nome in ('Técnico de Qualidade','Coordenador de QSMSS')));
$function$;
-- equipe que recebe o aviso de fila nova: engrenagem ou cargo (admin só se tiver um dos dois)
create or replace function "8 - coleta_campo".pav_qualidade_uuids()
returns uuid[] language sql stable security definer set search_path to 'public' as $function$
  select coalesce(array_agg(p.id), '{}') from public.perfil p
    left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id
   where coalesce(p.ativo, true)
     and (coalesce(p.qualidade_acesso, false) or c.nome in ('Técnico de Qualidade','Coordenador de QSMSS'));
$function$;
create or replace function "8 - coleta_campo".pav_tipo_lbl(p_tipo text)
returns text language sql immutable as $function$
  select case p_tipo when 'grama' then 'Grama' when 'asfalto' then 'Asfalto' when 'concreto' then 'Concreto'
    when 'bloquete' then 'Bloquete' when 'paralelepipedo' then 'Paralelepípedo' when 'pedra_portuguesa' then 'Pedra portuguesa'
    when 'piso_especial' then 'Piso especial' when 'piso_tatil' then 'Piso tátil' when 'meio_fio' then 'Meio-fio'
    when 'sarjeta' then 'Sarjeta' else coalesce(p_tipo,'—') end;
$function$;
revoke all on function "8 - coleta_campo".pav_qualidade_pode(uuid), "8 - coleta_campo".pav_qualidade_uuids(),
  "8 - coleta_campo".pav_tipo_lbl(text) from public, anon, authenticated;

-- histórico do reaterro de 1 tipo (ensaios + "refeito"), em ordem de tempo
create or replace function "8 - coleta_campo".pav_reaterro_hist(p_pav uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select coalesce(jsonb_agg(h.j order by h.em), '[]'::jsonb) from (
    select e.created_at em, jsonb_build_object('ev','ensaio','tentativa',e.tentativa,'resultado',e.resultado,'metodo',e.metodo,
      'gc_medido',e.gc_medido,'gc_exigido',e.gc_exigido,'obs',e.obs,'laudo',e.laudo,'foto1',e.foto1,'foto2',e.foto2,
      'dist_m',e.dist_ponto_m,'em',e.created_at,'por',coalesce(e.usuario_nome,e.usuario_email)) j
      from "8 - coleta_campo".pav_reaterro_ensaio e where e.pav_id = p_pav
    union all
    select v.em, jsonb_build_object('ev','refeito','data',v.data,'em',v.em,'por',v.por_nome)
      from "8 - coleta_campo".pav_reaterro_evento v where v.pav_id = p_pav and v.evento = 'refeito'
  ) h;
$function$;
revoke all on function "8 - coleta_campo".pav_reaterro_hist(uuid) from public, anon, authenticated;

-- 4) avisos (trigger na tabela de negócio, nunca inline na RPC)
create or replace function "8 - coleta_campo".pav_trg_reaterro_fila() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.reaterro_status = 'aguardando' and old.reaterro_status is distinct from 'aguardando' then
    perform "9 - suprimentos".sup_notificar("8 - coleta_campo".pav_qualidade_uuids(), 'pavimento',
      case when old.reaterro_status = 'reprovado' then '🧪 Reaterro refeito — novo ensaio' else '🧪 Ensaio de reaterro a fazer' end,
      "8 - coleta_campo".pav_tipo_lbl(new.tipo_pavimento)
        || coalesce(' · OS origem ' || new.os_sigos, '')
        || ' · ' || case new.consorcio when 'ZA1004' then 'Contagem' when 'ZA0200' then 'Betim' else coalesce(new.consorcio,'—') end,
      'pavqual', auth.uid());
  end if;
  return new;
end $function$;
drop trigger if exists pav_reaterro_fila_aviso on "8 - coleta_campo".pav_recomposicao;
create trigger pav_reaterro_fila_aviso after update of reaterro_status on "8 - coleta_campo".pav_recomposicao
  for each row execute function "8 - coleta_campo".pav_trg_reaterro_fila();

create or replace function "8 - coleta_campo".pav_trg_reaterro_resultado() returns trigger
language plpgsql security definer set search_path to 'public' as $function$
declare r record;
begin
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
drop trigger if exists pav_reaterro_resultado_aviso on "8 - coleta_campo".pav_reaterro_ensaio;
create trigger pav_reaterro_resultado_aviso after insert on "8 - coleta_campo".pav_reaterro_ensaio
  for each row execute function "8 - coleta_campo".pav_trg_reaterro_resultado();

-- 5) RPCs do programador (admin | aux_acesso)
-- resposta "Necessita ensaio?" de 1 tipo. Só sem OS e sem ensaio feito (Sim ↔ Não enquanto ninguém ensaiou = tirar da fila).
create or replace function public.app_pav_reaterro_decidir(p_id uuid, p_necessario boolean)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; r record;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_necessario is null then raise exception 'responda Sim ou Não'; end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  select os_recomposicao, reaterro_necessario into r from "8 - coleta_campo".pav_recomposicao where id = p_id for update;
  if not found then raise exception 'registro não encontrado'; end if;
  if r.os_recomposicao is not null then raise exception 'a OS da recomposição já foi criada — a resposta não pode mudar'; end if;
  if exists(select 1 from "8 - coleta_campo".pav_reaterro_ensaio where pav_id = p_id) then
    raise exception 'já há ensaio registrado para este pavimento — a resposta não pode mudar'; end if;
  if r.reaterro_necessario is not distinct from p_necessario then return 0; end if;
  update "8 - coleta_campo".pav_recomposicao
    set reaterro_necessario = p_necessario, reaterro_resp_em = now(), reaterro_resp_por = v_nome, reaterro_resp_uuid = v_id,
        reaterro_status = case when p_necessario then 'aguardando' end,
        reaterro_status_em = case when p_necessario then now() end
    where id = p_id;
  insert into "8 - coleta_campo".pav_reaterro_evento (pav_id, evento, por_uuid, por_nome)
    values (p_id, case when p_necessario then 'sim' else 'nao' end, v_id, v_nome);
  return 1;
end$function$;

-- reaterro reprovado foi refeito → volta pra fila da Qualidade (nova tentativa)
create or replace function public.app_pav_reaterro_refeito(p_id uuid, p_data date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; v_st text; v_ult timestamptz;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_data is null then raise exception 'informe o dia em que o reaterro foi refeito'; end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  select reaterro_status into v_st from "8 - coleta_campo".pav_recomposicao where id = p_id for update;
  if not found then raise exception 'registro não encontrado'; end if;
  if v_st is distinct from 'reprovado' then raise exception 'o reaterro deste pavimento não está reprovado'; end if;
  if p_data > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'data no futuro'; end if;
  select max(created_at) into v_ult from "8 - coleta_campo".pav_reaterro_ensaio where pav_id = p_id;
  if p_data < (v_ult at time zone 'America/Sao_Paulo')::date then raise exception 'data anterior ao ensaio reprovado'; end if;
  update "8 - coleta_campo".pav_recomposicao set reaterro_status = 'aguardando', reaterro_status_em = now() where id = p_id;
  insert into "8 - coleta_campo".pav_reaterro_evento (pav_id, evento, data, por_uuid, por_nome) values (p_id, 'refeito', p_data, v_id, v_nome);
  return 1;
end$function$;

-- lista da pavprog: + reaterro por tipo (resposta, situação, histórico)
create or replace function public.app_pav_listar(p_consorcio text default null, p_servico_origem text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=auth.uid() and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  return (
    select coalesce(jsonb_agg(g order by mc desc),'[]')
    from (
      select jsonb_build_object(
        'grupo',grupo,'servico_origem',min(servico_origem),'os_sigos',min(os_sigos),
        'os_recomposicao',case when count(distinct os_recomposicao)<=1 then min(os_recomposicao)
                               else string_agg(os_recomposicao, ', ' order by tipo_pavimento) end,
        'os_recomp_em',max(os_recomp_em),'os_recomp_por',min(os_recomp_por),
        'consorcio',min(consorcio),'created_at',max(created_at),
        'usuario',min(coalesce(usuario_nome,usuario_email)),
        'lat',min(lat),'lon',min(lon),'precisao',min(gps_precisao),
        'itens', jsonb_agg(jsonb_build_object('id',id,'tipo',tipo_pavimento,'dimensao',dimensao,'foto1',foto1,'foto2',foto2,
                 'os_recomposicao',os_recomposicao,'os_recomp_em',os_recomp_em,'os_recomp_por',os_recomp_por,
                 'execucao_data',execucao_data,'execucao_em',execucao_em,'execucao_por',execucao_por,
                 'reaterro_necessario',reaterro_necessario,'reaterro_resp_em',reaterro_resp_em,'reaterro_resp_por',reaterro_resp_por,
                 'reaterro_status',reaterro_status,'reaterro_status_em',reaterro_status_em,
                 'reaterro_hist',case when reaterro_necessario then "8 - coleta_campo".pav_reaterro_hist(id) else '[]'::jsonb end)
                 order by tipo_pavimento)
      ) g, max(created_at) mc
      from "8 - coleta_campo".pav_recomposicao
      where (p_consorcio is null or consorcio=p_consorcio)
        and (p_servico_origem is null or servico_origem=p_servico_origem)
      group by grupo
      limit 500
    ) q
  );
end$function$;

-- 6) RPCs da Qualidade (pav_qualidade_pode)
-- fila: pontos com tipo aguardando ensaio (só esses tipos), mais antigos na fila primeiro
create or replace function public.app_pav_qual_listar(p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not "8 - coleta_campo".pav_qualidade_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return (
    select coalesce(jsonb_agg(g order by desde),'[]')
    from (
      select jsonb_build_object(
        'grupo',grupo,'servico_origem',min(servico_origem),'os_sigos',min(os_sigos),'consorcio',min(consorcio),
        'created_at',max(created_at),'usuario',min(coalesce(usuario_nome,usuario_email)),'lat',min(lat),'lon',min(lon),
        'itens', jsonb_agg(jsonb_build_object('id',id,'tipo',tipo_pavimento,'dimensao',dimensao,'foto1',foto1,'foto2',foto2,
                 'reaterro_resp_por',reaterro_resp_por,'reaterro_resp_em',reaterro_resp_em,'reaterro_status_em',reaterro_status_em,
                 'reaterro_hist',"8 - coleta_campo".pav_reaterro_hist(id)) order by tipo_pavimento)
      ) g, min(reaterro_status_em) desde
      from "8 - coleta_campo".pav_recomposicao
      where reaterro_status = 'aguardando' and os_recomposicao is null
        and (p_consorcio is null or consorcio = p_consorcio)
      group by grupo
      limit 500
    ) q
  );
end$function$;

-- registrar o ensaio de 1 tipo (campo, pela fila offline: fotos/laudo já subidos, paths nos params). Idempotente por p_id.
create or replace function public.app_pav_reaterro_ensaio(p_id uuid, p_pav_id uuid, p_resultado text, p_metodo text,
  p_gc_medido numeric, p_gc_exigido numeric, p_obs text, p_laudo text, p_foto1 text, p_foto2 text,
  p_lat numeric, p_lon numeric, p_precisao numeric, p_dispositivo text)
returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_email text:=coalesce(auth.jwt()->>'email',''); v_nome text; r record; v_t int; v_geom geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "8 - coleta_campo".pav_qualidade_pode(v_id) then raise exception 'sem permissão'; end if;
  if exists(select 1 from "8 - coleta_campo".pav_reaterro_ensaio where id = p_id) then return p_id; end if;  -- reenvio da fila
  if p_resultado is null or p_resultado not in ('aprovado','reprovado') then raise exception 'informe o resultado (aprovado ou reprovado)'; end if;
  if nullif(btrim(p_metodo),'') is null then raise exception 'informe o método do ensaio'; end if;
  if nullif(p_laudo,'') is null then raise exception 'o laudo é obrigatório'; end if;
  if nullif(p_foto1,'') is null then raise exception 'a foto do ensaio é obrigatória'; end if;
  if p_resultado = 'reprovado' and nullif(btrim(p_obs),'') is null then raise exception 'descreva o motivo da reprovação'; end if;
  if (p_gc_medido is not null and (p_gc_medido <= 0 or p_gc_medido > 200)) or (p_gc_exigido is not null and (p_gc_exigido <= 0 or p_gc_exigido > 200)) then
    raise exception 'grau de compactação fora da faixa (0–200%%)'; end if;
  if p_lat is null or p_lon is null then raise exception 'coordenada obrigatória'; end if;
  if p_precisao is null or p_precisao > 15 then raise exception 'GPS sem precisão suficiente (≤ 15 m)'; end if;
  select os_recomposicao, reaterro_status, geom into r from "8 - coleta_campo".pav_recomposicao where id = p_pav_id for update;
  if not found then raise exception 'pavimento não encontrado'; end if;
  if r.reaterro_status is distinct from 'aguardando' or r.os_recomposicao is not null then
    raise exception 'este pavimento não está aguardando ensaio de reaterro'; end if;
  select nome into v_nome from public.perfil where id = v_id;
  select coalesce(max(tentativa),0)+1 into v_t from "8 - coleta_campo".pav_reaterro_ensaio where pav_id = p_pav_id;
  v_geom := st_setsrid(st_makepoint(p_lon,p_lat),4326);
  insert into "8 - coleta_campo".pav_reaterro_ensaio
    (id,pav_id,tentativa,resultado,metodo,gc_medido,gc_exigido,obs,laudo,foto1,foto2,lat,lon,gps_precisao,geom,dist_ponto_m,
     dispositivo,usuario_uuid,usuario_email,usuario_nome)
  values (p_id,p_pav_id,v_t,p_resultado,btrim(p_metodo),p_gc_medido,p_gc_exigido,nullif(btrim(p_obs),''),p_laudo,p_foto1,nullif(p_foto2,''),
     p_lat,p_lon,p_precisao,v_geom,
     case when r.geom is not null then round(st_distance(st_transform(v_geom,31983), st_transform(r.geom,31983))::numeric,1) end,
     p_dispositivo,v_id,v_email,v_nome);
  update "8 - coleta_campo".pav_recomposicao set reaterro_status = p_resultado, reaterro_status_em = now() where id = p_pav_id;
  return p_id;
end$function$;

-- engrenagem de acesso da Qualidade (admin)
create or replace function public.app_pav_qual_acesso_listar()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id=v_id and funcao='admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nome',coalesce(p.nome,p.email),'email',p.email,'funcao',p.funcao,
      'cargo',c.nome,'acesso',"8 - coleta_campo".pav_qualidade_pode(p.id),
      'acesso_pelo_cargo',(p.funcao='admin' or c.nome in ('Técnico de Qualidade','Coordenador de QSMSS')))
      order by coalesce(p.nome,p.email))
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id=p.cargo_id where coalesce(p.ativo,true)),'[]'::jsonb);
end $function$;
create or replace function public.app_pav_qual_acesso_set(p_uuid uuid, p_on boolean)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id=v_id and funcao='admin') then raise exception 'sem permissão'; end if;
  update public.perfil set qualidade_acesso = p_on where id = p_uuid;
end $function$;

-- 7) app_me: + 'qualidade' (card e tela da Qualidade)
create or replace function public.app_me()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid(); v_email text := coalesce(auth.jwt() ->> 'email',''); v_p public.perfil%rowtype; v_adm boolean; v_areas text[];
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  insert into public.perfil (id, email, nome, funcao) values (v_id, v_email, nullif(initcap(replace(split_part(v_email,'@',1),'.',' ')),''), 'campo') on conflict (id) do nothing;
  select * into v_p from public.perfil where id=v_id;
  v_adm := (v_p.funcao='admin');
  v_areas := array(select area from "9 - suprimentos".sup_acesso_area where colaborador_uuid=v_id);
  return jsonb_build_object('id',v_p.id,'email',v_p.email,'nome',v_p.nome,'cargo',v_p.cargo,'funcao',v_p.funcao,
    'is_admin',v_adm, 'is_almoxarife',(v_p.funcao in ('almoxarife','admin')), 'pode_aprovar',(v_p.funcao in ('aprovador','admin')),
    'frota_admin',coalesce(v_p.frota_admin,false), 'pessoas_admin',coalesce(v_p.pessoas_admin,false),
    'dev_acesso',(v_adm or coalesce(v_p.dev_acesso,false)),
    'proj_sup',(v_adm or coalesce(v_p.proj_sup_acesso,false)),
    'vrp_gestao',(v_adm or coalesce(v_p.vrp_gestao_acesso,false) or coalesce(v_p.aux_acesso,false)),
    'aux_acesso',(v_adm or coalesce(v_p.aux_acesso,false)),
    'qsms',"16 - qsms".qsms_pode(v_id),
    'qualidade',"8 - coleta_campo".pav_qualidade_pode(v_id),
    'epi_gestor',"9 - suprimentos".sup_epi_gestor(v_id),
    'sup_areas', jsonb_build_object('baixas', v_adm or ('baixas'=any(v_areas)), 'insumo', v_adm or ('insumo'=any(v_areas)), 'equip', v_adm or ('equip'=any(v_areas)), 'epi', v_adm or ('epi'=any(v_areas)), 'ferramenta', v_adm or ('ferramenta'=any(v_areas))),
    'equipes','[]'::jsonb);
end $function$;

-- 8) grants: RPCs só p/ authenticated
revoke all on function public.app_pav_reaterro_decidir(uuid,boolean), public.app_pav_reaterro_refeito(uuid,date),
  public.app_pav_qual_listar(text),
  public.app_pav_reaterro_ensaio(uuid,uuid,text,text,numeric,numeric,text,text,text,text,numeric,numeric,numeric,text),
  public.app_pav_qual_acesso_listar(), public.app_pav_qual_acesso_set(uuid,boolean) from public, anon;
grant execute on function public.app_pav_reaterro_decidir(uuid,boolean), public.app_pav_reaterro_refeito(uuid,date),
  public.app_pav_qual_listar(text),
  public.app_pav_reaterro_ensaio(uuid,uuid,text,text,numeric,numeric,text,text,text,text,numeric,numeric,numeric,text),
  public.app_pav_qual_acesso_listar(), public.app_pav_qual_acesso_set(uuid,boolean) to authenticated;
