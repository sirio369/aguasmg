-- =====================================================================
-- RH — Análise do ponto por área (filtro de área + indicadores estratégicos)
-- Recria public.app_rh_analise com p_area e novos agregados:
--   areas (lista do filtro), por_area, por_gestor, kpi (absenteísmo, % HE, pontualidade,
--   taxa de inconsistência, % não tratada), func com área/gestor/pendências.
-- Área = public.perfil.area do colaborador (funcionario.perfil_id); sem perfil/área = 'Sem área'.
-- Mantém todas as saídas anteriores (a tela antiga continua funcionando).
-- =====================================================================

-- Minutos previstos do dia a partir do texto de horário do Kairos
-- '07:00 - 12:00 | 13:00 - 17:00' → 540; 'Descanso Semanal' / 'Compensado' / 'Feriado' → 0
create or replace function "18 - rh".prev_min(p_horario text)
returns int language sql immutable set search_path = pg_catalog as $$
  select coalesce(sum(
           (split_part(m[2], ':', 1)::int * 60 + split_part(m[2], ':', 2)::int)
         - (split_part(m[1], ':', 1)::int * 60 + split_part(m[1], ':', 2)::int)), 0)::int
    from regexp_matches(coalesce(p_horario, ''), '(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})', 'g') as m;
$$;
revoke all on function "18 - rh".prev_min(text) from public, anon, authenticated;

drop function if exists public.app_rh_analise(date, date, text);

create or replace function public.app_rh_analise(p_ini date, p_fim date, p_consorcio text default null, p_area text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public', '18 - rh' as $$
declare v_uid uuid := auth.uid(); r jsonb;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  if not public.rh_pode_carregar(v_uid) and not exists(select 1 from public.perfil where id = v_uid and funcao in ('aprovador','admin')) then
    raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 366 then raise exception 'período inválido (máx. 1 ano)'; end if;
  with fv0 as (
    select f.id, f.nome, e.sigla, e.consorcio,
           coalesce(nullif(trim(p.area), ''), 'Sem área') as area,
           coalesce(g1.nome, g1.email, g2.nome, g2.email, 'Sem gestor no app') as gestor
      from func_visiveis(v_uid) x
      join "18 - rh".funcionario f on f.id = x.funcionario_id
      join "18 - rh".empresa e on e.cnpj = f.cnpj
      left join public.perfil p  on p.id  = f.perfil_id
      left join public.perfil g1 on g1.id = p.aprovador_uuid
      left join public.perfil g2 on g2.id = p.aprovador2_uuid
     where p_consorcio is null or e.consorcio = p_consorcio
  ), fv as (
    select * from fv0 where p_area is null or area = p_area
  ), d as (
    select pd.*, fv.nome, fv.sigla, fv.consorcio, fv.area, fv.gestor, "18 - rh".prev_min(pd.horario) as prev
      from "18 - rh".ponto_dia pd join fv on fv.id = pd.funcionario_id
     where pd.data between p_ini and p_fim
  ), inc as (
    select i.*, fv.nome, fv.sigla, fv.area, fv.gestor,
           case when t.funcionario_id is null or t.status = 'devolvido' then 'pend' when t.status = 'validado' then 'val' else 'trat' end as st
      from "18 - rh".inconsistencias(p_ini, p_fim) i join fv on fv.id = i.funcionario_id
      left join "18 - rh".tratativa t on t.funcionario_id = i.funcionario_id and t.data = i.data
  ), inc_t as (
    select unnest(tipos) tipo, funcionario_id from inc
  ), func as (
    select d.funcionario_id, min(d.nome) nome, min(d.sigla) sigla, min(d.area) area, min(d.gestor) gestor,
           sum(coalesce(d.he_min, 0)) he, sum(d.falta_min) falta, count(*) filter (where d.falta_min > 0) dias_falta,
           sum(d.atraso_min) atraso, count(*) filter (where coalesce(d.he_min, 0) > 120) dias_he2,
           sum(coalesce(d.htrab_min, 0)) htrab, count(*) filter (where cardinality(d.marcacoes) > 0) dias_trab,
           sum(d.prev) filter (where not d.parcial) prev
      from d group by d.funcionario_id
  ), agg as (   -- uma linha por grupo (área / gestor) com os mesmos indicadores
    select 'area' k, area g, count(distinct funcionario_id) funcionarios,
           sum(prev) filter (where not parcial) prev, sum(coalesce(htrab_min, 0)) htrab, sum(coalesce(he_min, 0)) he,
           sum(falta_min) filter (where not parcial) falta, sum(atraso_min) atraso,
           count(*) filter (where atraso_min > 0) n_atrasos,
           count(*) filter (where cardinality(marcacoes) > 0 and prev > 0) dias_prev_trab,
           count(*) filter (where not parcial) dias_aval, count(*) filter (where coalesce(he_min, 0) > 120) dias_he2
      from d group by area
    union all
    select 'gestor', gestor, count(distinct funcionario_id), sum(prev) filter (where not parcial), sum(coalesce(htrab_min, 0)),
           sum(coalesce(he_min, 0)), sum(falta_min) filter (where not parcial), sum(atraso_min), count(*) filter (where atraso_min > 0),
           count(*) filter (where cardinality(marcacoes) > 0 and prev > 0), count(*) filter (where not parcial),
           count(*) filter (where coalesce(he_min, 0) > 120)
      from d group by gestor
  ), agg_inc as (
    select 'area' k, area g, count(*) dias_inc, count(*) filter (where st = 'pend') pend, count(*) filter (where st = 'trat') trat,
           count(*) filter (where st = 'val') val, count(*) filter (where interjornada_min is not null) interj
      from inc group by area
    union all
    select 'gestor', gestor, count(*), count(*) filter (where st = 'pend'), count(*) filter (where st = 'trat'),
           count(*) filter (where st = 'val'), count(*) filter (where interjornada_min is not null)
      from inc group by gestor
  ), grp as (
    select a.k, jsonb_agg(jsonb_build_object('nome', a.g, 'funcionarios', a.funcionarios, 'prev', coalesce(a.prev, 0),
             'htrab', a.htrab, 'he', a.he, 'falta', coalesce(a.falta, 0), 'atraso', a.atraso, 'n_atrasos', a.n_atrasos,
             'dias_prev_trab', a.dias_prev_trab, 'dias_aval', a.dias_aval, 'dias_he2', a.dias_he2,
             'dias_inc', coalesce(i.dias_inc, 0), 'pend', coalesce(i.pend, 0), 'trat', coalesce(i.trat, 0),
             'val', coalesce(i.val, 0), 'interj', coalesce(i.interj, 0))
             order by coalesce(i.pend, 0) desc, a.g) j
      from agg a left join agg_inc i on i.k = a.k and i.g = a.g
     group by a.k
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('ini', p_ini, 'fim', p_fim, 'data_min', (select min(data) from d), 'data_max', (select max(data) from d),
                                  'parciais', (select count(*) from d where parcial)),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('nome', area, 'n', n) order by area = 'Sem área', area), '[]')
                from (select area, count(*) n from fv0 group by area) s),
    'tot', (select jsonb_build_object('funcionarios', count(distinct funcionario_id),
              'dias_trab', count(*) filter (where cardinality(marcacoes) > 0),
              'htrab', sum(coalesce(htrab_min, 0)), 'he', sum(coalesce(he_min, 0)), 'adn', sum(coalesce(adn_min, 0)),
              'falta_min', sum(falta_min), 'dias_falta', count(*) filter (where falta_min > 0),
              'atraso_min', sum(atraso_min), 'n_atrasos', count(*) filter (where atraso_min > 0),
              'dsr', count(*) filter (where dsr_min > 0),
              'prev', coalesce(sum(prev) filter (where not parcial), 0),
              'falta_aval', coalesce(sum(falta_min) filter (where not parcial), 0),
              'dias_prev_trab', count(*) filter (where cardinality(marcacoes) > 0 and prev > 0),
              'dias_aval', count(*) filter (where not parcial),
              'dias_he2', count(*) filter (where coalesce(he_min, 0) > 120)) from d),
    'por_area',   coalesce((select j from grp where k = 'area'), '[]'),
    'por_gestor', coalesce((select j from grp where k = 'gestor'), '[]'),
    'por_empresa', (select coalesce(jsonb_agg(x order by x->>'sigla'), '[]') from (select jsonb_build_object('sigla', sigla, 'consorcio', consorcio,
              'funcionarios', count(distinct funcionario_id), 'he', sum(coalesce(he_min, 0)), 'htrab', sum(coalesce(htrab_min, 0)),
              'falta_min', sum(falta_min), 'dias_falta', count(*) filter (where falta_min > 0), 'atraso_min', sum(atraso_min)) x
              from d group by sigla, consorcio) s),
    'por_dia', (select coalesce(jsonb_agg(x order by x->>'data'), '[]') from (select jsonb_build_object('data', d.data,
              'he', sum(coalesce(he_min, 0)), 'falta_min', sum(falta_min), 'presentes', count(*) filter (where cardinality(marcacoes) > 0),
              'inc', (select count(*) from inc where inc.data = d.data),
              'pend', (select count(*) from inc where inc.data = d.data and st = 'pend')) x
              from d group by d.data) s),
    'inc', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('casos', n, 'pessoas', p)), '{}') from
              (select tipo, count(*) n, count(distinct funcionario_id) p from inc_t group by tipo) s),
    'inc_st', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('pend', pd, 'trat', tr, 'val', vl)), '{}') from
              (select u.tipo, count(*) filter (where st = 'pend') pd, count(*) filter (where st = 'trat') tr,
                      count(*) filter (where st = 'val') vl
                 from inc, unnest(inc.tipos) u(tipo) group by u.tipo) s),
    'interjornada', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'sigla', sigla, 'area', area, 'data', data, 'descanso', interjornada_min)
              order by interjornada_min), '[]') from inc where interjornada_min is not null),
    'func', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'sigla', sigla, 'area', area, 'gestor', gestor,
              'he', he, 'falta', falta, 'dias_falta', dias_falta, 'atraso', atraso, 'dias_he2', dias_he2, 'htrab', htrab,
              'dias_trab', dias_trab, 'prev', coalesce(prev, 0),
              'interj', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and interjornada_min is not null),
              'dias_inc', (select count(*) from inc where inc.funcionario_id = func.funcionario_id),
              'pend', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and st = 'pend'))
              order by he desc), '[]') from func),
    'tratativas', (select jsonb_build_object('pendentes', count(*) filter (where st = 'pend'),
              'tratadas', count(*) filter (where st = 'trat'), 'validadas', count(*) filter (where st = 'val')) from inc)
  ) into r;
  return r;
end $$;

revoke all on function public.app_rh_analise(date, date, text, text) from public, anon;
grant execute on function public.app_rh_analise(date, date, text, text) to authenticated;
