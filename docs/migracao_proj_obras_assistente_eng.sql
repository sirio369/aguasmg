-- 12/11/2026 — Projetos: cargo "Assistente de Engenharia" passa a contar como Obras
-- (lança avanço, pré-obra, pedido/refação de ensaio de reaterro, relatórios de Obras
--  e recebe os avisos de Obras via proj_obras_uuids()).
-- JÁ APLICADA em produção (migração proj_obras_cargos_assistente_eng). Arquivo só de registro.
CREATE OR REPLACE FUNCTION "13 - projetos_obra".proj_obras_cargos()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select array['Supervisor de Produção','Coordenador de Serviços','Gestor de Obras','Assistente de Engenharia'];
$function$;
