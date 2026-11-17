-- RH · Validação gestor: cálculo do dia com as marcações ajustadas (2026-11-17)
-- Quando o gestor AJUSTA as batidas e a RH VALIDA, a tela passa a mostrar as batidas ajustadas e o H.trab / HE / Falta / Atraso
-- recalculados com elas (o Kairos só é corrigido depois, na próxima carga). Regra calibrada contra o Kairos 2.130 da AI:
--   · H.trab = soma dos pares entrada→saída (saída < entrada = virou o dia, +24h).
--   · Previsto = intervalos do texto de horário ("07:00 - 12:00 | 13:00 - 17:00"); dentro = sobreposição trabalhado × previsto.
--   · HE = trabalhado fora do previsto; Atraso = previsto não trabalhado (entrada tarde, saída cedo, almoço estourado).
--   · Tolerância (CLT art. 58 §1º): até 5 min por marcação e 10 min no dia, separada para HE e para atraso; passou de um dos dois,
--     conta tudo. Quando o nº de pares difere do nº de intervalos previstos, vale só o limite de 10 min no dia.
--   · Falta = previsto inteiro quando não há batida; com batida, o que faltou vira atraso (como o Kairos).
--   · Dia sem horário previsto (descanso/folga): todo o trabalhado é HE.
create or replace function "18 - rh".calc_marcacoes(p_horario text, p_marc text[])
 returns jsonb language plpgsql immutable
 set search_path to 'pg_catalog'
as $function$
declare s int[] := '{}'; e int[] := '{}'; mi int[] := '{}'; mo int[] := '{}'; m text[];
        n int; k int; i int; j int; v_in int; v_out int; htrab int := 0; prev int := 0; dentro int := 0;
        he_raw int; at_raw int; he_mx int := 0; at_mx int := 0; he int; at int;
begin
  for m in select regexp_matches(coalesce(p_horario, ''), '(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})', 'g') loop
    s := s || "18 - rh".hm(m[1]); e := e || "18 - rh".hm(m[2]);
    if e[cardinality(e)] < s[cardinality(s)] then e[cardinality(e)] := e[cardinality(e)] + 1440; end if;
    prev := prev + e[cardinality(e)] - s[cardinality(s)];
  end loop;
  n := coalesce(cardinality(p_marc), 0);
  if n = 0 then return jsonb_build_object('htrab', 0, 'he', 0, 'atraso', 0, 'falta', prev, 'prev', prev); end if;
  if n % 2 = 1 then return null; end if;
  for i in 1 .. n / 2 loop
    v_in := "18 - rh".hm(p_marc[2*i-1]); v_out := "18 - rh".hm(p_marc[2*i]);
    if v_in is null or v_out is null then return null; end if;
    if cardinality(mo) > 0 and v_in < mo[cardinality(mo)] then v_in := v_in + 1440; end if;
    if v_out < v_in then v_out := v_out + 1440; end if;
    mi := mi || v_in; mo := mo || v_out; htrab := htrab + v_out - v_in;
  end loop;
  k := coalesce(cardinality(s), 0);
  for i in 1 .. n / 2 loop
    for j in 1 .. k loop
      dentro := dentro + greatest(0, least(mo[i], e[j]) - greatest(mi[i], s[j]));
    end loop;
  end loop;
  he_raw := htrab - dentro; at_raw := prev - dentro;
  if k = n / 2 then   -- par a par: maior desvio de uma marcação, para a tolerância de 5 min
    for i in 1 .. k loop
      he_mx := greatest(he_mx, s[i] - mi[i], mo[i] - e[i]);
      at_mx := greatest(at_mx, mi[i] - s[i], e[i] - mo[i]);
    end loop;
  else he_mx := 99; at_mx := 99; end if;
  he := case when k = 0 then htrab when he_raw > 10 or (he_raw > 0 and he_mx > 5) then he_raw else 0 end;
  at := case when k = 0 then 0 when at_raw > 10 or (at_raw > 0 and at_mx > 5) then at_raw else 0 end;
  return jsonb_build_object('htrab', htrab, 'he', he, 'atraso', at, 'falta', 0, 'prev', prev);
end $function$;
revoke all on function "18 - rh".calc_marcacoes(text, text[]) from public, anon;

-- app_rh_val_lista: a tratativa de AJUSTE devolve 'calc' = H.trab/HE/Atraso/Falta calculados com as marcações do gestor
-- (a tela usa depois que a RH valida; quando o Kairos já reflete o ajuste, ela mostra os números do próprio Kairos).
create or replace function public.app_rh_val_lista(p_ini date, p_fim date, p_todos boolean default false)
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
        'calc', case when t.acao = 'ajustar' then "18 - rh".calc_marcacoes(pd.horario, t.marcacoes) end,
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
