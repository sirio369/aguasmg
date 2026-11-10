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

-- Parte 2 (2026-11-10, migração `rdo_vistoria_bloco_unico`, APLICADA): Vistoria de imóvel entra na mesma regra.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.rdo_eventos(date,date)'::regprocedure);
  if d !~ $x$'Troca de hidrômetro', 'Vistoria de imóvel'\)$x$ then
    n := replace(d, $x$in ('Recadastramento', 'Fiscalização de irregularidade', 'Troca de hidrômetro')$x$,
                    $x$in ('Recadastramento', 'Fiscalização de irregularidade', 'Troca de hidrômetro', 'Vistoria de imóvel')$x$);
    if n = d then raise exception 'âncora não encontrada em rdo_eventos'; end if;
    n := replace(n, '-- Recadastramento / Fiscalização / Troca de HD: executadas', '-- Recadastramento / Fiscalização / Troca de HD / Vistoria: executadas');
    execute n;
  end if;
end $mig$;

-- Parte 3 (2026-11-10, migração `rdo_todas_familias_bloco_unico`, APLICADA): TODAS as famílias em bloco único.
-- Linha só com encerradas sem execução sai como 'Pendência'. Não havia RDO fechado nem rdo_item em sigos:nexec:*.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.rdo_eventos(date,date)'::regprocedure);
  if d ~ $x$case when true then 'todas'$x$ then return; end if;
  n := replace(d,
    $x$case when public.sigos_servico_grupo(s.desc_servico) in ('Recadastramento', 'Fiscalização de irregularidade', 'Troca de hidrômetro', 'Vistoria de imóvel')$x$,
    $x$case when true   -- desde 2026-11-10 todas as famílias (antes: Recadastramento/Fiscalização/Troca de HD/Vistoria)$x$);
  if n = d then raise exception 'âncora 1 não encontrada em rdo_eventos'; end if;
  d := n;
  n := replace(d,
    $x$select x.d, x.z, 'sigos:exec:' || x.grp, 'Execução', 'SIGOS'$x$,
    $x$select x.d, x.z, 'sigos:exec:' || x.grp,
           case when count(*) filter (where x.sit = 'executada') = 0 then 'Pendência' else 'Execução' end, 'SIGOS'$x$);
  if n = d then raise exception 'âncora 2 não encontrada em rdo_eventos'; end if;
  execute n;
end $mig$;
