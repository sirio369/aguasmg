-- RH › Validação gestor + Análise do ponto (2026-11-13) — depende de docs/migracao_rh_ponto_carga.sql.
-- Inconsistências = calculadas na hora a partir de "18 - rh".ponto_dia (nada é gravado até alguém tratar):
--   marc_impar        nº ímpar de marcações (falta batida de entrada/saída)
--   sem_intervalo     só entrada e saída num dia de mais de 6 h (almoço não registrado / não descontado)
--   falta             desconto de falta no dia (sem justificativa no Kairos)
--   falta_pos_deslig  falta lançada depois do dia do desligamento
--   atraso            atraso ≥ 15 min no dia
--   he_excesso        hora extra > 2 h no dia
--   interjornada      descanso < 11 h entre a última batida da véspera e a primeira do dia
--   trab_descanso     marcação em dia de descanso semanal
-- Dia "parcial" (relatório tirado no meio do expediente) não entra.
-- Tratativa do GESTOR (Aprovador 1/2 do colaborador no AcquaHub; RH/admin tratam qualquer um), 1 por funcionário × dia:
--   ajustar    = informa as marcações corretas (entrada/saída) para a RH lançar no Kairos
--   falta      = confirma que o colaborador faltou / não trabalhou
--   justificar = teve um problema (atestado, esquecimento de batida, serviço externo…) — motivo + observação
--   ok         = está correto como está (ex.: hora extra autorizada)
--   → status 'tratado' (fica marcado). A RH corrige no Kairos e faz a 2ª validação: 'validado' ou 'devolvido' (volta ao gestor).
--   Quando um relatório novo muda o dia (versao sobe), a tela mostra "Kairos atualizado" e se as marcações batem com o ajuste.
-- Histórico append-only em tratativa_evento.

create table if not exists "18 - rh".tratativa (
  funcionario_id bigint not null references "18 - rh".funcionario(id) on delete cascade,
  data           date   not null,
  tipos          text[] not null default '{}',     -- inconsistências do dia no momento da tratativa
  acao           text   not null check (acao in ('ajustar','falta','justificar','ok')),
  marcacoes      text[],                            -- só em 'ajustar'
  motivo         text,
  obs            text,
  versao_dia     int,                               -- versão do ponto_dia quando o gestor tratou
  status         text   not null default 'tratado' check (status in ('tratado','validado','devolvido')),
  gestor_uuid    uuid   not null,
  gestor_em      timestamptz not null default now(),
  rh_uuid        uuid,
  rh_em          timestamptz,
  rh_obs         text,
  primary key (funcionario_id, data)
);
create table if not exists "18 - rh".tratativa_evento (
  id             bigserial primary key,
  funcionario_id bigint not null,
  data           date   not null,
  evento         text   not null,                  -- tratado | validado | devolvido
  dados          jsonb  not null default '{}',
  por            uuid,
  em             timestamptz not null default now()
);
create index if not exists rh_trat_ev_idx on "18 - rh".tratativa_evento (funcionario_id, data);
alter table "18 - rh".tratativa        enable row level security;
alter table "18 - rh".tratativa_evento enable row level security;
revoke all on "18 - rh".tratativa, "18 - rh".tratativa_evento from public, anon, authenticated;
revoke all on sequence "18 - rh".tratativa_evento_id_seq from public, anon, authenticated;

-- 'HH:MM' → minutos
create or replace function "18 - rh".hm(t text)
returns int language sql immutable set search_path = pg_catalog as $$
  select case when t ~ '^\d{1,2}:\d{2}$' then split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int end;
$$;

-- Funcionários que o usuário enxerga: RH/admin = todos; aprovador = quem o tem como Aprovador 1/2 (pelo perfil casado no CPF)
create or replace function "18 - rh".func_visiveis(p_uid uuid)
returns table (funcionario_id bigint) language sql stable security definer set search_path = public, "18 - rh" as $$
  select f.id from "18 - rh".funcionario f
   where public.rh_pode_carregar(p_uid)
      or exists (select 1 from public.perfil p where p.id = f.perfil_id and p_uid in (p.aprovador_uuid, p.aprovador2_uuid));
$$;
revoke all on function "18 - rh".func_visiveis(uuid) from public, anon, authenticated;

-- Inconsistências por funcionário × dia no período (não-parciais), para um conjunto de funcionários
create or replace function "18 - rh".inconsistencias(p_ini date, p_fim date)
returns table (funcionario_id bigint, data date, tipos text[], interjornada_min int)
language sql stable set search_path = public, "18 - rh" as $$
  with d as (
    select pd.*, cardinality(pd.marcacoes) as nm,
           hm(pd.marcacoes[1]) as ent, hm(pd.marcacoes[cardinality(pd.marcacoes)]) as sai,
           lag(pd.data) over w as d_ant,
           lag(hm(pd.marcacoes[cardinality(pd.marcacoes)])) over w as sai_ant,
           lag(cardinality(pd.marcacoes)) over w as nm_ant,
           (select min(x.data) from "18 - rh".ponto_dia x where x.funcionario_id = pd.funcionario_id
              and x.justificativa ilike '%deslig%') as dt_deslig
      from "18 - rh".ponto_dia pd
     where pd.data between p_ini - 1 and p_fim
    window w as (partition by pd.funcionario_id order by pd.data)
  ), t as (
    select d.funcionario_id, d.data,
      case when d.nm >= 2 and d.d_ant = d.data - 1 and d.nm_ant >= 2 and d.sai_ant is not null
           then 1440 - d.sai_ant + d.ent end as inter,
      array_remove(array[
        case when d.nm % 2 = 1 then 'marc_impar' end,
        case when d.nm = 2 and (d.sai - d.ent) > 360 then 'sem_intervalo' end,
        case when d.falta_min > 0 and d.dt_deslig is not null and d.data > d.dt_deslig then 'falta_pos_deslig'
             when d.falta_min > 0 then 'falta' end,
        case when d.atraso_min >= 15 then 'atraso' end,
        case when coalesce(d.he_min, 0) > 120 then 'he_excesso' end,
        case when d.horario ilike 'descanso%' and d.nm > 0 then 'trab_descanso' end
      ], null) as tp
      from d where d.data between p_ini and p_fim and not d.parcial
  )
  select t.funcionario_id, t.data,
         case when t.inter is not null and t.inter < 660 then t.tp || 'interjornada'::text else t.tp end,
         case when t.inter < 660 then t.inter end
    from t
   where cardinality(t.tp) > 0 or (t.inter is not null and t.inter < 660);
$$;
revoke all on function "18 - rh".inconsistencias(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- RPCs da Validação gestor
-- Lista: inconsistências do período (só dos funcionários visíveis) + o dia + a tratativa
create or replace function public.app_rh_val_lista(p_ini date, p_fim date)
returns jsonb language plpgsql stable security definer set search_path to 'public', '18 - rh' as $$
declare v_uid uuid := auth.uid(); v_rh boolean;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  v_rh := public.rh_pode_carregar(v_uid);
  if not v_rh and not exists(select 1 from public.perfil where id = v_uid and funcao in ('aprovador','admin')) then
    raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 92 then raise exception 'período inválido (máx. 3 meses)'; end if;
  return jsonb_build_object('rh', v_rh, 'itens', coalesce((select jsonb_agg(jsonb_build_object(
      'fid', f.id, 'nome', f.nome, 'matricula', f.matricula, 'sigla', e.sigla, 'consorcio', e.consorcio,
      'gestor', coalesce(g1.nome, g1.email), 'gestor2', coalesce(g2.nome, g2.email), 'sem_usuario', f.perfil_id is null,
      'data', i.data, 'tipos', i.tipos, 'interjornada_min', i.interjornada_min,
      'dia_semana', pd.dia_semana, 'horario', pd.horario, 'marcacoes', pd.marcacoes, 'htrab', pd.htrab_min, 'he', pd.he_min,
      'falta', pd.falta_min, 'atraso', pd.atraso_min, 'justificativa', pd.justificativa, 'versao', pd.versao,
      'trat', case when t.funcionario_id is null then null else jsonb_build_object(
        'acao', t.acao, 'marcacoes', t.marcacoes, 'motivo', t.motivo, 'obs', t.obs, 'status', t.status,
        'gestor', coalesce(pg.nome, pg.email), 'gestor_em', t.gestor_em, 'versao_dia', t.versao_dia,
        'rh', coalesce(pr.nome, pr.email), 'rh_em', t.rh_em, 'rh_obs', t.rh_obs,
        'kairos_atualizado', pd.versao > coalesce(t.versao_dia, pd.versao),
        'kairos_bate', case t.acao when 'ajustar' then pd.marcacoes = t.marcacoes
                                    when 'falta' then pd.falta_min > 0
                                    when 'justificar' then case when t.tipos && array['falta','falta_pos_deslig'] then pd.falta_min = 0 end
                                    else null end) end)
      order by f.nome, i.data)
    from "18 - rh".inconsistencias(p_ini, p_fim) i
    join func_visiveis(v_uid) fv on fv.funcionario_id = i.funcionario_id
    join "18 - rh".funcionario f on f.id = i.funcionario_id
    join "18 - rh".empresa e on e.cnpj = f.cnpj
    join "18 - rh".ponto_dia pd on pd.funcionario_id = i.funcionario_id and pd.data = i.data
    left join public.perfil p on p.id = f.perfil_id
    left join public.perfil g1 on g1.id = p.aprovador_uuid
    left join public.perfil g2 on g2.id = p.aprovador2_uuid
    left join "18 - rh".tratativa t on t.funcionario_id = i.funcionario_id and t.data = i.data
    left join public.perfil pg on pg.id = t.gestor_uuid
    left join public.perfil pr on pr.id = t.rh_uuid), '[]'::jsonb));
end $$;

-- Gestor trata o dia (ou refaz depois de devolvido). Validado pela RH = travado.
create or replace function public.app_rh_val_tratar(p_funcionario bigint, p_data date, p_acao text,
                                                    p_marcacoes text[] default null, p_motivo text default null, p_obs text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public', '18 - rh' as $$
declare v_uid uuid := auth.uid(); v_tipos text[]; v_ver int; v_st text; m text; prev int := -1;
begin
  if v_uid is null or not exists(select 1 from func_visiveis(v_uid) where funcionario_id = p_funcionario) then
    raise exception 'sem permissão para este colaborador'; end if;
  if p_acao not in ('ajustar','falta','justificar','ok') then raise exception 'ação inválida'; end if;
  select status into v_st from "18 - rh".tratativa where funcionario_id = p_funcionario and data = p_data;
  if v_st = 'validado' then raise exception 'dia já validado pela RH'; end if;
  select versao into v_ver from "18 - rh".ponto_dia where funcionario_id = p_funcionario and data = p_data;
  if v_ver is null then raise exception 'dia não encontrado'; end if;
  if p_acao = 'ajustar' then
    if coalesce(cardinality(p_marcacoes), 0) = 0 or cardinality(p_marcacoes) % 2 = 1 then
      raise exception 'informe pares de entrada e saída'; end if;
    foreach m in array p_marcacoes loop
      if hm(m) is null or hm(m) >= 1440 then raise exception 'horário inválido: %', m; end if;
      if hm(m) <= prev then raise exception 'os horários precisam estar em ordem crescente'; end if;
      prev := hm(m);
    end loop;
  else p_marcacoes := null; end if;
  if p_acao = 'justificar' and coalesce(trim(p_motivo), '') = '' then raise exception 'informe o motivo'; end if;
  select i.tipos into v_tipos from "18 - rh".inconsistencias(p_data, p_data) i where i.funcionario_id = p_funcionario;
  insert into "18 - rh".tratativa as t (funcionario_id, data, tipos, acao, marcacoes, motivo, obs, versao_dia, status, gestor_uuid, gestor_em)
  values (p_funcionario, p_data, coalesce(v_tipos, '{}'), p_acao, p_marcacoes, nullif(trim(p_motivo), ''), nullif(trim(p_obs), ''),
          v_ver, 'tratado', v_uid, now())
  on conflict (funcionario_id, data) do update set tipos = excluded.tipos, acao = excluded.acao, marcacoes = excluded.marcacoes,
    motivo = excluded.motivo, obs = excluded.obs, versao_dia = excluded.versao_dia, status = 'tratado',
    gestor_uuid = excluded.gestor_uuid, gestor_em = now(), rh_uuid = null, rh_em = null, rh_obs = null;
  insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
  values (p_funcionario, p_data, 'tratado', jsonb_build_object('acao', p_acao, 'marcacoes', p_marcacoes, 'motivo', p_motivo, 'obs', p_obs, 'tipos', v_tipos), v_uid);
  return jsonb_build_object('ok', true);
end $$;

-- 2ª validação (RH): depois de corrigir no Kairos → validado; ou devolve ao gestor com observação.
create or replace function public.app_rh_val_rh(p_funcionario bigint, p_data date, p_validar boolean, p_obs text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public', '18 - rh' as $$
declare v_uid uuid := auth.uid(); v_st text;
begin
  if not public.rh_pode_carregar(v_uid) then raise exception 'sem permissão'; end if;
  select status into v_st from "18 - rh".tratativa where funcionario_id = p_funcionario and data = p_data for update;
  if v_st is null then raise exception 'o gestor ainda não tratou este dia'; end if;
  if not p_validar and coalesce(trim(p_obs), '') = '' then raise exception 'diga ao gestor o que falta'; end if;
  update "18 - rh".tratativa set status = case when p_validar then 'validado' else 'devolvido' end,
         rh_uuid = v_uid, rh_em = now(), rh_obs = nullif(trim(p_obs), '')
   where funcionario_id = p_funcionario and data = p_data;
  insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
  values (p_funcionario, p_data, case when p_validar then 'validado' else 'devolvido' end, jsonb_build_object('obs', p_obs), v_uid);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- Análise do ponto (indicadores do período)
create or replace function public.app_rh_analise(p_ini date, p_fim date, p_consorcio text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public', '18 - rh' as $$
declare v_uid uuid := auth.uid(); r jsonb;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  if not public.rh_pode_carregar(v_uid) and not exists(select 1 from public.perfil where id = v_uid and funcao in ('aprovador','admin')) then
    raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 366 then raise exception 'período inválido (máx. 1 ano)'; end if;
  with fv as (
    select f.id, f.nome, e.sigla, e.consorcio from func_visiveis(v_uid) x
      join "18 - rh".funcionario f on f.id = x.funcionario_id join "18 - rh".empresa e on e.cnpj = f.cnpj
     where p_consorcio is null or e.consorcio = p_consorcio
  ), d as (
    select pd.*, fv.nome, fv.sigla, fv.consorcio from "18 - rh".ponto_dia pd join fv on fv.id = pd.funcionario_id
     where pd.data between p_ini and p_fim
  ), inc as (
    select i.*, fv.nome, fv.sigla from "18 - rh".inconsistencias(p_ini, p_fim) i join fv on fv.id = i.funcionario_id
  ), inc_t as (
    select unnest(tipos) tipo, funcionario_id from inc
  ), func as (
    select d.funcionario_id, min(d.nome) nome, min(d.sigla) sigla,
           sum(coalesce(d.he_min, 0)) he, sum(d.falta_min) falta, count(*) filter (where d.falta_min > 0) dias_falta,
           sum(d.atraso_min) atraso, count(*) filter (where coalesce(d.he_min, 0) > 120) dias_he2,
           sum(coalesce(d.htrab_min, 0)) htrab, count(*) filter (where cardinality(d.marcacoes) > 0) dias_trab
      from d group by d.funcionario_id
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('ini', p_ini, 'fim', p_fim, 'data_min', (select min(data) from d), 'data_max', (select max(data) from d),
                                  'parciais', (select count(*) from d where parcial)),
    'tot', (select jsonb_build_object('funcionarios', count(distinct funcionario_id),
              'dias_trab', count(*) filter (where cardinality(marcacoes) > 0),
              'htrab', sum(coalesce(htrab_min, 0)), 'he', sum(coalesce(he_min, 0)), 'adn', sum(coalesce(adn_min, 0)),
              'falta_min', sum(falta_min), 'dias_falta', count(*) filter (where falta_min > 0),
              'atraso_min', sum(atraso_min), 'n_atrasos', count(*) filter (where atraso_min > 0),
              'dsr', count(*) filter (where dsr_min > 0)) from d),
    'por_empresa', (select coalesce(jsonb_agg(x order by x->>'sigla'), '[]') from (select jsonb_build_object('sigla', sigla, 'consorcio', consorcio,
              'funcionarios', count(distinct funcionario_id), 'he', sum(coalesce(he_min, 0)), 'htrab', sum(coalesce(htrab_min, 0)),
              'falta_min', sum(falta_min), 'dias_falta', count(*) filter (where falta_min > 0), 'atraso_min', sum(atraso_min)) x
              from d group by sigla, consorcio) s),
    'por_dia', (select coalesce(jsonb_agg(x order by x->>'data'), '[]') from (select jsonb_build_object('data', data,
              'he', sum(coalesce(he_min, 0)), 'falta_min', sum(falta_min), 'presentes', count(*) filter (where cardinality(marcacoes) > 0)) x
              from d group by data) s),
    'inc', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('casos', n, 'pessoas', p)), '{}') from
              (select tipo, count(*) n, count(distinct funcionario_id) p from inc_t group by tipo) s),
    'interjornada', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'sigla', sigla, 'data', data, 'descanso', interjornada_min)
              order by interjornada_min), '[]') from inc where interjornada_min is not null),
    'func', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'sigla', sigla, 'he', he, 'falta', falta, 'dias_falta', dias_falta,
              'atraso', atraso, 'dias_he2', dias_he2, 'htrab', htrab, 'dias_trab', dias_trab,
              'interj', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and interjornada_min is not null))
              order by he desc), '[]') from func),
    'tratativas', (select jsonb_build_object('pendentes', count(*) filter (where t.funcionario_id is null or t.status = 'devolvido'),
              'tratadas', count(*) filter (where t.status = 'tratado'), 'validadas', count(*) filter (where t.status = 'validado'))
              from inc left join "18 - rh".tratativa t on t.funcionario_id = inc.funcionario_id and t.data = inc.data)
  ) into r;
  return r;
end $$;

revoke all on function public.app_rh_val_lista(date, date) from public, anon;
revoke all on function public.app_rh_val_tratar(bigint, date, text, text[], text, text) from public, anon;
revoke all on function public.app_rh_val_rh(bigint, date, boolean, text) from public, anon;
revoke all on function public.app_rh_analise(date, date, text) from public, anon;
grant execute on function public.app_rh_val_lista(date, date) to authenticated;
grant execute on function public.app_rh_val_tratar(bigint, date, text, text[], text, text) to authenticated;
grant execute on function public.app_rh_val_rh(bigint, date, boolean, text) to authenticated;
grant execute on function public.app_rh_analise(date, date, text) to authenticated;

notify pgrst, 'reload schema';
