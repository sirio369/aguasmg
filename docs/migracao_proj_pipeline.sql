-- Projetos · PIPELINE Engenharia → Qualidade → Obras (banco). 2026-11-02.
-- Cada intervenção passa por 5 fases; cada fase só abre quando a anterior fecha:
--   1 Projeto (Engenharia insere, liga/desliga etapas, anexa os documentos de projeto e LIBERA)
--   2 Aprovação (Qualidade aprova/reprova cada documento — data, usuário, comentário; reprovado volta p/ quem anexou)
--   3 Pré-obra (Obras: vistoria cautelar [link SharePoint, aprovada pela Qualidade], liberações, licença, OS SIGOS)
--   4 Execução (Obras lança o avanço — a árvore de sempre, em intervencao_estado.arv)
--   5 Encerramento (relatórios de Obras e o As built aprovados pela Qualidade + Relatório de Qualidade da Pavimentação)
-- Etapas por tipo (hdd/vca/vrp/registro/macro) em etapa_modelo (dado, não código). Estado atual em intervencao_etapa;
-- histórico append-only em intervencao_etapa_evento. Avisos por trigger no evento (sup_notificar).
-- Atores: Engenharia = admin/proj_sup_acesso · Qualidade = pav_qualidade_pode · Obras = admin ou cargo
-- Supervisor de Produção / Coordenador de Serviços / Gestor de Obras.
-- LEGADO: as intervenções já liberadas (locked) viram legado=true — sem portões de fase; o que já existe (documentos,
-- OS SIGOS da árvore) entra como etapa enviada; o que falta fica pendente sem travar.
-- Remove "7 - setorizacao".intervencoes_*.situacao_atual (sem uso; backup em "13 - projetos_obra"._bkp_proj_situacao_atual_20261102).
-- Nenhuma RPC existente muda de assinatura: o app em cache (≤ v316) segue funcionando.
-- Idempotente.

-- 0) backups (antes de qualquer mudança)
do $do$ begin
  if to_regclass('"13 - projetos_obra"._bkp_proj_estado_20261102') is null then
    create table "13 - projetos_obra"._bkp_proj_estado_20261102 as select * from "13 - projetos_obra".intervencao_estado;
    create table "13 - projetos_obra"._bkp_proj_documento_20261102 as select * from "13 - projetos_obra".intervencao_documento;
    create table "13 - projetos_obra"._bkp_proj_avanco_20261102 as select * from "13 - projetos_obra".intervencao_avanco;
  end if;
  if to_regclass('"13 - projetos_obra"._bkp_proj_situacao_atual_20261102') is null
     and exists (select 1 from information_schema.columns where table_schema='7 - setorizacao'
                 and table_name='intervencoes_pontuais' and column_name='situacao_atual') then
    create table "13 - projetos_obra"._bkp_proj_situacao_atual_20261102 as
      select 'ponto'::text kind, gid, id, situacao_atual from "7 - setorizacao".intervencoes_pontuais
      union all select 'linha', gid, id, situacao_atual from "7 - setorizacao".intervencoes_lineares;
  end if;
end $do$;
alter table "13 - projetos_obra"._bkp_proj_estado_20261102 enable row level security;
alter table "13 - projetos_obra"._bkp_proj_documento_20261102 enable row level security;
alter table "13 - projetos_obra"._bkp_proj_avanco_20261102 enable row level security;
alter table "13 - projetos_obra"._bkp_proj_situacao_atual_20261102 enable row level security;
revoke all on table "13 - projetos_obra"._bkp_proj_estado_20261102, "13 - projetos_obra"._bkp_proj_documento_20261102,
  "13 - projetos_obra"._bkp_proj_avanco_20261102, "13 - projetos_obra"._bkp_proj_situacao_atual_20261102 from public, anon, authenticated;

-- 1) atores
create or replace function "13 - projetos_obra".proj_obras_cargos()
returns text[] language sql immutable as $f$
  select array['Supervisor de Produção','Coordenador de Serviços','Gestor de Obras'];
$f$;
create or replace function "13 - projetos_obra".proj_eng_pode(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists (select 1 from public.perfil p where p.id = p_uid and coalesce(p.ativo, true)
                 and (p.funcao = 'admin' or coalesce(p.proj_sup_acesso, false)));
$f$;
create or replace function "13 - projetos_obra".proj_obras_pode(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $f$
  select exists (select 1 from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id
                 where p.id = p_uid and coalesce(p.ativo, true)
                   and (p.funcao = 'admin' or c.nome = any("13 - projetos_obra".proj_obras_cargos())));
$f$;
create or replace function "13 - projetos_obra".proj_ator_pode(p_uid uuid, p_ator text)
returns boolean language sql stable security definer set search_path to 'public' as $f$
  select case p_ator when 'eng' then "13 - projetos_obra".proj_eng_pode(p_uid)
                     when 'obra' then "13 - projetos_obra".proj_obras_pode(p_uid)
                     when 'qual' then "8 - coleta_campo".pav_qualidade_pode(p_uid) else false end;
$f$;
-- quem recebe os avisos de grupo (admin só se tiver a chave/cargo, como na Qualidade)
create or replace function "13 - projetos_obra".proj_obras_uuids()
returns uuid[] language sql stable security definer set search_path to 'public' as $f$
  select coalesce(array_agg(p.id), '{}') from public.perfil p join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id
   where coalesce(p.ativo, true) and c.nome = any("13 - projetos_obra".proj_obras_cargos());
$f$;
create or replace function "13 - projetos_obra".proj_eng_uuids()
returns uuid[] language sql stable security definer set search_path to 'public' as $f$
  select coalesce(array_agg(p.id), '{}') from public.perfil p where coalesce(p.ativo, true) and coalesce(p.proj_sup_acesso, false);
$f$;

-- 2) intervenções (pontos + linhas) com o tipo do pipeline e o consórcio
create or replace view "13 - projetos_obra".vw_iv as
  select 'ponto'::text kind, gid, id, projeto, cidade, dmc, tipo tipo_origem,
    case when tipo ilike 'vrp' then 'vrp'
         when tipo ilike any (array['valvula','válvula','registro']) then 'registro'
         when tipo ilike 'macromedidor' then 'macro' else 'vrp' end tipo,
    case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end consorcio
  from "7 - setorizacao".intervencoes_pontuais
  union all
  select 'linha', gid, id, projeto, cidade, dmc, tipo,
    case when coalesce(tipo,'') || ' ' || coalesce(layer_dwg,'') ~* 'HDD' then 'hdd' else 'vca' end,
    case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end
  from "7 - setorizacao".intervencoes_lineares;
revoke all on table "13 - projetos_obra".vw_iv from public, anon, authenticated;

-- 3) modelo de etapas por tipo (+ histórico de prazos)
create table if not exists "13 - projetos_obra".etapa_modelo (
  tipo text not null check (tipo in ('hdd','vca','vrp','registro','macro')),
  chave text not null,
  ordem int not null,
  fase smallint not null check (fase between 1 and 5),
  ator text not null check (ator in ('eng','qual','obra')),
  natureza text not null check (natureza in ('doc','aprovacao','link','os','avanco','ensaio')),
  nome text not null,
  aprova text,                                  -- natureza 'aprovacao': chave do item aprovado
  pede_folha boolean not null default false,    -- PDF com tamanho de folha (A0–A4)
  padrao_ativo boolean not null default true,   -- "No escopo?" padrão
  prazo_aten int, prazo_atraso int,             -- dias corridos: ≤aten no prazo · ≤atraso atenção · > atrasado (null = sem prazo)
  aliases text[] not null default '{}',         -- rótulos antigos (avanço) que casam com esta etapa
  primary key (tipo, chave),
  check ((natureza = 'aprovacao') = (aprova is not null)),
  check ((prazo_aten is null) = (prazo_atraso is null)),
  check (prazo_aten is null or (prazo_aten >= 0 and prazo_atraso > prazo_aten)));
create table if not exists "13 - projetos_obra".etapa_modelo_log (
  id bigint generated always as identity primary key,
  tipo text not null, chave text not null,
  prazo_aten_antes int, prazo_atraso_antes int, prazo_aten int, prazo_atraso int,
  por_uuid uuid, por_nome text, em timestamptz not null default now());

insert into "13 - projetos_obra".etapa_modelo as em
  (tipo, chave, ordem, fase, ator, natureza, nome, aprova, pede_folha, padrao_ativo, prazo_aten, prazo_atraso, aliases)
select t, s.chave, s.ordem, s.fase, s.ator, s.natureza, s.nome, s.aprova, s.pede_folha, s.padrao_ativo, s.aten, s.atraso, s.aliases
from (values
  -- F1 Projeto (Engenharia) — prazo só na correção de documento reprovado
  ('{hdd,vca,vrp,registro,macro}'::text[], 'executivo'::text, 10, 1::smallint, 'eng'::text, 'doc'::text, 'Projeto Executivo'::text, null::text, true, true, 3, 5, '{}'::text[]),
  ('{hdd,vca,vrp,registro,macro}', 'mapeamento', 20, 1, 'eng', 'doc', 'Mapeamento de interferências', null, true, true, 3, 5, '{}'),
  ('{hdd}', 'plano_furo', 30, 1, 'eng', 'doc', 'Plano de furo', null, true, true, 3, 5, '{}'),
  -- F2 Aprovação (Qualidade)
  ('{hdd,vca,vrp,registro,macro}', 'aprov_executivo', 110, 2, 'qual', 'aprovacao', 'Aprovar Projeto Executivo', 'executivo', false, true, 3, 5, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'aprov_mapeamento', 120, 2, 'qual', 'aprovacao', 'Aprovar Mapeamento de interferências', 'mapeamento', false, true, 3, 5, '{}'),
  ('{hdd}', 'aprov_plano_furo', 130, 2, 'qual', 'aprovacao', 'Aprovar Plano de furo', 'plano_furo', false, true, 3, 5, '{}'),
  -- F3 Pré-obra (Obras; vistoria aprovada pela Qualidade). Liberações e licença dependem de terceiros: sem prazo.
  ('{hdd,vca,vrp}', 'vistoria', 210, 3, 'obra', 'link', 'Vistoria cautelar', null, false, true, null, null, '{}'),
  ('{registro,macro}', 'vistoria', 210, 3, 'obra', 'link', 'Vistoria cautelar', null, false, false, null, null, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'aprov_vistoria', 215, 3, 'qual', 'aprovacao', 'Aprovar vistoria cautelar', 'vistoria', false, true, 3, 5, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'alvara', 220, 3, 'obra', 'doc', 'Liberação prefeitura', null, false, true, null, null, '{"Autorização de Intervenção de Via"}'),
  ('{hdd,vca,vrp,registro,macro}', 'lib_gasmig', 230, 3, 'obra', 'doc', 'Liberação GASMIG', null, false, true, null, null, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'lib_transcon', 240, 3, 'obra', 'doc', 'Liberação Transcon', null, false, true, null, null, '{}'),
  ('{hdd,vca,vrp}', 'licenca', 250, 3, 'obra', 'doc', 'Licença ambiental', null, false, true, null, null, '{}'),
  ('{registro,macro}', 'licenca', 250, 3, 'obra', 'doc', 'Licença ambiental', null, false, false, null, null, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'os_sigos', 260, 3, 'obra', 'os', 'OS SIGOS', null, false, true, 3, 5, '{}'),
  -- F4 Execução (Obras): etapas de topo da árvore de avanço (o detalhe fica em PJ_ARV, no app)
  ('{hdd}', 'av_mobilizacao', 310, 4, 'obra', 'avanco', 'Mobilização e montagem de equipamento HDD', null, false, true, null, null, '{"Mobilização e montagem do equipamento HDD"}'),
  ('{hdd}', 'av_valas', 320, 4, 'obra', 'avanco', 'Valas de perfuração', null, false, true, null, null, '{"Valas de entrada e saída"}'),
  ('{hdd}', 'av_piloto', 330, 4, 'obra', 'avanco', 'Perfuração de piloto (pilot bore)', null, false, true, null, null, '{"Perfuração piloto (pilot bore)"}'),
  ('{hdd}', 'av_alargamento', 340, 4, 'obra', 'avanco', 'Alargamento (reaming)', null, false, true, null, null, '{}'),
  ('{hdd}', 'av_pullback', 350, 4, 'obra', 'avanco', 'Puxamento da tubulação (pullback)', null, false, true, null, null, '{}'),
  ('{hdd,vca}', 'av_pecas', 360, 4, 'obra', 'avanco', 'Peças e acessórios', null, false, true, null, null, '{}'),
  ('{hdd,vca}', 'av_ramais', 370, 4, 'obra', 'avanco', 'Ramais', null, false, true, null, null, '{}'),
  ('{hdd,vca}', 'av_interligacao', 380, 4, 'obra', 'avanco', 'Interligação (tronco)', null, false, true, null, null, '{}'),
  ('{hdd}', 'av_estanqueidade', 390, 4, 'obra', 'avanco', 'Teste de Estanqueidade', null, false, true, null, null, '{"Teste de estanqueidade / pressão"}'),
  ('{vca}', 'av_locacao', 310, 4, 'obra', 'avanco', 'Locação e topografia do traçado', null, false, true, null, null, '{}'),
  ('{vca}', 'av_sinalizacao', 315, 4, 'obra', 'avanco', 'Sinalização e segurança da obra', null, false, true, null, null, '{}'),
  ('{vca}', 'av_escavacao', 320, 4, 'obra', 'avanco', 'Escavação de vala', null, false, true, null, null, '{}'),
  ('{vca}', 'av_assentamento', 330, 4, 'obra', 'avanco', 'Assentamento de tubulação (rede)', null, false, true, null, null, '{}'),
  ('{vca}', 'av_reaterro', 340, 4, 'obra', 'avanco', 'Reaterro compactado', null, false, true, null, null, '{}'),
  ('{vca}', 'av_recomposicao', 345, 4, 'obra', 'avanco', 'Recomposição de pavimento', null, false, true, null, null, '{}'),
  ('{vca}', 'av_estanqueidade', 390, 4, 'obra', 'avanco', 'Teste de estanqueidade / pressão', null, false, true, null, null, '{}'),
  ('{vrp,registro,macro}', 'av_locacao', 310, 4, 'obra', 'avanco', 'Locação e cadastro de interferências', null, false, true, null, null, '{}'),
  ('{vrp}', 'av_camara', 320, 4, 'obra', 'avanco', 'Câmara da VRP', null, false, true, null, null, '{}'),
  ('{vrp}', 'av_montagem', 330, 4, 'obra', 'avanco', 'Montagem hidráulica (VRP + by-pass, registros, filtro, manômetros)', null, false, true, null, null, '{}'),
  ('{vrp,macro}', 'av_interligacao', 340, 4, 'obra', 'avanco', 'Interligação', null, false, true, null, null, '{}'),
  ('{vrp,macro}', 'av_estanqueidade', 350, 4, 'obra', 'avanco', 'Teste de estanqueidade', null, false, true, null, null, '{}'),
  ('{vrp}', 'av_calibracao', 360, 4, 'obra', 'avanco', 'Calibração / ajuste de set point', null, false, true, null, null, '{}'),
  ('{vrp}', 'av_telemetria', 370, 4, 'obra', 'avanco', 'Telemetria / macromedidor associado', null, false, true, null, null, '{}'),
  ('{vrp}', 'av_comissionamento', 380, 4, 'obra', 'avanco', 'Comissionamento', null, false, true, null, null, '{}'),
  ('{registro}', 'av_obra_civil', 320, 4, 'obra', 'avanco', 'Obra civil (vala/caixa)', null, false, true, null, null, '{}'),
  ('{registro}', 'av_retirada', 330, 4, 'obra', 'avanco', 'Retirada da válvula antiga (se substituição)', null, false, true, null, null, '{}'),
  ('{registro}', 'av_instalacao', 340, 4, 'obra', 'avanco', 'Instalação da válvula + acessórios', null, false, true, null, null, '{}'),
  ('{registro}', 'av_interligacao', 350, 4, 'obra', 'avanco', 'Interligação / religação', null, false, true, null, null, '{}'),
  ('{registro}', 'av_estanqueidade', 360, 4, 'obra', 'avanco', 'Teste de estanqueidade / manobra', null, false, true, null, null, '{}'),
  ('{macro}', 'av_caixa', 320, 4, 'obra', 'avanco', 'Caixa do macromedidor', null, false, true, null, null, '{}'),
  ('{macro}', 'av_montagem', 330, 4, 'obra', 'avanco', 'Montagem hidráulica (macromedidor, trechos retos, registros)', null, false, true, null, null, '{}'),
  ('{macro}', 'av_eletrica', 360, 4, 'obra', 'avanco', 'Instalação elétrica / telemetria', null, false, true, null, null, '{}'),
  ('{macro}', 'av_comissionamento', 370, 4, 'obra', 'avanco', 'Parametrização e comissionamento', null, false, true, null, null, '{}'),
  -- ensaio de compactação do reaterro (Qualidade) — só o prazo mora aqui; o pedido vem do bloco Reaterro → Recomposição
  ('{hdd,vca,vrp,registro,macro}', 'ensaio_reaterro', 395, 4, 'qual', 'ensaio', 'Ensaio de compactação do reaterro', null, false, true, 1, 2, '{}'),
  -- F5 Encerramento
  ('{hdd}', 'rel_furo', 510, 5, 'obra', 'doc', 'Relatório de Furo', null, false, true, 5, 10, '{}'),
  ('{hdd}', 'aprov_rel_furo', 512, 5, 'qual', 'aprovacao', 'Aprovar Relatório de Furo', 'rel_furo', false, true, 3, 5, '{}'),
  ('{hdd}', 'rel_solda', 520, 5, 'obra', 'doc', 'Relatório de Solda', null, false, true, 5, 10, '{}'),
  ('{hdd}', 'aprov_rel_solda', 522, 5, 'qual', 'aprovacao', 'Aprovar Relatório de Solda', 'rel_solda', false, true, 3, 5, '{}'),
  ('{macro}', 'cert_calibracao', 525, 5, 'obra', 'doc', 'Certificado de calibração do medidor', null, false, true, 5, 10, '{}'),
  ('{macro}', 'aprov_cert_calibracao', 527, 5, 'qual', 'aprovacao', 'Aprovar Certificado de calibração', 'cert_calibracao', false, true, 3, 5, '{}'),
  ('{hdd,vca,vrp}', 'rel_estanq', 530, 5, 'obra', 'doc', 'Relatório de Estanqueidade', null, false, true, 5, 10, '{}'),
  ('{hdd,vca,vrp}', 'aprov_rel_estanq', 532, 5, 'qual', 'aprovacao', 'Aprovar Relatório de Estanqueidade', 'rel_estanq', false, true, 3, 5, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'rel_pav', 540, 5, 'qual', 'doc', 'Relatório de Qualidade da Pavimentação', null, false, true, 5, 10, '{}'),
  ('{hdd,vca,vrp,registro,macro}', 'as_built', 550, 5, 'eng', 'doc', 'As built', null, true, true, 10, 15, '{"Cadastro do As Built"}'),
  ('{hdd,vca,vrp,registro,macro}', 'aprov_as_built', 552, 5, 'qual', 'aprovacao', 'Aprovar As built', 'as_built', false, true, 3, 5, '{}')
) s(tipos, chave, ordem, fase, ator, natureza, nome, aprova, pede_folha, padrao_ativo, aten, atraso, aliases)
cross join unnest(s.tipos) t
on conflict (tipo, chave) do update set ordem = excluded.ordem, fase = excluded.fase, ator = excluded.ator,
  natureza = excluded.natureza, nome = excluded.nome, aprova = excluded.aprova, pede_folha = excluded.pede_folha,
  padrao_ativo = excluded.padrao_ativo, aliases = excluded.aliases;   -- prazos NÃO: re-rodar não desfaz o que foi ajustado na tela

-- 4) colunas novas nas tabelas existentes
alter table "13 - projetos_obra".intervencao_estado
  add column if not exists legado boolean not null default false,   -- já liberada antes do pipeline: sem portões de fase
  add column if not exists liberado_em timestamptz,
  add column if not exists fase3_em timestamptz,                    -- quando cada fase abriu (relógio + aviso único)
  add column if not exists fase4_em timestamptz,
  add column if not exists fase5_em timestamptz,
  add column if not exists concluida_em timestamptz,
  add column if not exists exec_pct numeric;                        -- % de execução da árvore (gravado ao salvar; leitura não recalcula)
alter table "13 - projetos_obra".intervencao_documento
  add column if not exists folha text;
alter table "13 - projetos_obra".intervencao_avanco
  add column if not exists etapa text;                              -- chave estável da etapa de topo (não depende do rótulo)

-- 5) estado atual de cada etapa + histórico append-only
create table if not exists "13 - projetos_obra".intervencao_etapa (
  kind text not null check (kind in ('ponto','linha')),
  gid bigint not null,
  chave text not null,
  ativo boolean,                                 -- "No escopo?" (null = padrão do modelo)
  status text not null default 'pendente' check (status in ('pendente','enviado','correcao','aguardando','aprovado','reprovado')),
  status_em timestamptz,                         -- início da situação atual (relógio)
  valor text,                                    -- nº da OS SIGOS / link da vistoria
  folha text check (folha is null or folha in ('A0','A1','A2','A3','A4')),
  justificativa text,                            -- por que saiu do escopo (visível à Qualidade)
  comentario text,                               -- comentário da última avaliação
  por_uuid uuid, por_nome text,                  -- último a mexer
  enviado_por uuid,                              -- quem enviou por último (recebe o aviso da reprovação)
  atualizado_em timestamptz not null default now(),
  primary key (kind, gid, chave));
create table if not exists "13 - projetos_obra".intervencao_etapa_evento (
  id bigint generated always as identity primary key,
  kind text not null, gid bigint not null, chave text,
  evento text not null check (evento in ('liberado','reaberto','enviado','aprovado','reprovado','removido','escopo','legado','fase')),
  valor text, arquivo text, nome_arquivo text, folha text, ativo boolean, comentario text,
  por_uuid uuid, por_nome text, em timestamptz not null default now());
create index if not exists intervencao_etapa_evento_iv_idx on "13 - projetos_obra".intervencao_etapa_evento (kind, gid);
create index if not exists intervencao_etapa_evento_em_idx on "13 - projetos_obra".intervencao_etapa_evento (em);

alter table "13 - projetos_obra".etapa_modelo enable row level security;          -- deny-all: acesso só via RPC
alter table "13 - projetos_obra".etapa_modelo_log enable row level security;
alter table "13 - projetos_obra".intervencao_etapa enable row level security;
alter table "13 - projetos_obra".intervencao_etapa_evento enable row level security;
revoke all on table "13 - projetos_obra".etapa_modelo, "13 - projetos_obra".etapa_modelo_log,
  "13 - projetos_obra".intervencao_etapa, "13 - projetos_obra".intervencao_etapa_evento from public, anon, authenticated;

create or replace function "13 - projetos_obra".proj_sem_alterar() returns trigger language plpgsql as $f$
begin raise exception 'O histórico do pipeline de Projetos não pode ser alterado nem apagado'; end $f$;
drop trigger if exists proj_evento_imutavel on "13 - projetos_obra".intervencao_etapa_evento;
create trigger proj_evento_imutavel before update or delete on "13 - projetos_obra".intervencao_etapa_evento
  for each row execute function "13 - projetos_obra".proj_sem_alterar();
drop trigger if exists proj_evento_sem_truncate on "13 - projetos_obra".intervencao_etapa_evento;
create trigger proj_evento_sem_truncate before truncate on "13 - projetos_obra".intervencao_etapa_evento
  for each statement execute function "13 - projetos_obra".proj_sem_alterar();
drop trigger if exists proj_modelo_log_imutavel on "13 - projetos_obra".etapa_modelo_log;
create trigger proj_modelo_log_imutavel before update or delete on "13 - projetos_obra".etapa_modelo_log
  for each row execute function "13 - projetos_obra".proj_sem_alterar();
drop trigger if exists proj_modelo_log_sem_truncate on "13 - projetos_obra".etapa_modelo_log;
create trigger proj_modelo_log_sem_truncate before truncate on "13 - projetos_obra".etapa_modelo_log
  for each statement execute function "13 - projetos_obra".proj_sem_alterar();

-- 6) cálculo
-- % de execução de um nó da árvore (espelha pjPct do app, mas: metro limitado a 100% e documento fora — documento agora é etapa)
create or replace function "13 - projetos_obra".proj_no_pct(n jsonb)
returns numeric language plpgsql immutable as $f$
declare k text; s numeric := 0; c int := 0; x numeric; f jsonb;
begin
  if n is null or jsonb_typeof(n) <> 'object' then return null; end if;
  if n->>'ativo' = 'false' then return null; end if;
  k := n->>'k';
  if k = '%' then return least(greatest(coalesce((n->>'p')::numeric, 0), 0), 100);
  elsif k = 'm' then
    if coalesce((n->>'meta')::numeric, 0) <= 0 then return 0; end if;
    return least(greatest(coalesce((n->>'exec')::numeric, 0), 0) / (n->>'meta')::numeric * 100, 100);
  elsif k = 'g' then
    for f in select value from jsonb_array_elements(coalesce(n->'f', '[]'::jsonb)) loop
      x := "13 - projetos_obra".proj_no_pct(f);
      if x is not null then s := s + x; c := c + 1; end if;
    end loop;
    return case when c = 0 then 0 else s / c end;
  end if;
  return null;   -- reg / sel / doc
end $f$;
create or replace function "13 - projetos_obra".proj_arv_pct(p_arv jsonb)
returns numeric language sql immutable as $f$
  select coalesce(round(avg(x), 1), 0) from (
    select "13 - projetos_obra".proj_no_pct(v) x
    from jsonb_array_elements(case when jsonb_typeof(p_arv) = 'array' then p_arv else '[]'::jsonb end) v) t
  where x is not null;
$f$;

-- etapa de topo (chave) a partir do rótulo gravado no avanço
create or replace function "13 - projetos_obra".proj_etapa_de_rotulo(p_tipo text, p_rotulo text)
returns text language sql stable security definer set search_path to 'public' as $f$
  select m.chave from "13 - projetos_obra".etapa_modelo m
  where m.tipo = p_tipo and m.natureza = 'avanco'
    and (lower(m.nome) = lower(btrim(p_rotulo)) or lower(btrim(p_rotulo)) = any (select lower(a) from unnest(m.aliases) a))
  order by m.ordem limit 1;
$f$;

-- situação completa do pipeline de 1 intervenção (tudo derivado na leitura)
create or replace function "13 - projetos_obra".proj_calc(p_kind text, p_gid bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_tipo text; v_leg boolean; v_lib boolean; v_arv jsonb; v_pct numeric;
  v_f3 timestamptz; v_f4 timestamptz; v_f5 timestamptz;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_base jsonb; v_itens jsonb; v_falta jsonb; v_atores jsonb;
  f2 boolean; f3 boolean; f5 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean; v_concl boolean;
  v_status text; v_fase int; v_exec boolean; v_feitos int; v_total int; v_desl int; v_leg_pend jsonb;
begin
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then return null; end if;
  select legado, locked, arv, exec_pct, fase3_em, fase4_em, fase5_em into v_leg, v_lib, v_arv, v_pct, v_f3, v_f4, v_f5
    from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  v_leg := coalesce(v_leg, false); v_lib := coalesce(v_lib, false);
  v_pct := coalesce(v_pct, "13 - projetos_obra".proj_arv_pct(v_arv));

  -- 1ª passada: modelo + estado; a aprovação acompanha o "No escopo?" do seu documento
  with b as (
    select m.chave, m.ordem, m.fase, m.ator, m.natureza, m.nome, m.aprova, m.pede_folha, m.prazo_aten, m.prazo_atraso,
           coalesce(e.ativo, m.padrao_ativo) ativo_p, coalesce(e.status, 'pendente') status, e.status_em, e.valor, e.folha,
           e.justificativa, e.por_nome, e.comentario
    from "13 - projetos_obra".etapa_modelo m
    left join "13 - projetos_obra".intervencao_etapa e on e.kind = p_kind and e.gid = p_gid and e.chave = m.chave
    where m.tipo = v_tipo and m.natureza in ('doc','link','os','aprovacao')
  ), c as (
    select b.*, case when b.natureza = 'aprovacao' then coalesce((select d.ativo_p from b d where d.chave = b.aprova), false)
                     else b.ativo_p end ativo
    from b
  ), d as (
    select c.*, case when c.natureza = 'aprovacao' then c.status = 'aprovado'
                     else coalesce((select a.status = 'aprovado' from c a
                                    where a.natureza = 'aprovacao' and a.aprova = c.chave and a.ativo limit 1),
                                   c.status = 'enviado') end feito
    from c
  )
  select coalesce(jsonb_agg(jsonb_build_object('chave',chave,'ordem',ordem,'fase',fase,'ator',ator,'natureza',natureza,
           'nome',nome,'aprova',aprova,'pede_folha',pede_folha,'prazo_aten',prazo_aten,'prazo_atraso',prazo_atraso,
           'ativo',ativo,'status',status,'status_em',status_em,'valor',valor,'folha',folha,'justificativa',justificativa,
           'por_nome',por_nome,'comentario',comentario,'feito',feito) order by ordem), '[]'::jsonb)
    into v_base from d;

  select coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 2), true),
         coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 3), true),
         coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 5), true),
         coalesce(jsonb_agg(x->>'nome' order by (x->>'ordem')::int) filter (
           where (x->>'ativo')::boolean and (x->>'fase')::int = 1 and x->>'natureza' = 'doc'
             and not (x->>'status' = 'enviado' and (not (x->>'pede_folha')::boolean or nullif(x->>'folha','') is not null))), '[]'::jsonb),
         count(*) filter (where not (x->>'ativo')::boolean and nullif(x->>'justificativa','') is not null)
    into f2, f3, f5, v_falta, v_desl
    from jsonb_array_elements(v_base) x;

  -- legado pula só os portões de antes da obra (2 e 3); o Encerramento abre em 100% para todas
  a2 := v_lib;
  a3 := v_lib and (v_leg or f2);
  a4 := a3 and (v_leg or f3);
  a5 := a4 and v_pct >= 100;
  v_concl := a4 and v_pct >= 100 and f5;
  v_exec := a4 and v_pct < 100;
  v_status := case when not v_lib then 'configuracao' when not a3 then 'aprovacao' when not a4 then 'preobra'
                   when v_pct < 100 then case when v_pct <= 0 then 'exec_nao_iniciada' else 'exec_andamento' end
                   when not v_concl then 'encerramento' else 'concluida' end;
  v_fase := case v_status when 'configuracao' then 1 when 'aprovacao' then 2 when 'preobra' then 3
                          when 'encerramento' then 5 when 'concluida' then 6 else 4 end;

  -- 2ª passada: etapa aberta? acionável? relógio. No legado, o que falta antes da obra (fases 1–3, pendente/aguardando)
  -- fica marcado como pendência do legado: aparece na intervenção, mas não entra nas filas nem no "com quem está".
  select coalesce(jsonb_agg(s3.x || jsonb_build_object('aberta', s3.ab, 'acionavel', s3.ac, 'pend_legado', s3.pl, 'desde', s3.ds,
           'dias', case when s3.ds is not null then v_hoje - (s3.ds at time zone 'America/Sao_Paulo')::date end,
           'faixa', case when s3.ds is null or s3.x->>'prazo_aten' is null then null
                         when v_hoje - (s3.ds at time zone 'America/Sao_Paulo')::date <= (s3.x->>'prazo_aten')::int then 'ok'
                         when v_hoje - (s3.ds at time zone 'America/Sao_Paulo')::date <= (s3.x->>'prazo_atraso')::int then 'aten'
                         else 'atraso' end)
           order by (s3.x->>'ordem')::int), '[]'::jsonb)
    into v_itens
    from (
      select s2.x, s2.ab, s2.pode and not s2.leg ac, s2.pode and s2.leg pl,
             case when not s2.pode or s2.leg then null
                  when s2.x->>'natureza' = 'aprovacao' or s2.x->>'status' = 'correcao' then (s2.x->>'status_em')::timestamptz
                  when (s2.x->>'fase')::int = 3 then v_f3
                  when (s2.x->>'fase')::int = 5 then v_f5 end ds
      from (
        select s1.x, s1.ab,
               (s1.x->>'ativo')::boolean and s1.ab and (
                 (s1.x->>'natureza' in ('doc','link','os') and s1.x->>'status' in ('pendente','correcao'))
                 or (s1.x->>'natureza' = 'aprovacao' and s1.x->>'status' = 'aguardando')) pode,
               v_leg and (s1.x->>'fase')::int <= 3 and s1.x->>'status' in ('pendente','aguardando') leg
        from (
          select x, case (x->>'fase')::int when 1 then (not v_lib) or x->>'status' = 'correcao' or v_leg
                                           when 2 then a2 when 3 then a3 when 4 then a4 when 5 then a5 else false end ab
          from jsonb_array_elements(v_base) x) s1) s2) s3;
  select coalesce(jsonb_object_agg(a, n), '{}'::jsonb) into v_leg_pend from (
    select x->>'ator' a, count(*) n from jsonb_array_elements(v_itens) x where (x->>'pend_legado')::boolean group by 1) z;

  -- com quem está (+ pior prazo por ator)
  select coalesce(jsonb_object_agg(w.ator, jsonb_build_object('n', w.n, 'dias', w.dias, 'faixa', w.faixa)), '{}'::jsonb)
    into v_atores
    from (
      select z.ator, count(*) n, max(z.dias) dias,
             case max(case z.faixa when 'atraso' then 3 when 'aten' then 2 when 'ok' then 1 else 0 end)
               when 3 then 'atraso' when 2 then 'aten' when 1 then 'ok' end faixa
      from (
        select x->>'ator' ator, (x->>'dias')::int dias, x->>'faixa' faixa
          from jsonb_array_elements(v_itens) x where (x->>'acionavel')::boolean
        union all select 'eng', null, null where not v_lib                                   -- configurar + Liberar
        union all select 'obra', case when v_f4 is not null and not v_leg then v_hoje - (v_f4 at time zone 'America/Sao_Paulo')::date end,
                         null where v_exec                                                   -- lançar avanço
      ) z group by z.ator) w;

  if v_fase = 4 then v_feitos := round(v_pct); v_total := 100;
  else
    select count(*) filter (where case when v_fase = 1 then x->>'status' = 'enviado' else (x->>'feito')::boolean end), count(*)
      into v_feitos, v_total
      from jsonb_array_elements(v_itens) x where (x->>'ativo')::boolean and (x->>'fase')::int = least(v_fase, 5);
  end if;

  return jsonb_build_object('kind', p_kind, 'gid', p_gid, 'tipo', v_tipo, 'legado', v_leg, 'liberado', v_lib,
    'status', v_status, 'fase', v_fase, 'exec_pct', v_pct, 'exec_pendente', v_exec,
    'em_correcao', exists (select 1 from jsonb_array_elements(v_itens) x where (x->>'ativo')::boolean and x->>'status' = 'correcao'),
    'aberta', jsonb_build_object('2', a2, '3', a3, '4', a4, '5', a5), 'concluida', v_concl,
    'f1_falta', v_falta, 'atores', v_atores, 'prog', jsonb_build_object('feitos', v_feitos, 'total', v_total),
    'desligados', v_desl, 'legado_pend', v_leg_pend, 'fase3_em', v_f3, 'fase4_em', v_f4, 'fase5_em', v_f5, 'itens', v_itens);
end $function$;

-- marca as fases que acabaram de abrir (1 vez só, gera o evento 'fase' → aviso). Legado não tem portão nem aviso de fase.
create or replace function "13 - projetos_obra".proj_fase_sync(p_kind text, p_gid bigint)
returns void language plpgsql security definer set search_path to 'public' as $f$
declare v_lib boolean; v_leg boolean; e3 timestamptz; e4 timestamptz; e5 timestamptz; e6 timestamptz; c jsonb; v_nome text;
begin
  select locked, legado, fase3_em, fase4_em, fase5_em, concluida_em into v_lib, v_leg, e3, e4, e5, e6
    from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  if not found or v_leg or not v_lib then return; end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then return; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = auth.uid();
  if (c->'aberta'->>'3')::boolean and e3 is null then
    update "13 - projetos_obra".intervencao_estado set fase3_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '3', auth.uid(), v_nome);
  end if;
  if (c->'aberta'->>'4')::boolean and e4 is null then
    update "13 - projetos_obra".intervencao_estado set fase4_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '4', auth.uid(), v_nome);
  end if;
  if (c->'aberta'->>'5')::boolean and e5 is null then
    update "13 - projetos_obra".intervencao_estado set fase5_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '5', auth.uid(), v_nome);
  end if;
  if (c->>'concluida')::boolean and e6 is null then
    update "13 - projetos_obra".intervencao_estado set concluida_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '6', auth.uid(), v_nome);
  end if;
end $f$;

-- registra o envio de uma etapa (documento/link/OS) e põe a(s) aprovação(ões) dela na fila
create or replace function "13 - projetos_obra".proj_etapa_envio(p_kind text, p_gid bigint, p_tipo text, p_chave text, p_uid uuid,
  p_valor text, p_folha text, p_path text, p_nome_arq text)
returns void language plpgsql security definer set search_path to 'public' as $f$
declare v_nome text;
begin
  select coalesce(nome, email) into v_nome from public.perfil where id = p_uid;
  insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, status, status_em, valor, folha, por_uuid, por_nome, enviado_por)
  values (p_kind, p_gid, p_chave, 'enviado', now(), p_valor, p_folha, p_uid, v_nome, p_uid)
  on conflict (kind, gid, chave) do update set status = 'enviado', status_em = now(), valor = excluded.valor, folha = excluded.folha,
    por_uuid = excluded.por_uuid, por_nome = excluded.por_nome, enviado_por = excluded.enviado_por, comentario = null, atualizado_em = now();
  insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, status, status_em)
  select p_kind, p_gid, a.chave, 'aguardando', now() from "13 - projetos_obra".etapa_modelo a
   where a.tipo = p_tipo and a.natureza = 'aprovacao' and a.aprova = p_chave
  on conflict (kind, gid, chave) do update set status = 'aguardando', status_em = now(), comentario = null,
    por_uuid = null, por_nome = null, atualizado_em = now();
  insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, valor, arquivo, nome_arquivo, folha, por_uuid, por_nome)
  values (p_kind, p_gid, p_chave, 'enviado', p_valor, p_path, p_nome_arq, p_folha, p_uid, v_nome);
end $f$;

-- documentos ativos da fase 1 que faltam para liberar (nome) — vazio = pode liberar
create or replace function "13 - projetos_obra".proj_f1_falta(p_kind text, p_gid bigint)
returns text language sql stable security definer set search_path to 'public' as $f$
  select string_agg(value #>> '{}', ', ') from jsonb_array_elements("13 - projetos_obra".proj_calc(p_kind, p_gid)->'f1_falta');
$f$;

-- 7) triggers
-- árvore salva → grava o % de execução (a leitura não recalcula a árvore)
create or replace function "13 - projetos_obra".proj_trg_estado_pct() returns trigger
language plpgsql security definer set search_path to 'public' as $f$
begin
  new.exec_pct := "13 - projetos_obra".proj_arv_pct(new.arv);
  return new;
end $f$;
drop trigger if exists proj_estado_pct on "13 - projetos_obra".intervencao_estado;
create trigger proj_estado_pct before insert or update of arv on "13 - projetos_obra".intervencao_estado
  for each row execute function "13 - projetos_obra".proj_trg_estado_pct();

-- árvore salva / cadeado mudou → confere se alguma fase abriu (ex.: execução chegou a 100% → Encerramento)
create or replace function "13 - projetos_obra".proj_trg_estado_sync() returns trigger
language plpgsql security definer set search_path to 'public' as $f$
begin
  perform "13 - projetos_obra".proj_fase_sync(new.kind, new.gid);
  return null;
end $f$;
drop trigger if exists proj_estado_sync on "13 - projetos_obra".intervencao_estado;
create trigger proj_estado_sync after insert or update of arv, locked on "13 - projetos_obra".intervencao_estado
  for each row execute function "13 - projetos_obra".proj_trg_estado_sync();

-- avanço novo ganha a chave da etapa de topo
create or replace function "13 - projetos_obra".proj_trg_avanco_etapa() returns trigger
language plpgsql security definer set search_path to 'public' as $f$
begin
  if new.etapa is null then
    new.etapa := "13 - projetos_obra".proj_etapa_de_rotulo(
      (select tipo from "13 - projetos_obra".vw_iv where kind = new.kind and gid = new.gid),
      coalesce(new.atividade, split_part(new.caminho, ' › ', 1)));
  end if;
  return new;
end $f$;
drop trigger if exists proj_avanco_etapa on "13 - projetos_obra".intervencao_avanco;
create trigger proj_avanco_etapa before insert on "13 - projetos_obra".intervencao_avanco
  for each row execute function "13 - projetos_obra".proj_trg_avanco_etapa();

-- avisos (trigger na tabela de negócio, nunca inline na RPC)
create or replace function "13 - projetos_obra".proj_trg_evento_aviso() returns trigger
language plpgsql security definer set search_path to 'public' as $f$
declare v_iv text; v_tipo text; v_lib boolean; v_nome text; v_doc text; v_dest uuid; n int;
begin
  select coalesce(v.id, v.projeto, '#' || v.gid)
           || coalesce(' · ' || case v.consorcio when 'ZA1004' then 'Contagem' when 'ZA0200' then 'Betim' end, ''), v.tipo
    into v_iv, v_tipo from "13 - projetos_obra".vw_iv v where v.kind = new.kind and v.gid = new.gid;
  if v_tipo is null then return new; end if;
  select coalesce(locked, false) into v_lib from "13 - projetos_obra".intervencao_estado where kind = new.kind and gid = new.gid;
  if new.evento = 'enviado' then
    -- documento/link com aprovação → fila da Qualidade (só depois de liberada; antes disso vai junto no aviso do Liberar)
    if coalesce(v_lib, false) and exists (select 1 from "13 - projetos_obra".etapa_modelo a
                                          where a.tipo = v_tipo and a.natureza = 'aprovacao' and a.aprova = new.chave) then
      select nome into v_nome from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = new.chave;
      perform "9 - suprimentos".sup_notificar("8 - coleta_campo".pav_qualidade_uuids(), 'projetos',
        '📐 Documento para aprovar', v_nome || ' · ' || v_iv, 'projeto_qual', new.por_uuid);
    end if;
  elsif new.evento = 'liberado' then
    select count(*) into n from "13 - projetos_obra".intervencao_etapa e
      join "13 - projetos_obra".etapa_modelo a on a.tipo = v_tipo and a.chave = e.chave and a.natureza = 'aprovacao'
     where e.kind = new.kind and e.gid = new.gid and e.status = 'aguardando';
    if n > 0 then
      perform "9 - suprimentos".sup_notificar("8 - coleta_campo".pav_qualidade_uuids(), 'projetos',
        '📐 Projeto liberado — documentos para aprovar', v_iv || ' · ' || n || ' documento(s)', 'projeto_qual', new.por_uuid);
    end if;
  elsif new.evento = 'reprovado' then
    -- pessoal: só para quem enviou o documento reprovado (sem "exceto")
    select a.aprova into v_doc from "13 - projetos_obra".etapa_modelo a where a.tipo = v_tipo and a.chave = new.chave;
    select e.enviado_por into v_dest from "13 - projetos_obra".intervencao_etapa e
     where e.kind = new.kind and e.gid = new.gid and e.chave = v_doc;
    select nome into v_nome from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = v_doc;
    perform "9 - suprimentos".sup_notificar(array[v_dest], 'projetos', '❌ ' || coalesce(v_nome, 'Documento') || ' reprovado — corrigir',
      v_iv || coalesce(' · ' || left(nullif(btrim(new.comentario), ''), 120), ''), 'pj:' || new.kind || ':' || new.gid, null);
  elsif new.evento = 'fase' then
    if new.valor = '3' then
      perform "9 - suprimentos".sup_notificar("13 - projetos_obra".proj_obras_uuids(), 'projetos', '🏗️ Pré-obra liberada',
        v_iv || ' · vistoria, liberações e OS SIGOS', 'pj:' || new.kind || ':' || new.gid, new.por_uuid);
    elsif new.valor = '4' then
      perform "9 - suprimentos".sup_notificar("13 - projetos_obra".proj_obras_uuids(), 'projetos', '🏗️ Execução liberada',
        v_iv || ' · pode lançar o avanço', 'pj:' || new.kind || ':' || new.gid, new.por_uuid);
    elsif new.valor = '5' then
      perform "9 - suprimentos".sup_notificar("13 - projetos_obra".proj_eng_uuids(), 'projetos', '📐 Encerramento — As built',
        v_iv || ' · execução em 100%', 'pj:' || new.kind || ':' || new.gid, new.por_uuid);
    end if;
  end if;
  return new;
end $f$;
drop trigger if exists proj_evento_aviso on "13 - projetos_obra".intervencao_etapa_evento;
create trigger proj_evento_aviso after insert on "13 - projetos_obra".intervencao_etapa_evento
  for each row execute function "13 - projetos_obra".proj_trg_evento_aviso();

-- 8) RPCs novas
create or replace function public.app_proj_modelo()
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('tipo',tipo,'chave',chave,'ordem',ordem,'fase',fase,'ator',ator,
      'natureza',natureza,'nome',nome,'aprova',aprova,'pede_folha',pede_folha,'padrao_ativo',padrao_ativo,
      'prazo_aten',prazo_aten,'prazo_atraso',prazo_atraso,'aliases',aliases) order by tipo, ordem)
    from "13 - projetos_obra".etapa_modelo), '[]'::jsonb);
end $f$;

-- pipeline de 1 intervenção + histórico
create or replace function public.app_proj_pipeline(p_kind text, p_gid bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare c jsonb;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then raise exception 'intervenção não encontrada'; end if;
  return c || jsonb_build_object('eventos', coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'chave',e.chave,
      'nome',m.nome,'evento',e.evento,'valor',e.valor,'arquivo',e.arquivo,'nome_arquivo',e.nome_arquivo,'folha',e.folha,
      'ativo',e.ativo,'comentario',e.comentario,'por',e.por_nome,'em',e.em) order by e.em, e.id)
    from "13 - projetos_obra".intervencao_etapa_evento e
    left join "13 - projetos_obra".etapa_modelo m on m.tipo = c->>'tipo' and m.chave = e.chave
    where e.kind = p_kind and e.gid = p_gid), '[]'::jsonb));
end $f$;

-- status/ator/prazo de todas (lista e mapa) — sem os itens
create or replace function public.app_proj_pipeline_resumo()
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(c - 'itens' order by c->>'kind', (c->>'gid')::bigint)
    from (select "13 - projetos_obra".proj_calc(kind, gid) c from "13 - projetos_obra".vw_iv) t where c is not null), '[]'::jsonb);
end $f$;

-- fila de pendências por ator (eng | qual | obra | null = todos) + documentos desligados com justificativa (p/ a Qualidade).
-- p_legado = true devolve também as pendências do legado (o que faltou antes da obra nas intervenções já liberadas).
create or replace function public.app_proj_fila(p_ator text default null, p_legado boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return (
  with cc as materialized (
    select v.kind, v.gid, v.id, v.projeto, v.cidade, v.consorcio, v.tipo, "13 - projetos_obra".proj_calc(v.kind, v.gid) c
    from "13 - projetos_obra".vw_iv v
  ), it as (
    select cc.*, x from cc cross join lateral jsonb_array_elements(cc.c->'itens') x
    where (p_ator is null or x->>'ator' = p_ator)
      and ((x->>'acionavel')::boolean or (p_legado and (x->>'pend_legado')::boolean))
  )
  select jsonb_build_object(
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object('kind',it.kind,'gid',it.gid,'id',it.id,'projeto',it.projeto,'cidade',it.cidade,
          'consorcio',it.consorcio,'tipo',it.tipo,'legado',it.c->'legado','status_iv',it.c->'status',
          'pend_legado',(it.x->>'pend_legado')::boolean,
          'chave',it.x->>'chave','nome',it.x->>'nome','natureza',it.x->>'natureza','fase',(it.x->>'fase')::int,'ator',it.x->>'ator',
          'status',it.x->>'status','desde',it.x->'desde','dias',it.x->'dias','faixa',it.x->'faixa','comentario',it.x->'comentario',
          'doc', d.doc, 'link', l.valor)
        order by (it.x->>'pend_legado')::boolean, (it.x->>'dias')::int desc nulls last, it.kind, it.gid, (it.x->>'ordem')::int)
      from it
      left join lateral (select jsonb_build_object('path',d.path,'nome',d.nome,'folha',d.folha) doc
                           from "13 - projetos_obra".intervencao_documento d
                          where d.kind = it.kind and d.gid = it.gid and d.tipo = coalesce(it.x->>'aprova', it.x->>'chave')) d on true
      left join lateral (select e.valor from "13 - projetos_obra".intervencao_etapa e
                          where it.x->>'natureza' = 'aprovacao' and e.kind = it.kind and e.gid = it.gid and e.chave = it.x->>'aprova') l on true
      ), '[]'::jsonb)
      || coalesce((
      select jsonb_agg(jsonb_build_object('kind',cc.kind,'gid',cc.gid,'id',cc.id,'projeto',cc.projeto,'cidade',cc.cidade,
          'consorcio',cc.consorcio,'tipo',cc.tipo,'legado',cc.c->'legado','status_iv',cc.c->'status','pend_legado',false,
          'chave','execucao','nome','Execução (lançar avanço)','natureza','avanco','fase',4,'ator','obra',
          'status','pendente','exec_pct',cc.c->'exec_pct','dias',cc.c->'atores'->'obra'->'dias'))
      from cc where (cc.c->>'exec_pendente')::boolean and (p_ator is null or p_ator = 'obra')), '[]'::jsonb),
    'desligados', coalesce((
      select jsonb_agg(jsonb_build_object('kind',e.kind,'gid',e.gid,'id',v.id,'projeto',v.projeto,'consorcio',v.consorcio,
          'tipo',v.tipo,'chave',e.chave,'nome',m.nome,'justificativa',e.justificativa,'por',e.por_nome,'em',e.atualizado_em)
        order by e.atualizado_em desc)
      from "13 - projetos_obra".intervencao_etapa e
      join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
      join "13 - projetos_obra".etapa_modelo m on m.tipo = v.tipo and m.chave = e.chave
      where e.ativo = false and nullif(e.justificativa, '') is not null
        and exists (select 1 from "13 - projetos_obra".etapa_modelo a where a.tipo = v.tipo and a.natureza = 'aprovacao' and a.aprova = e.chave)
        and (p_ator is null or p_ator = 'qual')), '[]'::jsonb)));
end $f$;

-- eventos do pipeline no período (Resumo)
create or replace function public.app_proj_eventos(p_de date default null, p_ate date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'gid',e.gid,'iv',v.id,'projeto',v.projeto,
      'cidade',v.cidade,'consorcio',v.consorcio,'tipo',v.tipo,'chave',e.chave,'nome',m.nome,'ator',m.ator,'natureza',m.natureza,
      'evento',e.evento,'valor',e.valor,'comentario',e.comentario,'por',e.por_nome,'em',e.em) order by e.em desc, e.id desc)
    from (select * from "13 - projetos_obra".intervencao_etapa_evento x
           where x.evento <> 'legado'
             and (p_de is null or (x.em at time zone 'America/Sao_Paulo')::date >= p_de)
             and (p_ate is null or (x.em at time zone 'America/Sao_Paulo')::date <= p_ate)
           order by x.em desc limit 3000) e
    left join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
    left join "13 - projetos_obra".etapa_modelo m on m.tipo = v.tipo and m.chave = e.chave), '[]'::jsonb);
end $f$;

-- "No escopo?" de uma etapa (Engenharia, só em configuração). Aprovação acompanha o documento; desligar documento que tem
-- aprovação exige justificativa (aparece para a Qualidade). Etapa com histórico não sai do escopo.
create or replace function public.app_proj_etapa_escopo(p_kind text, p_gid bigint, p_chave text, p_ativo boolean, p_justificativa text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare v_id uuid := auth.uid(); v_tipo text; m record; v_nome text; v_tem_aprov boolean;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_eng_pode(v_id) then raise exception 'sem permissão (Projetos · Engenharia)'; end if;
  if p_ativo is null then raise exception 'informe se a etapa fica no escopo'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then raise exception 'intervenção não encontrada'; end if;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = p_chave;
  if not found or m.natureza not in ('doc','link','os') then raise exception 'esta etapa não tem "No escopo?" (a aprovação acompanha o documento)'; end if;
  if exists (select 1 from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid and locked) then
    raise exception 'reabra a configuração para mudar o escopo'; end if;
  if not p_ativo then
    if exists (select 1 from "13 - projetos_obra".intervencao_etapa where kind = p_kind and gid = p_gid and chave = p_chave and status <> 'pendente')
       or exists (select 1 from "13 - projetos_obra".intervencao_etapa_evento where kind = p_kind and gid = p_gid and chave = p_chave
                  and evento in ('enviado','aprovado','reprovado','legado')) then
      raise exception 'etapa com histórico não sai do escopo'; end if;
    v_tem_aprov := exists (select 1 from "13 - projetos_obra".etapa_modelo a where a.tipo = v_tipo and a.natureza = 'aprovacao' and a.aprova = p_chave);
    if v_tem_aprov and length(coalesce(btrim(p_justificativa), '')) < 5 then
      raise exception 'escreva a justificativa para tirar este documento do escopo (ela aparece para a Qualidade)'; end if;
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, ativo, justificativa, por_uuid, por_nome)
  values (p_kind, p_gid, p_chave, p_ativo, case when p_ativo then null else btrim(p_justificativa) end, v_id, v_nome)
  on conflict (kind, gid, chave) do update set ativo = excluded.ativo, justificativa = excluded.justificativa,
    por_uuid = excluded.por_uuid, por_nome = excluded.por_nome, atualizado_em = now();
  insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, ativo, comentario, por_uuid, por_nome)
  values (p_kind, p_gid, p_chave, 'escopo', p_ativo, case when p_ativo then null else btrim(p_justificativa) end, v_id, v_nome);
  return "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens';
end $f$;

-- Liberar (inicia o pipeline) / Reabrir configuração — Engenharia. Liberar exige os documentos ativos da fase 1 anexados
-- (com folha). Legado não precisa. p_arv = árvore atual (cria o estado se a intervenção nunca foi salva).
create or replace function public.app_proj_liberar(p_kind text, p_gid bigint, p_on boolean, p_arv jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare v_id uuid := auth.uid(); v_nome text; v_leg boolean; v_lock boolean; v_falta text; v_existe boolean;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_eng_pode(v_id) then raise exception 'sem permissão (Projetos · Engenharia)'; end if;
  if p_on is null then raise exception 'informe liberar ou reabrir'; end if;
  if not exists (select 1 from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid) then raise exception 'intervenção não encontrada'; end if;
  select legado, locked into v_leg, v_lock from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  v_existe := found;
  if p_on then
    if coalesce(v_lock, false) then return "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens'; end if;
    if not coalesce(v_leg, false) then
      v_falta := "13 - projetos_obra".proj_f1_falta(p_kind, p_gid);
      if v_falta is not null then raise exception 'Para liberar, anexe (com o tamanho da folha): %', v_falta; end if;
    end if;
    if not v_existe and (p_arv is null or jsonb_typeof(p_arv) <> 'array') then raise exception 'abra a configuração da intervenção antes de liberar'; end if;
  elsif not coalesce(v_lock, false) then
    return "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens';
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  if v_existe then
    update "13 - projetos_obra".intervencao_estado set locked = p_on, arv = coalesce(p_arv, arv),
      liberado_em = case when p_on then now() else liberado_em end, atualizado_em = now(), atualizado_por = v_id
     where kind = p_kind and gid = p_gid;
  else
    insert into "13 - projetos_obra".intervencao_estado (kind, gid, arv, locked, status, atualizado_por, liberado_em)
    values (p_kind, p_gid, p_arv, true, 'new', v_id, now());
  end if;
  insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, por_uuid, por_nome)
  values (p_kind, p_gid, case when p_on then 'liberado' else 'reaberto' end, v_id, v_nome);
  return "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens';
end $f$;

-- enviar uma etapa: documento (path já no bucket; folha quando pedida), link (vistoria) ou nº da OS SIGOS
create or replace function public.app_proj_etapa_enviar(p_kind text, p_gid bigint, p_chave text,
  p_valor text default null, p_folha text default null, p_nome text default null, p_path text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare v_id uuid := auth.uid(); v_tipo text; m record; it jsonb; v_old text; v_valor text := p_valor;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then raise exception 'intervenção não encontrada'; end if;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = p_chave;
  if not found or m.natureza not in ('doc','link','os') then raise exception 'etapa inválida'; end if;
  if not "13 - projetos_obra".proj_ator_pode(v_id, m.ator) then
    raise exception 'sem permissão (%)', case m.ator when 'eng' then 'Projetos · Engenharia' when 'qual' then 'Qualidade' else 'responsáveis de obras' end;
  end if;
  select x into it from jsonb_array_elements("13 - projetos_obra".proj_calc(p_kind, p_gid)->'itens') x where x->>'chave' = p_chave;
  if not (it->>'ativo')::boolean then raise exception 'esta etapa está fora do escopo'; end if;
  if not (it->>'aberta')::boolean then raise exception 'esta etapa ainda não foi liberada'; end if;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa e join "13 - projetos_obra".etapa_modelo a
               on a.tipo = v_tipo and a.chave = e.chave and a.natureza = 'aprovacao' and a.aprova = p_chave
             where e.kind = p_kind and e.gid = p_gid and e.status = 'aprovado') then
    raise exception 'já aprovado pela Qualidade — não pode ser trocado'; end if;
  if m.natureza = 'doc' then
    if nullif(btrim(p_path), '') is null then raise exception 'anexe o arquivo'; end if;
    if m.pede_folha and coalesce(p_folha, '') not in ('A0','A1','A2','A3','A4') then raise exception 'escolha o tamanho da folha (A0 a A4)'; end if;
    select path into v_old from "13 - projetos_obra".intervencao_documento where kind = p_kind and gid = p_gid and tipo = p_chave;
    insert into "13 - projetos_obra".intervencao_documento (kind, gid, tipo, nome, path, folha, atualizado_por)
    values (p_kind, p_gid, p_chave, p_nome, p_path, case when m.pede_folha then p_folha end, v_id)
    on conflict (kind, gid, tipo) do update set nome = excluded.nome, path = excluded.path, folha = excluded.folha,
      atualizado_em = now(), atualizado_por = v_id;
    v_valor := null;
  elsif m.natureza = 'link' then
    v_valor := btrim(coalesce(p_valor, ''));
    if v_valor !~* '^https://\S+$' then raise exception 'informe o link completo (https://…)'; end if;
  else
    v_valor := regexp_replace(coalesce(p_valor, ''), '\D', '', 'g');
    if v_valor = '' then raise exception 'informe o número da OS SIGOS'; end if;
  end if;
  perform "13 - projetos_obra".proj_etapa_envio(p_kind, p_gid, v_tipo, p_chave, v_id, v_valor,
    case when m.pede_folha then p_folha end, case when m.natureza = 'doc' then p_path end, case when m.natureza = 'doc' then p_nome end);
  perform "13 - projetos_obra".proj_fase_sync(p_kind, p_gid);
  return jsonb_build_object('ok', true, 'old_path', case when v_old is distinct from p_path then v_old end,
    'pipeline', "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens');
end $f$;

-- aprovar / reprovar (Qualidade). Reprovação exige comentário e devolve o documento para quem o enviou.
create or replace function public.app_proj_etapa_avaliar(p_kind text, p_gid bigint, p_chave text, p_aprovado boolean, p_comentario text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare v_id uuid := auth.uid(); v_tipo text; m record; it jsonb; v_nome text; v_com text := nullif(btrim(p_comentario), '');
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "8 - coleta_campo".pav_qualidade_pode(v_id) then raise exception 'sem permissão (Qualidade)'; end if;
  if p_aprovado is null then raise exception 'informe aprovado ou reprovado'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then raise exception 'intervenção não encontrada'; end if;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = p_chave;
  if not found or m.natureza <> 'aprovacao' then raise exception 'etapa inválida'; end if;
  select x into it from jsonb_array_elements("13 - projetos_obra".proj_calc(p_kind, p_gid)->'itens') x where x->>'chave' = p_chave;
  if not (it->>'acionavel')::boolean then raise exception 'não há documento aguardando esta aprovação'; end if;
  if not p_aprovado and v_com is null then raise exception 'descreva o motivo da reprovação'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  update "13 - projetos_obra".intervencao_etapa set status = case when p_aprovado then 'aprovado' else 'reprovado' end,
    status_em = now(), por_uuid = v_id, por_nome = v_nome, comentario = v_com, atualizado_em = now()
   where kind = p_kind and gid = p_gid and chave = p_chave;
  if not p_aprovado then
    update "13 - projetos_obra".intervencao_etapa set status = 'correcao', status_em = now(), atualizado_em = now()
     where kind = p_kind and gid = p_gid and chave = m.aprova;
  end if;
  insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, comentario, por_uuid, por_nome)
  values (p_kind, p_gid, p_chave, case when p_aprovado then 'aprovado' else 'reprovado' end, v_com, v_id, v_nome);
  perform "13 - projetos_obra".proj_fase_sync(p_kind, p_gid);
  return "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens';
end $f$;

-- prazo de uma etapa (admin/Engenharia). Os dois nulos = sem prazo. Histórico em etapa_modelo_log.
create or replace function public.app_proj_prazo_set(p_tipo text, p_chave text, p_aten int, p_atraso int)
returns void language plpgsql security definer set search_path to 'public' as $f$
declare v_id uuid := auth.uid(); v_nome text; m record;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_eng_pode(v_id) then raise exception 'sem permissão (Projetos · Engenharia)'; end if;
  if (p_aten is null) <> (p_atraso is null) then raise exception 'preencha os dois prazos (ou marque sem prazo)'; end if;
  if p_aten is not null and (p_aten < 0 or p_atraso <= p_aten) then
    raise exception 'o atraso precisa começar depois da atenção'; end if;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = p_tipo and chave = p_chave for update;
  if not found then raise exception 'etapa não encontrada'; end if;
  if m.natureza = 'avanco' then raise exception 'as etapas de avanço não têm prazo'; end if;
  if m.prazo_aten is not distinct from p_aten and m.prazo_atraso is not distinct from p_atraso then return; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  update "13 - projetos_obra".etapa_modelo set prazo_aten = p_aten, prazo_atraso = p_atraso where tipo = p_tipo and chave = p_chave;
  insert into "13 - projetos_obra".etapa_modelo_log (tipo, chave, prazo_aten_antes, prazo_atraso_antes, prazo_aten, prazo_atraso, por_uuid, por_nome)
  values (p_tipo, p_chave, m.prazo_aten, m.prazo_atraso, p_aten, p_atraso, v_id, v_nome);
end $f$;

create or replace function public.app_proj_prazo_log(p_limit int default 200)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.em desc) from (
    select * from "13 - projetos_obra".etapa_modelo_log order by em desc limit greatest(coalesce(p_limit, 200), 1)) l), '[]'::jsonb);
end $f$;

-- 9) RPCs existentes ajustadas (mesma assinatura)
-- avanço: só responsáveis de obras e só com a Execução aberta (legado sempre aberto enquanto liberado)
create or replace function public.app_proj_avanco_registrar(p_kind text, p_gid bigint, p_iv_cod text, p_iv_local text, p_consorcio text,
  p_tipo text, p_caminho text, p_atividade text, p_sub text, p_valor numeric, p_unidade text,
  p_obs text default null, p_fotos text[] default '{}'::text[], p_equipe text default null)
returns jsonb language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_nome text; v_row "13 - projetos_obra".intervencao_avanco; c jsonb;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then raise exception 'intervenção não encontrada'; end if;
  if not coalesce((c->'aberta'->>'4')::boolean, false) then raise exception 'a execução desta intervenção ainda não foi liberada'; end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  insert into "13 - projetos_obra".intervencao_avanco(kind,gid,iv_cod,iv_local,consorcio,tipo,caminho,atividade,sub,valor,unidade,obs,fotos,autor,autor_nome,equipe)
  values(p_kind,p_gid,p_iv_cod,p_iv_local,p_consorcio,p_tipo,p_caminho,p_atividade,p_sub,p_valor,p_unidade,p_obs,coalesce(p_fotos,'{}'),v_id,v_nome,coalesce(p_equipe,v_nome))
  returning * into v_row;
  return to_jsonb(v_row);
end $function$;

-- árvore: só Engenharia ou responsáveis de obras; cadeado só pela Engenharia (liberar segue a mesma regra do app_proj_liberar)
create or replace function public.app_proj_estado_set(p_kind text, p_gid bigint, p_arv jsonb, p_locked boolean default false, p_status text default null)
returns void language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_eng boolean; v_lock_old boolean; v_leg boolean; v_lock boolean; v_falta text; v_nome text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if p_kind not in ('ponto','linha') then raise exception 'kind inválido'; end if;
  v_eng := "13 - projetos_obra".proj_eng_pode(v_id);
  if not (v_eng or "13 - projetos_obra".proj_obras_pode(v_id)) then raise exception 'sem permissão (Projetos · Engenharia ou responsáveis de obras)'; end if;
  select locked, legado into v_lock_old, v_leg from "13 - projetos_obra".intervencao_estado where kind=p_kind and gid=p_gid;
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

-- documento pelo caminho antigo (app em cache): mesmo gate de ator; se o tipo for etapa do pipeline, registra o envio
create or replace function public.app_proj_doc_set(p_kind text, p_gid bigint, p_tipo text, p_nome text, p_path text)
returns text language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_old text; v_tipo text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if p_tipo not in ('executivo','alvara','as_built','rtq','rel_furo','rel_solda','outro') then raise exception 'tipo inválido'; end if;
  if p_tipo in ('alvara','as_built','rtq','rel_furo','rel_solda') then
    if not ("13 - projetos_obra".proj_obras_pode(v_id) or "13 - projetos_obra".proj_eng_pode(v_id)) then raise exception 'sem permissão'; end if;
  elsif not "13 - projetos_obra".proj_eng_pode(v_id) then raise exception 'sem permissão';
  end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind=p_kind and gid=p_gid;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa e join "13 - projetos_obra".etapa_modelo a
               on a.tipo = v_tipo and a.chave = e.chave and a.natureza = 'aprovacao' and a.aprova = p_tipo
             where e.kind = p_kind and e.gid = p_gid and e.status = 'aprovado') then
    raise exception 'já aprovado pela Qualidade — não pode ser trocado'; end if;
  select path into v_old from "13 - projetos_obra".intervencao_documento where kind=p_kind and gid=p_gid and tipo=p_tipo;
  insert into "13 - projetos_obra".intervencao_documento(kind,gid,tipo,nome,path,atualizado_por)
  values(p_kind,p_gid,p_tipo,p_nome,p_path,v_id)
  on conflict (kind,gid,tipo) do update set nome=excluded.nome, path=excluded.path, atualizado_em=now(), atualizado_por=v_id;
  if exists (select 1 from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = p_tipo and natureza = 'doc') then
    perform "13 - projetos_obra".proj_etapa_envio(p_kind, p_gid, v_tipo, p_tipo, v_id, null, null, p_path, p_nome);
    perform "13 - projetos_obra".proj_fase_sync(p_kind, p_gid);
  end if;
  return v_old;
end $function$;

-- remover documento (Engenharia): aprovado não sai; a etapa volta para pendente
create or replace function public.app_proj_doc_remover(p_kind text, p_gid bigint, p_tipo text)
returns text language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_path text; v_tipo text; v_nome text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_eng_pode(v_id) then raise exception 'sem permissão'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind=p_kind and gid=p_gid;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa e join "13 - projetos_obra".etapa_modelo a
               on a.tipo = v_tipo and a.chave = e.chave and a.natureza = 'aprovacao' and a.aprova = p_tipo
             where e.kind = p_kind and e.gid = p_gid and e.status = 'aprovado') then
    raise exception 'documento aprovado pela Qualidade não pode ser removido'; end if;
  delete from "13 - projetos_obra".intervencao_documento where kind=p_kind and gid=p_gid and tipo=p_tipo returning path into v_path;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa where kind=p_kind and gid=p_gid and chave=p_tipo and status <> 'pendente') then
    update "13 - projetos_obra".intervencao_etapa set status='pendente', status_em=now(), folha=null, atualizado_em=now()
     where kind=p_kind and gid=p_gid and chave=p_tipo;
    update "13 - projetos_obra".intervencao_etapa e set status='pendente', status_em=now(), comentario=null, atualizado_em=now()
      from "13 - projetos_obra".etapa_modelo a
     where e.kind=p_kind and e.gid=p_gid and a.tipo=v_tipo and a.chave=e.chave and a.natureza='aprovacao' and a.aprova=p_tipo;
    select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, arquivo, por_uuid, por_nome)
    values (p_kind, p_gid, p_tipo, 'removido', v_path, v_id, v_nome);
  end if;
  return v_path;
end $function$;

create or replace function public.app_proj_docs_listar(p_kind text, p_gid bigint)
returns jsonb language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('tipo',tipo,'nome',nome,'path',path,'folha',folha,'atualizado_em',atualizado_em))
    from "13 - projetos_obra".intervencao_documento where kind=p_kind and gid=p_gid),'[]'::jsonb);
end $function$;

-- excluir: além de avanço/documento de execução, bloqueia se a Qualidade já avaliou algo; apaga também as etapas
create or replace function public.app_proj_intervencao_excluir(p_kind text, p_gid bigint)
returns jsonb language plpgsql security definer set search_path to 'public', '13 - projetos_obra' as $function$
declare v_id uuid := auth.uid(); v_email text; v_est jsonb; v_docs jsonb; v_etapas jsonb; v_paths text[]; v_tab text; v_n int;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  select coalesce(email, v_id::text) into v_email from public.perfil where id=v_id and (funcao='admin' or coalesce(proj_sup_acesso,false));
  if not found then raise exception 'sem permissão'; end if;
  if p_kind not in ('ponto','linha') then raise exception 'kind inválido'; end if;
  v_tab := case p_kind when 'ponto' then 'intervencoes_pontuais' else 'intervencoes_lineares' end;

  if exists (select 1 from "13 - projetos_obra".intervencao_avanco where kind=p_kind and gid=p_gid)
     or exists (select 1 from "13 - projetos_obra".intervencao_estado where kind=p_kind and gid=p_gid
                and jsonb_path_exists(arv, '$.** ? ((@.k == "%" && @.p > 0) || (@.k == "m" && @.exec > 0))')) then
    raise exception 'Intervenção com avanço lançado não pode ser excluída';
  end if;
  if exists (select 1 from "13 - projetos_obra".intervencao_documento where kind=p_kind and gid=p_gid
             and tipo not in ('executivo','mapeamento','plano_furo','outro')) then
    raise exception 'Intervenção com documento de execução anexado não pode ser excluída — remova o anexo antes';
  end if;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa_evento where kind=p_kind and gid=p_gid and evento in ('aprovado','reprovado')) then
    raise exception 'Intervenção com documento já avaliado pela Qualidade não pode ser excluída';
  end if;

  select to_jsonb(e) into v_est from "13 - projetos_obra".intervencao_estado e where kind=p_kind and gid=p_gid;
  select coalesce(jsonb_agg(to_jsonb(d)),'[]'::jsonb), coalesce(array_agg(d.path) filter (where d.path is not null), '{}')
    into v_docs, v_paths from "13 - projetos_obra".intervencao_documento d where kind=p_kind and gid=p_gid;
  select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) into v_etapas from "13 - projetos_obra".intervencao_etapa t where kind=p_kind and gid=p_gid;

  if p_kind='ponto' then delete from "7 - setorizacao".intervencoes_pontuais where gid=p_gid;
  else delete from "7 - setorizacao".intervencoes_lineares where gid=p_gid; end if;
  get diagnostics v_n = row_count;
  if v_n=0 then raise exception 'Intervenção não encontrada'; end if;

  delete from "13 - projetos_obra".intervencao_documento where kind=p_kind and gid=p_gid;
  delete from "13 - projetos_obra".intervencao_etapa where kind=p_kind and gid=p_gid;
  delete from "13 - projetos_obra".intervencao_estado where kind=p_kind and gid=p_gid;

  insert into "7 - setorizacao".intervencoes_audit(tabela,operacao,gid,dados_anteriores,alterado_por)
  values (v_tab, 'EXCLUSAO_APP', p_gid, jsonb_build_object('estado',v_est,'documentos',v_docs,'etapas',v_etapas,'excluido_por',v_id), v_email);

  return jsonb_build_object('ok',true,'paths',to_jsonb(v_paths));
end $function$;

-- importar: linhas (HDD/VCA) e PONTOS (VRP/Macromedidor/Registro) pelo tipo de geometria; sem situacao_atual;
-- intervenção já liberada não troca de tipo. Devolve erros por linha em vez de abortar o lote.
create or replace function public.app_proj_intervencao_importar(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare e jsonb; v_id text; v_dmc text; n_ins int:=0; n_upd int:=0; n_mant int:=0; v_erros jsonb := '[]'::jsonb;
  v_geom geometry; v_gt text; v_tipo text; v_gid bigint; v_tipo_old text; v_lock boolean;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_eng_pode(auth.uid()) then raise exception 'sem permissão (Projetos · Engenharia)'; end if;
  for e in select * from jsonb_array_elements(p_rows) loop
    if coalesce(e->>'wkt','')='' then continue; end if;
    v_id := nullif(btrim(e->>'id'),'');
    begin
      v_geom := ST_GeomFromText(e->>'wkt',31983);
    exception when others then
      v_erros := v_erros || jsonb_build_object('id',v_id,'erro','geometria inválida'); continue;
    end;
    v_gt := upper(GeometryType(v_geom));
    v_dmc := nullif(regexp_replace(upper(coalesce(e->>'dmc','')), '_', '-', 'g'), '');  -- normaliza DMC_06 -> DMC-06
    if v_gt = 'POINT' then
      v_tipo := case lower(btrim(coalesce(e->>'tipo',''))) when 'vrp' then 'VRP' when 'macromedidor' then 'Macromedidor'
                  when 'registro' then 'Registro' when 'valvula' then 'Registro' when 'válvula' then 'Registro' end;
      if v_tipo is null then
        v_erros := v_erros || jsonb_build_object('id',v_id,'erro','tipo do ponto obrigatório: VRP, Macromedidor ou Registro'); continue;
      end if;
      select gid, tipo into v_gid, v_tipo_old from "7 - setorizacao".intervencoes_pontuais where v_id is not null and id=v_id limit 1;
      if v_gid is not null then
        select coalesce(locked,false) into v_lock from "13 - projetos_obra".intervencao_estado where kind='ponto' and gid=v_gid;
        if coalesce(v_lock,false) and v_tipo_old is distinct from v_tipo then n_mant := n_mant + 1; end if;
        update "7 - setorizacao".intervencoes_pontuais set
          projeto=e->>'projeto', cidade=e->>'cidade', dmc=v_dmc,
          tipo=case when coalesce(v_lock,false) then tipo else v_tipo end,
          dn=nullif(e->>'dn','')::bigint, tubulacao=e->>'tubulacao',
          codigo_do_documento=e->>'codigo_do_documento', responsavel=e->>'responsavel',
          coordenada_x=ST_X(v_geom), coordenada_y=ST_Y(v_geom), geom=v_geom
        where gid=v_gid;
        n_upd:=n_upd+1;
      else
        insert into "7 - setorizacao".intervencoes_pontuais
          (id, projeto, cidade, dmc, tipo, dn, tubulacao, codigo_do_documento, responsavel, coordenada_x, coordenada_y, criado_em, geom)
        values (v_id, e->>'projeto', e->>'cidade', v_dmc, v_tipo, nullif(e->>'dn','')::bigint, e->>'tubulacao',
          e->>'codigo_do_documento', e->>'responsavel', ST_X(v_geom), ST_Y(v_geom), now(), v_geom);
        n_ins:=n_ins+1;
      end if;
    elsif v_gt = 'LINESTRING' then
      v_tipo := case upper(btrim(coalesce(e->>'tipo',''))) when '' then 'HDD' when 'HDD' then 'HDD' when 'VCA' then 'VCA' end;
      if v_tipo is null then
        v_erros := v_erros || jsonb_build_object('id',v_id,'erro','tipo da linha: HDD ou VCA'); continue;
      end if;
      select gid, tipo into v_gid, v_tipo_old from "7 - setorizacao".intervencoes_lineares where v_id is not null and id=v_id limit 1;
      if v_gid is not null then
        select coalesce(locked,false) into v_lock from "13 - projetos_obra".intervencao_estado where kind='linha' and gid=v_gid;
        if coalesce(v_lock,false) and v_tipo_old is distinct from v_tipo then n_mant := n_mant + 1; end if;
        update "7 - setorizacao".intervencoes_lineares set
          projeto=e->>'projeto', cidade=e->>'cidade', dmc=v_dmc,
          tipo=case when coalesce(v_lock,false) then tipo else v_tipo end,
          dn=nullif(e->>'dn','')::bigint, tubulacao=e->>'tubulacao',
          codigo_do_documento=e->>'codigo_do_documento', responsavel=e->>'responsavel',
          extensao_m=nullif(e->>'extensao_m','')::double precision, geom=v_geom
        where gid=v_gid;
        n_upd:=n_upd+1;
      else
        insert into "7 - setorizacao".intervencoes_lineares
          (id, projeto, cidade, dmc, tipo, dn, tubulacao, codigo_do_documento, responsavel, extensao_m, avanco_percentual, criado_em, geom)
        values (v_id, e->>'projeto', e->>'cidade', v_dmc, v_tipo, nullif(e->>'dn','')::bigint, e->>'tubulacao',
          e->>'codigo_do_documento', e->>'responsavel', nullif(e->>'extensao_m','')::double precision,
          coalesce(nullif(e->>'avanco_percentual','')::double precision,0), now(), v_geom);
        n_ins:=n_ins+1;
      end if;
    else
      v_erros := v_erros || jsonb_build_object('id',v_id,'erro','geometria '||lower(v_gt)||' não suportada (use ponto ou linha simples)');
    end if;
    v_gid := null; v_lock := null; v_tipo_old := null;
  end loop;
  return jsonb_build_object('inseridas',n_ins,'atualizadas',n_upd,'tipo_mantido',n_mant,'erros',v_erros);
end$function$;

-- listagem do mapa: sem situacao_atual (coluna removida)
create or replace function public.app_proj_intervencoes(p_consorcio text default null, p_tipo text default null, p_dmc text default null)
returns jsonb language plpgsql security definer set search_path to 'public', '7 - setorizacao', 'extensions' as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  return jsonb_build_object(
    'pontos', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom,4326))::jsonb,
        'properties', jsonb_build_object('gid',gid,'id',id,'projeto',projeto,'cidade',cidade,'consorcio',cons,
          'dmc',dmc,'tipo',tipo,'dn',dn,'tubulacao',tubulacao,'codigo',codigo_do_documento,
          'responsavel',responsavel,'avanco',avanco_percentual))))
      from (
        select *, case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end cons
        from "7 - setorizacao".intervencoes_pontuais
      ) s
      where geom is not null
        and (p_consorcio is null or cons=p_consorcio)
        and (p_tipo is null or tipo=p_tipo)
        and (p_dmc is null or dmc=p_dmc)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'linhas', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom,4326))::jsonb,
        'properties', jsonb_build_object('gid',gid,'id',id,'projeto',projeto,'cidade',cidade,'consorcio',cons,
          'dmc',dmc,'tipo',tipo,'dn',coalesce(dn,dn_do_layer),'tubulacao',tubulacao,'codigo',codigo_do_documento,
          'responsavel',responsavel,'avanco',avanco_percentual,
          'layer_dwg',layer_dwg,'extensao_m',extensao_m))))
      from (
        select *, case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end cons
        from "7 - setorizacao".intervencoes_lineares
      ) s
      where geom is not null
        and (p_consorcio is null or cons=p_consorcio or cons is null)
        and (p_tipo is null or tipo=p_tipo or tipo is null)
        and (p_dmc is null or dmc=p_dmc or dmc is null)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'limites', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(geom, 30), 4326))::jsonb,
        'properties', jsonb_build_object('consorcio', consorcio, 'nome', no_zona))))
      from "1 - suporte_geografico".limite_za
      where (p_consorcio is null or consorcio=p_consorcio)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'dmcs', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(geom, 15), 4326))::jsonb,
        'properties', jsonb_build_object('codigo', codigo_dmc, 'numero', numero_dmc, 'consorcio', consorcio))))
      from "7 - setorizacao".dmc
      where coalesce(ativo,true) and (p_consorcio is null or consorcio=p_consorcio)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'resumo', (
      with p as (select *, case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end cons from "7 - setorizacao".intervencoes_pontuais)
      select jsonb_build_object(
        'n_pontos', count(*),
        'n_linhas', (select count(*) from "7 - setorizacao".intervencoes_lineares),
        'por_tipo', (select jsonb_object_agg(tipo,n) from (select tipo,count(*) n from p group by tipo) t),
        'por_cidade', (select jsonb_object_agg(cidade,n) from (select cidade,count(*) n from p group by cidade) t),
        'avanco_medio', round(avg(coalesce(avanco_percentual,0))::numeric,1)
      ) from p
    )
  );
end $function$;

-- app_me: + 'proj_obras' (responsáveis de obras)
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
    'qualidade',"8 - coleta_campo".pav_qualidade_pode(v_id),
    'epi_gestor',"9 - suprimentos".sup_epi_gestor(v_id),
    'sup_areas', jsonb_build_object('baixas', v_adm or ('baixas'=any(v_areas)), 'insumo', v_adm or ('insumo'=any(v_areas)), 'equip', v_adm or ('equip'=any(v_areas)), 'epi', v_adm or ('epi'=any(v_areas)), 'ferramenta', v_adm or ('ferramenta'=any(v_areas))),
    'equipes','[]'::jsonb);
end $function$;

-- 10) legado + migração dos dados existentes (nada é apagado)
update "13 - projetos_obra".intervencao_estado set legado = true where locked and not legado;
update "13 - projetos_obra".intervencao_estado set exec_pct = "13 - projetos_obra".proj_arv_pct(arv) where exec_pct is null;

-- documentos já anexados viram etapas enviadas (só os tipos que existem no modelo do tipo da intervenção)
insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, status, status_em, por_uuid, por_nome, enviado_por)
select d.kind, d.gid, d.tipo, 'enviado', d.atualizado_em, d.atualizado_por, coalesce(p.nome, p.email), d.atualizado_por
from "13 - projetos_obra".intervencao_documento d
join "13 - projetos_obra".vw_iv v on v.kind = d.kind and v.gid = d.gid
join "13 - projetos_obra".etapa_modelo m on m.tipo = v.tipo and m.chave = d.tipo and m.natureza = 'doc'
left join public.perfil p on p.id = d.atualizado_por
on conflict (kind, gid, chave) do nothing;
-- OS SIGOS que já estava na árvore das liberadas
insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, status, status_em, valor, por_uuid, enviado_por)
select e.kind, e.gid, 'os_sigos', 'enviado', e.atualizado_em, regexp_replace(o->>'v', '\D', '', 'g'), e.atualizado_por, e.atualizado_por
from "13 - projetos_obra".intervencao_estado e
cross join lateral jsonb_path_query(e.arv, '$[*] ? (@.os == true)') o
where e.legado and regexp_replace(coalesce(o->>'v', ''), '\D', '', 'g') <> ''
on conflict (kind, gid, chave) do nothing;
-- aprovações dos documentos migrados → aguardando (as das liberadas aparecem na fila da Qualidade com selo "legado", sem travar)
insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, status, status_em)
select e.kind, e.gid, a.chave, 'aguardando', e.status_em
from "13 - projetos_obra".intervencao_etapa e
join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
join "13 - projetos_obra".etapa_modelo a on a.tipo = v.tipo and a.natureza = 'aprovacao' and a.aprova = e.chave
where e.status = 'enviado'
on conflict (kind, gid, chave) do nothing;
-- rastro da migração (evento 'legado' não gera aviso)
insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, valor, arquivo, nome_arquivo, comentario, por_uuid, por_nome, em)
select e.kind, e.gid, e.chave, 'legado', e.valor, d.path, d.nome, 'migração para o pipeline (02/11/2026)', e.por_uuid, e.por_nome, coalesce(e.status_em, now())
from "13 - projetos_obra".intervencao_etapa e
left join "13 - projetos_obra".intervencao_documento d on d.kind = e.kind and d.gid = e.gid and d.tipo = e.chave
where not exists (select 1 from "13 - projetos_obra".intervencao_etapa_evento x where x.kind = e.kind and x.gid = e.gid and x.chave = e.chave);
-- chave da etapa nos avanços já lançados
update "13 - projetos_obra".intervencao_avanco a
   set etapa = "13 - projetos_obra".proj_etapa_de_rotulo(v.tipo, coalesce(a.atividade, split_part(a.caminho, ' › ', 1)))
  from "13 - projetos_obra".vw_iv v
 where v.kind = a.kind and v.gid = a.gid and a.etapa is null;

-- 11) situacao_atual sai (sem uso; backup no passo 0)
alter table "7 - setorizacao".intervencoes_pontuais drop column if exists situacao_atual;
alter table "7 - setorizacao".intervencoes_lineares drop column if exists situacao_atual;

-- 12) grants: helpers internos fechados; RPCs só p/ authenticated
revoke all on function "13 - projetos_obra".proj_obras_cargos(), "13 - projetos_obra".proj_eng_pode(uuid),
  "13 - projetos_obra".proj_obras_pode(uuid), "13 - projetos_obra".proj_ator_pode(uuid,text),
  "13 - projetos_obra".proj_obras_uuids(), "13 - projetos_obra".proj_eng_uuids(),
  "13 - projetos_obra".proj_no_pct(jsonb), "13 - projetos_obra".proj_arv_pct(jsonb),
  "13 - projetos_obra".proj_etapa_de_rotulo(text,text), "13 - projetos_obra".proj_calc(text,bigint),
  "13 - projetos_obra".proj_fase_sync(text,bigint),
  "13 - projetos_obra".proj_etapa_envio(text,bigint,text,text,uuid,text,text,text,text),
  "13 - projetos_obra".proj_f1_falta(text,bigint)
  from public, anon, authenticated;
revoke all on function public.app_proj_modelo(), public.app_proj_pipeline(text,bigint), public.app_proj_pipeline_resumo(),
  public.app_proj_fila(text,boolean), public.app_proj_eventos(date,date), public.app_proj_etapa_escopo(text,bigint,text,boolean,text),
  public.app_proj_liberar(text,bigint,boolean,jsonb), public.app_proj_etapa_enviar(text,bigint,text,text,text,text,text),
  public.app_proj_etapa_avaliar(text,bigint,text,boolean,text), public.app_proj_prazo_set(text,text,int,int),
  public.app_proj_prazo_log(int) from public, anon;
grant execute on function public.app_proj_modelo(), public.app_proj_pipeline(text,bigint), public.app_proj_pipeline_resumo(),
  public.app_proj_fila(text,boolean), public.app_proj_eventos(date,date), public.app_proj_etapa_escopo(text,bigint,text,boolean,text),
  public.app_proj_liberar(text,bigint,boolean,jsonb), public.app_proj_etapa_enviar(text,bigint,text,text,text,text,text),
  public.app_proj_etapa_avaliar(text,bigint,text,boolean,text), public.app_proj_prazo_set(text,text,int,int),
  public.app_proj_prazo_log(int) to authenticated;
