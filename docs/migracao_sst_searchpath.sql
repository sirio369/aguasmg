-- Indicadores SST: fixa o search_path dos 2 helpers puros (advisor 0011 function_search_path_mutable). 2026-11-05.
alter function "16 - qsms".sst_hoje() set search_path = '';
alter function "16 - qsms".sst_consorcio_nome(text) set search_path = '';
