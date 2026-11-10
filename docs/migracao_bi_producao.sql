-- BI "Dashboard Producao" lendo o SIGOS do banco (2026-11-10) — APLICADA em 10/11/2026 (migrações `bi_producao` e `bi_producao_redes_pesquisa`, parte 2 no fim).
-- Antes: a consulta qRealizado do BI lia os CSV de Encerradas soltos em
--        Bases\Realizado SIGOS\<AAAA-MM>\*.csv (pasta do SharePoint, pelo OneDrive de quem atualiza).
-- Agora: lê "17 - sigos".os_encerrada (alimentada pela tela Carga SIGOS do Auxiliar) pela API HTTPS,
--        no mesmo esquema do BI QSMS (docs/migracao_bi_api.sql):
--   GET {SbUrl}rest/v1/rpc/bi_dados?p_view=bi_producao_os&apikey={SbAnon}&p_chave={SbChave}
--
-- A view devolve exatamente as colunas que a função fnLerSigos do BI extraía do CSV (mesmos nomes),
-- para que o resto do qRealizado (consórcio, de-para código→ação, preço, valor) não mude.
--   n_os           = Número
--   status         = Status (com acento correto — o CSV às vezes vinha com "N?O")
--   codigo_bruto   = Cód. serviço (7 dígitos, sem espaço; o BI formata "999 99 99")
--   descricao      = Descrição do serviço
--   gerencia       = Gerência
--   matricula      = Matrícula (texto, como no CSV)
--   endereco       = Endereço (o BI usa p/ achar o consórcio quando a empresa vem vazia)
--   data_geracao   = Data de geração
--   data_execucao  = Data de execução
--   empresa        = Empresa contratada (o BI procura "INTEGRADAS"/"EFICI")
--   ocorrencia     = Ocorrência
--   arquivo_origem = nome do arquivo enviado na Carga SIGOS
--   pasta_origem   = AAAA-MM da execução (antes era o nome da subpasta)
--   carregado_em   = quando a OS entrou no banco
-- Fora (LGPD / sem uso no BI): responsável, integrantes, coordenadas, reclamação, resultado.
--
-- Chave do BI (SQL Editor, como postgres — mostra a chave UMA vez; a anterior deixa de valer):
--   select public.bi_chave_criar('producao', '17 - sigos', 'bi_producao');
-- No Power BI: parâmetro SbChave = essa chave; no serviço, credencial Anônimo + "Ignorar conexão de teste".

create or replace view "17 - sigos".bi_producao_os as
select e.numero                                   as n_os,
       e.status,
       e.cod_servico                              as codigo_bruto,
       e.desc_servico                             as descricao,
       e.gerencia,
       e.matricula::text                          as matricula,
       e.endereco,
       e.data_geracao,
       e.execucao                                 as data_execucao,
       e.empresa_contratada                       as empresa,
       e.ocorrencia,
       a.nome_original                            as arquivo_origem,
       to_char(e.execucao, 'YYYY-MM')             as pasta_origem,
       e.carregado_em
  from "17 - sigos".os_encerrada e
  left join "17 - sigos".arquivo a on a.id = e.arquivo_id;

comment on view "17 - sigos".bi_producao_os is
  'BI Dashboard Producao (qRealizado): OS encerradas do SIGOS no formato que o BI lia do CSV. Lida via public.bi_dados com a chave "producao".';

revoke all on "17 - sigos".bi_producao_os from public, anon, authenticated;
grant select on "17 - sigos".bi_producao_os to bi_sigos_leitura;

-- =====================================================================================================
-- Parte 2 (2026-11-10, migração `bi_producao_redes_pesquisa`): Redes e Pesquisa também saem do banco.
-- Antes: CSV exportados à mão do AcquaHub em Bases\Realizado Redes\<AAAA-MM> e Bases\Realizado Pesquisa\<AAAA-MM>.
-- As views ficam no "17 - sigos" só porque a chave "producao" do BI é presa a um schema (bi_dados);
-- elas leem o "13 - projetos_obra" e o "8 - coleta_campo" (views definer → rodam como postgres).
-- Datas = dia no horário de Brasília (igual ao app). Nomes das colunas = cabeçalho dos CSV antigos (contrato com o BI).

-- Avanço de obra (mesmas colunas do resumo_avancos_projetos.csv). O BI usa só unidade m + atividade com "tubula".
create or replace view "17 - sigos".bi_producao_redes as
select a.id,
       (a.ts at time zone 'America/Sao_Paulo')::date            as "Data",
       a.iv_local                                               as "Intervencao",
       a.iv_cod                                                 as "Codigo",
       a.consorcio                                              as "Consorcio",
       case a.tipo when 'rede_hdd'   then 'Rede HDD'
                   when 'rede_vca'   then 'Rede VCA'
                   when 'vrp_impl'   then 'Instalação de VRP'
                   when 'macro_impl' then 'Instalação de macromedidor'
                   when 'valvula'    then 'Instalação de registro'
                   else a.tipo end                              as "Tipo",
       coalesce(m.nome, a.atividade)                            as "Atividade",   -- nome da etapa pela chave estável (como o app)
       a.sub                                                    as "Subatividade",
       abs(a.valor)                                             as "Avanco",
       a.unidade                                                as "Unidade",
       coalesce(a.obs, '')                                      as "Observacao",
       coalesce(a.equipe, a.autor_nome, '')                     as "Equipe"
  from "13 - projetos_obra".intervencao_avanco a
  left join "13 - projetos_obra".etapa_modelo m
         on m.chave = a.etapa
        and m.tipo = case a.tipo when 'rede_hdd' then 'hdd' when 'rede_vca' then 'vca' when 'vrp_impl' then 'vrp'
                                 when 'valvula' then 'registro' when 'macro_impl' then 'macro' end;

-- Pesquisa de vazamento por dia × ZA × colaborador (mesmo cálculo do Acompanhamento da pesquisa):
--   km_rede_pesquisado = pp_execucao (ZA pela rede) · km_andado = pesquisa_trecho (ZA pela geometria no limite da ZA —
--   o campo consorcio do trecho vem vazio/errado em parte dos registros) · vazamentos = tipos "Vazamento…" ·
--   ocorrencias = todas as ocorrências (ZA pelo ponto). Dia sem nada (tudo arredondado a zero) não entra.
create or replace view "17 - sigos".bi_producao_pesquisa as
with ex as (
  select (e.executado_em at time zone 'America/Sao_Paulo')::date d, r.consorcio za, e.colaborador_uuid u,
         sum(coalesce(e.comprimento_m, st_length(e.geom)))::numeric m
    from "8 - coleta_campo".pp_execucao e
    join "2 - infra_agua".rede r on r.id = e.rede_id
   where e.colaborador_uuid is not null
   group by 1, 2, 3),
an as (
  select (t.inicio_ts at time zone 'America/Sao_Paulo')::date d,
         coalesce((select z.consorcio from "1 - suporte_geografico".limite_za z
                    where st_intersects(z.geom, st_pointonsurface(t.geom)) limit 1), t.consorcio) za,
         pe.id u, sum(coalesce(t.comprimento_m, st_length(t.geom)))::numeric m
    from "8 - coleta_campo".pesquisa_trecho t
    join public.perfil pe on t.usuario in (pe.nome, pe.email)
   group by 1, 2, 3),
oc as (
  select (o.data_hora at time zone 'America/Sao_Paulo')::date d, o.consorcio za, pe.id u,
         count(*) filter (where o.tipo ilike 'vazamento%') vaz, count(*) n
    from "8 - coleta_campo".ocorrencia o
    join public.perfil pe on o.usuario in (pe.nome, pe.email)
   group by 1, 2, 3),
k as (select d, za, u from ex union select d, za, u from an union select d, za, u from oc)
select k.d                                              as "Data",
       k.za                                             as "ZA",
       case k.za when 'ZA1004' then 'AI' when 'ZA0200' then 'EH' end as "Consorcio_id",
       pe.nome                                          as "Colaborador",
       round(coalesce(ex.m, 0) / 1000.0, 2)             as km_rede_pesquisado,
       round(coalesce(an.m, 0) / 1000.0, 2)             as km_andado,
       coalesce(oc.vaz, 0)                              as vazamentos,
       coalesce(oc.n, 0)                                as ocorrencias
  from k
  join public.perfil pe on pe.id = k.u
  left join ex using (d, za, u)
  left join an using (d, za, u)
  left join oc using (d, za, u)
 where k.za in ('ZA1004', 'ZA0200')
   and (round(coalesce(ex.m, 0) / 1000.0, 2) > 0 or round(coalesce(an.m, 0) / 1000.0, 2) > 0 or coalesce(oc.n, 0) > 0);

comment on view "17 - sigos".bi_producao_redes is 'BI Dashboard Producao (qRedes): avanço de obra dos Projetos, formato do resumo_avancos_projetos.csv.';
comment on view "17 - sigos".bi_producao_pesquisa is 'BI Dashboard Producao (qPesquisa): km de rede pesquisado por dia × ZA × colaborador (Acompanhamento da pesquisa).';

revoke all on "17 - sigos".bi_producao_redes, "17 - sigos".bi_producao_pesquisa from public, anon, authenticated;
grant select on "17 - sigos".bi_producao_redes, "17 - sigos".bi_producao_pesquisa to bi_sigos_leitura;
