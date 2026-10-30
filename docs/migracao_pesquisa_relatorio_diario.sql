-- Relatório diário da pesquisa de vazamentos (2026-10-30) — Auxiliar de Programação › Pesquisa de Vazamentos.
-- Uma folha por DIA × COLABORADOR: mapa (rede pesquisada + trajetos + vazamentos/fraudes) + KPIs + detalhe de cada ocorrência.
-- Mesmas definições do Acompanhamento (§4.3.8): km de rede = pp_execucao; km andado = pesquisa_trecho;
-- vaz/km = vazamentos ÷ km de rede; velocidade = km andado ÷ tempo dos trechos; vazamento = tipo que NÃO começa com "Fraude".
-- Fraudes (tipo "Fraude - …") entram na folha à parte (card + lista própria), fora do vaz/km.
-- Dia: inicio_ts/data_hora (timestamp sem tz) já são horário de Brasília; executado_em (timestamptz) é convertido.
-- Casamento traço/ocorrência ↔ usuário por nome OU e-mail (pegadinha da §4.3.5).

-- Colaboradores com atividade no dia (alimenta o filtro da tela).
create or replace function public.app_pp_diario_colabs(p_data date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=auth.uid() and (funcao in ('admin','aprovador') or coalesce(aux_acesso,false))) then
    raise exception 'sem permissão'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('id',pe.id,'nome',coalesce(pe.nome,pe.email),
             'km_andado',round((an.m/1000.0)::numeric,2),'km_rede',round((ke.m/1000.0)::numeric,2),'vazamentos',oc.vaz,'fraudes',oc.fra)
           order by coalesce(pe.nome,pe.email)),'[]'::jsonb)
    from public.perfil pe
    cross join lateral (select coalesce(sum(t.comprimento_m),0) m, count(*) n from "8 - coleta_campo".pesquisa_trecho t
      where t.usuario in (pe.nome, pe.email) and t.inicio_ts::date = p_data) an
    cross join lateral (select coalesce(sum(coalesce(e.comprimento_m, st_length(e.geom))),0) m, count(*) n from "8 - coleta_campo".pp_execucao e
      where e.colaborador_uuid = pe.id and (e.executado_em at time zone 'America/Sao_Paulo')::date = p_data) ke
    cross join lateral (select count(*) n, count(*) filter (where coalesce(o.tipo,'') not ilike 'fraude%') vaz,
                               count(*) filter (where o.tipo ilike 'fraude%') fra
      from "8 - coleta_campo".ocorrencia o
      where o.usuario in (pe.nome, pe.email) and o.data_hora::date = p_data) oc
    where an.n > 0 or ke.n > 0 or oc.n > 0);
end $$;

-- A folha do relatório.
create or replace function public.app_pp_relatorio_diario(p_colaborador uuid, p_data date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_nome text; v_email text;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=auth.uid() and (funcao in ('admin','aprovador') or coalesce(aux_acesso,false))) then
    raise exception 'sem permissão'; end if;
  select nome, email into v_nome, v_email from public.perfil where id=p_colaborador;
  if not found then raise exception 'colaborador não encontrado'; end if;
  return (
    with tr as (
      select t.* from "8 - coleta_campo".pesquisa_trecho t
      where t.usuario in (v_nome, v_email) and t.inicio_ts::date = p_data),
    ex as (
      select e.*, r.consorcio from "8 - coleta_campo".pp_execucao e
      left join "2 - infra_agua".rede r on r.id = e.rede_id
      where e.colaborador_uuid = p_colaborador and (e.executado_em at time zone 'America/Sao_Paulo')::date = p_data),
    oc as (
      select o.* from "8 - coleta_campo".ocorrencia o
      where o.usuario in (v_nome, v_email) and o.data_hora::date = p_data),
    k as (select
      (select coalesce(sum(coalesce(comprimento_m, st_length(geom))),0) from ex) rede_m,
      (select coalesce(sum(comprimento_m),0) from tr) andado_m,
      (select coalesce(sum(duracao_s),0) from tr) dur_s,
      (select count(*) from tr) n_tr,
      (select count(*) from oc where coalesce(tipo,'') not ilike 'fraude%') vaz,
      (select count(*) from oc where tipo ilike 'fraude%') fra,
      (select min(inicio_ts) from tr) ini,
      (select max(fim_ts) from tr) fim)
    select jsonb_build_object(
      'colaborador', jsonb_build_object('id', p_colaborador, 'nome', coalesce(v_nome, v_email)),
      'data', p_data,
      'consorcios', (select coalesce(jsonb_agg(distinct c order by c),'[]'::jsonb)
                     from (select consorcio c from ex union select consorcio from oc
                           union select coalesce(t.consorcio, (select l.consorcio from "1 - suporte_geografico".limite_za l
                                                               where st_intersects(l.geom, t.geom) limit 1)) from tr t) z  -- trecho recente vem sem consórcio
                     where c is not null),
      'kpis', jsonb_build_object(
        'km_rede_pesquisado', round((k.rede_m/1000.0)::numeric,2),
        'km_andado', round((k.andado_m/1000.0)::numeric,2),
        'vazamentos', k.vaz,
        'fraudes', k.fra,
        'vaz_km', case when k.rede_m>0 then round((k.vaz/(k.rede_m/1000.0))::numeric,2) else 0 end,
        'velocidade_kmh', case when k.dur_s>0 then round(((k.andado_m/1000.0)/(k.dur_s/3600.0))::numeric,2) else 0 end,
        'n_trechos', k.n_tr, 'duracao_s', k.dur_s, 'inicio', k.ini, 'fim', k.fim),
      'trechos', jsonb_build_object('type','FeatureCollection','features',
        (select coalesce(jsonb_agg(jsonb_build_object('type','Feature','geometry',st_asgeojson(st_transform(geom,4326),6)::jsonb,
           'properties',jsonb_build_object('inicio',inicio_ts,'fim',fim_ts,'metros',round(comprimento_m))) order by inicio_ts),'[]'::jsonb)
         from tr where geom is not null)),
      'rede', jsonb_build_object('type','FeatureCollection','features',
        (select coalesce(jsonb_agg(jsonb_build_object('type','Feature','geometry',st_asgeojson(st_transform(geom,4326),6)::jsonb,
           'properties',jsonb_build_object('n_passada',n_passada))),'[]'::jsonb)
         from (select distinct on (coalesce(segmento_id::text, id::text)) geom, n_passada from ex where geom is not null
               order by coalesce(segmento_id::text, id::text), n_passada desc) s)),
      'vazamentos', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'tipo',tipo,'local',local_ref,'observacao',observacao,
           'foto',foto,'lat',lat,'lon',lon,'data_hora',data_hora,'os',os_numero,'consorcio',consorcio,'gps_precisao',gps_precisao)
           order by data_hora),'[]'::jsonb) from oc where coalesce(tipo,'') not ilike 'fraude%'),
      'fraudes', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'tipo',tipo,'local',local_ref,'observacao',observacao,
           'foto',foto,'lat',lat,'lon',lon,'data_hora',data_hora,'os',os_numero,'consorcio',consorcio,'gps_precisao',gps_precisao)
           order by data_hora),'[]'::jsonb) from oc where tipo ilike 'fraude%'))
    from k);
end $$;

revoke all on function public.app_pp_diario_colabs(date) from public, anon;
revoke all on function public.app_pp_relatorio_diario(uuid, date) from public, anon;
grant execute on function public.app_pp_diario_colabs(date) to authenticated;
grant execute on function public.app_pp_relatorio_diario(uuid, date) to authenticated;
