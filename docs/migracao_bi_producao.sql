-- BI "Dashboard Producao" lendo o SIGOS do banco (2026-11-10) — APLICADA no banco em 10/11/2026 (migração `bi_producao`).
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
--   select public.bi_chave_criar('producao', '17 - sigos', 'bi_');
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
