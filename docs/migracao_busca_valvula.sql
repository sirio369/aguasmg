-- =====================================================================
-- Cadastro técnico — busca "Válvula" (2026-11-09)
-- Branch 'valvulas_manobra' na app_cadastro_buscar: procura na view
-- "2 - infra_agua".unidades_valvulas_manobra (nós REG/RGF/ALM/VBO) pelo
-- código do nó (cd_no_agua — aceita só o número, ex. 1249821) ou pela referência.
-- =====================================================================
do $mig$
declare d text; novo text;
begin
  d := pg_get_functiondef('public.app_cadastro_buscar'::regproc);
  if position('p_layer=''valvulas_manobra''' in d) > 0 then
    raise notice 'branch valvulas_manobra já existe'; return;
  end if;
  novo := $b$elsif p_layer='valvulas_manobra' then
    select coalesce(jsonb_agg(f),'[]'::jsonb) into result from (
      select jsonb_build_object('lat',ST_Y(ST_Transform(t.geom,4326)),'lon',ST_X(ST_Transform(t.geom,4326)),
        'label','Válvula '||t.cd_no_agua||coalesce(' · DN '||t.diametro,'')||coalesce(' · '||case t.estado when 'A' then 'Aberta' when 'F' then 'Fechada' end,''),
        'props',jsonb_build_object('cd_no_agua',t.cd_no_agua,'tipo',t.tipo_valvula,
          'situacao',case t.estado when 'A' then 'Aberta' when 'F' then 'Fechada' else t.estado end,
          'diametro',t.diametro,'material',t.material,'cota',t.cota,'referencia',t.referencia,'consorcio',t.consorcio)) f
      from "2 - infra_agua".unidades_valvulas_manobra t
      where t.cd_no_agua ilike term or coalesce(t.referencia,'') ilike term
      order by t.cd_no_agua
      limit 25) s;
  elsif p_layer='rede' then$b$;
  if position('elsif p_layer=''rede'' then' in d) = 0 then
    raise exception 'âncora do branch rede não encontrada';
  end if;
  d := replace(d, 'elsif p_layer=''rede'' then', novo);
  execute d;
end
$mig$;
