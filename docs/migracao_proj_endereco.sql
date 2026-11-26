-- Projetos › endereço automático das intervenções (2026-11-26)
-- Fonte: "1 - suporte_geografico".logradouros (eixos de rua, SRID 31983) + bairros.
-- Ponto (VRP/Válvula): rua mais próxima (até 60 m) + bairro que contém o ponto.
-- Linha (HDD/VCA): amostra o traçado a cada ~5 m, pega a rua mais próxima de cada amostra (até 40 m)
--   e fica com as ruas que cobrem >= 10% do trecho ou >= 20 m (rua que só cruza fica de fora),
--   na ordem em que aparecem do início (I) ao fim (F). Sempre fica ao menos a rua dominante.
-- Calculado ao vivo em app_proj_intervencoes (acompanha edição de geometria no QGIS).

-- "R" + "DOS INGAS" → "Rua dos Ingas" (initcap + preposições em minúsculo)
create or replace function public.proj_fmt_logradouro(p_tipo text, p_nome text)
returns text language plpgsql immutable set search_path to 'public' as $$
declare v text; t text;
begin
  v := initcap(regexp_replace(trim(coalesce(p_nome,'')),'\s+',' ','g'));
  v := replace(replace(replace(replace(replace(replace(' '||v||' ',' De ',' de '),' Da ',' da '),' Do ',' do '),' Das ',' das '),' Dos ',' dos '),' E ',' e ');
  v := trim(v);
  -- algarismos romanos (Pio Xii → Pio XII) e siglas sem vogal (Bb → BB) ficam em maiúsculo
  select string_agg(case when length(w)>=2 and (upper(w) ~ '^[IVXL]+$' or (upper(w) !~ '[AEIOUY0-9]' and w not in ('Dr','Sr','Sta','Sto'))) then upper(w) else w end, ' ' order by n)
    into v from unnest(string_to_array(v,' ')) with ordinality u(w,n);
  t := case upper(trim(coalesce(p_tipo,'')))
      when 'R' then 'Rua' when 'AV' then 'Av.' when 'BC' then 'Beco' when 'PR' then 'Praça'
      when 'RD' then 'Rodovia' when 'T' then 'Travessa' when 'VI' then 'Via' when 'AL' then 'Alameda'
      when 'ET' then 'Estrada' when 'VD' then 'Viaduto' when 'PS' then 'Passagem' else trim(coalesce(p_tipo,'')) end;
  return nullif(trim(t||' '||coalesce(v,'')),'');
end $$;

-- {ruas:[...], bairros:[...]} de uma geometria (SRID 31983)
create or replace function public.proj_endereco(p_geom geometry)
returns jsonb language plpgsql stable set search_path to 'public','extensions' as $$
declare v_ruas jsonb; v_bairros jsonb; v_len float8; v_ns int;
begin
  if p_geom is null then return null; end if;
  if GeometryType(p_geom) in ('POINT','MULTIPOINT') then
    select jsonb_build_array(public.proj_fmt_logradouro(g.tipo_logradouro, g.nome)) into v_ruas
      from "1 - suporte_geografico".logradouros g
      where ST_DWithin(g.geom, p_geom, 60)
      order by g.geom <-> p_geom limit 1;
    select coalesce(jsonb_agg(distinct public.proj_fmt_logradouro('', b.nome)),'[]') into v_bairros
      from "1 - suporte_geografico".bairros b where ST_Intersects(b.geom, p_geom) and b.nome is not null;
  else
    p_geom := ST_LineMerge(p_geom);
    if GeometryType(p_geom) <> 'LINESTRING' then p_geom := ST_GeometryN(p_geom,1); end if;  -- multiline desconexa: usa a 1ª parte
    v_len := ST_Length(p_geom); v_ns := greatest(2, ceil(v_len/5))::int;
    with s as (select i, ST_LineInterpolatePoint(p_geom, i::float8/v_ns) p from generate_series(0, v_ns) i),
    n as (select s.i, r.nm from s join lateral (
            select public.proj_fmt_logradouro(g.tipo_logradouro, g.nome) nm, g.geom <-> s.p d
            from "1 - suporte_geografico".logradouros g order by g.geom <-> s.p limit 1) r on r.d <= 40),
    a as (select nm, count(*) c, min(i) o from n where nm is not null group by nm),
    k as (select nm, o, c, rank() over (order by c desc, o) rk from a)
    select coalesce(jsonb_agg(nm order by o),'[]') into v_ruas from k
      where rk = 1 or c::float8/(v_ns+1) >= 0.10 or c*v_len/v_ns >= 20;
    select coalesce(jsonb_agg(nm order by ov desc),'[]') into v_bairros from (
      select public.proj_fmt_logradouro('', b.nome) nm, max(ST_Length(ST_Intersection(b.geom, p_geom))) ov
      from "1 - suporte_geografico".bairros b where ST_Intersects(b.geom, p_geom) and b.nome is not null group by 1) x
      where ov >= least(20, v_len*0.1);
  end if;
  return jsonb_build_object('ruas', coalesce(v_ruas,'[]'::jsonb), 'bairros', coalesce(v_bairros,'[]'::jsonb));
end $$;
revoke all on function public.proj_endereco(geometry) from public, anon;

-- app_proj_intervencoes: + 'endereco' {ruas,bairros} nas properties de pontos e linhas (só acrescenta; app antigo ignora)
create or replace function public.app_proj_intervencoes(p_consorcio text default null, p_tipo text default null, p_dmc text default null)
 returns jsonb language plpgsql security definer
 set search_path to 'public', '7 - setorizacao', 'extensions'
as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  return jsonb_build_object(
    'pontos', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom,4326))::jsonb,
        'properties', jsonb_build_object('gid',gid,'id',id,'projeto',projeto,'cidade',cidade,'consorcio',cons,
          'dmc',dmc,'tipo',tipo,'dn',dn,'tubulacao',tubulacao,'codigo',codigo_do_documento,
          'responsavel',responsavel,'avanco',avanco_percentual,
          'endereco',public.proj_endereco(geom)))))
      from (
        select *, case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end cons
        from "7 - setorizacao".intervencoes_pontuais
      ) s
      where geom is not null
        and (p_consorcio is null or cons=p_consorcio)
        and (p_tipo is null or tipo=p_tipo)
        and (p_dmc is null or dmc=p_dmc)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'linhas', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom,4326))::jsonb,
        'properties', jsonb_build_object('gid',gid,'id',id,'projeto',projeto,'cidade',cidade,'consorcio',cons,
          'dmc',dmc,'tipo',tipo,'dn',coalesce(dn,dn_do_layer),'tubulacao',tubulacao,'codigo',codigo_do_documento,
          'responsavel',responsavel,'avanco',avanco_percentual,
          'layer_dwg',layer_dwg,'extensao_m',extensao_m,
          'endereco',public.proj_endereco(geom)))))
      from (
        select *, case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end cons
        from "7 - setorizacao".intervencoes_lineares
      ) s
      where geom is not null
        and (p_consorcio is null or cons=p_consorcio or cons is null)
        and (p_tipo is null or tipo=p_tipo or tipo is null)
        and (p_dmc is null or dmc=p_dmc or dmc is null)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'limites', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(geom, 30), 4326))::jsonb,
        'properties', jsonb_build_object('consorcio', consorcio, 'nome', no_zona))))
      from "1 - suporte_geografico".limite_za
      where (p_consorcio is null or consorcio=p_consorcio)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'dmcs', coalesce((
      select jsonb_build_object('type','FeatureCollection','features', jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(geom, 15), 4326))::jsonb,
        'properties', jsonb_build_object('codigo', codigo_dmc, 'numero', numero_dmc, 'consorcio', consorcio))))
      from "7 - setorizacao".dmc
      where coalesce(ativo,true) and (p_consorcio is null or consorcio=p_consorcio)
    ), jsonb_build_object('type','FeatureCollection','features',jsonb_build_array())),
    'resumo', (
      with p as (select *, case when cidade ilike 'BETIM%' then 'ZA0200' when cidade ilike 'CONTAGEM%' then 'ZA1004' end cons from "7 - setorizacao".intervencoes_pontuais)
      select jsonb_build_object(
        'n_pontos', count(*),
        'n_linhas', (select count(*) from "7 - setorizacao".intervencoes_lineares),
        'por_tipo', (select jsonb_object_agg(tipo,n) from (select tipo,count(*) n from p group by tipo) t),
        'por_cidade', (select jsonb_object_agg(cidade,n) from (select cidade,count(*) n from p group by cidade) t),
        'avanco_medio', round(avg(coalesce(avanco_percentual,0))::numeric,1)
      ) from p
    )
  );
end $function$;
