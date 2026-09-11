-- ============================================================
-- PONTO DE RETORNO — Fase E "Segmentação de redes p/ Programação de Pesquisa"
-- Baseline: 2026-09-11, antes da fase E. pp_config = (tol_m=8, cov_pct=0.6,
-- max_ang_deg=35, min_len_m=12). programacao_pesquisa tinha 100 linhas reais
-- (Sander/ZA1004, 13 executado / 87 pendente), chave rede_id -> "2 - infra_agua".rede(id).
-- pesquisa_trecho tinha 7 trechos reais (não mexidos por esta fase, preservar).
--
-- Este rollback volta ao esquema de "1 programação = 1 rede inteira" (sem
-- segmentação) e restaura as 4 funções ao estado anterior. É uma aproximação
-- ao converter de volta segmento->rede (várias linhas de segmento por rede
-- viram 1 linha por rede; status='executado' só se TODOS os segmentos daquela
-- rede estavam executado, senão 'pendente') — não há como reconstruir o
-- histórico de cobertura fina após o rollback.
--
-- Rodar via mcp supabase apply_migration (name: rollback_fase_e_pp) ou psql.
-- ============================================================

begin;

-- 1. reconstrói programacao_pesquisa no formato antigo (1 linha por rede_id)
create temp table _pp_old as
select r.id as rede_id, pp.colaborador_uuid,
       min(pp.programado_por) as programado_por,
       min(pp.programado_em) as programado_em,
       r.consorcio, r.comprimento as comprimento_m,
       bool_and(pp.status='executado') as todos_executados,
       min(pp.executado_em) as executado_em
from "8 - coleta_campo".programacao_pesquisa pp
join "8 - coleta_campo".rede_pp_segmento s on s.id = pp.segmento_id
join "2 - infra_agua".rede r on r.id = s.rede_id
group by r.id, pp.colaborador_uuid, r.consorcio, r.comprimento;

alter table "8 - coleta_campo".programacao_pesquisa drop constraint if exists programacao_pesquisa_segmento_id_fkey;
alter table "8 - coleta_campo".programacao_pesquisa drop column if exists segmento_id;
alter table "8 - coleta_campo".programacao_pesquisa add column if not exists rede_id bigint;

truncate "8 - coleta_campo".programacao_pesquisa;
insert into "8 - coleta_campo".programacao_pesquisa
  (rede_id, consorcio, colaborador_uuid, programado_por, programado_em, comprimento_m, status, executado_em)
select rede_id, consorcio, colaborador_uuid, programado_por, programado_em, comprimento_m,
       case when todos_executados then 'executado' else 'pendente' end,
       case when todos_executados then executado_em else null end
from _pp_old;

alter table "8 - coleta_campo".programacao_pesquisa
  add constraint programacao_pesquisa_rede_id_key unique (rede_id),
  add constraint programacao_pesquisa_rede_id_fkey foreign key (rede_id) references "2 - infra_agua".rede(id);

-- 1b. view da vitrine volta a apontar direto pra rede (não mais pro segmento)
create or replace view "0 - vitrine_gis".vw_gis_programacao_pesquisa as
 SELECT pp.rede_id,
    pp.consorcio,
    pp.status,
    pe.nome AS colaborador,
    pp.programado_em,
    pp.executado_em,
    round(pp.comprimento_m, 1) AS comprimento_m,
    r.geom
   FROM "8 - coleta_campo".programacao_pesquisa pp
     JOIN "2 - infra_agua".rede r ON r.id = pp.rede_id
     LEFT JOIN perfil pe ON pe.id = pp.colaborador_uuid;

-- 2. dropa a segmentação
drop trigger if exists trg_rede_pp_segmentar on "2 - infra_agua".rede;
drop function if exists "8 - coleta_campo".trg_pp_segmentar_rede();
drop function if exists "8 - coleta_campo".pp_segmentar_um(bigint, boolean);
drop function if exists "8 - coleta_campo".pp_segmentar_todas(boolean);
drop table if exists "8 - coleta_campo".rede_pp_segmento;
drop table if exists "8 - coleta_campo".rede_pp_segmento_fonte;
alter table "8 - coleta_campo".pp_config drop column if exists seg_max_len_m;

-- 3. config volta ao valor anterior à Fase D/E
update "8 - coleta_campo".pp_config set tol_m=8, cov_pct=0.6, max_ang_deg=35, min_len_m=12, atualizado_em=now() where id=1;

-- 4. RPCs voltam à versão anterior (sem segmento, direto em "2 - infra_agua".rede)
create or replace function public.app_rede_bbox(p_xmin double precision, p_ymin double precision, p_xmax double precision, p_ymax double precision, p_consorcio text DEFAULT NULL::text, p_so_operacional boolean DEFAULT true, p_nao_pesquisado_desde date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tol numeric;
begin
  select tol_m into v_tol from "8 - coleta_campo".pp_config where id = 1;
  return (
    with bb as (select st_transform(st_makeenvelope(p_xmin,p_ymin,p_xmax,p_ymax,4326),31983) g),
    base as (
      select r.*,
             (select max(t.inicio_ts) from "8 - coleta_campo".pesquisa_trecho t
              where t.geom && st_expand(r.geom, v_tol) and st_dwithin(r.geom, t.geom, v_tol)) as ultima_pesquisa
      from bb, "2 - infra_agua".rede r
      where r.geom && bb.g and st_intersects(r.geom, bb.g)
        and (p_consorcio is null or r.consorcio = p_consorcio)
        and (not p_so_operacional or r.situacao = 'O')
    )
    select jsonb_build_object('type','FeatureCollection','features',
      coalesce(jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', st_asgeojson(st_transform(st_simplify(b.geom,1.0),4326))::jsonb,
        'properties', jsonb_build_object(
          'id',b.id,'nu_trecho',b.nu_trecho,'material',b.material,'diametro',b.diametro,
          'comprimento',round(b.comprimento::numeric,1),
          'ultima_pesquisa', b.ultima_pesquisa,
          'programado_para',(select pe.nome from "8 - coleta_campo".programacao_pesquisa pp
                             join public.perfil pe on pe.id=pp.colaborador_uuid where pp.rede_id=b.id),
          'pp_status',(select pp.status from "8 - coleta_campo".programacao_pesquisa pp where pp.rede_id=b.id)))),
      '[]'::jsonb))
    from base b
    where p_nao_pesquisado_desde is null
       or b.ultima_pesquisa is null
       or b.ultima_pesquisa::date < p_nao_pesquisado_desde
    limit 4000
  );
end; $function$;

create or replace function public.app_pp_rede_no_poligono(p_polygon_geojson text, p_consorcio text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fun text; v_g geometry;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(auth.uid()),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  v_g := st_transform(
           st_makevalid(st_force2d(st_setsrid(st_geomfromgeojson(p_polygon_geojson), 4326))),
           31983);
  return (
    select jsonb_build_object('type','FeatureCollection','features',
      coalesce(jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', st_asgeojson(st_transform(r.geom,4326))::jsonb,
        'properties', jsonb_build_object(
          'id',r.id,'nu_trecho',r.nu_trecho,'material',r.material,
          'comprimento',round(r.comprimento::numeric,1),
          'programado_para',(select pe.nome from "8 - coleta_campo".programacao_pesquisa pp
                             join public.perfil pe on pe.id=pp.colaborador_uuid where pp.rede_id=r.id),
          'pp_status',(select pp.status from "8 - coleta_campo".programacao_pesquisa pp where pp.rede_id=r.id)))),
      '[]'::jsonb))
    from "2 - infra_agua".rede r
    where r.geom && v_g and st_intersects(r.geom, v_g) and r.situacao='O'
      and (p_consorcio is null or r.consorcio=p_consorcio)
    limit 3000
  );
end; $function$;

create or replace function public.app_pp_atribuir(p_rede_ids bigint[], p_colaborador uuid, p_sobrescrever boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fun text; v_uid uuid := auth.uid(); v_ins int; v_skip int;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(v_uid),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  if p_colaborador is null then raise exception 'colaborador obrigatorio'; end if;

  with alvo as (
    select r.id rede_id, r.consorcio, r.comprimento
    from "2 - infra_agua".rede r
    where r.id = any(p_rede_ids)
  ),
  ups as (
    insert into "8 - coleta_campo".programacao_pesquisa
      (rede_id, consorcio, colaborador_uuid, programado_por, comprimento_m)
    select a.rede_id, a.consorcio, p_colaborador, v_uid, a.comprimento from alvo a
    on conflict (rede_id) do update
      set colaborador_uuid = excluded.colaborador_uuid,
          programado_por   = excluded.programado_por,
          programado_em    = now(),
          status = 'pendente', coberto_m = 0, primeiro_trecho_id = null, executado_em = null
      where p_sobrescrever
    returning 1
  )
  select count(*) into v_ins from ups;
  v_skip := coalesce(array_length(p_rede_ids,1),0) - v_ins;
  return jsonb_build_object('atribuidos', v_ins, 'ignorados', v_skip);
end; $function$;

create or replace function public.app_pp_desatribuir(p_rede_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fun text; v_n int;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(auth.uid()),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  delete from "8 - coleta_campo".programacao_pesquisa where rede_id = any(p_rede_ids);
  get diagnostics v_n = row_count;
  return jsonb_build_object('removidos', v_n);
end; $function$;

create or replace function public.app_pp_por_colaborador(p_colaborador uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_fun text;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(auth.uid()),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  return jsonb_build_object(
    'type','FeatureCollection',
    'features', coalesce((select jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', st_asgeojson(st_transform(r.geom,4326))::jsonb,
        'properties', jsonb_build_object(
          'id', r.id, 'nu_trecho', r.nu_trecho,
          'comprimento', round(r.comprimento::numeric,1),
          'pp_status', pp.status, 'executado_em', pp.executado_em)))
      from "8 - coleta_campo".programacao_pesquisa pp
      join "2 - infra_agua".rede r on r.id = pp.rede_id
      where pp.colaborador_uuid = p_colaborador), '[]'::jsonb));
end; $function$;

create or replace function public.app_pp_minhas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'type','FeatureCollection',
    'n_pendentes',(select count(*) from "8 - coleta_campo".programacao_pesquisa where colaborador_uuid=auth.uid() and status='pendente'),
    'km_pendente',(select round((coalesce(sum(comprimento_m),0)/1000.0)::numeric,2) from "8 - coleta_campo".programacao_pesquisa where colaborador_uuid=auth.uid() and status='pendente'),
    'features', coalesce((select jsonb_agg(jsonb_build_object(
        'type','Feature',
        'geometry', st_asgeojson(st_transform(r.geom,4326))::jsonb,
        'properties', jsonb_build_object('rede_id',r.id,'nu_trecho',r.nu_trecho,'comprimento',round(r.comprimento::numeric,1))))
      from "8 - coleta_campo".programacao_pesquisa pp
      join "2 - infra_agua".rede r on r.id = pp.rede_id
      where pp.colaborador_uuid = auth.uid() and pp.status = 'pendente'), '[]'::jsonb));
$function$;

create or replace function public.app_pp_mapa(p_colaborador uuid DEFAULT NULL::uuid, p_consorcio text DEFAULT NULL::text, p_data_ini date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date, p_usuario text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_nome text; v_uid uuid;
begin
  if p_colaborador is not null then
    v_uid := p_colaborador;
    select nome into v_nome from public.perfil where id = p_colaborador;
  elsif p_usuario is not null and p_usuario <> '' then
    v_nome := p_usuario;
    select id into v_uid from public.perfil where nome = p_usuario limit 1;
  end if;
  return jsonb_build_object(
    'cadastro_pendente', (
      select jsonb_build_object('type','FeatureCollection','features', coalesce(jsonb_agg(jsonb_build_object(
        'type','Feature','geometry',st_asgeojson(st_transform(r.geom,4326))::jsonb,
        'properties',jsonb_build_object('rede_id',r.id,'nu_trecho',r.nu_trecho,'comprimento',round(r.comprimento::numeric,1)))),'[]'::jsonb))
      from "8 - coleta_campo".programacao_pesquisa pp join "2 - infra_agua".rede r on r.id=pp.rede_id
      where pp.status='pendente'
        and (v_uid is null or pp.colaborador_uuid=v_uid)
        and (p_consorcio is null or pp.consorcio=p_consorcio)),
    'cadastro_executado', (
      select jsonb_build_object('type','FeatureCollection','features', coalesce(jsonb_agg(jsonb_build_object(
        'type','Feature','geometry',st_asgeojson(st_transform(r.geom,4326))::jsonb,
        'properties',jsonb_build_object('rede_id',r.id,'nu_trecho',r.nu_trecho,'executado_em',pp.executado_em))),'[]'::jsonb))
      from "8 - coleta_campo".programacao_pesquisa pp join "2 - infra_agua".rede r on r.id=pp.rede_id
      where pp.status='executado'
        and (v_uid is null or pp.colaborador_uuid=v_uid)
        and (p_consorcio is null or pp.consorcio=p_consorcio)
        and (p_data_ini is null or pp.executado_em::date >= p_data_ini)
        and (p_data_fim is null or pp.executado_em::date <= p_data_fim)),
    'reportes_campo', (
      select jsonb_build_object('type','FeatureCollection','features', coalesce(jsonb_agg(jsonb_build_object(
        'type','Feature','geometry',st_asgeojson(st_transform(t.geom,4326))::jsonb,
        'properties',jsonb_build_object('id',t.id,'usuario',t.usuario,'metros',round(t.comprimento_m::numeric,1),'inicio',t.inicio_ts))),'[]'::jsonb))
      from "8 - coleta_campo".pesquisa_trecho t
      where (v_nome is null or t.usuario = v_nome)
        and (p_consorcio is null or t.consorcio = p_consorcio)
        and (p_data_ini is null or t.inicio_ts::date >= p_data_ini)
        and (p_data_fim is null or t.inicio_ts::date <= p_data_fim)),
    'kpis', (
      select jsonb_build_object(
        'km_programado', round((coalesce(sum(comprimento_m),0)/1000.0)::numeric,2),
        'km_executado',  round((coalesce(sum(comprimento_m) filter (where status='executado'),0)/1000.0)::numeric,2),
        'n_pendentes',   count(*) filter (where status='pendente'),
        'pct_cobertura', case when sum(comprimento_m)>0 then round((sum(comprimento_m) filter (where status='executado')/sum(comprimento_m)*100)::numeric,1) else 0 end)
      from "8 - coleta_campo".programacao_pesquisa
      where (v_uid is null or colaborador_uuid=v_uid)
        and (p_consorcio is null or consorcio=p_consorcio)));
end; $function$;

create or replace function "8 - coleta_campo".pp_cruzar_trecho()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tol numeric; v_ids bigint[];
begin
  if new.geom is null then return null; end if;
  select tol_m into v_tol from "8 - coleta_campo".pp_config where id = 1;
  select array_agg(pp.rede_id) into v_ids
  from "8 - coleta_campo".programacao_pesquisa pp
  join "2 - infra_agua".rede r on r.id = pp.rede_id
  where st_dwithin(r.geom, new.geom, v_tol + 60);
  if v_ids is not null then perform "8 - coleta_campo".pp_recompute(v_ids); end if;
  return null;
end;
$function$;

create or replace function "8 - coleta_campo".pp_recompute(p_rede_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tol numeric; v_cov numeric; v_ang numeric; v_min numeric; v_loop int := 0;
begin
  select tol_m, cov_pct, max_ang_deg, min_len_m into v_tol, v_cov, v_ang, v_min
  from "8 - coleta_campo".pp_config where id = 1;

  update "8 - coleta_campo".programacao_pesquisa pp
     set coberto_m = 0, status = 'pendente', executado_em = null, primeiro_trecho_id = null
   where (p_rede_ids is null or pp.rede_id = any(p_rede_ids));

  update "8 - coleta_campo".programacao_pesquisa pp
     set coberto_m = coalesce(x.cob, 0),
         primeiro_trecho_id = x.primeiro
  from (
    select pp2.rede_id,
           coalesce(st_length(st_union(d.g) filter (where d.dang <= radians(v_ang))), 0) as cob,
           (array_agg(d.tid order by d.tini))[1] as primeiro
    from "8 - coleta_campo".programacao_pesquisa pp2
    join "2 - infra_agua".rede r on r.id = pp2.rede_id
    join "8 - coleta_campo".pesquisa_trecho t on st_dwithin(r.geom, t.geom, v_tol)
    cross join lateral (
      select dd.geom g, t.id tid, t.inicio_ts tini,
             least(m.mm, pi() - m.mm) as dang
      from st_dump(st_linemerge(st_intersection(st_buffer(t.geom, v_tol), r.geom))) dd
      cross join lateral (select
        ( st_azimuth(st_startpoint(dd.geom), st_endpoint(dd.geom))
        - st_azimuth(st_startpoint(t.geom),  st_endpoint(t.geom)) + 100*pi() ) as a) q
      cross join lateral (select (q.a - pi() * floor(q.a / pi())) as mm) m
      where st_geometrytype(dd.geom) = 'ST_LineString' and st_length(dd.geom) >= 1
    ) d
    where (p_rede_ids is null or pp2.rede_id = any(p_rede_ids))
    group by pp2.rede_id
  ) x
  where x.rede_id = pp.rede_id;

  update "8 - coleta_campo".programacao_pesquisa pp
     set status = 'executado', executado_em = now()
  from "2 - infra_agua".rede r
  where r.id = pp.rede_id
    and (p_rede_ids is null or pp.rede_id = any(p_rede_ids))
    and pp.status = 'pendente'
    and coalesce(pp.comprimento_m,0) > 0
    and pp.coberto_m / pp.comprimento_m >=
        case when coalesce(r.comprimento,0) >= v_min then v_cov else 0.90 end;

  loop
    v_loop := v_loop + 1;
    update "8 - coleta_campo".programacao_pesquisa pp
       set status = 'executado', executado_em = now()
    from "2 - infra_agua".rede rp
    where rp.id = pp.rede_id
      and (p_rede_ids is null or pp.rede_id = any(p_rede_ids))
      and pp.status = 'pendente'
      and coalesce(rp.comprimento,0) < v_min
      and exists (
        select 1 from "8 - coleta_campo".programacao_pesquisa nb
        join "2 - infra_agua".rede rn on rn.id = nb.rede_id
        where nb.status = 'executado' and rp.no_agua_ini is not null and rp.no_agua_fim is not null
          and ( rn.no_agua_ini in (rp.no_agua_ini, rp.no_agua_fim)
             or rn.no_agua_fim in (rp.no_agua_ini, rp.no_agua_fim) ));
    exit when not found or v_loop >= 5;
  end loop;
end;
$function$;

drop temp table if exists _pp_old;

commit;

notify pgrst, 'reload schema';

-- confirmação pós-rollback (rodar em transação separada):
-- select count(*) filter (where status='executado') ex, count(*) filter (where status='pendente') pe
--   from "8 - coleta_campo".programacao_pesquisa;
-- esperado: 13 executado / 87 pendente (mesmo total de antes da Fase E, aproximado
-- pela regra "todos os segmentos executados" acima).
