-- Logística reversa de HD — quantidade e lista de HDs por caixa (2026-11-18, aplicada como migração `hd_caixas_qtd_lista_hds`)
-- Motivo: na carga da COPASA (planilha "BANCO - HD", 100 caixas × 10 HDs) 19 caixas de Betim (A25HX…) têm HDs fora de sequência;
-- só com HD inicial/final o app contava milhares de HDs por caixa. Colunas nulas = app segue calculando pela faixa (cadastro manual).
alter table "12 - retaguarda".hd_caixa add column if not exists qtd_hd int, add column if not exists hds text[];

-- app_hdcx_listar passa a devolver 'qtd' e 'hds'; app_hdcx_editar zera qtd/hds se a faixa inicial/final for alterada.
-- (definições completas aplicadas no banco — ver pg_get_functiondef('public.app_hdcx_listar'::regproc))
