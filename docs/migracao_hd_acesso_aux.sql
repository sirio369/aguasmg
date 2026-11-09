-- ============================================================================
-- Priorização de troca de HD — acesso do Auxiliar de Programação (2026-11-09)
-- docs/MODULOS.md §11 (Priorização de HD)
--
-- A tela abre pelo Auxiliar de Programação (perdas.html?s=hdpri, aux-solo), mas as RPCs só
-- liberavam admin|dev_acesso → quem entrava só com aux_acesso via "sem permissão".
-- Mesmo gate da Fiscalização (_nrw_fraude_gate): admin | dev_acesso | aux_acesso.
-- Só as RPCs de LEITURA; app_nrw_hd_premissas_salvar / rebuild seguem admin|dev.
-- Troca só o trecho do gate no corpo atual de cada função (assinaturas inalteradas).
-- ============================================================================
do $$
declare r record; d text; antigo text := '(funcao=''admin'' or coalesce(dev_acesso,false))';
begin
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('app_nrw_hd_resumo','app_nrw_hd_mapa','app_nrw_hd_ranking','app_nrw_hd_detalhe',
                         'app_nrw_hd_sigos_diverg','app_nrw_hd_premissas')
  loop
    d := pg_get_functiondef(r.oid);
    if position(antigo in d) = 0 then raise exception 'gate não encontrado em %', r.proname; end if;
    execute replace(d, antigo, '(funcao=''admin'' or coalesce(dev_acesso,false) or coalesce(aux_acesso,false))');
  end loop;
end $$;
