-- Relatório consolidado — versão FISCALIZAÇÃO (2026-11-13)
-- A tela fiscv_rel (bloco 🏛️ Fiscalização) lê os dias validados por app_fiscv_periodo (fisc_pode_ver_validado) e precisa
-- classificar as OS por agrupamento: app_fisc_rel_classes passa a aceitar também quem vê o validado (admin | fiscal |
-- fisc_acesso). Só leitura (código de serviço → gestor/agrupamento); retrocompatível.
do $m$
declare d text; a text := $x$if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;$x$;
begin
  d := pg_get_functiondef('public.app_fisc_rel_classes(text[])'::regprocedure);
  if position('fisc_pode_ver_validado' in d) = 0 then
    if position(a in d) = 0 then raise exception 'trecho não achado'; end if;
    execute replace(d, a, $x$if not (public.sigos_pode_ver(auth.uid()) or public.fisc_pode_ver_validado(auth.uid())) then raise exception 'sem permissão'; end if;$x$);
  end if;
end $m$;
