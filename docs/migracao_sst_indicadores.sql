-- QSMS — Indicadores de SST no AcquaHub (PR-A: banco). 2026-11-05.
-- Substitui a planilha 18. QSMS\Indicadores\Base_Indicadores_SST_PowerBI.xlsx e a fonte do BI QSMS.
--   • campo (card novo "QSMS campo", TSTs): inspeção de segurança, DDS, ocorrência (acidente/quase acidente/incidente);
--   • gestão (hub QSMS › Indicadores SST): painel, tratativa de NC, validação de ocorrência + ações corretivas,
--     ASO, treinamentos (tipos + matriz), CIPA (membros + reuniões), anulação;
--   • BI: views bi_sst_* com os MESMOS nomes de coluna que as consultas M entregam hoje (DirectQuery),
--     lidas pelo login só-leitura bi_qsms_leitura (a senha é definida pelo dono do projeto, fora daqui).
-- Padrões do schema "16 - qsms": RLS deny-all, escrita só por RPC definer, nada é apagado (qsms_sem_delete) —
-- registro errado é ANULADO (anulado_em/por/motivo) e some das views; toda alteração vai para sst_evento.
-- Idempotente (create if not exists / create or replace).

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 0) ACESSO DE CAMPO + helpers
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
alter table public.perfil add column if not exists qsms_campo boolean not null default false;
comment on column public.perfil.qsms_campo is 'Libera o card QSMS campo (TSTs: inspeção, DDS, ocorrência). Gestão QSMS (qsms_pode) também vê.';

create or replace function "16 - qsms".sst_campo_pode(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select "16 - qsms".qsms_pode(p_uid)
      or exists (select 1 from public.perfil where id = p_uid and coalesce(ativo, true) and coalesce(qsms_campo, false));
$$;

create or replace function "16 - qsms".sst_hoje()
returns date language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- efetivo de uma área numa data (DDS): ativos naquela data no consórcio; se a área existe no cadastro
-- (perfil.area) conta só ela, senão ("Geral", frente de obra…) conta o consórcio todo.
create or replace function "16 - qsms".sst_efetivo(p_consorcio text, p_area text, p_data date)
returns integer language sql stable security definer set search_path to 'public' as $$
  select count(*)::int from public.perfil p
  where (p.admissao is null or p.admissao <= p_data)
    and (p.demissao is null or p.demissao > p_data)
    and (coalesce(p.ativo, true) or p.demissao is not null)
    and (p_consorcio is null or p.consorcio = p_consorcio)
    and (not exists (select 1 from public.perfil x where lower(btrim(x.area)) = lower(btrim(p_area)))
         or lower(btrim(p.area)) = lower(btrim(p_area)));
$$;

create or replace function "16 - qsms".sst_consorcio_nome(p_za text)
returns text language sql immutable as $$
  select case p_za when 'ZA1004' then 'Águas Integradas' when 'ZA0200' then 'Eficiência Hídrica' else p_za end
$$;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 1) TABELAS
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- trilha de alterações (update/anulação) de todas as tabelas sst_*
create table if not exists "16 - qsms".sst_evento (
  id bigserial primary key,
  tabela text not null,
  registro_id text,
  antes jsonb,
  depois jsonb,
  por uuid,
  em timestamptz not null default now()
);

-- checklist-modelo da inspeção (configurável pela gestão)
create table if not exists "16 - qsms".sst_inspecao_modelo (
  id serial primary key,
  grupo text not null,
  item text not null,
  ordem int not null default 0,
  ativo boolean not null default true
);

create table if not exists "16 - qsms".sst_inspecao (
  id uuid primary key,
  data date not null,
  consorcio text,
  area text,
  local text,                                   -- frente/obra/endereço informado
  responsavel_uuid uuid,
  responsavel_nome text,
  responsavel_cargo text not null default 'TST' check (responsavel_cargo in ('TST','Supervisor','Coordenador','Gerente')),
  observacoes text,
  lat numeric, lon numeric, gps_precisao numeric, geom geometry(Point,31983),
  endereco text, bairro text, municipio text,
  fotos jsonb not null default '{}'::jsonb,
  alertas jsonb not null default '[]'::jsonb,
  -- série importada da planilha (sem itens): totais informados
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  itens_imp int, ncs_imp int, tratadas_imp int,
  usuario_uuid uuid, usuario_nome text, dispositivo text,
  criado_em timestamptz not null default now(),
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_inspecao_item (
  id uuid primary key default gen_random_uuid(),
  inspecao_id uuid not null references "16 - qsms".sst_inspecao(id),
  ordem int not null default 0,
  modelo_id int references "16 - qsms".sst_inspecao_modelo(id),
  grupo text,
  item text not null,
  resultado text not null check (resultado in ('C','NC','NA')),
  descricao text,                               -- o que foi encontrado (NC)
  foto text,                                    -- caminho no Storage
  prazo date,                                   -- prazo da tratativa (NC)
  trat_status text check (trat_status in ('pendente','tratada')),
  trat_obs text, trat_foto text, trat_em timestamptz, trat_por uuid, trat_por_nome text
);

create table if not exists "16 - qsms".sst_dds (
  id uuid primary key,
  data date not null,
  consorcio text,
  area text,
  tema text not null,
  responsavel_uuid uuid,
  responsavel_nome text,
  duracao_min int,
  efetivo int,                                  -- foto do efetivo no dia (sst_efetivo) ou o informado na planilha
  observacoes text,
  lat numeric, lon numeric, gps_precisao numeric, geom geometry(Point,31983),
  endereco text, bairro text, municipio text,
  fotos jsonb not null default '{}'::jsonb,
  alertas jsonb not null default '[]'::jsonb,
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  participantes_imp int,
  usuario_uuid uuid, usuario_nome text, dispositivo text,
  criado_em timestamptz not null default now(),
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_dds_presenca (
  id uuid primary key default gen_random_uuid(),
  dds_id uuid not null references "16 - qsms".sst_dds(id),
  ordem int not null default 0,
  pessoa_uuid uuid,
  nome text not null,
  matricula text,
  funcao text,
  assinatura text,
  assinado_em timestamptz
);
create unique index if not exists sst_dds_presenca_pessoa on "16 - qsms".sst_dds_presenca(dds_id, pessoa_uuid) where pessoa_uuid is not null;

-- acidente / quase acidente / incidente (une as duas abas de acidente da planilha)
create table if not exists "16 - qsms".sst_ocorrencia (
  id uuid primary key,
  data date not null,
  hora time,
  natureza text not null default 'Acidente' check (natureza in ('Acidente','Quase acidente','Incidente')),
  tipo text,                                    -- Típico, Trajeto, Doença ocupacional, Outro…
  consorcio text,
  area text,
  setor_local text,
  vinculo text check (vinculo in ('Próprio','Terceiro')),
  empresa text,
  vitima_uuid uuid,
  vitima_nome text,
  parte_corpo text,
  descricao text,
  causa text,
  -- classificação (campo pode sugerir; a gestão valida)
  classificacao text check (classificacao in ('Com Afastamento','Sem Afastamento')),
  gravidade text check (gravidade in ('Leve','Moderada','Grave','Fatal')),
  dias_perdidos int not null default 0,
  dias_debitados int not null default 0,
  cat_emitida boolean,
  status text not null default 'registrada' check (status in ('registrada','validada')),
  validado_em timestamptz, validado_por uuid, validado_por_nome text,
  lat numeric, lon numeric, gps_precisao numeric, geom geometry(Point,31983),
  endereco text, bairro text, municipio text,
  fotos jsonb not null default '{}'::jsonb,
  alertas jsonb not null default '[]'::jsonb,
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  usuario_uuid uuid, usuario_nome text, dispositivo text,
  criado_em timestamptz not null default now(),
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_acao (
  id uuid primary key default gen_random_uuid(),
  ocorrencia_id uuid not null references "16 - qsms".sst_ocorrencia(id),
  descricao text not null,
  responsavel_uuid uuid,
  responsavel_nome text,
  prazo date,
  status text not null default 'Aberta' check (status in ('Aberta','Em andamento','Concluída')),
  concluida_em date,
  obs text,
  criado_em timestamptz not null default now(), criado_por uuid,
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_aso (
  id uuid primary key default gen_random_uuid(),
  pessoa_uuid uuid,
  colaborador_nome text not null,
  matricula text,
  area text,
  cargo text,
  tipo_exame text not null check (tipo_exame in ('Admissional','Periódico','Retorno ao Trabalho','Mudança de Função','Demissional')),
  data_exame date,
  vencimento date,
  audiometria boolean not null default false,
  audiometria_data date,
  audiometria_proxima date,
  arquivo text,
  obs text,
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  criado_em timestamptz not null default now(), criado_por uuid,
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_treinamento_tipo (
  id serial primary key,
  nome text not null unique,
  validade_meses int not null default 12 check (validade_meses > 0),
  carga_horaria numeric,
  ordem int not null default 0,
  ativo boolean not null default true
);

-- um registro por realização; data_realizacao nula = treinamento exigido sem data ("Sem data" da planilha)
create table if not exists "16 - qsms".sst_treinamento (
  id uuid primary key default gen_random_uuid(),
  pessoa_uuid uuid,
  colaborador_nome text not null,
  area text, cargo text,
  tipo_id int not null references "16 - qsms".sst_treinamento_tipo(id),
  data_realizacao date,
  carga_horaria numeric,
  instrutor text,
  certificado text,
  obs text,
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  criado_em timestamptz not null default now(), criado_por uuid,
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_cipa_membro (
  id uuid primary key default gen_random_uuid(),
  pessoa_uuid uuid,
  nome text not null,                           -- nome livre até vincular ao perfil
  representacao text check (representacao in ('Empregador','Empregados')),
  tipo text check (tipo in ('Titular','Suplente')),
  cargo_cipa text,
  area text,
  consorcio text,
  inicio_mandato date,
  fim_mandato date,
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  criado_em timestamptz not null default now(), criado_por uuid,
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create table if not exists "16 - qsms".sst_cipa_reuniao (
  id uuid primary key default gen_random_uuid(),
  data date not null,
  consorcio text,
  pauta text,
  presentes int,
  total_membros int,
  encaminhamentos text,
  ata text,
  origem text not null default 'app' check (origem in ('app','planilha')),
  origem_ref text,
  criado_em timestamptz not null default now(), criado_por uuid,
  anulado_em timestamptz, anulado_por uuid, anulado_motivo text
);

create index if not exists sst_inspecao_data on "16 - qsms".sst_inspecao(data, consorcio);
create index if not exists sst_inspecao_item_insp on "16 - qsms".sst_inspecao_item(inspecao_id);
create index if not exists sst_dds_data on "16 - qsms".sst_dds(data, consorcio);
create index if not exists sst_dds_presenca_dds on "16 - qsms".sst_dds_presenca(dds_id);
create index if not exists sst_ocorrencia_data on "16 - qsms".sst_ocorrencia(data, consorcio);
create index if not exists sst_acao_oc on "16 - qsms".sst_acao(ocorrencia_id);
create index if not exists sst_aso_pessoa on "16 - qsms".sst_aso(pessoa_uuid);
create index if not exists sst_trein_pessoa on "16 - qsms".sst_treinamento(pessoa_uuid, tipo_id);
create unique index if not exists sst_origem_ref_insp on "16 - qsms".sst_inspecao(origem_ref) where origem_ref is not null;
create unique index if not exists sst_origem_ref_dds on "16 - qsms".sst_dds(origem_ref) where origem_ref is not null;
create unique index if not exists sst_origem_ref_oc on "16 - qsms".sst_ocorrencia(origem_ref) where origem_ref is not null;
create unique index if not exists sst_origem_ref_aso on "16 - qsms".sst_aso(origem_ref) where origem_ref is not null;
create unique index if not exists sst_origem_ref_trein on "16 - qsms".sst_treinamento(origem_ref) where origem_ref is not null;
create unique index if not exists sst_origem_ref_cipam on "16 - qsms".sst_cipa_membro(origem_ref) where origem_ref is not null;
create unique index if not exists sst_origem_ref_cipar on "16 - qsms".sst_cipa_reuniao(origem_ref) where origem_ref is not null;

-- RLS deny-all + sem delete + trilha de update
create or replace function "16 - qsms".sst_trg_audit()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into "16 - qsms".sst_evento(tabela, registro_id, antes, depois, por)
  values (tg_table_name, to_jsonb(new)->>'id', to_jsonb(old), to_jsonb(new), auth.uid());
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['sst_evento','sst_inspecao_modelo','sst_inspecao','sst_inspecao_item','sst_dds','sst_dds_presenca',
                           'sst_ocorrencia','sst_acao','sst_aso','sst_treinamento_tipo','sst_treinamento','sst_cipa_membro','sst_cipa_reuniao'] loop
    execute format('alter table "16 - qsms".%I enable row level security', t);
    execute format('revoke all on "16 - qsms".%I from public, anon, authenticated', t);
    execute format('drop trigger if exists %I on "16 - qsms".%I', t||'_sem_delete', t);
    execute format('create trigger %I before delete on "16 - qsms".%I for each row execute function "16 - qsms".qsms_sem_delete()', t||'_sem_delete', t);
    if t <> 'sst_evento' then
      execute format('drop trigger if exists %I on "16 - qsms".%I', t||'_audit', t);
      execute format('create trigger %I after update on "16 - qsms".%I for each row execute function "16 - qsms".sst_trg_audit()', t||'_audit', t);
    end if;
  end loop;
end $$;

-- dados iniciais: tipos de treinamento da planilha (validades da aba Parâmetros) e checklist genérico
insert into "16 - qsms".sst_treinamento_tipo(nome, validade_meses, ordem) values
  ('Direção Defensiva', 24, 1),
  ('Trabalho em Altura (NR-35)', 24, 2),
  ('NR-33 Trabalhador Autorizado/Vigia', 12, 3),
  ('NR-33 Supervisor de Entrada (Espaço Confinado)', 12, 4)
on conflict (nome) do nothing;

insert into "16 - qsms".sst_inspecao_modelo(grupo, item, ordem)
select g, i, o from (values
  ('Documentação', 'APR preenchida e assinada pela equipe', 1),
  ('Documentação', 'PT/PET emitida quando exigida', 2),
  ('Sinalização', 'Sinalização e isolamento da área conforme padrão', 3),
  ('Sinalização', 'Desvio/proteção de pedestres', 4),
  ('EPI/EPC', 'EPIs em uso e em bom estado', 5),
  ('EPI/EPC', 'EPCs disponíveis e adequados', 6),
  ('Veículos e equipamentos', 'Veículo estacionado e sinalizado corretamente', 7),
  ('Veículos e equipamentos', 'Ferramentas e equipamentos em bom estado', 8),
  ('Escavação', 'Escavação escorada/protegida e com acesso seguro', 9),
  ('Organização', 'Frente de serviço limpa e organizada', 10)
) v(g, i, o)
where not exists (select 1 from "16 - qsms".sst_inspecao_modelo);

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 2) app_me + engrenagem de acesso (campo)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
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
    'proj_obras',"13 - projetos_obra".proj_obras_pode(v_id),
    'vrp_gestao',(v_adm or coalesce(v_p.vrp_gestao_acesso,false) or coalesce(v_p.aux_acesso,false)),
    'aux_acesso',(v_adm or coalesce(v_p.aux_acesso,false)),
    'qsms',"16 - qsms".qsms_pode(v_id),
    'qsms_campo',"16 - qsms".sst_campo_pode(v_id),
    'qualidade',"8 - coleta_campo".pav_qualidade_pode(v_id),
    'epi_gestor',"9 - suprimentos".sup_epi_gestor(v_id),
    'sup_areas', jsonb_build_object('baixas', v_adm or ('baixas'=any(v_areas)), 'insumo', v_adm or ('insumo'=any(v_areas)), 'equip', v_adm or ('equip'=any(v_areas)), 'epi', v_adm or ('epi'=any(v_areas)), 'ferramenta', v_adm or ('ferramenta'=any(v_areas))),
    'equipes','[]'::jsonb);
end $function$;

create or replace function public.app_qsms_acesso_listar()
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id=v_id and funcao='admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nome',coalesce(p.nome,p.email),'email',p.email,'funcao',p.funcao,
      'cargo',c.nome,'acesso',"16 - qsms".qsms_pode(p.id),
      'acesso_pelo_cargo',(p.funcao='admin' or c.nome in ('Técnico de Segurança do Trabalho','Técnico de Qualidade','Coordenador de QSMSS')),
      'campo',coalesce(p.qsms_campo,false))
      order by coalesce(p.nome,p.email))
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id=p.cargo_id where coalesce(p.ativo,true)),'[]'::jsonb);
end $function$;

create or replace function public.app_qsms_campo_set(p_uuid uuid, p_on boolean)
 returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id=v_id and funcao='admin') then raise exception 'sem permissão'; end if;
  update public.perfil set qsms_campo = coalesce(p_on,false) where id = p_uuid;
end $function$;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 3) RPCs DE CAMPO (gate sst_campo_pode). Idempotentes por p_id (fila offline). Conteúdo inválido vira
--    ALERTA, não erro (a fila descartaria em silêncio) — mesmo princípio do app_seg_registrar.
--    p_anexos = {chave: caminho no Storage}; as fotos/assinaturas no p_dados referenciam a chave.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function public.app_sst_modelo_listar()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'grupo',grupo,'item',item,'ordem',ordem,'ativo',ativo) order by ordem, id)
    from "16 - qsms".sst_inspecao_modelo), '[]'::jsonb);
end $$;

create or replace function public.app_sst_inspecao_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_cargo text;
  it jsonb; i int := 0; v_al jsonb := '[]'::jsonb; v_res text; v_foto text; v_trat boolean;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_inspecao where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  v_lat := nullif(d->>'lat','')::numeric; v_lon := nullif(d->>'lon','')::numeric;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  if v_geom is null then v_al := v_al || jsonb_build_array('Sem GPS'); end if;
  v_loc := "16 - qsms".qsms_local(v_geom);
  v_cargo := case when d->>'cargo' in ('TST','Supervisor','Coordenador','Gerente') then d->>'cargo' else 'TST' end;

  insert into "16 - qsms".sst_inspecao(id, data, consorcio, area, local, responsavel_uuid, responsavel_nome, responsavel_cargo, observacoes,
    lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, usuario_uuid, usuario_nome, dispositivo)
  values (p_id, v_data, coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid)),
    nullif(btrim(d->>'area'),''), nullif(btrim(d->>'local'),''), v_uid, v_nome, v_cargo, nullif(btrim(d->>'observacoes'),''),
    v_lat, v_lon, nullif(d->>'precisao','')::numeric, v_geom, v_loc->>'endereco', v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_uid, v_nome, left(d->>'dispositivo', 120));

  for it in select * from jsonb_array_elements(coalesce(d->'itens','[]'::jsonb)) loop
    i := i + 1;
    v_res := upper(coalesce(it->>'resultado',''));
    if v_res not in ('C','NC','NA') then
      v_al := v_al || jsonb_build_array(format('Item %s sem resultado (gravado como NA)', i)); v_res := 'NA';
    end if;
    v_foto := case when nullif(it->>'foto','') is not null then v_anx->>(it->>'foto') end;
    v_trat := coalesce((it->>'tratada_no_local')::boolean, false);
    if v_res = 'NC' and v_foto is null then v_al := v_al || jsonb_build_array(format('NC no item %s sem foto', i)); end if;
    if v_res = 'NC' and nullif(btrim(it->>'descricao'),'') is null then v_al := v_al || jsonb_build_array(format('NC no item %s sem descrição', i)); end if;
    insert into "16 - qsms".sst_inspecao_item(inspecao_id, ordem, modelo_id, grupo, item, resultado, descricao, foto, prazo,
      trat_status, trat_obs, trat_em, trat_por, trat_por_nome)
    values (p_id, i, nullif(it->>'modelo_id','')::int, nullif(btrim(it->>'grupo'),''), coalesce(nullif(btrim(it->>'item'),''), '(item sem nome)'),
      v_res, nullif(btrim(it->>'descricao'),''), v_foto, nullif(it->>'prazo','')::date,
      case when v_res = 'NC' then case when v_trat then 'tratada' else 'pendente' end end,
      case when v_res = 'NC' and v_trat then nullif(btrim(it->>'tratativa'),'') end,
      case when v_res = 'NC' and v_trat then now() end,
      case when v_res = 'NC' and v_trat then v_uid end,
      case when v_res = 'NC' and v_trat then v_nome end);
  end loop;
  if i = 0 then v_al := v_al || jsonb_build_array('Inspeção sem itens'); end if;
  update "16 - qsms".sst_inspecao set alertas = v_al where id = p_id;
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $$;

create or replace function public.app_sst_dds_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_cons text; v_area text;
  p jsonb; i int := 0; v_al jsonb := '[]'::jsonb; v_pid uuid; v_mat text; v_fun text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_dds where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  v_lat := nullif(d->>'lat','')::numeric; v_lon := nullif(d->>'lon','')::numeric;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  if v_geom is null then v_al := v_al || jsonb_build_array('Sem GPS'); end if;
  v_loc := "16 - qsms".qsms_local(v_geom);
  v_cons := coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid));
  v_area := coalesce(nullif(btrim(d->>'area'),''), 'Geral');
  if nullif(btrim(d->>'tema'),'') is null then v_al := v_al || jsonb_build_array('DDS sem tema'); end if;

  insert into "16 - qsms".sst_dds(id, data, consorcio, area, tema, responsavel_uuid, responsavel_nome, duracao_min, efetivo, observacoes,
    lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, usuario_uuid, usuario_nome, dispositivo)
  values (p_id, v_data, v_cons, v_area, coalesce(nullif(btrim(d->>'tema'),''), '(sem tema)'), v_uid, v_nome,
    nullif(d->>'duracao_min','')::int, "16 - qsms".sst_efetivo(v_cons, v_area, v_data), nullif(btrim(d->>'observacoes'),''),
    v_lat, v_lon, nullif(d->>'precisao','')::numeric, v_geom, v_loc->>'endereco', v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_uid, v_nome, left(d->>'dispositivo', 120));

  for p in select * from jsonb_array_elements(coalesce(d->'participantes','[]'::jsonb)) loop
    i := i + 1;
    v_pid := nullif(p->>'pessoa_uuid','')::uuid; v_mat := null; v_fun := null;
    select pe.matricula, coalesce(c.nome, pe.cargo) into v_mat, v_fun
      from public.perfil pe left join "9 - suprimentos".sup_cargo c on c.id = pe.cargo_id where pe.id = v_pid;
    if nullif(p->>'sig','') is null or v_anx->>(p->>'sig') is null then
      v_al := v_al || jsonb_build_array(format('Participante %s sem assinatura', coalesce(nullif(btrim(p->>'nome'),''), i::text)));
    end if;
    insert into "16 - qsms".sst_dds_presenca(dds_id, ordem, pessoa_uuid, nome, matricula, funcao, assinatura, assinado_em)
    values (p_id, i, v_pid, coalesce(nullif(btrim(p->>'nome'),''), '(sem nome)'), v_mat, v_fun,
      case when nullif(p->>'sig','') is not null then v_anx->>(p->>'sig') end, nullif(p->>'assinado_em','')::timestamptz)
    on conflict do nothing;
  end loop;
  if i = 0 then v_al := v_al || jsonb_build_array('DDS sem participantes'); end if;
  update "16 - qsms".sst_dds set alertas = v_al where id = p_id;
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $$;

create or replace function public.app_sst_ocorrencia_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_al jsonb := '[]'::jsonb;
  v_nat text; v_vinc text; v_vit uuid; v_vitnome text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_ocorrencia where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  v_lat := nullif(d->>'lat','')::numeric; v_lon := nullif(d->>'lon','')::numeric;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  v_loc := "16 - qsms".qsms_local(v_geom);
  v_nat := case when d->>'natureza' in ('Acidente','Quase acidente','Incidente') then d->>'natureza' else 'Acidente' end;
  v_vinc := case when d->>'vinculo' in ('Próprio','Terceiro') then d->>'vinculo' end;
  v_vit := nullif(d->>'vitima_uuid','')::uuid;
  v_vitnome := coalesce(nullif(btrim(d->>'vitima_nome'),''), (select coalesce(nome,email) from public.perfil where id = v_vit));
  if v_vit is not null and v_vinc is null then v_vinc := 'Próprio'; end if;
  if nullif(btrim(d->>'descricao'),'') is null then v_al := v_al || jsonb_build_array('Ocorrência sem descrição'); end if;

  insert into "16 - qsms".sst_ocorrencia(id, data, hora, natureza, tipo, consorcio, area, setor_local, vinculo, empresa, vitima_uuid, vitima_nome,
    parte_corpo, descricao, causa, classificacao, gravidade, dias_perdidos, cat_emitida,
    lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, alertas, usuario_uuid, usuario_nome, dispositivo)
  values (p_id, v_data, nullif(d->>'hora','')::time, v_nat, nullif(btrim(d->>'tipo'),''),
    coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid)),
    nullif(btrim(d->>'area'),''), nullif(btrim(d->>'setor_local'),''), v_vinc,
    coalesce(nullif(btrim(d->>'empresa'),''), case when v_vinc = 'Próprio' then "16 - qsms".sst_consorcio_nome((select consorcio from public.perfil where id = v_vit)) end),
    v_vit, v_vitnome, nullif(btrim(d->>'parte_corpo'),''), nullif(btrim(d->>'descricao'),''), nullif(btrim(d->>'causa'),''),
    case when d->>'classificacao' in ('Com Afastamento','Sem Afastamento') then d->>'classificacao' end,
    case when d->>'gravidade' in ('Leve','Moderada','Grave','Fatal') then d->>'gravidade' end,
    coalesce(nullif(d->>'dias_perdidos','')::int, 0), nullif(d->>'cat_emitida','')::boolean,
    v_lat, v_lon, nullif(d->>'precisao','')::numeric, v_geom, v_loc->>'endereco', v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_al, v_uid, v_nome, left(d->>'dispositivo', 120));
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $$;

-- o que eu lancei nos últimos p_dias (lista do card de campo)
create or replace function public.app_sst_minhas(p_dias integer default 30)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_de date := "16 - qsms".sst_hoje() - greatest(coalesce(p_dias,30),1);
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'inspecoes', coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'data',i.data,'area',i.area,'local',i.local,'endereco',i.endereco,
        'itens',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado<>'NA'),
        'ncs',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado='NC'),
        'pendentes',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.trat_status='pendente'),
        'alertas',i.alertas) order by i.data desc, i.criado_em desc)
      from "16 - qsms".sst_inspecao i where i.usuario_uuid=v_uid and i.anulado_em is null and i.data>=v_de), '[]'::jsonb),
    'dds', coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'data',x.data,'area',x.area,'tema',x.tema,
        'participantes',(select count(*) from "16 - qsms".sst_dds_presenca pp where pp.dds_id=x.id),'efetivo',x.efetivo,'alertas',x.alertas)
        order by x.data desc, x.criado_em desc)
      from "16 - qsms".sst_dds x where x.usuario_uuid=v_uid and x.anulado_em is null and x.data>=v_de), '[]'::jsonb),
    'ocorrencias', coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'data',o.data,'natureza',o.natureza,'area',o.area,
        'vitima',o.vitima_nome,'status',o.status,'alertas',o.alertas) order by o.data desc, o.criado_em desc)
      from "16 - qsms".sst_ocorrencia o where o.usuario_uuid=v_uid and o.anulado_em is null and o.data>=v_de), '[]'::jsonb));
end $$;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 4) VIEWS DO BI — nomes/tipos de coluna = saída atual das consultas M do QSMS.SemanticModel
--    (+ "Consórcio"). Situações calculadas com a data de hoje em BRT. Anulados ficam de fora.
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
create or replace view "16 - qsms".bi_sst_inspecoes as
with t as (
  select i.*,
    coalesce(i.itens_imp, (select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado<>'NA'))::int as n_itens,
    coalesce(i.ncs_imp, (select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado='NC'))::int as n_ncs,
    coalesce(i.tratadas_imp, (select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.trat_status='tratada'))::int as n_trat
  from "16 - qsms".sst_inspecao i where i.anulado_em is null)
select id::text as "ID", data as "Data", area as "Área", consorcio as "Consórcio",
  responsavel_nome as "Responsável", responsavel_cargo as "Cargo",
  n_itens::double precision as "Itens Verificados", n_ncs::double precision as "NCs Encontradas", n_trat::double precision as "NCs Tratadas",
  observacoes as "Observações",
  (case responsavel_cargo when 'TST' then 1 when 'Supervisor' then 2 when 'Coordenador' then 3 when 'Gerente' then 4 else 99 end)::bigint as "Cargo Ordem"
from t;

create or replace view "16 - qsms".bi_sst_dds as
select d.id::text as "ID", d.data as "Data", d.area as "Área", d.consorcio as "Consórcio", d.tema as "Tema",
  d.responsavel_nome as "Responsável",
  coalesce(d.participantes_imp, (select count(*) from "16 - qsms".sst_dds_presenca p where p.dds_id=d.id))::double precision as "Participantes",
  coalesce(d.efetivo, 0)::double precision as "Efetivo da Área",
  coalesce(d.duracao_min, 0)::double precision as "Duração (min)"
from "16 - qsms".sst_dds d where d.anulado_em is null;

create or replace view "16 - qsms".bi_sst_acidentes as
select o.id::text as "ID", o.data as "Data", o.area as "Área", o.consorcio as "Consórcio", o.setor_local as "Setor",
  o.tipo as "Tipo", o.classificacao as "Classificação", o.gravidade as "Gravidade", o.parte_corpo as "Parte do Corpo",
  o.dias_perdidos::double precision as "Dias Perdidos", o.empresa as "Empresa", o.dias_debitados::double precision as "Dias Debitados",
  o.causa as "Causa Principal", o.descricao as "Descrição",
  (case o.gravidade when 'Leve' then 1 when 'Moderada' then 2 when 'Grave' then 3 when 'Fatal' then 4 else 99 end)::bigint as "Gravidade Ordem",
  o.vinculo as "Vínculo", case when o.status='validada' then 'Sim' else 'Não' end as "Validado"
from "16 - qsms".sst_ocorrencia o where o.anulado_em is null and o.natureza = 'Acidente';

-- uma linha por acidente; ações corretivas consolidadas
create or replace view "16 - qsms".bi_sst_acidentes_vinculo as
with a as (
  select ac.ocorrencia_id,
    string_agg(ac.descricao, ' | ' order by ac.criado_em) as acoes,
    string_agg(distinct ac.responsavel_nome, ', ') as resp,
    min(ac.prazo) filter (where ac.status <> 'Concluída') as prazo_aberto,
    max(ac.prazo) as prazo_max,
    bool_and(ac.status = 'Concluída') as todas_ok,
    bool_or(ac.status = 'Em andamento') as andamento
  from "16 - qsms".sst_acao ac where ac.anulado_em is null group by ac.ocorrencia_id)
select o.id::text as "ID", o.data as "Data", coalesce(o.vinculo, 'Não informado') as "Vínculo", o.empresa as "Empresa",
  o.area as "Área", o.consorcio as "Consórcio", o.tipo as "Tipo", o.gravidade as "Gravidade",
  o.dias_perdidos::double precision as "Dias Perdidos",
  case o.cat_emitida when true then 'Sim' when false then 'Não' end as "CAT Emitida",
  a.acoes as "Ação Corretiva", a.resp as "Responsável", coalesce(a.prazo_aberto, a.prazo_max) as "Prazo",
  case when a.ocorrencia_id is null then null when a.todas_ok then 'Concluída' when a.andamento then 'Em andamento' else 'Aberta' end as "Status da Ação",
  case when a.ocorrencia_id is not null and not a.todas_ok and a.prazo_aberto < "16 - qsms".sst_hoje() then 'Sim' else 'Não' end as "Ação Vencida"
from "16 - qsms".sst_ocorrencia o left join a on a.ocorrencia_id = o.id
where o.anulado_em is null and o.natureza = 'Acidente';

-- ASO vigente = o mais recente de cada colaborador ativo
create or replace view "16 - qsms".bi_sst_saude as
with u as (
  select distinct on (coalesce(s.pessoa_uuid::text, lower(s.colaborador_nome))) s.*
  from "16 - qsms".sst_aso s left join public.perfil p on p.id = s.pessoa_uuid
  where s.anulado_em is null and (s.pessoa_uuid is null or coalesce(p.ativo, true))
  order by coalesce(s.pessoa_uuid::text, lower(s.colaborador_nome)), s.data_exame desc nulls last, s.criado_em desc),
c as (
  select u.*, p.matricula as p_mat, coalesce(p.nome, u.colaborador_nome) as p_nome, coalesce(p.area, u.area) as p_area,
    coalesce(sc.nome, p.cargo, u.cargo) as p_cargo, p.consorcio as p_cons, "16 - qsms".sst_hoje() as hoje,
    case when u.vencimento is null then 'Sem data' when u.vencimento < "16 - qsms".sst_hoje() then 'Vencido'
         when u.vencimento <= "16 - qsms".sst_hoje() + 30 then 'A vencer (30 dias)' else 'Em dia' end as sit_aso,
    case when not u.audiometria then 'Não realizada' when u.audiometria_proxima is null then 'Sem data'
         when u.audiometria_proxima < "16 - qsms".sst_hoje() then 'Vencida'
         when u.audiometria_proxima <= "16 - qsms".sst_hoje() + 30 then 'A vencer (30 dias)' else 'Em dia' end as sit_aud
  from u left join public.perfil p on p.id = u.pessoa_uuid left join "9 - suprimentos".sup_cargo sc on sc.id = p.cargo_id)
select id::text as "ID", coalesce(p_mat, matricula) as "Matrícula", p_nome as "Colaborador", p_area as "Área", p_cons as "Consórcio",
  p_cargo as "Cargo", tipo_exame as "Tipo de Exame", data_exame as "Data do Exame", vencimento as "Vencimento ASO",
  case when audiometria then 'Sim' else 'Não' end as "Realizou Audiometria",
  audiometria_data as "Última Audiometria", audiometria_proxima as "Próxima Audiometria",
  sit_aso as "Situação ASO",
  (case sit_aso when 'Em dia' then 1 when 'A vencer (30 dias)' then 2 when 'Vencido' then 3 else 4 end)::bigint as "Situação ASO Ordem",
  (vencimento - hoje)::bigint as "Dias p/ Vencer ASO",
  sit_aud as "Situação Audiometria",
  (case sit_aud when 'Em dia' then 1 when 'A vencer (30 dias)' then 2 when 'Vencida' then 3 when 'Sem data' then 4 else 5 end)::bigint as "Situação Audiometria Ordem"
from c;

-- treinamento vigente = o registro mais recente de cada colaborador ativo × tipo
create or replace view "16 - qsms".bi_sst_treinamentos as
with u as (
  select distinct on (coalesce(t.pessoa_uuid::text, lower(t.colaborador_nome)), t.tipo_id) t.*
  from "16 - qsms".sst_treinamento t left join public.perfil p on p.id = t.pessoa_uuid
  where t.anulado_em is null and (t.pessoa_uuid is null or coalesce(p.ativo, true))
  order by coalesce(t.pessoa_uuid::text, lower(t.colaborador_nome)), t.tipo_id, t.data_realizacao desc nulls last, t.criado_em desc),
c as (
  select u.*, tt.nome as tipo_nome, tt.validade_meses, coalesce(u.carga_horaria, tt.carga_horaria, 0) as ch,
    coalesce(p.nome, u.colaborador_nome) as p_nome, coalesce(p.area, u.area) as p_area,
    coalesce(sc.nome, p.cargo, u.cargo) as p_cargo, p.consorcio as p_cons,
    (u.data_realizacao + make_interval(months => tt.validade_meses))::date as venc
  from u join "16 - qsms".sst_treinamento_tipo tt on tt.id = u.tipo_id
  left join public.perfil p on p.id = u.pessoa_uuid left join "9 - suprimentos".sup_cargo sc on sc.id = p.cargo_id),
s as (
  select c.*, case when data_realizacao is null then 'Sem data de realização' when venc < "16 - qsms".sst_hoje() then 'Vencido'
                   when venc <= "16 - qsms".sst_hoje() + 60 then 'A vencer (60 dias)' else 'Válido' end as sit
  from c)
select id::text as "ID", p_nome as "Colaborador", p_area as "Área", p_cons as "Consórcio", p_cargo as "Cargo",
  tipo_nome as "Treinamento", data_realizacao as "Data de Realização", ch::double precision as "Carga Horária (h)",
  instrutor as "Instrutor", validade_meses::double precision as "Validade (meses)",
  case when data_realizacao is null then null else 'Concluído' end as "Status de Realização",
  venc as "Vencimento", sit as "Situação",
  (case sit when 'Válido' then 1 when 'A vencer (60 dias)' then 2 when 'Vencido' then 3 when 'Não realizado' then 4 else 5 end)::bigint as "Situação Ordem",
  case when data_realizacao is null then 'Sem data'
       else (array['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'])[extract(month from data_realizacao)::int]
            || '/' || to_char(data_realizacao, 'YY') end as "Mês de Realização",
  coalesce(date_trunc('month', data_realizacao)::date, date '2999-01-01') as "Mês de Realização Ordem"
from s;

create or replace view "16 - qsms".bi_sst_cipa_membros as
select m.id::text as "ID", coalesce(p.nome, m.nome) as "Membro", m.representacao as "Representação", m.tipo as "Tipo",
  m.cargo_cipa as "Cargo na CIPA", coalesce(m.area, p.area) as "Área", m.consorcio as "Consórcio",
  "16 - qsms".sst_consorcio_nome(m.consorcio) as "Empresa",
  m.inicio_mandato as "Início do Mandato", m.fim_mandato as "Fim do Mandato",
  case when m.fim_mandato is not null and m.fim_mandato < "16 - qsms".sst_hoje() then 'Encerrado' else 'Ativo' end as "Situação do Mandato"
from "16 - qsms".sst_cipa_membro m left join public.perfil p on p.id = m.pessoa_uuid
where m.anulado_em is null;

create or replace view "16 - qsms".bi_sst_cipa_reunioes as
select r.id::text as "ID", r.data as "Data", r.pauta as "Pauta", r.consorcio as "Consórcio",
  "16 - qsms".sst_consorcio_nome(r.consorcio) as "Empresa",
  coalesce(r.presentes, 0)::double precision as "Presentes", coalesce(r.total_membros, 0)::double precision as "Total de Membros",
  r.encaminhamentos as "Encaminhamentos"
from "16 - qsms".sst_cipa_reuniao r where r.anulado_em is null;

create or replace view "16 - qsms".bi_sst_area as
select distinct "Área" from (
  select "Área" from "16 - qsms".bi_sst_acidentes union all
  select "Área" from "16 - qsms".bi_sst_acidentes_vinculo union all
  select "Área" from "16 - qsms".bi_sst_inspecoes union all
  select "Área" from "16 - qsms".bi_sst_saude union all
  select "Área" from "16 - qsms".bi_sst_dds union all
  select "Área" from "16 - qsms".bi_sst_treinamentos) x
where "Área" is not null;

create or replace view "16 - qsms".bi_sst_info as
select (now() at time zone 'America/Sao_Paulo')::timestamp as "Atualizado em", 'Supabase · AcquaHub (schema 16 - qsms)'::text as "Arquivo";

-- login só-leitura do BI (sem senha aqui: o dono do projeto roda ALTER ROLE ... PASSWORD no SQL editor)
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'bi_qsms_leitura') then
    create role bi_qsms_leitura login noinherit;
  end if;
end $$;
alter role bi_qsms_leitura set statement_timeout = '60s';
alter role bi_qsms_leitura set default_transaction_read_only = on;
grant usage on schema "16 - qsms" to bi_qsms_leitura;

do $$
declare v text;
begin
  foreach v in array array['bi_sst_inspecoes','bi_sst_dds','bi_sst_acidentes','bi_sst_acidentes_vinculo','bi_sst_saude',
                           'bi_sst_treinamentos','bi_sst_cipa_membros','bi_sst_cipa_reunioes','bi_sst_area','bi_sst_info'] loop
    execute format('revoke all on "16 - qsms".%I from public, anon, authenticated', v);
    execute format('grant select on "16 - qsms".%I to bi_qsms_leitura', v);
  end loop;
end $$;
-- as views chamam sst_hoje/sst_consorcio_nome (executáveis por public por padrão) e leem as tabelas como dono.

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 5) RPCs DE GESTÃO (gate qsms_pode)
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
create or replace function "16 - qsms".sst_gestao_check()
returns uuid language plpgsql stable security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".qsms_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return auth.uid();
end $$;

create or replace function "16 - qsms".sst_nome(p_uid uuid)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(nome, email) from public.perfil where id = p_uid
$$;

-- painel consolidado: lê as próprias views do BI (uma regra só para app e BI)
create or replace function public.app_sst_painel(p_de date, p_ate date, p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_c text := nullif(btrim(p_consorcio),''); v_hoje date := "16 - qsms".sst_hoje(); r jsonb;
begin
  perform "16 - qsms".sst_gestao_check();
  with
  i as (select * from "16 - qsms".bi_sst_inspecoes where "Data" between p_de and p_ate and (v_c is null or "Consórcio" = v_c)),
  d as (select * from "16 - qsms".bi_sst_dds where "Data" between p_de and p_ate and (v_c is null or "Consórcio" = v_c)),
  o as (select * from "16 - qsms".sst_ocorrencia where anulado_em is null and data between p_de and p_ate and (v_c is null or consorcio = v_c)),
  s as (select * from "16 - qsms".bi_sst_saude where v_c is null or "Consórcio" = v_c),
  t as (select * from "16 - qsms".bi_sst_treinamentos where v_c is null or "Consórcio" = v_c),
  cm as (select * from "16 - qsms".bi_sst_cipa_membros where v_c is null or "Consórcio" = v_c),
  cr as (select * from "16 - qsms".bi_sst_cipa_reunioes where "Data" between p_de and p_ate and (v_c is null or "Consórcio" = v_c)),
  nc as (select x.* from "16 - qsms".sst_inspecao_item x join "16 - qsms".sst_inspecao ii on ii.id = x.inspecao_id
         where ii.anulado_em is null and x.trat_status = 'pendente' and (v_c is null or ii.consorcio = v_c))
  select jsonb_build_object(
    'inspecoes', (select jsonb_build_object('n', count(*), 'itens', coalesce(sum("Itens Verificados"),0), 'ncs', coalesce(sum("NCs Encontradas"),0),
        'tratadas', coalesce(sum("NCs Tratadas"),0),
        'conformidade', case when sum("Itens Verificados") > 0 then round(((sum("Itens Verificados") - sum("NCs Encontradas")) / sum("Itens Verificados"))::numeric, 4) end,
        'tratativas', case when sum("NCs Encontradas") > 0 then round((sum("NCs Tratadas") / sum("NCs Encontradas"))::numeric, 4) end) from i),
    'nc_pendentes', (select jsonb_build_object('n', count(*), 'vencidas', count(*) filter (where prazo < v_hoje)) from nc),
    'dds', (select jsonb_build_object('n', count(*), 'participacoes', coalesce(sum("Participantes"),0), 'efetivo', coalesce(sum("Efetivo da Área"),0),
        'participacao', case when sum("Efetivo da Área") > 0 then round((sum("Participantes") / sum("Efetivo da Área"))::numeric, 4) end,
        'horas', round(coalesce(sum("Duração (min)"),0)::numeric / 60, 1),
        'homem_hora', round(coalesce(sum("Participantes" * "Duração (min)"),0)::numeric / 60, 1)) from d),
    'ocorrencias', (select jsonb_build_object('acidentes', count(*) filter (where natureza = 'Acidente'),
        'com_afastamento', count(*) filter (where natureza = 'Acidente' and classificacao = 'Com Afastamento'),
        'sem_afastamento', count(*) filter (where natureza = 'Acidente' and classificacao = 'Sem Afastamento'),
        'graves', count(*) filter (where natureza = 'Acidente' and gravidade in ('Grave','Fatal')),
        'quase_acidentes', count(*) filter (where natureza = 'Quase acidente'),
        'incidentes', count(*) filter (where natureza = 'Incidente'),
        'a_validar', count(*) filter (where status = 'registrada'),
        'dias_perdidos', coalesce(sum(dias_perdidos) filter (where natureza = 'Acidente'),0),
        'proprios', count(*) filter (where natureza = 'Acidente' and vinculo = 'Próprio'),
        'terceiros', count(*) filter (where natureza = 'Acidente' and vinculo = 'Terceiro')) from o),
    'dias_sem_acidente_afast', (select v_hoje - max(data) from "16 - qsms".sst_ocorrencia
        where anulado_em is null and natureza = 'Acidente' and classificacao = 'Com Afastamento' and (v_c is null or consorcio = v_c)),
    'acoes', (select jsonb_build_object('abertas', count(*) filter (where ac.status <> 'Concluída'),
        'vencidas', count(*) filter (where ac.status <> 'Concluída' and ac.prazo < v_hoje), 'concluidas', count(*) filter (where ac.status = 'Concluída'))
      from "16 - qsms".sst_acao ac join "16 - qsms".sst_ocorrencia oo on oo.id = ac.ocorrencia_id
      where ac.anulado_em is null and oo.anulado_em is null and (v_c is null or oo.consorcio = v_c)),
    'aso', (select jsonb_build_object('total', count(*), 'em_dia', count(*) filter (where "Situação ASO" = 'Em dia'),
        'a_vencer', count(*) filter (where "Situação ASO" = 'A vencer (30 dias)'), 'vencidos', count(*) filter (where "Situação ASO" = 'Vencido'),
        'sem_data', count(*) filter (where "Situação ASO" = 'Sem data'),
        'audio_vencidas', count(*) filter (where "Situação Audiometria" = 'Vencida')) from s),
    'treinamentos', (select jsonb_build_object('total', count(*), 'validos', count(*) filter (where "Situação" = 'Válido'),
        'a_vencer', count(*) filter (where "Situação" = 'A vencer (60 dias)'), 'vencidos', count(*) filter (where "Situação" = 'Vencido'),
        'sem_data', count(*) filter (where "Situação" = 'Sem data de realização'),
        'por_tipo', coalesce((select jsonb_agg(jsonb_build_object('tipo', tp, 'validos', v, 'a_vencer', av, 'vencidos', ve, 'sem_data', sd) order by tp)
          from (select "Treinamento" tp, count(*) filter (where "Situação"='Válido') v, count(*) filter (where "Situação"='A vencer (60 dias)') av,
                count(*) filter (where "Situação"='Vencido') ve, count(*) filter (where "Situação"='Sem data de realização') sd
                from t group by 1) z), '[]'::jsonb)) from t),
    'cipa', jsonb_build_object('ativos', (select count(*) from cm where "Situação do Mandato" = 'Ativo'),
        'titulares', (select count(*) from cm where "Situação do Mandato" = 'Ativo' and "Tipo" = 'Titular'),
        'suplentes', (select count(*) from cm where "Situação do Mandato" = 'Ativo' and "Tipo" = 'Suplente'),
        'fim_mandato', (select max("Fim do Mandato") from cm where "Situação do Mandato" = 'Ativo'),
        'reunioes', (select count(*) from cr),
        'presenca', (select case when sum("Total de Membros") > 0 then round((sum("Presentes") / sum("Total de Membros"))::numeric, 4) end from cr)),
    'por_responsavel', coalesce((select jsonb_agg(jsonb_build_object('nome', nome, 'inspecoes', ni, 'dds', nd, 'ncs', nn) order by ni + nd desc, nome)
        from (select nome, sum(ni) ni, sum(nd) nd, sum(nn) nn from (
                select "Responsável" nome, count(*) ni, 0 nd, sum("NCs Encontradas") nn from i group by 1
                union all select "Responsável", 0, count(*), 0 from d group by 1) u group by nome) z), '[]'::jsonb),
    'por_semana', coalesce((select jsonb_agg(jsonb_build_object('semana', sem, 'inspecoes', ni, 'dds', nd) order by sem)
        from (select sem, sum(ni) ni, sum(nd) nd from (
                select date_trunc('week', "Data")::date sem, count(*) ni, 0 nd from i group by 1
                union all select date_trunc('week', "Data")::date, 0, count(*) from d group by 1) u group by sem) z), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- listas da gestão: p_tipo = inspecao | dds | ocorrencia
create or replace function public.app_sst_listar(p_tipo text, p_de date, p_ate date, p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_c text := nullif(btrim(p_consorcio),'');
begin
  perform "16 - qsms".sst_gestao_check();
  if p_tipo = 'inspecao' then
    return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'data',i.data,'consorcio',i.consorcio,'area',i.area,'local',i.local,
        'endereco',i.endereco,'bairro',i.bairro,'responsavel',i.responsavel_nome,'cargo',i.responsavel_cargo,'origem',i.origem,
        'lat',i.lat,'lon',i.lon,'alertas',i.alertas,'itens',b."Itens Verificados",'ncs',b."NCs Encontradas",'tratadas',b."NCs Tratadas",
        'pendentes',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.trat_status='pendente'),
        'vencidas',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.trat_status='pendente' and x.prazo < "16 - qsms".sst_hoje()))
        order by i.data desc, i.criado_em desc)
      from "16 - qsms".sst_inspecao i join "16 - qsms".bi_sst_inspecoes b on b."ID" = i.id::text
      where i.data between p_de and p_ate and (v_c is null or i.consorcio = v_c)), '[]'::jsonb);
  elsif p_tipo = 'dds' then
    return coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'data',d.data,'consorcio',d.consorcio,'area',d.area,'tema',d.tema,
        'responsavel',d.responsavel_nome,'duracao_min',d.duracao_min,'participantes',b."Participantes",'efetivo',b."Efetivo da Área",
        'origem',d.origem,'endereco',d.endereco,'lat',d.lat,'lon',d.lon,'alertas',d.alertas) order by d.data desc, d.criado_em desc)
      from "16 - qsms".sst_dds d join "16 - qsms".bi_sst_dds b on b."ID" = d.id::text
      where d.data between p_de and p_ate and (v_c is null or d.consorcio = v_c)), '[]'::jsonb);
  elsif p_tipo = 'ocorrencia' then
    return coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'data',o.data,'hora',o.hora,'natureza',o.natureza,'tipo',o.tipo,
        'consorcio',o.consorcio,'area',o.area,'setor_local',o.setor_local,'vinculo',o.vinculo,'empresa',o.empresa,'vitima',o.vitima_nome,
        'classificacao',o.classificacao,'gravidade',o.gravidade,'dias_perdidos',o.dias_perdidos,'cat_emitida',o.cat_emitida,'status',o.status,
        'registrado_por',o.usuario_nome,'endereco',o.endereco,'lat',o.lat,'lon',o.lon,'alertas',o.alertas,
        'acoes_abertas',(select count(*) from "16 - qsms".sst_acao a where a.ocorrencia_id=o.id and a.anulado_em is null and a.status<>'Concluída'))
        order by o.data desc, o.criado_em desc)
      from "16 - qsms".sst_ocorrencia o
      where o.anulado_em is null and o.data between p_de and p_ate and (v_c is null or o.consorcio = v_c)), '[]'::jsonb);
  end if;
  raise exception 'tipo inválido';
end $$;

create or replace function public.app_sst_ver(p_tipo text, p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; v_tab text;
begin
  -- quem lançou pode ver o próprio registro; a gestão vê tudo
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if p_tipo = 'inspecao' then
    select to_jsonb(i) - 'geom' || jsonb_build_object('itens', coalesce((select jsonb_agg(to_jsonb(x) order by x.ordem)
      from "16 - qsms".sst_inspecao_item x where x.inspecao_id = i.id), '[]'::jsonb)) into r
      from "16 - qsms".sst_inspecao i where i.id = p_id and ("16 - qsms".qsms_pode(auth.uid()) or i.usuario_uuid = auth.uid());
    v_tab := 'sst_inspecao';
  elsif p_tipo = 'dds' then
    select to_jsonb(d) - 'geom' || jsonb_build_object('presenca', coalesce((select jsonb_agg(to_jsonb(x) order by x.ordem)
      from "16 - qsms".sst_dds_presenca x where x.dds_id = d.id), '[]'::jsonb)) into r
      from "16 - qsms".sst_dds d where d.id = p_id and ("16 - qsms".qsms_pode(auth.uid()) or d.usuario_uuid = auth.uid());
    v_tab := 'sst_dds';
  elsif p_tipo = 'ocorrencia' then
    select to_jsonb(o) - 'geom' || jsonb_build_object('acoes', coalesce((select jsonb_agg(to_jsonb(a) order by a.criado_em)
      from "16 - qsms".sst_acao a where a.ocorrencia_id = o.id and a.anulado_em is null), '[]'::jsonb)) into r
      from "16 - qsms".sst_ocorrencia o where o.id = p_id and ("16 - qsms".qsms_pode(auth.uid()) or o.usuario_uuid = auth.uid());
    v_tab := 'sst_ocorrencia';
  else raise exception 'tipo inválido';
  end if;
  if r is null then raise exception 'registro não encontrado'; end if;
  if "16 - qsms".qsms_pode(auth.uid()) then
    r := r || jsonb_build_object('historico', coalesce((select jsonb_agg(jsonb_build_object('em', e.em, 'por', "16 - qsms".sst_nome(e.por),
        'tabela', e.tabela) order by e.em)
      from "16 - qsms".sst_evento e where e.registro_id = p_id::text and e.tabela = v_tab), '[]'::jsonb));
  end if;
  return r;
end $$;

create or replace function public.app_sst_nc_tratar(p_item uuid, p_status text, p_obs text default null, p_foto text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check();
begin
  if p_status not in ('pendente','tratada') then raise exception 'situação inválida'; end if;
  if p_status = 'tratada' and nullif(btrim(p_obs),'') is null then raise exception 'descreva a tratativa'; end if;
  update "16 - qsms".sst_inspecao_item set trat_status = p_status,
      trat_obs = case when p_status = 'tratada' then btrim(p_obs) end,
      trat_foto = case when p_status = 'tratada' then nullif(p_foto,'') end,
      trat_em = case when p_status = 'tratada' then now() end,
      trat_por = case when p_status = 'tratada' then v_uid end,
      trat_por_nome = case when p_status = 'tratada' then "16 - qsms".sst_nome(v_uid) end
    where id = p_item and resultado = 'NC';
  if not found then raise exception 'NC não encontrada'; end if;
end $$;

-- validação da ocorrência pela gestão (classificação, gravidade, dias, CAT, vínculo…)
create or replace function public.app_sst_ocorrencia_validar(p_id uuid, p_dados jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); d jsonb := coalesce(p_dados,'{}'::jsonb);
begin
  update "16 - qsms".sst_ocorrencia o set
    natureza = case when d ? 'natureza' and d->>'natureza' in ('Acidente','Quase acidente','Incidente') then d->>'natureza' else o.natureza end,
    tipo = case when d ? 'tipo' then nullif(btrim(d->>'tipo'),'') else o.tipo end,
    area = case when d ? 'area' then nullif(btrim(d->>'area'),'') else o.area end,
    setor_local = case when d ? 'setor_local' then nullif(btrim(d->>'setor_local'),'') else o.setor_local end,
    vinculo = case when d ? 'vinculo' then case when d->>'vinculo' in ('Próprio','Terceiro') then d->>'vinculo' end else o.vinculo end,
    empresa = case when d ? 'empresa' then nullif(btrim(d->>'empresa'),'') else o.empresa end,
    parte_corpo = case when d ? 'parte_corpo' then nullif(btrim(d->>'parte_corpo'),'') else o.parte_corpo end,
    causa = case when d ? 'causa' then nullif(btrim(d->>'causa'),'') else o.causa end,
    descricao = case when d ? 'descricao' then nullif(btrim(d->>'descricao'),'') else o.descricao end,
    classificacao = case when d ? 'classificacao' then case when d->>'classificacao' in ('Com Afastamento','Sem Afastamento') then d->>'classificacao' end else o.classificacao end,
    gravidade = case when d ? 'gravidade' then case when d->>'gravidade' in ('Leve','Moderada','Grave','Fatal') then d->>'gravidade' end else o.gravidade end,
    dias_perdidos = case when d ? 'dias_perdidos' then greatest(coalesce(nullif(d->>'dias_perdidos','')::int,0),0) else o.dias_perdidos end,
    dias_debitados = case when d ? 'dias_debitados' then greatest(coalesce(nullif(d->>'dias_debitados','')::int,0),0) else o.dias_debitados end,
    cat_emitida = case when d ? 'cat_emitida' then nullif(d->>'cat_emitida','')::boolean else o.cat_emitida end,
    status = case when coalesce((d->>'validar')::boolean, true) then 'validada' else o.status end,
    validado_em = case when coalesce((d->>'validar')::boolean, true) then now() else o.validado_em end,
    validado_por = case when coalesce((d->>'validar')::boolean, true) then v_uid else o.validado_por end,
    validado_por_nome = case when coalesce((d->>'validar')::boolean, true) then "16 - qsms".sst_nome(v_uid) else o.validado_por_nome end
  where o.id = p_id and o.anulado_em is null;
  if not found then raise exception 'ocorrência não encontrada'; end if;
end $$;

-- ação corretiva (p_id nulo = nova)
create or replace function public.app_sst_acao_salvar(p_id uuid, p_ocorrencia uuid, p_dados jsonb)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_id uuid; v_st text; v_resp uuid;
begin
  v_st := case when d->>'status' in ('Aberta','Em andamento','Concluída') then d->>'status' else 'Aberta' end;
  v_resp := nullif(d->>'responsavel_uuid','')::uuid;
  if nullif(btrim(d->>'descricao'),'') is null then raise exception 'descreva a ação'; end if;
  if p_id is null then
    if not exists (select 1 from "16 - qsms".sst_ocorrencia where id = p_ocorrencia and anulado_em is null) then raise exception 'ocorrência não encontrada'; end if;
    insert into "16 - qsms".sst_acao(ocorrencia_id, descricao, responsavel_uuid, responsavel_nome, prazo, status, concluida_em, obs, criado_por)
    values (p_ocorrencia, btrim(d->>'descricao'), v_resp, coalesce(nullif(btrim(d->>'responsavel_nome'),''), "16 - qsms".sst_nome(v_resp)),
      nullif(d->>'prazo','')::date, v_st, case when v_st = 'Concluída' then coalesce(nullif(d->>'concluida_em','')::date, "16 - qsms".sst_hoje()) end,
      nullif(btrim(d->>'obs'),''), v_uid)
    returning id into v_id;
  else
    update "16 - qsms".sst_acao set descricao = btrim(d->>'descricao'), responsavel_uuid = v_resp,
        responsavel_nome = coalesce(nullif(btrim(d->>'responsavel_nome'),''), "16 - qsms".sst_nome(v_resp)),
        prazo = nullif(d->>'prazo','')::date, status = v_st,
        concluida_em = case when v_st = 'Concluída' then coalesce(nullif(d->>'concluida_em','')::date, concluida_em, "16 - qsms".sst_hoje()) end,
        obs = nullif(btrim(d->>'obs'),'')
      where id = p_id and anulado_em is null returning id into v_id;
    if v_id is null then raise exception 'ação não encontrada'; end if;
  end if;
  return v_id;
end $$;

-- anular (registro errado sai das views e do painel; fica guardado). p_tipo = inspecao|dds|ocorrencia|acao|aso|treinamento|cipa_membro|cipa_reuniao
create or replace function public.app_sst_anular(p_tipo text, p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); v_tab text; n int;
begin
  if nullif(btrim(p_motivo),'') is null then raise exception 'informe o motivo'; end if;
  v_tab := case p_tipo when 'inspecao' then 'sst_inspecao' when 'dds' then 'sst_dds' when 'ocorrencia' then 'sst_ocorrencia'
    when 'acao' then 'sst_acao' when 'aso' then 'sst_aso' when 'treinamento' then 'sst_treinamento'
    when 'cipa_membro' then 'sst_cipa_membro' when 'cipa_reuniao' then 'sst_cipa_reuniao' end;
  if v_tab is null then raise exception 'tipo inválido'; end if;
  execute format('update "16 - qsms".%I set anulado_em = now(), anulado_por = $1, anulado_motivo = $2 where id = $3 and anulado_em is null', v_tab)
    using v_uid, btrim(p_motivo), p_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'registro não encontrado (ou já anulado)'; end if;
end $$;

-- ASO
create or replace function public.app_sst_aso_listar(p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_c text := nullif(btrim(p_consorcio),'');
begin
  perform "16 - qsms".sst_gestao_check();
  return jsonb_build_object(
    'vigentes', coalesce((select jsonb_agg(to_jsonb(b) order by b."Colaborador") from "16 - qsms".bi_sst_saude b where v_c is null or b."Consórcio" = v_c), '[]'::jsonb),
    'sem_aso', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', coalesce(p.nome, p.email), 'area', p.area, 'consorcio', p.consorcio,
        'matricula', p.matricula) order by coalesce(p.nome, p.email))
      from public.perfil p where coalesce(p.ativo, true) and (v_c is null or p.consorcio = v_c)
        and not exists (select 1 from "16 - qsms".sst_aso s where s.pessoa_uuid = p.id and s.anulado_em is null)), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(to_jsonb(s) order by s.data_exame desc nulls last)
      from "16 - qsms".sst_aso s left join public.perfil p on p.id = s.pessoa_uuid
      where s.anulado_em is null and (v_c is null or p.consorcio = v_c)), '[]'::jsonb));
end $$;

create or replace function public.app_sst_aso_salvar(p_id uuid, p_dados jsonb)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_id uuid; v_pid uuid; v_nome text;
  v_tipo text; v_ex date; v_venc date;
begin
  v_pid := nullif(d->>'pessoa_uuid','')::uuid;
  v_nome := coalesce((select coalesce(nome, email) from public.perfil where id = v_pid), nullif(btrim(d->>'colaborador_nome'),''));
  if v_nome is null then raise exception 'informe o colaborador'; end if;
  v_tipo := d->>'tipo_exame';
  if v_tipo is null or v_tipo not in ('Admissional','Periódico','Retorno ao Trabalho','Mudança de Função','Demissional') then raise exception 'tipo de exame inválido'; end if;
  v_ex := nullif(d->>'data_exame','')::date;
  v_venc := nullif(d->>'vencimento','')::date;
  if v_venc is null and v_ex is not null and v_tipo <> 'Demissional' then v_venc := (v_ex + interval '12 months')::date; end if;
  if p_id is null then
    insert into "16 - qsms".sst_aso(pessoa_uuid, colaborador_nome, matricula, area, cargo, tipo_exame, data_exame, vencimento, audiometria,
      audiometria_data, audiometria_proxima, arquivo, obs, criado_por)
    values (v_pid, v_nome, nullif(btrim(d->>'matricula'),''), nullif(btrim(d->>'area'),''), nullif(btrim(d->>'cargo'),''), v_tipo, v_ex, v_venc,
      coalesce((d->>'audiometria')::boolean, false), nullif(d->>'audiometria_data','')::date, nullif(d->>'audiometria_proxima','')::date,
      nullif(d->>'arquivo',''), nullif(btrim(d->>'obs'),''), v_uid)
    returning id into v_id;
  else
    update "16 - qsms".sst_aso set pessoa_uuid = v_pid, colaborador_nome = v_nome, matricula = nullif(btrim(d->>'matricula'),''),
        area = nullif(btrim(d->>'area'),''), cargo = nullif(btrim(d->>'cargo'),''), tipo_exame = v_tipo, data_exame = v_ex, vencimento = v_venc,
        audiometria = coalesce((d->>'audiometria')::boolean, false), audiometria_data = nullif(d->>'audiometria_data','')::date,
        audiometria_proxima = nullif(d->>'audiometria_proxima','')::date, arquivo = coalesce(nullif(d->>'arquivo',''), arquivo),
        obs = nullif(btrim(d->>'obs'),'')
      where id = p_id and anulado_em is null returning id into v_id;
    if v_id is null then raise exception 'ASO não encontrado'; end if;
  end if;
  return v_id;
end $$;

-- Treinamentos
create or replace function public.app_sst_trein_tipos()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform "16 - qsms".sst_gestao_check();
  return coalesce((select jsonb_agg(to_jsonb(t) order by t.ordem, t.id) from "16 - qsms".sst_treinamento_tipo t), '[]'::jsonb);
end $$;

create or replace function public.app_sst_trein_tipo_salvar(p_id integer, p_dados jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare d jsonb := coalesce(p_dados,'{}'::jsonb); v_id int;
begin
  perform "16 - qsms".sst_gestao_check();
  if nullif(btrim(d->>'nome'),'') is null then raise exception 'informe o nome'; end if;
  if coalesce(nullif(d->>'validade_meses','')::int, 0) <= 0 then raise exception 'validade em meses inválida'; end if;
  if p_id is null then
    insert into "16 - qsms".sst_treinamento_tipo(nome, validade_meses, carga_horaria, ordem, ativo)
    values (btrim(d->>'nome'), (d->>'validade_meses')::int, nullif(d->>'carga_horaria','')::numeric,
      coalesce(nullif(d->>'ordem','')::int, (select coalesce(max(ordem),0)+1 from "16 - qsms".sst_treinamento_tipo)), coalesce((d->>'ativo')::boolean, true))
    returning id into v_id;
  else
    update "16 - qsms".sst_treinamento_tipo set nome = btrim(d->>'nome'), validade_meses = (d->>'validade_meses')::int,
        carga_horaria = nullif(d->>'carga_horaria','')::numeric, ordem = coalesce(nullif(d->>'ordem','')::int, ordem),
        ativo = coalesce((d->>'ativo')::boolean, ativo)
      where id = p_id returning id into v_id;
    if v_id is null then raise exception 'tipo não encontrado'; end if;
  end if;
  return v_id;
end $$;

-- matriz pessoa × tipo (situação vigente) + colaboradores ativos sem nenhum registro
create or replace function public.app_sst_trein_matriz(p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_c text := nullif(btrim(p_consorcio),'');
begin
  perform "16 - qsms".sst_gestao_check();
  return jsonb_build_object(
    'tipos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'validade_meses', validade_meses) order by ordem, id), '[]'::jsonb)
              from "16 - qsms".sst_treinamento_tipo where ativo),
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', coalesce(p.nome, p.email), 'area', p.area,
        'cargo', coalesce(sc.nome, p.cargo), 'consorcio', p.consorcio,
        'treinos', coalesce((select jsonb_object_agg(tt.id::text, jsonb_build_object('registro', b."ID", 'data', b."Data de Realização",
              'vencimento', b."Vencimento", 'situacao', b."Situação"))
            from "16 - qsms".bi_sst_treinamentos b join "16 - qsms".sst_treinamento t on t.id::text = b."ID"
            join "16 - qsms".sst_treinamento_tipo tt on tt.id = t.tipo_id where t.pessoa_uuid = p.id), '{}'::jsonb))
        order by coalesce(p.nome, p.email))
      from public.perfil p left join "9 - suprimentos".sup_cargo sc on sc.id = p.cargo_id
      where coalesce(p.ativo, true) and (v_c is null or p.consorcio = v_c)), '[]'::jsonb),
    'sem_vinculo', coalesce((select jsonb_agg(to_jsonb(b) order by b."Colaborador")
      from "16 - qsms".bi_sst_treinamentos b join "16 - qsms".sst_treinamento t on t.id::text = b."ID" where t.pessoa_uuid is null), '[]'::jsonb));
end $$;

create or replace function public.app_sst_trein_salvar(p_id uuid, p_dados jsonb)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_id uuid; v_pid uuid; v_nome text; v_tipo int; v_dt date;
begin
  v_pid := nullif(d->>'pessoa_uuid','')::uuid;
  v_nome := coalesce((select coalesce(nome, email) from public.perfil where id = v_pid), nullif(btrim(d->>'colaborador_nome'),''));
  if v_nome is null then raise exception 'informe o colaborador'; end if;
  v_tipo := nullif(d->>'tipo_id','')::int;
  if not exists (select 1 from "16 - qsms".sst_treinamento_tipo where id = v_tipo) then raise exception 'tipo de treinamento inválido'; end if;
  v_dt := nullif(d->>'data_realizacao','')::date;
  if v_dt > "16 - qsms".sst_hoje() then raise exception 'data de realização no futuro'; end if;
  if p_id is null then
    insert into "16 - qsms".sst_treinamento(pessoa_uuid, colaborador_nome, area, cargo, tipo_id, data_realizacao, carga_horaria, instrutor, certificado, obs, criado_por)
    values (v_pid, v_nome, nullif(btrim(d->>'area'),''), nullif(btrim(d->>'cargo'),''), v_tipo, v_dt, nullif(d->>'carga_horaria','')::numeric,
      nullif(btrim(d->>'instrutor'),''), nullif(d->>'certificado',''), nullif(btrim(d->>'obs'),''), v_uid)
    returning id into v_id;
  else
    update "16 - qsms".sst_treinamento set pessoa_uuid = v_pid, colaborador_nome = v_nome, tipo_id = v_tipo, data_realizacao = v_dt,
        carga_horaria = nullif(d->>'carga_horaria','')::numeric, instrutor = nullif(btrim(d->>'instrutor'),''),
        certificado = coalesce(nullif(d->>'certificado',''), certificado), obs = nullif(btrim(d->>'obs'),'')
      where id = p_id and anulado_em is null returning id into v_id;
    if v_id is null then raise exception 'registro não encontrado'; end if;
  end if;
  return v_id;
end $$;

-- CIPA
create or replace function public.app_sst_cipa_listar()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform "16 - qsms".sst_gestao_check();
  return jsonb_build_object(
    'membros', coalesce((select jsonb_agg(to_jsonb(b) || jsonb_build_object('pessoa_uuid', m.pessoa_uuid) order by b."Empresa", b."Tipo", b."Membro")
      from "16 - qsms".bi_sst_cipa_membros b join "16 - qsms".sst_cipa_membro m on m.id::text = b."ID"), '[]'::jsonb),
    'reunioes', coalesce((select jsonb_agg(to_jsonb(b) order by b."Data" desc) from "16 - qsms".bi_sst_cipa_reunioes b), '[]'::jsonb));
end $$;

create or replace function public.app_sst_cipa_membro_salvar(p_id uuid, p_dados jsonb)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_id uuid; v_pid uuid; v_nome text;
begin
  v_pid := nullif(d->>'pessoa_uuid','')::uuid;
  v_nome := coalesce((select coalesce(nome, email) from public.perfil where id = v_pid), nullif(btrim(d->>'nome'),''));
  if v_nome is null then raise exception 'informe o membro'; end if;
  if p_id is null then
    insert into "16 - qsms".sst_cipa_membro(pessoa_uuid, nome, representacao, tipo, cargo_cipa, area, consorcio, inicio_mandato, fim_mandato, criado_por)
    values (v_pid, v_nome, case when d->>'representacao' in ('Empregador','Empregados') then d->>'representacao' end,
      case when d->>'tipo' in ('Titular','Suplente') then d->>'tipo' end, nullif(btrim(d->>'cargo_cipa'),''), nullif(btrim(d->>'area'),''),
      case when d->>'consorcio' in ('ZA1004','ZA0200') then d->>'consorcio' end, nullif(d->>'inicio_mandato','')::date, nullif(d->>'fim_mandato','')::date, v_uid)
    returning id into v_id;
  else
    update "16 - qsms".sst_cipa_membro set pessoa_uuid = v_pid, nome = v_nome,
        representacao = case when d->>'representacao' in ('Empregador','Empregados') then d->>'representacao' end,
        tipo = case when d->>'tipo' in ('Titular','Suplente') then d->>'tipo' end, cargo_cipa = nullif(btrim(d->>'cargo_cipa'),''),
        area = nullif(btrim(d->>'area'),''), consorcio = case when d->>'consorcio' in ('ZA1004','ZA0200') then d->>'consorcio' end,
        inicio_mandato = nullif(d->>'inicio_mandato','')::date, fim_mandato = nullif(d->>'fim_mandato','')::date
      where id = p_id and anulado_em is null returning id into v_id;
    if v_id is null then raise exception 'membro não encontrado'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.app_sst_cipa_reuniao_salvar(p_id uuid, p_dados jsonb)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := "16 - qsms".sst_gestao_check(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_id uuid; v_dt date;
begin
  v_dt := nullif(d->>'data','')::date;
  if v_dt is null then raise exception 'informe a data'; end if;
  if p_id is null then
    insert into "16 - qsms".sst_cipa_reuniao(data, consorcio, pauta, presentes, total_membros, encaminhamentos, ata, criado_por)
    values (v_dt, case when d->>'consorcio' in ('ZA1004','ZA0200') then d->>'consorcio' end, nullif(btrim(d->>'pauta'),''),
      nullif(d->>'presentes','')::int, nullif(d->>'total_membros','')::int, nullif(btrim(d->>'encaminhamentos'),''), nullif(d->>'ata',''), v_uid)
    returning id into v_id;
  else
    update "16 - qsms".sst_cipa_reuniao set data = v_dt, consorcio = case when d->>'consorcio' in ('ZA1004','ZA0200') then d->>'consorcio' end,
        pauta = nullif(btrim(d->>'pauta'),''), presentes = nullif(d->>'presentes','')::int, total_membros = nullif(d->>'total_membros','')::int,
        encaminhamentos = nullif(btrim(d->>'encaminhamentos'),''), ata = coalesce(nullif(d->>'ata',''), ata)
      where id = p_id and anulado_em is null returning id into v_id;
    if v_id is null then raise exception 'reunião não encontrada'; end if;
  end if;
  return v_id;
end $$;

-- checklist-modelo da inspeção (gestão)
create or replace function public.app_sst_modelo_salvar(p_id integer, p_dados jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare d jsonb := coalesce(p_dados,'{}'::jsonb); v_id int;
begin
  perform "16 - qsms".sst_gestao_check();
  if nullif(btrim(d->>'item'),'') is null or nullif(btrim(d->>'grupo'),'') is null then raise exception 'informe grupo e item'; end if;
  if p_id is null then
    insert into "16 - qsms".sst_inspecao_modelo(grupo, item, ordem, ativo)
    values (btrim(d->>'grupo'), btrim(d->>'item'), coalesce(nullif(d->>'ordem','')::int, (select coalesce(max(ordem),0)+1 from "16 - qsms".sst_inspecao_modelo)),
      coalesce((d->>'ativo')::boolean, true))
    returning id into v_id;
  else
    update "16 - qsms".sst_inspecao_modelo set grupo = btrim(d->>'grupo'), item = btrim(d->>'item'),
        ordem = coalesce(nullif(d->>'ordem','')::int, ordem), ativo = coalesce((d->>'ativo')::boolean, ativo)
      where id = p_id returning id into v_id;
    if v_id is null then raise exception 'item não encontrado'; end if;
  end if;
  return v_id;
end $$;

-- ═════════════════════════════════════════════════════════════════════════════════════════════════
-- 6) GRANTS: RPCs públicas → só authenticated; helpers internos sem grant
-- ═════════════════════════════════════════════════════════════════════════════════════════════════
do $$
declare f text;
begin
  foreach f in array array[
    'public.app_qsms_campo_set(uuid,boolean)',
    'public.app_sst_modelo_listar()',
    'public.app_sst_inspecao_registrar(uuid,jsonb,jsonb)',
    'public.app_sst_dds_registrar(uuid,jsonb,jsonb)',
    'public.app_sst_ocorrencia_registrar(uuid,jsonb,jsonb)',
    'public.app_sst_minhas(integer)',
    'public.app_sst_painel(date,date,text)',
    'public.app_sst_listar(text,date,date,text)',
    'public.app_sst_ver(text,uuid)',
    'public.app_sst_nc_tratar(uuid,text,text,text)',
    'public.app_sst_ocorrencia_validar(uuid,jsonb)',
    'public.app_sst_acao_salvar(uuid,uuid,jsonb)',
    'public.app_sst_anular(text,uuid,text)',
    'public.app_sst_aso_listar(text)',
    'public.app_sst_aso_salvar(uuid,jsonb)',
    'public.app_sst_trein_tipos()',
    'public.app_sst_trein_tipo_salvar(integer,jsonb)',
    'public.app_sst_trein_matriz(text)',
    'public.app_sst_trein_salvar(uuid,jsonb)',
    'public.app_sst_cipa_listar()',
    'public.app_sst_cipa_membro_salvar(uuid,jsonb)',
    'public.app_sst_cipa_reuniao_salvar(uuid,jsonb)',
    'public.app_sst_modelo_salvar(integer,jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    '"16 - qsms".sst_campo_pode(uuid)', '"16 - qsms".sst_efetivo(text,text,date)', '"16 - qsms".sst_gestao_check()',
    '"16 - qsms".sst_nome(uuid)', '"16 - qsms".sst_trg_audit()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
-- app_me / app_qsms_acesso_listar mantêm os grants que já tinham (create or replace preserva).
