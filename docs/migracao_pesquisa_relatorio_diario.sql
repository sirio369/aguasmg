-- Relatório diário da pesquisa de vazamentos (2026-10-30) — Auxiliar de Programação › Pesquisa de Vazamentos.
-- Lista de BLOCOS (dia × colaborador × consórcio) com a OS SIGOS do dia lançada pelo backoffice (pendente de OS → OS
-- criada) + a folha de cada bloco: mapa (rede pesquisada + trajetos + vazamentos/fraudes) + KPIs + detalhe de cada ocorrência.
-- Mesmas definições do Acompanhamento (§4.3.8): km de rede = pp_execucao; km andado = pesquisa_trecho;
-- vaz/km = vazamentos ÷ km de rede; velocidade = km andado ÷ tempo dos trechos; vazamento = tipo que NÃO começa com "Fraude".
-- Fraudes (tipo "Fraude - …") entram na folha à parte (card + lista própria), fora do vaz/km.
-- Dia: inicio_ts/data_hora (timestamp sem tz) já são horário de Brasília; executado_em (timestamptz) é convertido.
-- Casamento traço/ocorrência ↔ usuário por nome OU e-mail (pegadinha da §4.3.5).
-- CONSÓRCIO de cada coisa: rede = "2 - infra_agua".rede.consorcio; ocorrência = ocorrencia.consorcio (pelo ponto desde
-- 2026-10-27); TRECHO = pela geometria (limite_za que contém o ponto do trecho) — pesquisa_trecho.consorcio vem do aparelho
-- e está errado/vazio em 190 de 299 trechos (ex.: Marcos, Betim, gravado ZA1004); o gravado só vale se cair fora das ZAs.

-- Consórcio do trecho pela geometria (fallback: o gravado).
create or replace function public.pp_trecho_consorcio(p_geom geometry, p_gravado text)
returns text language sql stable set search_path to 'public' as $$
  select coalesce((select l.consorcio from "1 - suporte_geografico".limite_za l
                   where st_intersects(l.geom, st_pointonsurface(p_geom)) limit 1), p_gravado);
$$;
revoke all on function public.pp_trecho_consorcio(geometry, text) from public, anon, authenticated;

-- OS SIGOS do dia de pesquisa (1 por colaborador × dia × consórcio — cada consórcio é um contrato/OS próprio).
-- Backoffice puro → schema 12 (app-only, sem acesso GIS). Sem linha = "pendente de OS"; apagar a OS apaga a linha.
-- consorcio '' = atividade sem consórcio identificado (não ocorre hoje).
create table if not exists "12 - retaguarda".pesquisa_dia_os (
  colaborador_uuid uuid not null references public.perfil(id),
  dia date not null,
  consorcio text not null,
  os_sigos text not null check (length(btrim(os_sigos)) between 1 and 40),
  os_em timestamptz not null default now(),
  os_por uuid references public.perfil(id),
  primary key (colaborador_uuid, dia, consorcio)
);
alter table "12 - retaguarda".pesquisa_dia_os enable row level security;   -- sem policy: só via RPC definer
revoke all on "12 - retaguarda".pesquisa_dia_os from public, anon, authenticated;

-- Blocos dia × colaborador × consórcio com pesquisa (trecho, rede pesquisada ou ocorrência) + OS. Filtros/prazo no front.
create or replace function public.app_pp_diario_lista()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=auth.uid() and (funcao in ('admin','aprovador') or coalesce(aux_acesso,false))) then
    raise exception 'sem permissão'; end if;
  return (
    with tr as (
      select pe.id u, t.inicio_ts::date d, coalesce(public.pp_trecho_consorcio(t.geom, t.consorcio),'') c,
             sum(t.comprimento_m) m, sum(t.duracao_s) s, count(*) n
      from "8 - coleta_campo".pesquisa_trecho t join public.perfil pe on t.usuario in (pe.nome, pe.email)
      group by 1, 2, 3),
    ex as (
      select e.colaborador_uuid u, (e.executado_em at time zone 'America/Sao_Paulo')::date d, coalesce(r.consorcio,'') c,
             sum(coalesce(e.comprimento_m, st_length(e.geom))::numeric) m
      from "8 - coleta_campo".pp_execucao e left join "2 - infra_agua".rede r on r.id = e.rede_id
      where e.colaborador_uuid is not null group by 1, 2, 3),
    oc as (
      select pe.id u, o.data_hora::date d, coalesce(o.consorcio,'') c,
             count(*) filter (where coalesce(o.tipo,'') not ilike 'fraude%') vaz, count(*) filter (where o.tipo ilike 'fraude%') fra
      from "8 - coleta_campo".ocorrencia o join public.perfil pe on o.usuario in (pe.nome, pe.email)
      group by 1, 2, 3),
    b as (select u, d, c from tr union select u, d, c from ex union select u, d, c from oc)
    select coalesce(jsonb_agg(jsonb_build_object(
        'colaborador_uuid', b.u, 'nome', coalesce(pe.nome, pe.email), 'dia', b.d, 'consorcio', nullif(b.c,''),
        'km_rede', round(coalesce(ex.m,0)/1000.0, 2), 'km_andado', round(coalesce(tr.m,0)/1000.0, 2),
        'duracao_s', coalesce(tr.s,0), 'n_trechos', coalesce(tr.n,0),
        'vazamentos', coalesce(oc.vaz,0), 'fraudes', coalesce(oc.fra,0),
        'os_sigos', os.os_sigos, 'os_em', os.os_em, 'os_por', (select coalesce(nome,email) from public.perfil where id=os.os_por))
      order by b.d desc, coalesce(pe.nome, pe.email), b.c), '[]'::jsonb)
    from b join public.perfil pe on pe.id = b.u
    left join tr on tr.u = b.u and tr.d = b.d and tr.c = b.c
    left join ex on ex.u = b.u and ex.d = b.d and ex.c = b.c
    left join oc on oc.u = b.u and oc.d = b.d and oc.c = b.c
    left join "12 - retaguarda".pesquisa_dia_os os on os.colaborador_uuid = b.u and os.dia = b.d and os.consorcio = b.c);
end $$;

-- Lança/troca a OS SIGOS do bloco (vazio = apaga → volta a pendente). Só para bloco que existe (houve pesquisa).
create or replace function public.app_pp_diario_os(p_colaborador uuid, p_data date, p_consorcio text, p_os text)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare v_os text := nullif(btrim(p_os), ''); v_c text := coalesce(p_consorcio, ''); v_nome text; v_email text; r jsonb;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=auth.uid() and (funcao in ('admin','aprovador') or coalesce(aux_acesso,false))) then
    raise exception 'sem permissão'; end if;
  select nome, email into v_nome, v_email from public.perfil where id=p_colaborador;
  if not found then raise exception 'colaborador não encontrado'; end if;
  if not (exists(select 1 from "8 - coleta_campo".pesquisa_trecho t where t.usuario in (v_nome, v_email) and t.inicio_ts::date = p_data
                   and coalesce(public.pp_trecho_consorcio(t.geom, t.consorcio),'') = v_c)
       or exists(select 1 from "8 - coleta_campo".pp_execucao e left join "2 - infra_agua".rede r on r.id = e.rede_id
                   where e.colaborador_uuid = p_colaborador and (e.executado_em at time zone 'America/Sao_Paulo')::date = p_data
                     and coalesce(r.consorcio,'') = v_c)
       or exists(select 1 from "8 - coleta_campo".ocorrencia o where o.usuario in (v_nome, v_email) and o.data_hora::date = p_data
                   and coalesce(o.consorcio,'') = v_c)) then
    raise exception 'não há pesquisa desse colaborador nesse dia e consórcio'; end if;
  if v_os is null then
    delete from "12 - retaguarda".pesquisa_dia_os where colaborador_uuid = p_colaborador and dia = p_data and consorcio = v_c;
    return jsonb_build_object('os_sigos', null);
  end if;
  if length(v_os) > 40 then raise exception 'OS muito longa (máx. 40 caracteres)'; end if;
  insert into "12 - retaguarda".pesquisa_dia_os (colaborador_uuid, dia, consorcio, os_sigos, os_em, os_por)
  values (p_colaborador, p_data, v_c, v_os, now(), auth.uid())
  on conflict (colaborador_uuid, dia, consorcio) do update set os_sigos = excluded.os_sigos, os_em = excluded.os_em, os_por = excluded.os_por;
  select jsonb_build_object('os_sigos', d.os_sigos, 'os_em', d.os_em, 'os_por', (select coalesce(nome,email) from public.perfil where id=d.os_por))
    into r from "12 - retaguarda".pesquisa_dia_os d where d.colaborador_uuid = p_colaborador and d.dia = p_data and d.consorcio = v_c;
  return r;
end $$;

-- A folha do bloco (p_consorcio null = o dia inteiro, todos os consórcios).
create or replace function public.app_pp_relatorio_diario(p_colaborador uuid, p_data date, p_consorcio text default null)
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
      select * from (select t.*, coalesce(public.pp_trecho_consorcio(t.geom, t.consorcio),'') c
                     from "8 - coleta_campo".pesquisa_trecho t
                     where t.usuario in (v_nome, v_email) and t.inicio_ts::date = p_data) x
      where p_consorcio is null or x.c = p_consorcio),
    ex as (
      select e.*, coalesce(r.consorcio,'') c from "8 - coleta_campo".pp_execucao e
      left join "2 - infra_agua".rede r on r.id = e.rede_id
      where e.colaborador_uuid = p_colaborador and (e.executado_em at time zone 'America/Sao_Paulo')::date = p_data
        and (p_consorcio is null or coalesce(r.consorcio,'') = p_consorcio)),
    oc as (
      select o.*, coalesce(o.consorcio,'') c from "8 - coleta_campo".ocorrencia o
      where o.usuario in (v_nome, v_email) and o.data_hora::date = p_data
        and (p_consorcio is null or coalesce(o.consorcio,'') = p_consorcio)),
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
      'os_dia', (select jsonb_build_object('os_sigos',d.os_sigos,'os_em',d.os_em,'os_por',(select coalesce(nome,email) from public.perfil where id=d.os_por))
                 from "12 - retaguarda".pesquisa_dia_os d
                 where d.colaborador_uuid=p_colaborador and d.dia=p_data and d.consorcio=coalesce(p_consorcio,'') ),  -- dia inteiro (p_consorcio null) não tem OS única
      'consorcios', (select coalesce(jsonb_agg(distinct c order by c),'[]'::jsonb)
                     from (select c from ex union select c from oc union select c from tr) z where c <> ''),
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

-- versões anteriores deste PR (assinaturas sem consórcio) — drop p/ não sobrar overload (§0.6)
drop function if exists public.app_pp_diario_colabs(date);
drop function if exists public.app_pp_diario_os(uuid, date, text);
drop function if exists public.app_pp_relatorio_diario(uuid, date);
revoke all on function public.app_pp_diario_lista() from public, anon;
revoke all on function public.app_pp_diario_os(uuid, date, text, text) from public, anon;
revoke all on function public.app_pp_relatorio_diario(uuid, date, text) from public, anon;
grant execute on function public.app_pp_diario_lista() to authenticated;
grant execute on function public.app_pp_diario_os(uuid, date, text, text) to authenticated;
grant execute on function public.app_pp_relatorio_diario(uuid, date, text) to authenticated;
