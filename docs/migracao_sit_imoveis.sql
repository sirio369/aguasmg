-- Situação dos Imóveis (Auxiliar de Programação › Serviços comerciais) — 2026-10-30
-- JÁ APLICADA no projeto lwttadkctfznidzvmury (migração `sit_imoveis_rpcs`). Arquivo de registro/reaplicação.
-- Fonte única: "3 - comercial".ligacoes (situacao = CD_SITUACA, situacao_desde = DT_SITUACA).
-- Gate: admin | dev_acesso | aux_acesso (reaproveita _nrw_fraude_gate).

create or replace function public._sit_imoveis_base(
  p_consorcio text, p_situacoes text[], p_desde_ini date, p_desde_fim date,
  p_sem_data boolean, p_poly geometry, p_busca text)
returns table(matricula bigint, consorcio text, situacao text, situacao_desde date, geom geometry)
language sql stable
set search_path to 'public'
as $$
  select l.matricula, l.consorcio, l.situacao, l.situacao_desde, l.geom
  from "3 - comercial".ligacoes l
  where (p_consorcio is null or l.consorcio = p_consorcio)
    and (p_situacoes is null or cardinality(p_situacoes) = 0 or l.situacao = any(p_situacoes))
    and (case when coalesce(p_sem_data,false) then l.situacao_desde is null
              else (p_desde_ini is null or l.situacao_desde >= p_desde_ini)
               and (p_desde_fim is null or l.situacao_desde <= p_desde_fim) end)
    and (p_poly is null or st_contains(p_poly, l.geom))
    and (p_busca is null or l.matricula::text like p_busca || '%')
$$;

create or replace function public._sit_imoveis_faixa(d integer)
returns text language sql immutable
set search_path to 'public'
as $$
  select case when d is null then 'sem'
              when d <= 7 then '0-7' when d <= 15 then '8-15' when d <= 30 then '16-30'
              when d <= 60 then '31-60' when d <= 90 then '61-90' when d <= 180 then '91-180'
              when d <= 365 then '181-365' when d <= 730 then '1-2a' when d <= 1825 then '2-5a'
              else '5a+' end
$$;

create or replace function public.app_sit_imoveis_resumo(
  p_consorcio text default null, p_situacoes text[] default null,
  p_desde_ini date default null, p_desde_fim date default null, p_sem_data boolean default false,
  p_poligono text default null, p_busca text default null)
returns jsonb language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_poly geometry;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_busca text := nullif(trim(p_busca), '');
begin
  perform public._nrw_fraude_gate();
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return jsonb_build_object(
    'total', (select count(*) from public._sit_imoveis_base(p_consorcio,p_situacoes,p_desde_ini,p_desde_fim,p_sem_data,v_poly,v_busca)),
    -- cada distribuição ignora o próprio filtro (cross-filter): situação sem o filtro de situação, faixa sem o filtro de data
    'por_situacao', (select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) from (
        select coalesce(b.situacao,'?') s, count(*) n
        from public._sit_imoveis_base(p_consorcio,null,p_desde_ini,p_desde_fim,p_sem_data,v_poly,v_busca) b group by 1) x),
    'por_faixa', (select coalesce(jsonb_object_agg(f, n), '{}'::jsonb) from (
        select public._sit_imoveis_faixa(v_hoje - b.situacao_desde) f, count(*) n
        from public._sit_imoveis_base(p_consorcio,p_situacoes,null,null,false,v_poly,v_busca) b group by 1) x),
    'por_consorcio', (select coalesce(jsonb_object_agg(c, n), '{}'::jsonb) from (
        select coalesce(b.consorcio,'?') c, count(*) n
        from public._sit_imoveis_base(p_consorcio,p_situacoes,p_desde_ini,p_desde_fim,p_sem_data,v_poly,v_busca) b group by 1) x),
    'hoje', v_hoje,
    'ultima_data', (select max(l.situacao_desde) from "3 - comercial".ligacoes l)
  );
end $$;

create or replace function public.app_sit_imoveis_lista(
  p_consorcio text default null, p_situacoes text[] default null,
  p_desde_ini date default null, p_desde_fim date default null, p_sem_data boolean default false,
  p_poligono text default null, p_busca text default null,
  p_limit integer default 300, p_offset integer default 0, p_ordem text default 'recente')
returns jsonb language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_poly geometry;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_busca text := nullif(trim(p_busca), '');
begin
  perform public._nrw_fraude_gate();
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return jsonb_build_object(
    'total', (select count(*) from public._sit_imoveis_base(p_consorcio,p_situacoes,p_desde_ini,p_desde_fim,p_sem_data,v_poly,v_busca)),
    'rows', coalesce((select jsonb_agg(row_to_json(r)) from (
       select b.matricula, b.consorcio, b.situacao, b.situacao_desde, v_hoje - b.situacao_desde dias,
              ad.bairro, ad.endereco
       from (select * from public._sit_imoveis_base(p_consorcio,p_situacoes,p_desde_ini,p_desde_fim,p_sem_data,v_poly,v_busca) x
             order by case when p_ordem = 'antigo' then x.situacao_desde end asc nulls last,
                      case when p_ordem = 'matricula' then x.matricula end asc,
                      x.situacao_desde desc nulls last, x.matricula
             limit greatest(1, least(p_limit, 2000)) offset greatest(0, p_offset)) b
       left join lateral (select c.bairro, c.endereco from "0 - vitrine_gis".vw_gis_cadastro_comercial c
                          where c.matricula = b.matricula limit 1) ad on true
       order by case when p_ordem = 'antigo' then b.situacao_desde end asc nulls last,
                case when p_ordem = 'matricula' then b.matricula end asc,
                b.situacao_desde desc nulls last, b.matricula) r), '[]'::jsonb)
  );
end $$;

-- mapa: array compacto [matricula, lat, lon, situacao, dias] (até 150 mil pontos = todas as ligações)
create or replace function public.app_sit_imoveis_mapa(
  p_consorcio text default null, p_situacoes text[] default null,
  p_desde_ini date default null, p_desde_fim date default null, p_sem_data boolean default false,
  p_poligono text default null, p_busca text default null, p_limit integer default 150000)
returns json language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_poly geometry;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_busca text := nullif(trim(p_busca), '');
begin
  perform public._nrw_fraude_gate();
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return coalesce((select json_agg(json_build_array(x.matricula, round(st_y(x.g)::numeric,6), round(st_x(x.g)::numeric,6), x.situacao, v_hoje - x.situacao_desde))
    from (select b.matricula, b.situacao, b.situacao_desde, st_transform(b.geom,4326) g
          from public._sit_imoveis_base(p_consorcio,p_situacoes,p_desde_ini,p_desde_fim,p_sem_data,v_poly,v_busca) b
          where b.geom is not null
          limit greatest(1, least(p_limit, 150000))) x), '[]'::json);
end $$;

revoke all on function public._sit_imoveis_base(text,text[],date,date,boolean,geometry,text) from public, anon, authenticated;
revoke all on function public._sit_imoveis_faixa(integer) from public, anon, authenticated;
revoke all on function public.app_sit_imoveis_resumo(text,text[],date,date,boolean,text,text) from public, anon;
revoke all on function public.app_sit_imoveis_lista(text,text[],date,date,boolean,text,text,integer,integer,text) from public, anon;
revoke all on function public.app_sit_imoveis_mapa(text,text[],date,date,boolean,text,text,integer) from public, anon;
grant execute on function public.app_sit_imoveis_resumo(text,text[],date,date,boolean,text,text) to authenticated;
grant execute on function public.app_sit_imoveis_lista(text,text[],date,date,boolean,text,text,integer,integer,text) to authenticated;
grant execute on function public.app_sit_imoveis_mapa(text,text[],date,date,boolean,text,text,integer) to authenticated;
