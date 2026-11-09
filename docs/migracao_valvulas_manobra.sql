-- =====================================================================
-- Cadastro técnico — camada "Válvulas de manobra" passa a vir dos NÓS
-- (2026-11-09)
--
-- Antes: a camada lia "2 - infra_agua".caixas_manobra = 448 POLÍGONOS de
-- caixa (tipo_co 12201/12202), só ZA1004, sem casar com nenhum nó — ou seja,
-- mostrava as caixas, não as válvulas.
-- Agora: view "2 - infra_agua".unidades_valvulas_manobra sobre nos_agua com
-- os prefixos REG, RGF, ALM e VBO (2.405 nós nas duas ZAs). Mesmo padrão de
-- unidades_hidrantes: acompanha sozinha a carga diária de nós (10_sync_nos.py).
--
-- O branch 'caixas_manobra' da RPC fica (apps em cache ≤ v335 ainda pedem);
-- o app novo pede 'valvulas_manobra'. A tabela caixas_manobra NÃO é apagada.
-- =====================================================================

create or replace view "2 - infra_agua".unidades_valvulas_manobra as
select id, consorcio, cd_no_agua, left(cd_no_agua,3) as tipo_valvula,
       objectid, tipo_co, simbolo, nome, funcao, estado, diametro, material,
       cota, referencia, fl_georref, geom
  from "2 - infra_agua".nos_agua
 where left(cd_no_agua,3) in ('REG','RGF','ALM','VBO');

comment on view "2 - infra_agua".unidades_valvulas_manobra is
  'Válvulas/registros de manobra = nos_agua com prefixo REG, RGF, ALM ou VBO. estado: A = aberta, F = fechada. Camada valvulas_manobra do Cadastro técnico (app_cadastro_geojson).';

-- mesma visibilidade dos demais objetos do schema 2 (leitura GIS)
grant select on "2 - infra_agua".unidades_valvulas_manobra to gis_visualizacao;

-- branch novo na RPC, inserido antes do branch antigo das caixas
do $mig$
declare d text; novo text;
begin
  d := pg_get_functiondef('public.app_cadastro_geojson'::regproc);
  if position('p_layer=''valvulas_manobra''' in d) > 0 then
    raise notice 'branch valvulas_manobra já existe';
    return;
  end if;
  novo := $b$elsif p_layer='valvulas_manobra' then
    -- válvulas/registros de manobra = nós REG/RGF/ALM/VBO (view unidades_valvulas_manobra). estado A/F → Aberta/Fechada.
    select jsonb_build_object('type','FeatureCollection','features',coalesce(jsonb_agg(f),'[]'::jsonb)) into result from (
      select jsonb_build_object('type','Feature','geometry',ST_AsGeoJSON(ST_Transform(t.geom,4326),6)::jsonb,
        'properties',jsonb_build_object('id',t.id,'consorcio',t.consorcio,'cd_no_agua',t.cd_no_agua,'tipo',t.tipo_valvula,
          'situacao',case t.estado when 'A' then 'Aberta' when 'F' then 'Fechada' else t.estado end,
          'diametro',t.diametro,'material',t.material,'cota',t.cota,'referencia',t.referencia)) f
      from "2 - infra_agua".unidades_valvulas_manobra t where t.geom && bbox limit p_limit) s;
  elsif p_layer='caixas_manobra' then$b$;
  if position('elsif p_layer=''caixas_manobra'' then' in d) = 0 then
    raise exception 'âncora do branch caixas_manobra não encontrada';
  end if;
  d := replace(d, 'elsif p_layer=''caixas_manobra'' then', novo);
  execute d;
end
$mig$;
