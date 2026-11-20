-- RH · Análise do ponto — base dia a dia p/ HE por tipo, DSR e conformidade CLT (2026-11-20)
-- Só ACRESCENTA (nenhuma função existente muda): "18 - rh".marc_info + public.app_rh_ponto_dias.
-- A aba ⏱️ Horas passa a calcular tudo no navegador a partir destas linhas (filtros cruzados instantâneos).
--
-- Regras (cada dia, por colaborador):
--   tipo do dia (td): F = Feriado · D = DSR (Descanso Semanal no domingo ou com dsr_min > 0)
--                     S = "Descanso Semanal" sem DSR (sábado da semana compensada) · C = "Compensado" · U = dia útil
--   HE 100% = HE em D/S/F · HE 60% = HE em U/C — é a regra do Kairos: bate 100% com o resumo dos relatórios 01–17/11
--   (AI 100% = 6.527 min, 60% + noturna 60% = 34.329; EH 100% = 2.710, 60% = 38.341). Mínimo legal: 50% (CF art. 7º XVI)
--   e 100% em domingo/feriado não compensado (Lei 605/49 art. 9º; Súmula 146 TST).
--   noturno = minutos trabalhados entre 22h e 5h (CLT art. 73 §2º), das batidas; HE noturna = menor entre noturno e HE
--   intervalo = soma dos vãos entre os pares de batidas (art. 71) · interjornada = saída do dia anterior → entrada (art. 66)
--   seq = dias trabalhados seguidos até este (art. 67 + OJ 410 SDI-1: 7º dia seguido sem folga = DSR não concedido)
--   ds = descanso (min) desde a última saída quando houve ao menos 1 dia inteiro sem trabalho no meio (Súmula 110: ≥ 35h)
-- Dia com ajuste validado pela RH usa as batidas do gestor enquanto o Kairos não refletir (mesma regra da app_rh_analise).

create or replace function "18 - rh".marc_info(p_marc text[])
returns jsonb language plpgsql immutable set search_path to 'pg_catalog' as $xa$
declare n int := coalesce(cardinality(p_marc), 0); i int; a int; b int; ult int := null; ini int; itv int := 0; itv_mx int := 0; nt int := 0; k int;
begin
  if n < 2 or n % 2 = 1 then return null; end if;
  for i in 1 .. n / 2 loop
    a := "18 - rh".hm(p_marc[2*i-1]); b := "18 - rh".hm(p_marc[2*i]);
    if a is null or b is null then return null; end if;
    if ult is not null and a < ult then a := a + 1440; end if;
    if b < a then b := b + 1440; end if;
    if ult is null then ini := a; else itv := itv + (a - ult); itv_mx := greatest(itv_mx, a - ult); end if;
    -- janelas noturnas 22h–5h: [k*1440-120, k*1440+300] para k = 0, 1, 2
    for k in 0 .. 2 loop
      nt := nt + greatest(0, least(b, k*1440 + 300) - greatest(a, k*1440 - 120));
    end loop;
    ult := b;
  end loop;
  return jsonb_build_object('ini', ini, 'fim', ult, 'itv', itv, 'itv_mx', itv_mx, 'pares', n / 2, 'not', nt);
end $xa$;

create or replace function public.app_rh_ponto_dias(p_ini date, p_fim date, p_consorcio text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public', '18 - rh' as $xb$
declare v_uid uuid := auth.uid(); r jsonb;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  if not public.rh_tela(v_uid, 'analise') then raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 366 then raise exception 'período inválido (máx. 1 ano)'; end if;
  with fv as (
    select f.id, f.nome, e.sigla, e.consorcio,
           coalesce(nullif(trim(p.area), ''), 'Sem área') as area,
           coalesce(g1.nome, g1.email, g2.nome, g2.email, 'Sem gestor no app') as gestor
      from "18 - rh".funcionario f
      join "18 - rh".empresa e on e.cnpj = f.cnpj
      left join public.perfil p  on p.id  = f.perfil_id
      left join public.perfil g1 on g1.id = p.aprovador_uuid
      left join public.perfil g2 on g2.id = p.aprovador2_uuid
     where p_consorcio is null or e.consorcio = p_consorcio
  ), d0 as (   -- 13 dias antes do início só para a sequência de dias trabalhados e o descanso
    select pd.*, "18 - rh".prev_min(pd.horario) as prev,
           case when tv.funcionario_id is not null then tv.marcacoes end as marc_val,
           case when tv.funcionario_id is not null then "18 - rh".calc_marcacoes(pd.horario, tv.marcacoes) end as cv
      from "18 - rh".ponto_dia pd join fv on fv.id = pd.funcionario_id
      left join "18 - rh".tratativa tv on tv.funcionario_id = pd.funcionario_id and tv.data = pd.data
                                       and tv.status = 'validado' and tv.acao = 'ajustar'
                                       and tv.marcacoes is distinct from pd.marcacoes
     where pd.data between p_ini - 13 and p_fim
  ), d1 as (
    select funcionario_id, data, dia_semana, horario, parcial, dsr_min, prev, justificativa,
           cv is not null as validado,
           case when cv is not null then marc_val else marcacoes end as marc,
           coalesce(case when cv is not null then (cv->>'htrab')::int  else htrab_min  end, 0) as htrab,
           coalesce(case when cv is not null then (cv->>'he')::int     else he_min     end, 0) as he,
           coalesce(case when cv is not null then (cv->>'atraso')::int else atraso_min end, 0) as atraso,
           coalesce(case when cv is not null then (cv->>'falta')::int  else falta_min  end, 0) as falta,
           case when horario ilike 'feriado%' then 'F'
                when horario ilike 'descanso%' and (coalesce(dsr_min, 0) > 0 or dia_semana = 'dom') then 'D'
                when horario ilike 'descanso%' then 'S'
                when horario ilike 'compensado%' then 'C'
                else 'U' end as td
      from d0
  ), d2 as (
    select d1.*, "18 - rh".marc_info(d1.marc) as mi from d1
  ), d3 as (   -- dias trabalhados: sequência (ilhas de datas seguidas) e vão desde a última saída
    select d2.*, (mi is not null) as trab,
           data - (row_number() over (partition by funcionario_id, (mi is not null) order by data))::int as ilha
      from d2
  ), d4 as (
    select d3.*,
           case when trab then count(*) over (partition by funcionario_id, trab, ilha order by data) end as seq
      from d3
  ), dt as (   -- saída do último dia trabalhado anterior (só entre dias trabalhados)
    select funcionario_id, data, (mi->>'ini')::int as ini,
           lag(data) over w as d_ant, lag((mi->>'fim')::int) over w as fim_ant
      from d4 where trab window w as (partition by funcionario_id order by data)
  ), dd as (
    select d4.*, dt.d_ant, dt.fim_ant, dt.ini,
           case when dt.d_ant is not null then (d4.data - dt.d_ant) * 1440 - dt.fim_ant + dt.ini end as vao
      from d4 left join dt on dt.funcionario_id = d4.funcionario_id and dt.data = d4.data
  )
  select jsonb_build_object(
    'cols', jsonb_build_array('f','d','td','pv','ht','he','fa','at','pc','vl','tb','mi','nt','itv','pr','ij','seq','ds','js'),
    'funcs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'sigla', sigla, 'cons', consorcio, 'area', area, 'gestor', gestor) order by nome), '[]')
                from fv where exists (select 1 from "18 - rh".ponto_dia pd where pd.funcionario_id = fv.id and pd.data between p_ini and p_fim)),
    'dias', (select coalesce(jsonb_agg(jsonb_build_array(
                funcionario_id, data, td, prev, htrab, he, falta, atraso, case when parcial then 1 else 0 end, case when validado then 1 else 0 end,
                case when trab then 1 else 0 end, case when coalesce(cardinality(marc), 0) % 2 = 1 then 1 else 0 end,
                coalesce((mi->>'not')::int, 0), (mi->>'itv')::int, (mi->>'pares')::int,
                case when d_ant = data - 1 then vao end,            -- interjornada (dia seguido)
                seq,
                case when d_ant < data - 1 then vao end,            -- descanso que abrange ≥ 1 dia inteiro (DSR)
                case when nullif(trim(justificativa), '') is not null then 1 else 0 end
              ) order by funcionario_id, data), '[]') from dd where data between p_ini and p_fim),
    -- como o Kairos classificou a HE no resumo de cada relatório (para conferir o percentual aplicado)
    'kairos_he', (select coalesce(jsonb_agg(jsonb_build_object('sigla', s.sigla, 'ini', s.periodo_ini, 'fim', s.periodo_fim, 'tipo', s.tipo, 'min', s.m, 'pessoas', s.p)
                    order by s.sigla, s.periodo_ini, s.periodo_fim, s.tipo), '[]') from (
                    select e.sigla, a.periodo_ini, a.periodo_fim, initcap(lower(x->>'tipo')) tipo, sum((x->>'min')::int) m, count(distinct rs.funcionario_id) p
                      from "18 - rh".ponto_resumo rs
                      join "18 - rh".arquivo a on a.id = rs.arquivo_id and a.status = 'ok'
                      join "18 - rh".empresa e on e.cnpj = a.cnpj
                      cross join lateral jsonb_array_elements(rs.he_percentual) x
                     where a.periodo_fim >= p_ini and a.periodo_ini <= p_fim and (p_consorcio is null or e.consorcio = p_consorcio)
                     group by 1, 2, 3, 4) s)
  ) into r;
  return r;
end $xb$;

revoke all on function public.app_rh_ponto_dias(date, date, text) from public, anon;
grant execute on function public.app_rh_ponto_dias(date, date, text) to authenticated;
