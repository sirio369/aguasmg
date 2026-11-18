-- QSMS campo — Checklists do POP-022 Rev. 03 (Reaterro e Recomposição de Pavimento) — 2026-11-18
-- Checklist 01 (reaterro) e 02 (recomposição de pavimento) preenchidos em campo pelo QSMS campo (sst_form),
-- vistos na gestão (tela sst_ck, hub QSMS › SST) e acompanhados no BI QSMS (página "Reaterro e pavimento").
-- Os itens vêm do app e são gravados com o texto (grupo + item): o registro guarda a revisão que foi respondida.
-- Nada pode ser apagado (trigger qsms_sem_delete); a gestão anula (app_sst_anular, tipo 'checklist').

create table if not exists "16 - qsms".sst_checklist (
  id uuid primary key,
  tipo text not null check (tipo in ('reaterro','recomposicao')),
  data date not null,
  consorcio text,
  os text,
  tipo_intervencao text,
  equipe text,
  local text,
  tipo_pavimento text,
  resultado text check (resultado in ('conforme','nao_conforme','pendente')),
  observacoes text,
  encarregado_uuid uuid,
  encarregado_nome text,
  encarregado_assinatura text,
  encarregado_assinado_em timestamptz,
  fiscal_assinatura text,
  fiscal_assinado_em timestamptz,
  lat numeric, lon numeric, gps_precisao numeric,
  geom geometry(Point,31983),
  endereco text, bairro text, municipio text,
  fotos jsonb not null default '{}'::jsonb,
  alertas jsonb not null default '[]'::jsonb,
  usuario_uuid uuid,
  usuario_nome text,
  dispositivo text,
  criado_em timestamptz not null default now(),
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);
create table if not exists "16 - qsms".sst_checklist_item (
  id uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references "16 - qsms".sst_checklist(id),
  ordem int not null,
  codigo text,
  grupo text,
  item text not null,
  resultado text not null check (resultado in ('C','NC','NA')),
  obs text,
  foto text
);
create index if not exists sst_checklist_data_idx on "16 - qsms".sst_checklist(data);
create index if not exists sst_checklist_item_ck_idx on "16 - qsms".sst_checklist_item(checklist_id);
alter table "16 - qsms".sst_checklist enable row level security;
alter table "16 - qsms".sst_checklist_item enable row level security;
drop trigger if exists sst_checklist_sem_delete on "16 - qsms".sst_checklist;
create trigger sst_checklist_sem_delete before delete on "16 - qsms".sst_checklist for each row execute function "16 - qsms".qsms_sem_delete();
drop trigger if exists sst_checklist_item_sem_delete on "16 - qsms".sst_checklist_item;
create trigger sst_checklist_item_sem_delete before delete on "16 - qsms".sst_checklist_item for each row execute function "16 - qsms".qsms_sem_delete();
drop trigger if exists sst_checklist_audit on "16 - qsms".sst_checklist;
create trigger sst_checklist_audit after update on "16 - qsms".sst_checklist for each row execute function "16 - qsms".sst_trg_audit();

-- ---------- campo: registrar (idempotente pelo id; inválido vira alerta, não erro) ----------
create or replace function public.app_sst_ck_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_tipo text; v_res text;
  it jsonb; i int := 0; n_nc int := 0; v_al jsonb := '[]'::jsonb; v_r text; v_foto text;
  v_euid uuid; v_enome text; v_esig text; v_fsig text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_checklist where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  v_tipo := d->>'tipo'; if v_tipo is null or v_tipo not in ('reaterro','recomposicao') then raise exception 'tipo de checklist inválido'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  v_lat := nullif(d->>'lat','')::numeric; v_lon := nullif(d->>'lon','')::numeric;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  if v_geom is null then v_al := v_al || jsonb_build_array('Sem GPS'); end if;
  v_loc := "16 - qsms".qsms_local(v_geom);
  if nullif(btrim(d->>'os'),'') is null then v_al := v_al || jsonb_build_array('Sem OS'); end if;
  v_res := d->>'resultado'; if v_res is null or v_res not in ('conforme','nao_conforme','pendente') then v_res := 'pendente'; v_al := v_al || jsonb_build_array('Sem resultado (gravado como pendente)'); end if;
  v_euid := nullif(d->>'encarregado_uuid','')::uuid;
  v_enome := coalesce(nullif(btrim(d->>'encarregado_nome'),''), (select coalesce(nome,email) from public.perfil where id = v_euid));
  v_esig := case when nullif(d->>'encarregado_sig','') is not null then v_anx->>(d->>'encarregado_sig') end;
  v_fsig := case when nullif(d->>'fiscal_sig','') is not null then v_anx->>(d->>'fiscal_sig') end;
  if v_enome is null then v_al := v_al || jsonb_build_array('Sem encarregado'); elsif v_esig is null then v_al := v_al || jsonb_build_array('Encarregado sem assinatura'); end if;
  if v_fsig is null then v_al := v_al || jsonb_build_array('Fiscalização sem assinatura'); end if;

  insert into "16 - qsms".sst_checklist(id, tipo, data, consorcio, os, tipo_intervencao, equipe, local, tipo_pavimento, resultado, observacoes,
    encarregado_uuid, encarregado_nome, encarregado_assinatura, encarregado_assinado_em, fiscal_assinatura, fiscal_assinado_em,
    lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, usuario_uuid, usuario_nome, dispositivo)
  values (p_id, v_tipo, v_data, coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid)),
    nullif(btrim(d->>'os'),''), nullif(btrim(d->>'tipo_intervencao'),''), nullif(btrim(d->>'equipe'),''), nullif(btrim(d->>'local'),''),
    case when v_tipo = 'recomposicao' then nullif(btrim(d->>'tipo_pavimento'),'') end, v_res, nullif(btrim(d->>'observacoes'),''),
    v_euid, v_enome, v_esig, case when v_esig is not null then nullif(d->>'encarregado_assinado_em','')::timestamptz end,
    v_fsig, case when v_fsig is not null then nullif(d->>'fiscal_assinado_em','')::timestamptz end,
    v_lat, v_lon, nullif(d->>'precisao','')::numeric, v_geom, v_loc->>'endereco', v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_uid, v_nome, left(d->>'dispositivo', 120));

  for it in select * from jsonb_array_elements(coalesce(d->'itens','[]'::jsonb)) loop
    i := i + 1;
    v_r := upper(coalesce(it->>'resultado',''));
    if v_r not in ('C','NC','NA') then v_al := v_al || jsonb_build_array(format('Item %s sem resposta (gravado como NA)', i)); v_r := 'NA'; end if;
    if v_r = 'NC' then n_nc := n_nc + 1;
      if nullif(btrim(it->>'obs'),'') is null then v_al := v_al || jsonb_build_array(format('NC no item %s sem observação', i)); end if; end if;
    v_foto := case when nullif(it->>'foto','') is not null then v_anx->>(it->>'foto') end;
    insert into "16 - qsms".sst_checklist_item(checklist_id, ordem, codigo, grupo, item, resultado, obs, foto)
    values (p_id, i, nullif(it->>'codigo',''), nullif(btrim(it->>'grupo'),''), coalesce(nullif(btrim(it->>'item'),''), '(item sem nome)'),
      v_r, nullif(btrim(it->>'obs'),''), v_foto);
  end loop;
  if i = 0 then v_al := v_al || jsonb_build_array('Checklist sem itens'); end if;
  if v_res = 'conforme' and n_nc > 0 then v_al := v_al || jsonb_build_array('Resultado "conforme" com item não conforme'); end if;
  update "16 - qsms".sst_checklist set alertas = v_al where id = p_id;
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $$;

-- ---------- gestão: lista do período ----------
create or replace function public.app_sst_ck_listar(p_de date, p_ate date, p_consorcio text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform "16 - qsms".sst_gestao_check();
  return coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'tipo',c.tipo,'data',c.data,'consorcio',c.consorcio,'os',c.os,
      'tipo_intervencao',c.tipo_intervencao,'equipe',c.equipe,'local',c.local,'tipo_pavimento',c.tipo_pavimento,'resultado',c.resultado,
      'endereco',c.endereco,'bairro',c.bairro,'municipio',c.municipio,'fiscal',c.usuario_nome,'encarregado',c.encarregado_nome,'alertas',c.alertas,
      'c',(select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='C'),
      'nc',(select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='NC'),
      'na',(select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='NA'))
      order by c.data desc, c.criado_em desc)
    from "16 - qsms".sst_checklist c
    where c.anulado_em is null and (p_de is null or c.data >= p_de) and (p_ate is null or c.data <= p_ate)
      and (nullif(btrim(p_consorcio),'') is null or c.consorcio = p_consorcio)), '[]'::jsonb);
end $$;

-- ---------- detalhe (gestão ou quem preencheu) ----------
create or replace function public.app_sst_ck_ver(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); r jsonb;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not ("16 - qsms".qsms_pode(v_uid) or exists (select 1 from "16 - qsms".sst_checklist where id = p_id and usuario_uuid = v_uid)) then
    raise exception 'sem permissão'; end if;
  select to_jsonb(c) - 'geom' || jsonb_build_object('itens', coalesce((select jsonb_agg(to_jsonb(x) - 'checklist_id' order by x.ordem)
      from "16 - qsms".sst_checklist_item x where x.checklist_id = c.id), '[]'::jsonb))
    into r from "16 - qsms".sst_checklist c where c.id = p_id;
  if r is null then raise exception 'checklist não encontrado'; end if;
  return r;
end $$;

-- ---------- anular: + 'checklist' ----------
create or replace function public.app_sst_anular(p_tipo text, p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); v_tab text; n int;
begin
  if nullif(btrim(p_motivo),'') is null then raise exception 'informe o motivo'; end if;
  v_tab := case p_tipo when 'inspecao' then 'sst_inspecao' when 'dds' then 'sst_dds' when 'ocorrencia' then 'sst_ocorrencia'
    when 'acao' then 'sst_acao' when 'aso' then 'sst_aso' when 'treinamento' then 'sst_treinamento'
    when 'cipa_membro' then 'sst_cipa_membro' when 'cipa_reuniao' then 'sst_cipa_reuniao' when 'checklist' then 'sst_checklist' end;
  if v_tab is null then raise exception 'tipo inválido'; end if;
  execute format('update "16 - qsms".%I set anulado_em = now(), anulado_por = $1, anulado_motivo = $2 where id = $3 and anulado_em is null', v_tab)
    using v_uid, btrim(p_motivo), p_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'registro não encontrado (ou já anulado)'; end if;
end $$;

-- ---------- campo: "Meus lançamentos" + checklists ----------
create or replace function public.app_sst_minhas(p_dias integer default 30)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_de date := "16 - qsms".sst_hoje() - greatest(coalesce(p_dias,30),1);
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'inspecoes', coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'data',i.data,'area',i.area,'local',i.local,'endereco',i.endereco,'os',i.os,
        'itens',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado<>'NA'),
        'ncs',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado='NC'),
        'pendentes',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.trat_status='pendente'),
        'alertas',i.alertas) order by i.data desc, i.criado_em desc)
      from "16 - qsms".sst_inspecao i where i.usuario_uuid=v_uid and i.anulado_em is null and i.data>=v_de), '[]'::jsonb),
    'dds', coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'data',x.data,'area',x.area,'tema',x.tema,
        'participantes',coalesce(x.participantes_qtd,(select count(*) from "16 - qsms".sst_dds_presenca pp where pp.dds_id=x.id)::int),'efetivo',x.efetivo,'alertas',x.alertas)
        order by x.data desc, x.criado_em desc)
      from "16 - qsms".sst_dds x where x.usuario_uuid=v_uid and x.anulado_em is null and x.data>=v_de), '[]'::jsonb),
    'ocorrencias', coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'data',o.data,'natureza',o.natureza,'area',o.area,
        'vitima',o.vitima_nome,'status',o.status,'alertas',o.alertas) order by o.data desc, o.criado_em desc)
      from "16 - qsms".sst_ocorrencia o where o.usuario_uuid=v_uid and o.anulado_em is null and o.data>=v_de), '[]'::jsonb),
    'checklists', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'tipo',c.tipo,'data',c.data,'os',c.os,'equipe',c.equipe,'resultado',c.resultado,
        'nc',(select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='NC'),'alertas',c.alertas)
        order by c.data desc, c.criado_em desc)
      from "16 - qsms".sst_checklist c where c.usuario_uuid=v_uid and c.anulado_em is null and c.data>=v_de), '[]'::jsonb));
end $$;

-- ---------- views do BI (mesmo padrão bi_sst_*: nomes de coluna do BI) ----------
create or replace view "16 - qsms".bi_sst_checklist as
select c.id as "ID", c.data as "Data", c.consorcio as "Consórcio",
  case c.tipo when 'reaterro' then 'Reaterro' else 'Recomposição de pavimento' end as "Checklist",
  c.os as "OS", c.tipo_intervencao as "Tipo de Intervenção", c.equipe as "Equipe", c.tipo_pavimento as "Tipo de Pavimento",
  c.usuario_nome as "Fiscal", c.encarregado_nome as "Encarregado",
  case c.resultado when 'conforme' then 'Conforme' when 'nao_conforme' then 'Não conforme' else 'Pendente' end as "Resultado",
  (select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado in ('C','NC'))::int as "Itens Verificados",
  (select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='C')::int as "Conformes",
  (select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='NC')::int as "NCs",
  (select count(*) from "16 - qsms".sst_checklist_item x where x.checklist_id=c.id and x.resultado='NA')::int as "N/A",
  c.endereco as "Endereço", c.bairro as "Bairro", c.municipio as "Município", c.observacoes as "Observações"
from "16 - qsms".sst_checklist c where c.anulado_em is null;

create or replace view "16 - qsms".bi_sst_checklist_item as
select x.checklist_id as "Checklist ID", c.data as "Data", c.consorcio as "Consórcio",
  case c.tipo when 'reaterro' then 'Reaterro' else 'Recomposição de pavimento' end as "Checklist",
  c.equipe as "Equipe", x.ordem as "Ordem", x.grupo as "Grupo", x.item as "Item", x.resultado as "Resultado", x.obs as "Observação"
from "16 - qsms".sst_checklist_item x join "16 - qsms".sst_checklist c on c.id = x.checklist_id
where c.anulado_em is null;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'bi_qsms_leitura') then
    grant select on "16 - qsms".bi_sst_checklist, "16 - qsms".bi_sst_checklist_item to bi_qsms_leitura;
  end if;
end $$;

-- ---------- BI no app: + checklists e itens ----------
create or replace function public.app_sst_bi(p_de date default null, p_ate date default null, p_consorcio text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_c text := nullif(btrim(p_consorcio),''); r jsonb;
begin
  perform "16 - qsms".sst_gestao_check();
  select jsonb_build_object(
    'hoje', "16 - qsms".sst_hoje(),
    'areas', coalesce((select jsonb_agg(x."Área" order by x."Área") from "16 - qsms".bi_sst_area x), '[]'::jsonb),
    'acidentes', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_acidentes x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'vinculo', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_acidentes_vinculo x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'inspecoes', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_inspecoes x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'dds', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_dds x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'cipa_reunioes', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_cipa_reunioes x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'treinamentos', coalesce((select jsonb_agg(to_jsonb(x) order by x."Colaborador", x."Treinamento") from "16 - qsms".bi_sst_treinamentos x
        where v_c is null or x."Consórcio" = v_c), '[]'::jsonb),
    'saude', coalesce((select jsonb_agg(to_jsonb(x) order by x."Colaborador") from "16 - qsms".bi_sst_saude x
        where v_c is null or x."Consórcio" = v_c), '[]'::jsonb),
    'cipa_membros', coalesce((select jsonb_agg(to_jsonb(x) order by x."Membro") from "16 - qsms".bi_sst_cipa_membros x
        where v_c is null or x."Consórcio" = v_c), '[]'::jsonb),
    'checklists', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_checklist x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'checklist_itens', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc, x."Ordem") from "16 - qsms".bi_sst_checklist_item x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    -- "Sem dados" do cartão do BI = tabela inteira vazia (ISEMPTY(ALL(...))), independente de filtro
    'vazias', jsonb_build_object(
        'acidentes', not exists (select 1 from "16 - qsms".bi_sst_acidentes),
        'vinculo', not exists (select 1 from "16 - qsms".bi_sst_acidentes_vinculo),
        'inspecoes', not exists (select 1 from "16 - qsms".bi_sst_inspecoes),
        'dds', not exists (select 1 from "16 - qsms".bi_sst_dds),
        'treinamentos', not exists (select 1 from "16 - qsms".bi_sst_treinamentos),
        'saude', not exists (select 1 from "16 - qsms".bi_sst_saude),
        'cipa_membros', not exists (select 1 from "16 - qsms".bi_sst_cipa_membros),
        'cipa_reunioes', not exists (select 1 from "16 - qsms".bi_sst_cipa_reunioes),
        'checklists', not exists (select 1 from "16 - qsms".bi_sst_checklist))
  ) into r;
  return r;
end $$;

revoke all on function public.app_sst_ck_registrar(uuid, jsonb, jsonb) from public, anon;
revoke all on function public.app_sst_ck_listar(date, date, text) from public, anon;
revoke all on function public.app_sst_ck_ver(uuid) from public, anon;
revoke all on function public.app_sst_anular(text, uuid, text) from public, anon;
revoke all on function public.app_sst_minhas(integer) from public, anon;
revoke all on function public.app_sst_bi(date, date, text) from public, anon;
grant execute on function public.app_sst_ck_registrar(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.app_sst_ck_listar(date, date, text) to authenticated;
grant execute on function public.app_sst_ck_ver(uuid) to authenticated;
grant execute on function public.app_sst_anular(text, uuid, text) to authenticated;
grant execute on function public.app_sst_minhas(integer) to authenticated;
grant execute on function public.app_sst_bi(date, date, text) to authenticated;
