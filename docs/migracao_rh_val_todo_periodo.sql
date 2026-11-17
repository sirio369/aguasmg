-- RH · Validação gestor "Todo o período" + Análise do ponto com filtro de colaborador e visão de todas as áreas (2026-11-17)
-- 1) app_rh_val_lista ganha p_todos (default false = comportamento antigo, compatível com a v409):
--    true devolve TODOS os dias de ponto dos colaboradores visíveis, com 'inc' = tem inconsistência.
-- 2) app_rh_analise ganha p_funcionario (filtra uma pessoa) e devolve 'funcs' (lista p/ o filtro).
--    A Análise passa a mostrar TODOS os colaboradores a quem tem a tela 'analise' (não só a equipe do gestor).
-- Assinaturas novas só acrescentam parâmetro com default → drop + create (regra §0.6), chamadas antigas seguem funcionando.

drop function if exists public.app_rh_val_lista(date, date);
create function public.app_rh_val_lista(p_ini date, p_fim date, p_todos boolean default false)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public', '18 - rh'
as $function$
declare v_uid uuid := auth.uid(); v_rh boolean;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  v_rh := public.rh_pode_carregar(v_uid);
  if not public.rh_tela(v_uid, 'val') then raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 92 then raise exception 'período inválido (máx. 3 meses)'; end if;
  return jsonb_build_object('rh', v_rh, 'todos', coalesce(p_todos, false), 'itens', coalesce((select jsonb_agg(jsonb_build_object(
      'fid', f.id, 'nome', f.nome, 'matricula', f.matricula, 'sigla', e.sigla, 'consorcio', e.consorcio,
      'gestor', coalesce(g1.nome, g1.email), 'gestor2', coalesce(g2.nome, g2.email), 'sem_usuario', f.perfil_id is null,
      'data', pd.data, 'inc', i.funcionario_id is not null, 'tipos', coalesce(i.tipos, '{}'::text[]), 'interjornada_min', i.interjornada_min,
      'dia_semana', pd.dia_semana, 'horario', pd.horario, 'marcacoes', pd.marcacoes, 'htrab', pd.htrab_min, 'he', pd.he_min,
      'falta', pd.falta_min, 'atraso', pd.atraso_min, 'justificativa', pd.justificativa, 'versao', pd.versao, 'parcial', pd.parcial,
      'trat', case when t.funcionario_id is null then null else jsonb_build_object(
        'acao', t.acao, 'marcacoes', t.marcacoes, 'motivo', t.motivo, 'obs', t.obs, 'status', t.status,
        'gestor', coalesce(pg.nome, pg.email), 'gestor_em', t.gestor_em, 'versao_dia', t.versao_dia,
        'rh', coalesce(pr.nome, pr.email), 'rh_em', t.rh_em, 'rh_obs', t.rh_obs,
        'kairos_atualizado', pd.versao > coalesce(t.versao_dia, pd.versao),
        'kairos_bate', case t.acao when 'ajustar' then pd.marcacoes = t.marcacoes
                                    when 'falta' then pd.falta_min > 0
                                    when 'justificar' then case when t.tipos && array['falta','falta_pos_deslig'] then pd.falta_min = 0 end
                                    else null end) end)
      order by f.nome, pd.data)
    from "18 - rh".ponto_dia pd
    join func_visiveis(v_uid) fv on fv.funcionario_id = pd.funcionario_id
    join "18 - rh".funcionario f on f.id = pd.funcionario_id
    join "18 - rh".empresa e on e.cnpj = f.cnpj
    left join "18 - rh".inconsistencias(p_ini, p_fim) i on i.funcionario_id = pd.funcionario_id and i.data = pd.data
    left join public.perfil p on p.id = f.perfil_id
    left join public.perfil g1 on g1.id = p.aprovador_uuid
    left join public.perfil g2 on g2.id = p.aprovador2_uuid
    left join "18 - rh".tratativa t on t.funcionario_id = pd.funcionario_id and t.data = pd.data
    left join public.perfil pg on pg.id = t.gestor_uuid
    left join public.perfil pr on pr.id = t.rh_uuid
   where pd.data between p_ini and p_fim
     and (coalesce(p_todos, false) or i.funcionario_id is not null)), '[]'::jsonb));
end $function$;
revoke all on function public.app_rh_val_lista(date, date, boolean) from public, anon;
grant execute on function public.app_rh_val_lista(date, date, boolean) to authenticated;

drop function if exists public.app_rh_analise(date, date, text, text);
create function public.app_rh_analise(p_ini date, p_fim date, p_consorcio text default null, p_area text default null, p_funcionario bigint default null)
 returns jsonb language plpgsql stable security definer
 set search_path to 'public', '18 - rh'
as $function$
declare v_uid uuid := auth.uid(); r jsonb;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  if not public.rh_tela(v_uid, 'analise') then raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 366 then raise exception 'período inválido (máx. 1 ano)'; end if;
  -- todos os colaboradores (2026-11-17: quem tem a tela vê todas as áreas, não só a própria equipe)
  with fv0 as (
    select f.id, f.nome, e.sigla, e.consorcio,
           coalesce(nullif(trim(p.area), ''), 'Sem área') as area,
           coalesce(g1.nome, g1.email, g2.nome, g2.email, 'Sem gestor no app') as gestor
      from "18 - rh".funcionario f
      join "18 - rh".empresa e on e.cnpj = f.cnpj
      left join public.perfil p  on p.id  = f.perfil_id
      left join public.perfil g1 on g1.id = p.aprovador_uuid
      left join public.perfil g2 on g2.id = p.aprovador2_uuid
     where p_consorcio is null or e.consorcio = p_consorcio
  ), fv1 as (
    select * from fv0 where p_area is null or area = p_area
  ), fv as (
    select * from fv1 where p_funcionario is null or id = p_funcionario
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
    -- lista do filtro de colaborador: quem tem ponto no período (respeita consórcio e área, não o próprio filtro)
    'funcs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'sigla', sigla) order by nome), '[]')
                from fv1 where exists (select 1 from "18 - rh".ponto_dia pd where pd.funcionario_id = fv1.id and pd.data between p_ini and p_fim)),
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
    'func', (select coalesce(jsonb_agg(jsonb_build_object('fid', funcionario_id, 'nome', nome, 'sigla', sigla, 'area', area, 'gestor', gestor,
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
end $function$;
revoke all on function public.app_rh_analise(date, date, text, text, bigint) from public, anon;
grant execute on function public.app_rh_analise(date, date, text, text, bigint) to authenticated;
