-- RH · Carga RH aceita o Excel do Kairos (2026-11-13) — roda DEPOIS de migracao_rh_ponto_carga.sql.
-- O "relatorio_ponto_funcionario…xls" do Kairos é uma página HTML salva como .xls; o app lê no navegador (rhParseXls) e
-- manda ao banco o mesmo JSON do PDF — nenhuma RPC muda. Só o bucket precisa aceitar o tipo do arquivo guardado como prova.
-- A emissão (que o Excel não traz) é a data/hora do arquivo, gravada no nome do objeto: <dia>/<uuid>_e<AAAAMMDDhhmm>_<nome>.
update storage.buckets
   set allowed_mime_types = array['application/pdf', 'application/vnd.ms-excel']
 where id = 'rh-ponto';
