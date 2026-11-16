-- VRPs – Campo › Ficha cadastral (16/11/2026)
-- A lista de fichas passa a abrir para qualquer usuário logado (antes: só vrp_pode_gestao()).
-- Devolve só cadastro + contagens (OS, visitas, pendências) — sem dado pessoal.
-- app_vrp_ficha (ficha individual) já não tinha gate. Ações de gestão seguem com gate próprio.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.app_vrp_ficha_listar(text,text)'::regprocedure);
  d := replace(d, 'if not public.vrp_pode_gestao() then raise exception ''sem permissão''; end if;',
                  'if auth.uid() is null then raise exception ''sem permissão''; end if;');
  execute d;
end $$;
