-- Família "Mobilização social" no SIGOS (2026-11-10) — APLICADA em 10/11/2026 (migração `sigos_familia_mobilizacao_social`).
-- Código 732 79 00 "TRABALHO MOB.SOCIAL CT.PERF.PERDAS-AGUA" (gerência GNDS; 233 OS de 21–29/09/2026 inseridas a partir do
-- CSV legado do BI Producao). Antes caía no "else" das funções e aparecia no RDO/Vitrine com o texto cru do SIGOS.
-- Usado por rdo_eventos, app_vitrine_feed, app_vitrine_sigos e app_sigos_abertas.
-- Editado por substituição de texto nas funções atuais (preserva o resto da regra); idempotente.
do $mig$
declare d text; n text;
begin
  -- grupo
  d := pg_get_functiondef('public.sigos_servico_grupo(text)'::regprocedure);
  if d !~ 'MOB' then
    n := replace(d, $x$when p_desc ~* 'REDE AGUA' then$x$,
                    $x$when p_desc ~* 'MOB\.?\s*SOCIAL' then 'Mobilização social'
    when p_desc ~* 'REDE AGUA' then$x$);
    if n = d then raise exception 'âncora não encontrada em sigos_servico_grupo'; end if;
    execute n;
  end if;
  -- ordem da família (depois de Padrão de ligação 75, antes de Atendimento comercial 80)
  d := pg_get_functiondef('public.rdo_familia_ordem(text)'::regprocedure);
  if d !~ 'Mobiliza' then
    n := replace(d, $x$when 'Atendimento comercial' then 80$x$,
                    $x$when 'Mobilização social' then 78 when 'Atendimento comercial' then 80$x$);
    if n = d then raise exception 'âncora não encontrada em rdo_familia_ordem'; end if;
    execute n;
  end if;
  -- nome legível do serviço
  d := pg_get_functiondef('public.sigos_servico_nome(text)'::regprocedure);
  if d !~ 'MOB' then
    n := replace(d, $x$when d ~ 'VISTORIA' then$x$,
                    $x$when d ~ 'MOB\.?\s*SOCIAL' then 'trabalho de mobilização social'
    when d ~ 'VISTORIA' then$x$);
    if n = d then raise exception 'âncora não encontrada em sigos_servico_nome'; end if;
    execute n;
  end if;
end $mig$;

-- Parte 2 (2026-11-10, migração `sigos_vistoria_em_fiscalizacao`, APLICADA): VISTORIA DE IMOVEL (676 79 00 = fiscalização de
-- fraudes) entra na família "Fiscalização de irregularidade" (antes: família própria "Vistoria de imóvel").
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.sigos_servico_grupo(text)'::regprocedure);
  n := replace(d, $x$when p_desc ~* '^VISTORIA DE IMOVEL' then 'Vistoria de imóvel'$x$,
                  $x$when p_desc ~* '^VISTORIA DE IMOVEL' then 'Fiscalização de irregularidade'   -- 676 79 00 = fiscalização de fraudes (2026-11-10)$x$);
  if n = d then
    if d ~ 'VISTORIA DE IMOVEL'' then ''Fiscaliza' then return; end if;
    raise exception 'âncora não encontrada em sigos_servico_grupo';
  end if;
  execute n;
end $mig$;
