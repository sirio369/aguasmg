-- RDO: km da pesquisa = km de REDE pesquisada (2026-11-10) — APLICADA em 10/11/2026 (migrações `rdo_pesquisa_km_rede` +
-- `rdo_pesquisa_km_rede_fix`). Antes a linha "Pesquisa de vazamento — X km de rede pesquisados" somava o km ANDADO
-- (pesquisa_trecho). Agora: pp_execucao, ZA pela rede, dia no horário de Brasília — mesma conta do Acompanhamento e do BI.
-- ⚠️ st_length devolve double precision: sem o ::numeric o round(km, 1) do l_pesq quebra a função inteira.
do $mig$
declare d text; i int; j int; novo text;
begin
  d := pg_get_functiondef('public.rdo_eventos(date,date)'::regprocedure);
  if d like '%km de REDE pesquisada (pp_execucao%' then return; end if;
  i := strpos(d, '  pq as (');
  if i = 0 then raise exception 'âncora pq não encontrada'; end if;
  j := i + strpos(substr(d, i), E'\n  ),') - 1;   -- fim do CTE pq
  if substr(d, i, j - i) not like '%pesquisa_trecho%' then raise exception 'CTE pq inesperado'; end if;
  novo := $x$  pq as (   -- km de REDE pesquisada (pp_execucao, ZA pela rede) — não o km andado (2026-11-10)
    select (e.executado_em at time zone 'America/Sao_Paulo')::date d, r.consorcio z,
           coalesce(e.comprimento_m, st_length(e.geom)::numeric) m
      from "8 - coleta_campo".pp_execucao e
      join "2 - infra_agua".rede r on r.id = e.rede_id
     where (e.executado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate$x$;
  execute substr(d, 1, i - 1) || novo || substr(d, j);
end $mig$;
