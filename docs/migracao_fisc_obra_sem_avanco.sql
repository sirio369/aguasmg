-- Consolidador › Obras em andamento: OBRA SEM AVANÇO NO DIA NÃO PRECISA DE VALIDAÇÃO (2026-11-13)
-- Pedido do usuário: fim de semana/dia sem lançamento na obra obrigava a validar a obra (e o dia) sem nada ter acontecido.
-- "Sem avanço" = nenhum avanço lançado no dia e não concluída no dia (fisc_sem_avanco). Essas obras continuam aparecendo
-- (com o % do dia), mas:
--   · não contam como pendência p/ "Validar o dia" (app_fisc_dia_validar) nem no calendário (app_fisc_mes: n/pend);
--     dia que só tem obra sem avanço vira "vazio" (nada a validar);
--   · "Validar todas as linhas" não as marca (app_fisc_linhas_validar_todas);
--   · entram no snapshot do dia validado (a Fiscalização COPASA vê o % delas);
--   · no Excel/período, situação "sem avanço" (app_fisc_periodo).
-- Hash do dia (fisc_dia_hash) e das obras não mudam → dias já validados continuam validados; avanço lançado depois com data
-- desse dia muda o hash da obra (ela passa a ter avanço → volta a exigir validação) e o dia validado aparece como "mudou".
-- APLICADO em produção em 2026-11-13 (migração `fisc_obra_sem_avanco`, via MCP), antes do merge do PR #352 (retrocompatível).
-- Patch textual sobre as definições vigentes (falha se algum trecho não casar).

create or replace function public.fisc_sem_avanco(x jsonb) returns boolean
 language sql immutable set search_path to 'public'
as $f$ select x ? 'avancos' and coalesce(jsonb_array_length(x->'avancos'), 0) = 0 and not coalesce((x->>'concluida')::boolean, false) $f$;
revoke all on function public.fisc_sem_avanco(jsonb) from public, anon, authenticated;

do $mig$
declare d text; d0 text;
begin
  -- 1) validar o dia: obra sem avanço não é pendência; snapshot leva as obras sem avanço
  d0 := pg_get_functiondef('public.app_fisc_dia_validar(date,text)'::regprocedure);
  d := replace(d0, $a$   where x->'val' is null or jsonb_typeof(x->'val') = 'null' or (x->'val'->>'ok')::boolean is not true;$a$,
                   $a$   where (x->'val' is null or jsonb_typeof(x->'val') = 'null' or (x->'val'->>'ok')::boolean is not true)
     and not public.fisc_sem_avanco(x);   -- obra sem avanço no dia não precisa de validação$a$);
  if d = d0 then raise exception 'app_fisc_dia_validar: trecho 1 não encontrado'; end if;
  d0 := d;
  d := replace(d0, $a$jsonb_array_elements(d->'projetos') x where x->'val'->>'status' = 'validada'), '[]'::jsonb));$a$,
                   $a$jsonb_array_elements(d->'projetos') x where x->'val'->>'status' = 'validada' or public.fisc_sem_avanco(x)), '[]'::jsonb));$a$);
  if d = d0 then raise exception 'app_fisc_dia_validar: trecho 2 não encontrado'; end if;
  execute d;

  -- 2) validar todas as linhas: não marca obra sem avanço
  d0 := pg_get_functiondef('public.app_fisc_linhas_validar_todas(date,text)'::regprocedure);
  d := replace(d0, $a$select y->>'chave' chave, y->>'hash' hash, y->'val' val from$a$,
                   $a$select y->>'chave' chave, y->>'hash' hash, y->'val' val, public.fisc_sem_avanco(y) sa from$a$);
  if d = d0 then raise exception 'app_fisc_linhas_validar_todas: trecho 1 não encontrado'; end if;
  d0 := d;
  d := replace(d0, $a$   where x.val is null or jsonb_typeof(x.val) = 'null' or (x.val->>'ok')::boolean is not true$a$,
                   $a$   where (x.val is null or jsonb_typeof(x.val) = 'null' or (x.val->>'ok')::boolean is not true) and not x.sa$a$);
  if d = d0 then raise exception 'app_fisc_linhas_validar_todas: trecho 2 não encontrado'; end if;
  execute d;

  -- 3) calendário: n/pend sem as obras sem avanço (o hash do dia continua com tudo)
  d0 := pg_get_functiondef('public.app_fisc_mes(date,text)'::regprocedure);
  d := replace(d0, $a$select l.dia, l.chave, l.hash from public.fisc_linhas(v_de, v_ate, p_za) l
             union all select p.dia, p.chave, p.hash from public.fisc_projetos(v_de, v_ate, p_za) p),$a$,
                   $a$select l.dia, l.chave, l.hash, false sa from public.fisc_linhas(v_de, v_ate, p_za) l
             union all select p.dia, p.chave, p.hash, (p.avancos = '[]'::jsonb and not p.concluida) from public.fisc_projetos(v_de, v_ate, p_za) p),$a$);
  if d = d0 then raise exception 'app_fisc_mes: trecho 1 não encontrado'; end if;
  d0 := d;
  d := replace(d0, $a$  s as (select l.dia, count(*) n,
               count(*) filter (where v.chave is null or v.hash is distinct from l.hash) pend,$a$,
                   $a$  s as (select l.dia, count(*) filter (where not l.sa) n,
               count(*) filter (where not l.sa and (v.chave is null or v.hash is distinct from l.hash)) pend,$a$);
  if d = d0 then raise exception 'app_fisc_mes: trecho 2 não encontrado'; end if;
  execute d;

  -- 4) período (Excel): situação "sem avanço"
  d0 := pg_get_functiondef('public.app_fisc_periodo(date,date,text)'::regprocedure);
  d := replace(d0, $a$'concluida', p.concluida, 'avancos', p.avancos,
                              'status', case when v.chave is null$a$,
                   $a$'concluida', p.concluida, 'avancos', p.avancos,
                              'status', case when p.avancos = '[]'::jsonb and not p.concluida then 'sem avanço' when v.chave is null$a$);
  if d = d0 then raise exception 'app_fisc_periodo: trecho 1 não encontrado'; end if;
  execute d;
end $mig$;

-- ===================== 2ª parte (2026-11-13, pedido do usuário: "o que estiver validado e não tiver avanço, remova o validado") =====================
-- APLICADO em produção em 2026-11-13 (migração `fisc_obra_sem_avanco_trava`).
-- Limpeza feita antes (via MCP), com backup:
--   · 9 validações de obra sem avanço apagadas de fisc_linha_val (ZA1004, AL 13 F01/F02 em 03–06/10 e F04 em 06/10)
--     → backup "12 - retaguarda"._bkp_fisc_linha_val_semav_20261113;
--   · 2 dias validados que só tinham obra sem avanço (ZA1004 03/10 e 04/10) desvalidados (viram "vazio")
--     → backup "12 - retaguarda"._bkp_fisc_dia_semav_20261113.
-- Os 21 dias validados restantes não mudaram (hash do dia não depende das validações de linha).
-- Trava no servidor (vale também p/ app antigo): não valida obra sem avanço nem dia sem nada a validar.
do $mig$
declare d text; d0 text;
begin
  d0 := pg_get_functiondef('public.app_fisc_linha_validar(date,text,text,text,text)'::regprocedure);
  d := replace(d0, $a$  if v_hash is null then raise exception 'linha não encontrada neste dia'; end if;$a$,
                   $a$  if v_hash is null then raise exception 'linha não encontrada neste dia'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(d->'projetos', '[]')) x where x->>'chave' = p_chave and public.fisc_sem_avanco(x))
    then raise exception 'obra sem avanço neste dia — não precisa de validação'; end if;$a$);
  if d = d0 then raise exception 'app_fisc_linha_validar: trecho 1 não encontrado'; end if;
  execute d;

  d0 := pg_get_functiondef('public.app_fisc_dia_validar(date,text)'::regprocedure);
  d := replace(d0, $a$  if v_pend > 0 then raise exception '% linha(s) ainda sem validar', v_pend; end if;$a$,
                   $a$  if v_pend > 0 then raise exception '% linha(s) ainda sem validar', v_pend; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) x where not public.fisc_sem_avanco(x))
    then raise exception 'nada a validar neste dia (sem execuções e obras sem avanço)'; end if;$a$);
  if d = d0 then raise exception 'app_fisc_dia_validar: trecho 3 não encontrado'; end if;
  execute d;
end $mig$;
