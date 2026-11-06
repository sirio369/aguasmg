-- Segurança (diagnóstico LGPD 06/11/2026): 4 RPCs da Priorização de HD estavam executáveis por `anon`.
--  * app_nrw_hd_premissas / _premissas_salvar / _recompute_derive usam o gate
--    "v_id is not null and not exists(...)" → com auth.uid() nulo (anônimo) o gate PASSAVA.
--  * app_nrw_hd_rebuild_chunk não tem gate nenhum.
-- Qualquer um com a chave pública do app podia ler/alterar as premissas e reprocessar a priorização.
--
-- Correção só de privilégio (o corpo das funções não muda):
--  * premissas / premissas_salvar → só `authenticated` (o front chama; logado sempre tem auth.uid(),
--    então o gate admin|dev volta a valer).
--  * recompute_derive / rebuild_chunk → internas: ninguém da API executa. São chamadas por
--    premissas_salvar (SECURITY DEFINER, roda como postgres) e pelo rebuild manual no SQL editor (postgres).
-- O `revoke ... from public` é o que tira o anon (o grant vinha do PUBLIC padrão).

revoke execute on function public.app_nrw_hd_premissas()                         from public, anon;
revoke execute on function public.app_nrw_hd_premissas_salvar(jsonb, jsonb)      from public, anon;
grant  execute on function public.app_nrw_hd_premissas()                         to authenticated;
grant  execute on function public.app_nrw_hd_premissas_salvar(jsonb, jsonb)      to authenticated;

revoke execute on function public.app_nrw_hd_recompute_derive(bigint[])          from public, anon, authenticated;
revoke execute on function public.app_nrw_hd_rebuild_chunk(integer, integer)     from public, anon, authenticated;
