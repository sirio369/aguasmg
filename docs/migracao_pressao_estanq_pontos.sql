-- Mapeamento de pressão: pontos sugeridos p/ teste de estanqueidade do DMC escolhido (2026-11-17, sw v409) — JÁ APLICADA.
CREATE OR REPLACE FUNCTION public.app_pressao_estanq_pontos(p_dmc text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
-- Pontos sugeridos p/ teste de estanqueidade de um DMC (2026-11-17). Cada trecho de rede com uma ponta dentro e
-- outra fora do DMC é uma ligação com o vizinho; cruzamentos a ≤30 m viram um "par". Para cada par: a ligação
-- ativa (R) mais próxima DENTRO e FORA (do próprio trecho que cruza até 250 m, ou de outro trecho até 60 m; ≥5 m do
-- limite). Sem ligação num lado → ponto na rede a ≥10 m do limite e ≤120 m do cruzamento (tipo 'rede': medir em hidrante/registro).
-- + válvula de manobra mais próxima do cruzamento (≤40 m).
declare v_geom geometry; v_b geometry; v_cons text; r jsonb;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  select d.geom, ST_Boundary(d.geom), d.consorcio into v_geom, v_b, v_cons
    from "7 - setorizacao".dmc d where d.cod_dmc_za=p_dmc and d.ativo and d.vigencia_fim is null limit 1;
  if v_geom is null then return jsonb_build_object('pares','[]'::jsonb); end if;
  with cr as (
    select t.nu_trecho, t.diametro, t.material, t.geom as lg,
           ST_GeometryN(ST_Multi(ST_Intersection(t.geom, v_b)),1) as pt
    from "2 - infra_agua".rede t
    where t.geom && v_b and ST_Intersects(t.geom, v_b)
      and ST_Contains(v_geom, ST_StartPoint(ST_LineMerge(t.geom))) <> ST_Contains(v_geom, ST_EndPoint(ST_LineMerge(t.geom)))
  ), cr2 as (
    select *, ST_ClusterDBSCAN(pt, 30, 1) over () as cl from cr where pt is not null and GeometryType(pt)='POINT'
  ), grp as (
    select cl, array_agg(nu_trecho) as trechos,
           (array_agg(pt order by diametro desc nulls last))[1] as pt,
           (array_agg(lg order by diametro desc nulls last))[1] as lg,
           max(diametro) as diametro,
           (array_agg(material order by diametro desc nulls last))[1] as material
    from cr2 group by cl
  ), par as (
    select row_number() over (order by ST_Azimuth(ST_Centroid(v_geom), g.pt)) as n, g.*,
      (select l from "3 - comercial".ligacoes l
        where l.situacao='R' and l.geom && ST_Expand(g.pt,250) and ST_DWithin(l.geom,g.pt,250)
          and ST_Contains(v_geom,l.geom) and ST_Distance(l.geom,v_b)>=5 and (l.nu_trecho = any(g.trechos) or ST_DWithin(l.geom,g.pt,60))
        order by (l.nu_trecho = any(g.trechos)) desc, l.geom <-> g.pt limit 1) as ld,
      (select l from "3 - comercial".ligacoes l
        where l.situacao='R' and l.geom && ST_Expand(g.pt,250) and ST_DWithin(l.geom,g.pt,250)
          and not ST_Contains(v_geom,l.geom) and ST_Distance(l.geom,v_b)>=5 and (l.nu_trecho = any(g.trechos) or ST_DWithin(l.geom,g.pt,60))
        order by (l.nu_trecho = any(g.trechos)) desc, l.geom <-> g.pt limit 1) as lf,
      (select jsonb_build_object('cd',v.cd_no_agua,'tipo',v.tipo_valvula,'estado',v.estado,'dn',v.diametro,'dist',round(ST_Distance(v.geom,g.pt)))
        from "2 - infra_agua".unidades_valvulas_manobra v
        where v.geom && ST_Expand(g.pt,40) and ST_DWithin(v.geom,g.pt,40) order by v.geom <-> g.pt limit 1) as valv,
      -- pontos na rede (fallback sem ligação): o mais próximo do cruzamento a ≥10 m do limite, ≤120 m (um de cada lado)
      (select ST_ClosestPoint(x.pc, g.pt) from (select ST_Intersection(t.geom, ST_Intersection(ST_Buffer(g.pt,120), ST_Buffer(v_geom,-10))) pc, t.nu_trecho
        from "2 - infra_agua".rede t where t.geom && ST_Expand(g.pt,120) and ST_DWithin(t.geom,g.pt,120)) x
       where not ST_IsEmpty(x.pc) order by (x.nu_trecho = any(g.trechos)) desc, ST_Distance(x.pc,g.pt) limit 1) as rd,
      (select ST_ClosestPoint(x.pc, g.pt) from (select ST_Intersection(t.geom, ST_Difference(ST_Buffer(g.pt,120), ST_Buffer(v_geom,10))) pc, t.nu_trecho
        from "2 - infra_agua".rede t where t.geom && ST_Expand(g.pt,120) and ST_DWithin(t.geom,g.pt,120)) x
       where not ST_IsEmpty(x.pc) order by (x.nu_trecho = any(g.trechos)) desc, ST_Distance(x.pc,g.pt) limit 1) as rf
    from grp g
  ), lado as (
    select p.*,
      case when (ld).id is not null then jsonb_build_object('tipo','ligacao',
          'lon',round(ST_X(ST_Transform((ld).geom,4326))::numeric,7),'lat',round(ST_Y(ST_Transform((ld).geom,4326))::numeric,7),
          'matricula',(ld).matricula,'no_trecho',(ld).nu_trecho = any(trechos),
          'dist',round(ST_Distance((ld).geom,pt)),'dist_limite',round(ST_Distance((ld).geom,v_b)),
          'endereco',nullif(trim(concat_ws(' ',(select g2.nome_completo from "1 - suporte_geografico".logradouros g2
             where g2.cd_logradouro=(ld).cd_logradouro::text and (g2.cd_localidade=(ld).cd_localidade or (g2.cd_localidade is null and g2.consorcio=(ld).consorcio))
             order by (g2.cd_localidade=(ld).cd_localidade) desc nulls last limit 1), nullif((ld).num_imovel,0)::text,(ld).complemento)),''))
        when rd is not null and not ST_IsEmpty(rd) then jsonb_build_object('tipo','rede',
          'lon',round(ST_X(ST_Transform(rd,4326))::numeric,7),'lat',round(ST_Y(ST_Transform(rd,4326))::numeric,7),
          'dist',round(ST_Distance(rd,pt)),'dist_limite',round(ST_Distance(rd,v_b))) end as jd,
      case when (lf).id is not null then jsonb_build_object('tipo','ligacao',
          'lon',round(ST_X(ST_Transform((lf).geom,4326))::numeric,7),'lat',round(ST_Y(ST_Transform((lf).geom,4326))::numeric,7),
          'matricula',(lf).matricula,'no_trecho',(lf).nu_trecho = any(trechos),
          'dist',round(ST_Distance((lf).geom,pt)),'dist_limite',round(ST_Distance((lf).geom,v_b)),
          'endereco',nullif(trim(concat_ws(' ',(select g2.nome_completo from "1 - suporte_geografico".logradouros g2
             where g2.cd_logradouro=(lf).cd_logradouro::text and (g2.cd_localidade=(lf).cd_localidade or (g2.cd_localidade is null and g2.consorcio=(lf).consorcio))
             order by (g2.cd_localidade=(lf).cd_localidade) desc nulls last limit 1), nullif((lf).num_imovel,0)::text,(lf).complemento)),''))
        when rf is not null and not ST_IsEmpty(rf) then jsonb_build_object('tipo','rede',
          'lon',round(ST_X(ST_Transform(rf,4326))::numeric,7),'lat',round(ST_Y(ST_Transform(rf,4326))::numeric,7),
          'dist',round(ST_Distance(rf,pt)),'dist_limite',round(ST_Distance(rf,v_b))) end as jf
    from par p
  )
  select jsonb_build_object('dmc',p_dmc,'consorcio',v_cons,'pares',coalesce(jsonb_agg(jsonb_build_object(
    'n',n,
    'cruz',jsonb_build_array(round(ST_X(ST_Transform(pt,4326))::numeric,7),round(ST_Y(ST_Transform(pt,4326))::numeric,7)),
    'trechos',trechos,'dn',diametro,'material',material,'valvula',valv,'dentro',jd,'fora',jf
  ) order by n),'[]'::jsonb)) into r from lado;
  return r;
end $function$;
revoke all on function public.app_pressao_estanq_pontos(text) from public, anon;
grant execute on function public.app_pressao_estanq_pontos(text) to authenticated;
