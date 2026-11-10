-- RDO: Troca de hidrômetro numa linha só (2026-11-10) — APLICADA em 10/11/2026 (migração `rdo_troca_hd_bloco_unico`).
-- Igual Recadastramento/Fiscalização (docs/migracao_rdo_agrupa_familias.sql): executadas + encerradas sem execução saem num
-- bloco único por dia × ZA, chave sigos:exec:Troca de hidrômetro. Não havia rdo_item na chave sigos:nexec:Troca… nem RDO fechado.
-- Editado por substituição de texto na função atual; idempotente.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.rdo_eventos(date,date)'::regprocedure);
  if d !~ $x$in \('Recadastramento', 'Fiscalização de irregularidade', 'Troca de hidrômetro'\)$x$ then
    n := replace(d, $x$in ('Recadastramento', 'Fiscalização de irregularidade')$x$,
                    $x$in ('Recadastramento', 'Fiscalização de irregularidade', 'Troca de hidrômetro')$x$);
    if n = d then raise exception 'âncora não encontrada em rdo_eventos'; end if;
    n := replace(n, '-- Recadastramento / Fiscalização: executadas', '-- Recadastramento / Fiscalização / Troca de HD: executadas');
    execute n;
  end if;
end $mig$;
