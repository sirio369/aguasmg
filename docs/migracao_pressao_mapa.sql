-- Mapeamento de pressão: tela inicial em mapa (2026-11-17, sw v407) — JÁ APLICADA no projeto.
-- DMCs oficiais (camada única "7 - setorizacao".dmc, só os vigentes) p/ ligar/desligar no mapa
create or replace function public.app_pressao_dmcs()
returns jsonb language sql stable security definer
set search_path to 'public','extensions' as $$
  select jsonb_build_object('type','FeatureCollection','features', coalesce(jsonb_agg(jsonb_build_object(
    'type','Feature',
    'properties', jsonb_build_object('id',d.id,'consorcio',d.consorcio,'codigo',d.codigo_dmc,'cod_za',d.cod_dmc_za),
    'geometry', ST_AsGeoJSON(ST_Transform(ST_SimplifyPreserveTopology(d.geom,2),4326),6)::jsonb
  ) order by d.consorcio, d.codigo_dmc), '[]'::jsonb))
  from "7 - setorizacao".dmc d
  where d.ativo and d.vigencia_fim is null and d.geom is not null;
$$;
revoke all on function public.app_pressao_dmcs() from public, anon;
grant execute on function public.app_pressao_dmcs() to authenticated;

-- Pressões aferidas nas últimas N horas (padrão 36h), de TODOS os usuários
create or replace function public.app_pressao_recentes(p_horas int default 36)
returns jsonb language sql stable security definer
set search_path to 'public','extensions' as $$
  with g as (
    select m.*, coalesce(pf.nome, m.usuario) as coletor,
      (select d.codigo_dmc from "7 - setorizacao".dmc d
        where d.ativo and d.vigencia_fim is null and ST_Intersects(d.geom, m.geom) limit 1) as dmc
    from "8 - coleta_campo".mapeamento_pressao m
    left join public.perfil pf on lower(pf.email)=lower(m.usuario)
    where m.created_at >= now() - make_interval(hours => greatest(1, least(coalesce(p_horas,36), 168)))
      and m.geom is not null
  )
  select jsonb_build_object('type','FeatureCollection','features', coalesce(jsonb_agg(jsonb_build_object(
    'type','Feature',
    'geometry', ST_AsGeoJSON(ST_Transform(geom,4326),7)::jsonb,
    'properties', jsonb_build_object(
      'id',id,'pressao',pressao_mca,'cota',cota_m,'consorcio',consorcio,'dmc',dmc,
      'numero_hd',numero_hd,'foto',foto,'coletor',coletor,
      'quando', created_at,
      'data', to_char(created_at at time zone 'America/Sao_Paulo','DD/MM HH24:MI'))
  ) order by created_at), '[]'::jsonb))
  from g;
$$;
revoke all on function public.app_pressao_recentes(int) from public, anon;
grant execute on function public.app_pressao_recentes(int) to authenticated;
