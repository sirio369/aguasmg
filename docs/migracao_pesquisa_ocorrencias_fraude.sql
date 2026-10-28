-- Pesquisa de vazamentos — ocorrências de fraude + quadros no Acompanhamento + consórcio pelo ponto. 2026-10-27.
-- 1) app_ocorrencia_registrar: consórcio = ZA do limite_za que contém o ponto → p_consorcio → perfil.consorcio
--    (mesmo bug do Pavimento/Solicitação: o app manda o localStorage 'consorcio', que só a Pressão grava →
--    8 de 19 ocorrências estavam na ZA errada). Backfill com backup das chaves.
-- 2) app_ocorrencia_fila / app_pp_passadas_bbox: devolvem usuario_nome (perfil) e, no mapa, foto e local.
-- 3) app_pp_acompanhamento: "vazamentos" (KPI + resumo) deixa de contar fraude (tipo 'Fraude - …') e ganha
--    'ocorrencias' = contagem por colaborador × tipo (alimenta os quadros "Vazamentos" e "Ocorrências reportadas").
-- Regra única: vazamento = ocorrência cujo tipo NÃO começa com 'Fraude' (o 'Outro' antigo segue como vazamento).
-- Idempotente; mesmas assinaturas (mantém grants).

-- 1) gravação
create or replace function public.app_ocorrencia_registrar(p_id uuid DEFAULT gen_random_uuid(), p_pesquisa_id uuid DEFAULT NULL::uuid,
  p_origem text DEFAULT 'pesquisa'::text, p_tipo text DEFAULT NULL::text, p_local text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text,
  p_foto text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lon double precision DEFAULT NULL::double precision,
  p_precisao numeric DEFAULT NULL::numeric, p_consorcio text DEFAULT NULL::text, p_dispositivo text DEFAULT NULL::text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
declare v_user text; v_ts timestamp; v_geom geometry; v_cons text;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if p_lat is null or p_lon is null then raise exception 'coordenadas obrigatorias ausentes'; end if;
  v_user := coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name', auth.jwt() ->> 'email');
  v_ts := (now() at time zone 'America/Sao_Paulo');
  v_geom := ST_Transform(ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326),31983);
  -- consórcio do PONTO (limite da ZA) → senão o que o app mandou → senão o do perfil
  v_cons := coalesce(
    (select z.consorcio from "1 - suporte_geografico".limite_za z
      where st_intersects(z.geom, st_transform(v_geom, st_srid(z.geom))) limit 1),
    nullif(btrim(p_consorcio),''), (select consorcio from public.perfil where id=auth.uid()));
  insert into "8 - coleta_campo".ocorrencia
    (id, pesquisa_id, origem, consorcio, usuario, data_hora, tipo, local_ref, observacao, foto,
     gps_precisao, lat, lon, dispositivo, geom)
  values
    (p_id, p_pesquisa_id, coalesce(nullif(p_origem,''),'pesquisa'), v_cons, v_user, v_ts,
     p_tipo, p_local, p_observacao, p_foto,
     p_precisao, p_lat, p_lon, p_dispositivo, v_geom)
  on conflict (id) do nothing;
  return p_id;
end $function$;

-- backfill (backup só da chave; reverter: update ... o set consorcio=b.consorcio from <bkp> b where b.id=o.id)
create table if not exists "8 - coleta_campo"._bkp_ocorrencia_consorcio_20261027 as
  select o.id, o.consorcio from "8 - coleta_campo".ocorrencia o
  where o.consorcio is distinct from (select z.consorcio from "1 - suporte_geografico".limite_za z
      where o.geom is not null and st_intersects(z.geom, st_transform(o.geom, st_srid(z.geom))) limit 1)
    and exists (select 1 from "1 - suporte_geografico".limite_za z
      where o.geom is not null and st_intersects(z.geom, st_transform(o.geom, st_srid(z.geom))));
alter table "8 - coleta_campo"._bkp_ocorrencia_consorcio_20261027 enable row level security;
revoke all on "8 - coleta_campo"._bkp_ocorrencia_consorcio_20261027 from public, anon, authenticated;
update "8 - coleta_campo".ocorrencia o set consorcio = (select z.consorcio from "1 - suporte_geografico".limite_za z
      where st_intersects(z.geom, st_transform(o.geom, st_srid(z.geom))) limit 1)
  where o.id in (select id from "8 - coleta_campo"._bkp_ocorrencia_consorcio_20261027);

-- 2a) fila da abertura de serviços — + usuario_nome
create or replace function public.app_ocorrencia_fila(p_filtro text DEFAULT 'pendente'::text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select case when coalesce("9 - suprimentos".sup_funcao(auth.uid()),'') not in ('aprovador','admin') then '[]'::jsonb else
  coalesce((select jsonb_agg(jsonb_build_object(
     'id',o.id,'tipo',o.tipo,'local',o.local_ref,'consorcio',o.consorcio,'observacao',o.observacao,
     'foto',o.foto,'lat',o.lat,'lon',o.lon,'data_hora',o.data_hora,'usuario',o.usuario,'usuario_nome',pu.nome,'origem',o.origem,
     'os_numero',o.os_numero,'os_criada_em',o.os_criada_em,'os_por',pe.nome) order by o.data_hora desc)
   from "8 - coleta_campo".ocorrencia o
   left join public.perfil pe on pe.id=o.os_por
   left join lateral (select p.nome from public.perfil p where o.usuario in (p.nome, p.email) limit 1) pu on true
   where (p_filtro='todas' or (p_filtro='pendente' and o.os_numero is null) or (p_filtro='criada' and o.os_numero is not null))
  ),'[]'::jsonb) end;
$function$;

-- 2b) mapa do Acompanhamento — ocorrências com foto/local/usuario_nome (popup)
create or replace function public.app_pp_passadas_bbox(p_xmin double precision, p_ymin double precision, p_xmax double precision, p_ymax double precision,
  p_consorcio text DEFAULT NULL::text, p_colaborador uuid DEFAULT NULL::uuid, p_data_ini date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fun text; v_nome text; v_email text; v_g geometry;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(auth.uid()),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  if p_colaborador is not null then select nome, email into v_nome, v_email from public.perfil where id=p_colaborador; end if;
  v_g := st_transform(st_makeenvelope(p_xmin,p_ymin,p_xmax,p_ymax,4326),31983);
  return jsonb_build_object(
    'passadas', (
      with cnt as (select segmento_id, count(*) np from "8 - coleta_campo".pp_execucao where segmento_id is not null group by segmento_id),
      base as (
        select s.id, s.geom, coalesce(c.np,0) np
        from "8 - coleta_campo".rede_pp_segmento s
        join "2 - infra_agua".rede r on r.id = s.rede_id
        left join cnt c on c.segmento_id = s.id
        where s.geom && v_g and st_intersects(s.geom, v_g) and r.situacao='O'
          and (p_consorcio is null or r.consorcio = p_consorcio)
        limit 12000)
      select jsonb_build_object('type','FeatureCollection','features',
        coalesce(jsonb_agg(jsonb_build_object('type','Feature',
          'geometry', st_asgeojson(st_transform(b.geom,4326))::jsonb,
          'properties', jsonb_build_object('n_passada', b.np))),'[]'::jsonb))
      from base b),
    'reportes', (
      select jsonb_build_object('type','FeatureCollection','features',
        coalesce(jsonb_agg(jsonb_build_object('type','Feature',
          'geometry', st_asgeojson(st_transform(t.geom,4326))::jsonb,
          'properties', jsonb_build_object('id',t.id,'usuario',t.usuario,'metros',round(t.comprimento_m::numeric,1),'inicio',t.inicio_ts))),'[]'::jsonb))
      from "8 - coleta_campo".pesquisa_trecho t
      where t.geom && v_g
        and (p_colaborador is null or t.usuario in (v_nome, v_email))
        and (p_consorcio is null or t.consorcio = p_consorcio)
        and (p_data_ini is null or t.inicio_ts::date >= p_data_ini)
        and (p_data_fim is null or t.inicio_ts::date <= p_data_fim)),
    'ocorrencias', (
      select jsonb_build_object('type','FeatureCollection','features',
        coalesce(jsonb_agg(jsonb_build_object('type','Feature',
          'geometry', st_asgeojson(st_transform(o.geom,4326))::jsonb,
          'properties', jsonb_build_object('id',o.id,'tipo',o.tipo,'usuario',o.usuario,'usuario_nome',pu.nome,'data',o.data_hora,
            'os',o.os_numero,'foto',o.foto,'local',o.local_ref))),'[]'::jsonb))
      from "8 - coleta_campo".ocorrencia o
      left join lateral (select p.nome from public.perfil p where o.usuario in (p.nome, p.email) limit 1) pu on true
      where o.geom is not null and o.geom && v_g
        and (p_colaborador is null or o.usuario in (v_nome, v_email))
        and (p_consorcio is null or o.consorcio = p_consorcio)
        and (p_data_ini is null or o.data_hora::date >= p_data_ini)
        and (p_data_fim is null or o.data_hora::date <= p_data_fim)));
end; $function$;

-- 3) Acompanhamento — vazamentos sem fraude + contagem por colaborador × tipo
create or replace function public.app_pp_acompanhamento(p_consorcio text DEFAULT NULL::text, p_colaborador uuid DEFAULT NULL::uuid,
  p_data_ini date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fun text; v_nome text; v_email text;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(auth.uid()),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  if p_colaborador is not null then select nome, email into v_nome, v_email from public.perfil where id=p_colaborador; end if;

  return jsonb_build_object(
    'kpis', (
      with rede_exec as (
        select coalesce(sum(coalesce(e.comprimento_m, st_length(e.geom))),0) m
        from "8 - coleta_campo".pp_execucao e
        left join "2 - infra_agua".rede r on r.id = e.rede_id
        where (p_colaborador is null or e.colaborador_uuid = p_colaborador)
          and (p_consorcio is null or r.consorcio = p_consorcio)
          and (p_data_ini is null or e.executado_em::date >= p_data_ini)
          and (p_data_fim is null or e.executado_em::date <= p_data_fim)),
      andado as (
        select coalesce(sum(t.comprimento_m),0) m, coalesce(sum(t.duracao_s),0) s
        from "8 - coleta_campo".pesquisa_trecho t
        where (p_colaborador is null or t.usuario in (v_nome, v_email))
          and (p_consorcio is null or t.consorcio = p_consorcio)
          and (p_data_ini is null or t.inicio_ts::date >= p_data_ini)
          and (p_data_fim is null or t.inicio_ts::date <= p_data_fim)),
      vaz as (
        select count(*) n from "8 - coleta_campo".ocorrencia o
        where coalesce(o.tipo,'') not ilike 'fraude%'
          and (p_colaborador is null or o.usuario in (v_nome, v_email))
          and (p_consorcio is null or o.consorcio = p_consorcio)
          and (p_data_ini is null or o.data_hora::date >= p_data_ini)
          and (p_data_fim is null or o.data_hora::date <= p_data_fim))
      select jsonb_build_object(
        'km_rede_pesquisado', round((rede_exec.m/1000.0)::numeric,2),
        'km_andado', round((andado.m/1000.0)::numeric,2),
        'vazamentos', vaz.n,
        'vaz_km', case when rede_exec.m>0 then round((vaz.n/(rede_exec.m/1000.0))::numeric,2) else 0 end,
        'velocidade_kmh', case when andado.s>0 then round(((andado.m/1000.0)/(andado.s/3600.0))::numeric,2) else 0 end)
      from rede_exec, andado, vaz),
    'progresso_passadas', (
      with cnt as (select segmento_id, count(*) np from "8 - coleta_campo".pp_execucao where segmento_id is not null group by segmento_id),
      segb as (
        select least(coalesce(c.np,0),5) as bucket, coalesce(s.comprimento_m, st_length(s.geom)) as len
        from "8 - coleta_campo".rede_pp_segmento s
        join "2 - infra_agua".rede r on r.id = s.rede_id
        left join cnt c on c.segmento_id = s.id
        where r.situacao='O' and (p_consorcio is null or r.consorcio = p_consorcio)),
      agg as (select bucket, count(*) n, round((sum(len)/1000.0)::numeric,2) km from segb group by bucket)
      select coalesce(jsonb_agg(jsonb_build_object('passada', g.b, 'n_segmentos', coalesce(a.n,0), 'km', coalesce(a.km,0)) order by g.b),'[]'::jsonb)
      from generate_series(0,5) g(b) left join agg a on a.bucket = g.b),
    'resumo', (
      with univ as (
        select distinct e.colaborador_uuid u from "8 - coleta_campo".pp_execucao e left join "2 - infra_agua".rede r on r.id=e.rede_id where e.colaborador_uuid is not null and (p_consorcio is null or r.consorcio = p_consorcio)
        union
        select distinct pp.colaborador_uuid from "8 - coleta_campo".programacao_pesquisa pp where pp.colaborador_uuid is not null and (p_consorcio is null or pp.consorcio = p_consorcio))
      select coalesce(jsonb_agg(jsonb_build_object(
        'nome', pe.nome,
        'km_rede_pesquisado', ke.km,
        'km_andado', round((an.m/1000.0)::numeric,2),
        'vazamentos', vz.n,
        'vaz_km', case when ke.km>0 then round((vz.n/ke.km)::numeric,2) else 0 end,
        'velocidade_kmh', case when an.s>0 then round(((an.m/1000.0)/(an.s/3600.0))::numeric,2) else 0 end) order by pe.nome), '[]'::jsonb)
      from univ join public.perfil pe on pe.id = univ.u
      cross join lateral (
        select round((coalesce(sum(coalesce(e.comprimento_m,st_length(e.geom))),0)/1000.0)::numeric,2) km
        from "8 - coleta_campo".pp_execucao e left join "2 - infra_agua".rede r on r.id=e.rede_id
        where e.colaborador_uuid=univ.u and (p_consorcio is null or r.consorcio=p_consorcio)
          and (p_data_ini is null or e.executado_em::date>=p_data_ini) and (p_data_fim is null or e.executado_em::date<=p_data_fim)) ke
      cross join lateral (
        select count(*) n from "8 - coleta_campo".ocorrencia o
        where o.usuario in (pe.nome, pe.email) and coalesce(o.tipo,'') not ilike 'fraude%'
          and (p_consorcio is null or o.consorcio=p_consorcio)
          and (p_data_ini is null or o.data_hora::date>=p_data_ini) and (p_data_fim is null or o.data_hora::date<=p_data_fim)) vz
      cross join lateral (
        select coalesce(sum(t.comprimento_m),0) m, coalesce(sum(t.duracao_s),0) s from "8 - coleta_campo".pesquisa_trecho t
        where t.usuario in (pe.nome, pe.email) and (p_consorcio is null or t.consorcio=p_consorcio)
          and (p_data_ini is null or t.inicio_ts::date>=p_data_ini) and (p_data_fim is null or t.inicio_ts::date<=p_data_fim)) an),
    -- quadros "Vazamentos" e "Ocorrências reportadas": quem reportou × tipo (o front pivota)
    'ocorrencias', (
      select coalesce(jsonb_agg(jsonb_build_object('nome', x.nome, 'tipo', x.tipo, 'n', x.n, 'com_os', x.com_os) order by x.nome, x.tipo), '[]'::jsonb)
      from (
        select coalesce(pu.nome, o.usuario, '—') nome, coalesce(o.tipo,'—') tipo, count(*) n, count(o.os_numero) com_os
        from "8 - coleta_campo".ocorrencia o
        left join lateral (select p.nome from public.perfil p where o.usuario in (p.nome, p.email) limit 1) pu on true
        where (p_colaborador is null or o.usuario in (v_nome, v_email))
          and (p_consorcio is null or o.consorcio = p_consorcio)
          and (p_data_ini is null or o.data_hora::date >= p_data_ini)
          and (p_data_fim is null or o.data_hora::date <= p_data_fim)
        group by 1, 2) x)
  );
end; $function$;
