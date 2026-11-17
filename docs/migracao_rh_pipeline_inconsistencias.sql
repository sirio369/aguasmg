-- RH · Pipeline das inconsistências + Kairos oficial quando já reflete o ajuste (2026-11-17, sw v412)
-- Roda DEPOIS de docs/migracao_rh_analise_validados.sql e docs/migracao_rh_desligamento_propaga.sql (edita as funções vigentes).
-- 1) Números: o ajuste validado só substitui o Kairos enquanto o Kairos AINDA NÃO reflete as batidas validadas
--    (tv.marcacoes <> pd.marcacoes). Quando a carga nova traz as mesmas batidas, valem os números do Kairos (informação oficial).
-- 2) Rastro: dia que teve inconsistência e tratativa, e que o Kairos já corrigiu (não acusa mais nada), continua no universo das
--    inconsistências com a situação 'corr' (Corrigida no Kairos), com os tipos guardados na tratativa (tratativa.tipos).
--    Conformidade = dias avaliados sem inconsistência EM ABERTO (a corrigida conta como conforme); o pipeline mostra quantas
--    existiam e onde cada uma está: a tratar → aguardando RH → validada (aguarda Kairos) → corrigida no Kairos.
--    Inconsistência que some sem nunca ter sido tratada não deixa rastro (não há tratativa) — fica fora do pipeline.

do $mig$ declare d text; n text;
  procedure_r text[][] := array[
    -- (1) Kairos oficial quando já reflete o ajuste
    [$xa$                                       and tv.status = 'validado' and tv.acao = 'ajustar'$xa$,
     $xb$                                       and tv.status = 'validado' and tv.acao = 'ajustar'
                                       and tv.marcacoes is distinct from pd.marcacoes   -- Kairos já reflete = vale o Kairos$xb$],
    [$xa$  ), d as (   -- ajuste validado pela RH vale sobre o Kairos, mesmo que uma carga nova tenha substituído o dia (2026-11-17)$xa$,
     $xb$  ), d as (   -- ajuste validado pela RH vale enquanto o Kairos não refletir as batidas validadas (2026-11-17)$xb$],
    -- (2) rastro das inconsistências corrigidas
    [$xa$  ), inc as (
    select i.*, fv.nome, fv.sigla, fv.area, fv.gestor,
           case when t.funcionario_id is null or t.status = 'devolvido' then 'pend' when t.status = 'validado' then 'val' else 'trat' end as st
      from "18 - rh".inconsistencias(p_ini, p_fim) i join fv on fv.id = i.funcionario_id
      left join "18 - rh".tratativa t on t.funcionario_id = i.funcionario_id and t.data = i.data
  ), inc_t as ($xa$,
     $xb$  ), incr as materialized (
    select * from "18 - rh".inconsistencias(p_ini, p_fim)
  ), inc0 as (
    select i.funcionario_id, i.data, i.tipos, i.interjornada_min,
           case when t.funcionario_id is null or t.status = 'devolvido' then 'pend' when t.status = 'validado' then 'val' else 'trat' end as st
      from incr i
      left join "18 - rh".tratativa t on t.funcionario_id = i.funcionario_id and t.data = i.data
    union all   -- rastro: dia tratado que o Kairos já corrigiu (não acusa mais) = corrigida no Kairos
    select t.funcionario_id, t.data, t.tipos, null::int, 'corr'
      from "18 - rh".tratativa t
     where t.data between p_ini and p_fim and coalesce(cardinality(t.tipos), 0) > 0
       and not exists (select 1 from incr i2 where i2.funcionario_id = t.funcionario_id and i2.data = t.data)
  ), inc as (
    select inc0.*, fv.nome, fv.sigla, fv.area, fv.gestor from inc0 join fv on fv.id = inc0.funcionario_id
  ), inc_t as ($xb$],
    [$xa$           count(*) filter (where st = 'val') val, count(*) filter (where interjornada_min is not null) interj
      from inc group by area$xa$,
     $xb$           count(*) filter (where st = 'val') val, count(*) filter (where interjornada_min is not null) interj,
           count(*) filter (where st = 'corr') corr
      from inc group by area$xb$],
    [$xa$           count(*) filter (where st = 'val'), count(*) filter (where interjornada_min is not null)
      from inc group by gestor$xa$,
     $xb$           count(*) filter (where st = 'val'), count(*) filter (where interjornada_min is not null),
           count(*) filter (where st = 'corr')
      from inc group by gestor$xb$],
    [$xa$             'val', coalesce(i.val, 0), 'interj', coalesce(i.interj, 0))$xa$,
     $xb$             'val', coalesce(i.val, 0), 'interj', coalesce(i.interj, 0), 'corr', coalesce(i.corr, 0))$xb$],
    [$xa$              'pend', (select count(*) from inc where inc.data = d.data and st = 'pend')) x$xa$,
     $xb$              'pend', (select count(*) from inc where inc.data = d.data and st = 'pend'),
              'corr', (select count(*) from inc where inc.data = d.data and st = 'corr')) x$xb$],
    [$xa$    'inc_st', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('pend', pd, 'trat', tr, 'val', vl)), '{}') from
              (select u.tipo, count(*) filter (where st = 'pend') pd, count(*) filter (where st = 'trat') tr,
                      count(*) filter (where st = 'val') vl$xa$,
     $xb$    'inc_st', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('pend', pd, 'trat', tr, 'val', vl, 'corr', cr)), '{}') from
              (select u.tipo, count(*) filter (where st = 'pend') pd, count(*) filter (where st = 'trat') tr,
                      count(*) filter (where st = 'val') vl, count(*) filter (where st = 'corr') cr$xb$],
    [$xa$              'pend', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and st = 'pend'))$xa$,
     $xb$              'pend', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and st = 'pend'),
              'corr', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and st = 'corr'))$xb$],
    [$xa$              'tratadas', count(*) filter (where st = 'trat'), 'validadas', count(*) filter (where st = 'val')) from inc)$xa$,
     $xb$              'tratadas', count(*) filter (where st = 'trat'), 'validadas', count(*) filter (where st = 'val'),
              'corrigidas', count(*) filter (where st = 'corr')) from inc)$xb$]
  ];
  i int;
begin
  -- Análise
  d := pg_get_functiondef('public.app_rh_analise(date,date,text,text,bigint)'::regprocedure); n := d;
  for i in 1 .. array_length(procedure_r, 1) loop
    if position(procedure_r[i][1] in n) = 0 then raise exception 'trecho % não encontrado na app_rh_analise', i; end if;
    n := replace(n, procedure_r[i][1], procedure_r[i][2]);
  end loop;
  execute n;
  -- Validação: o dia corrigido continua na lista (aba Validados / Todas inconsistências) marcado como corrigido no Kairos
  d := pg_get_functiondef('public.app_rh_val_lista(date,date,boolean)'::regprocedure); n := d;
  n := replace(n, $xa$'inc', i.funcionario_id is not null, 'tipos', coalesce(i.tipos, '{}'::text[]),$xa$,
                  $xb$'inc', i.funcionario_id is not null or coalesce(cardinality(t.tipos), 0) > 0,
      'corrigido', i.funcionario_id is null and coalesce(cardinality(t.tipos), 0) > 0, 'tipos', coalesce(i.tipos, t.tipos, '{}'::text[]),$xb$);
  n := replace(n, $xa$and (coalesce(p_todos, false) or i.funcionario_id is not null)),$xa$,
                  $xb$and (coalesce(p_todos, false) or i.funcionario_id is not null or coalesce(cardinality(t.tipos), 0) > 0)),$xb$);
  if n = d or position('corrigido' in n) = 0 or position('or coalesce(cardinality(t.tipos), 0) > 0)),' in n) = 0 then
    raise exception 'replace da app_rh_val_lista falhou'; end if;
  execute n;
end $mig$;

-- Correção (aplicada 17/11/2026): calc_marcacoes(horário, NULL) devolve "dia sem batida" e não NULL — sem este case, todo dia SEM
-- ajuste validado virava "ajustado" com H.trab 0 / falta = previsto na Análise.
do $mig$ declare d text; n text;
begin
  d := pg_get_functiondef('public.app_rh_analise(date,date,text,text,bigint)'::regprocedure);
  n := replace(d, $xa$tv.marcacoes as marc_val, "18 - rh".calc_marcacoes(pd.horario, tv.marcacoes) as cv$xa$,
                  $xb$tv.marcacoes as marc_val,
           case when tv.funcionario_id is not null then "18 - rh".calc_marcacoes(pd.horario, tv.marcacoes) end as cv$xb$);
  if n = d then raise exception 'replace falhou'; end if;
  execute n;
end $mig$;
