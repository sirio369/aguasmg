-- Priorização de troca de HD — filtro por IDADE do medidor + universo "todo o parque" (2026-10-29)
--
-- Novos parâmetros (todos com default → chamadas antigas continuam funcionando):
--   p_idades int[]          seleção múltipla de faixas de idade: 0..29 = idade exata, 30 = "30+ anos", -1 = sem idade
--   p_idade_min / p_idade_max  intervalo "de X até Y anos" (idade crua, inclusivo; sem idade fica de fora)
--   p_incluir_sem_troca     (resumo e mapa; o ranking já tinha) true = TODO o parque, não só troca_efetiva
-- app_nrw_hd_resumo devolve também 'por_idade' (mesmas faixas) calculado SEM o filtro de idade
-- (o histograma continua mostrando todas as idades p/ a seleção múltipla) e 'idade_media'.
-- ⚠️ §0.6: assinatura muda → drop + create (create or replace criaria overload).

drop function if exists public.app_nrw_hd_resumo(text,text,text,text,text,text,text,text,text);
drop function if exists public.app_nrw_hd_ranking(text,text,text,text,text,text,text,integer,integer,text,text,text,boolean,boolean);
drop function if exists public.app_nrw_hd_mapa(text,text,text,text,text,integer,text,text,text);

create function public.app_nrw_hd_resumo(p_consorcio text DEFAULT NULL::text, p_situacao text DEFAULT 'ativa'::text, p_interno text DEFAULT NULL::text, p_categoria text DEFAULT NULL::text, p_motivo text DEFAULT NULL::text, p_cap text DEFAULT NULL::text, p_adequacao text DEFAULT NULL::text, p_codigo text DEFAULT NULL::text, p_poligono text DEFAULT NULL::text, p_idades integer[] DEFAULT NULL::integer[], p_idade_min integer DEFAULT NULL::integer, p_idade_max integer DEFAULT NULL::integer, p_incluir_sem_troca boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_poly geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return (
    with b as (   -- todos os filtros, menos idade (base do histograma de idade)
      select p.*, case when p.idade_medidor is null then -1 when p.idade_medidor>=30 then 30 else p.idade_medidor end faixa_idade
      from "11 - perdas_nrw".hd_priorizacao p
      where (p_consorcio is null or consorcio=p_consorcio)
        and (p_incluir_sem_troca or coalesce(p.troca_efetiva,false))
        and (p_situacao='todas' or (p_situacao='ativa' and situacao_lig='R') or (p_situacao='inativa' and coalesce(situacao_lig,'X') in ('I','F','P')))
        and (p_interno is null or interno_externo=p_interno)
        and (p_categoria is null or categoria=p_categoria)
        and (p_motivo is null or p_motivo = any(motivos))
        and (p_cap is null or cap=p_cap)
        and (p_adequacao is null or adequacao=p_adequacao)
        and (p_codigo is null or codigo_servico=p_codigo)
        and (v_poly is null or exists(select 1 from "3 - comercial".ligacoes l where l.matricula=p.matricula and l.geom is not null and st_contains(v_poly, l.geom)))
    ), f as (
      select * from b
      where (p_idades is null or faixa_idade = any(p_idades))
        and (p_idade_min is null or idade_medidor >= p_idade_min)
        and (p_idade_max is null or idade_medidor <= p_idade_max)
    )
    select jsonb_build_object(
      'n_total', (select count(*) from f),
      'n_remanejamento', (select count(*) from f where remanejamento_sugerido),
      'ips_medio', (select round(avg(ips),1) from f),
      'idade_media', (select round(avg(idade_medidor),1) from f),
      'por_categoria', (select coalesce(jsonb_object_agg(categoria,n),'{}') from (select categoria,count(*) n from f group by categoria) t),
      'por_adequacao', (select coalesce(jsonb_object_agg(adequacao,n),'{}') from (select adequacao,count(*) n from f group by adequacao) t),
      'por_codigo', (select coalesce(jsonb_object_agg(coalesce(codigo_servico,'(fora do contrato)'),n),'{}') from (select codigo_servico,count(*) n from f group by codigo_servico) t),
      'por_motivo', (select coalesce(jsonb_object_agg(mot,n),'{}') from (select unnest(motivos) mot,count(*) n from f group by 1 order by 2 desc) t),
      'por_idade', (select coalesce(jsonb_object_agg(faixa_idade,n),'{}') from (select faixa_idade,count(*) n from b group by faixa_idade) t)
    )
  );
end $function$;

create function public.app_nrw_hd_ranking(p_consorcio text DEFAULT NULL::text, p_categoria text DEFAULT NULL::text, p_motivo text DEFAULT NULL::text, p_cap text DEFAULT NULL::text, p_situacao text DEFAULT 'ativa'::text, p_interno text DEFAULT NULL::text, p_busca text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_adequacao text DEFAULT NULL::text, p_codigo text DEFAULT NULL::text, p_poligono text DEFAULT NULL::text, p_incluir_endereco boolean DEFAULT false, p_incluir_sem_troca boolean DEFAULT false, p_idades integer[] DEFAULT NULL::integer[], p_idade_min integer DEFAULT NULL::integer, p_idade_max integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_poly geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return (
    with f as (
      select p.*, lg.situacao_desde, h.num_hidr, ad.bairro, ad.endereco
      from "11 - perdas_nrw".hd_priorizacao p
      left join "3 - comercial".ligacoes lg on lg.matricula=p.matricula
      left join "11 - perdas_nrw".hd_cadastro h on h.matricula=p.matricula
      left join lateral (
        select c.bairro, c.endereco
        from "0 - vitrine_gis".vw_gis_cadastro_comercial c
        where p_incluir_endereco and c.matricula=p.matricula and c.consorcio=p.consorcio
        limit 1
      ) ad on true
      where (p_consorcio is null or p.consorcio=p_consorcio)
        and (p_incluir_sem_troca or coalesce(p.troca_efetiva,false))
        and (p_categoria is null or p.categoria=p_categoria)
        and (p_motivo is null or p_motivo = any(p.motivos))
        and (p_cap is null or p.cap=p_cap)
        and (p_adequacao is null or p.adequacao=p_adequacao)
        and (p_codigo is null or p.codigo_servico=p_codigo)
        and (p_situacao='todas' or (p_situacao='ativa' and p.situacao_lig='R') or (p_situacao='inativa' and coalesce(p.situacao_lig,'X') in ('I','F','P')))
        and (p_interno is null or p.interno_externo=p_interno)
        and (p_busca is null or p_busca='' or p.matricula::text like p_busca||'%')
        and (p_idades is null or (case when p.idade_medidor is null then -1 when p.idade_medidor>=30 then 30 else p.idade_medidor end) = any(p_idades))
        and (p_idade_min is null or p.idade_medidor >= p_idade_min)
        and (p_idade_max is null or p.idade_medidor <= p_idade_max)
        and (v_poly is null or exists(select 1 from "3 - comercial".ligacoes l where l.matricula=p.matricula and l.geom is not null and st_contains(v_poly, l.geom)))
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'rows', coalesce((select jsonb_agg(row_to_json(r)) from (
        select matricula, num_hidr, cap, q3, cal_recomendado, q3_recomendado, codigo_recomendado, desc_recomendado,
          codigo_servico, in_contrato, idade_medidor, round(media,1) media, media_m3h, round(media_4m,1) media_4m, p90, faixa_predominante, tendencia,
          adequacao, troca_efetiva, round(volume_periodo,0) volume_periodo, ips, categoria, interno_externo, situacao_lig, situacao_desde, remanejamento_sugerido, justificativa,
          bairro, endereco
        from f order by ips desc nulls last, matricula
        limit greatest(1,least(p_limit,2000)) offset greatest(0,p_offset)) r),'[]')
    )
  );
end $function$;

create function public.app_nrw_hd_mapa(p_consorcio text DEFAULT NULL::text, p_categoria text DEFAULT NULL::text, p_situacao text DEFAULT 'ativa'::text, p_interno text DEFAULT NULL::text, p_cap text DEFAULT NULL::text, p_limit integer DEFAULT 8000, p_adequacao text DEFAULT NULL::text, p_codigo text DEFAULT NULL::text, p_poligono text DEFAULT NULL::text, p_idades integer[] DEFAULT NULL::integer[], p_idade_min integer DEFAULT NULL::integer, p_idade_max integer DEFAULT NULL::integer, p_incluir_sem_troca boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_poly geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return coalesce((select jsonb_agg(row_to_json(r)) from (
    select p.matricula, p.cap, p.cal_recomendado, p.codigo_servico, p.ips, p.categoria, p.remanejamento_sugerido, p.idade_medidor,
      round(st_y(st_transform(l.geom,4326))::numeric,6) lat, round(st_x(st_transform(l.geom,4326))::numeric,6) lon
    from "11 - perdas_nrw".hd_priorizacao p
    join "3 - comercial".ligacoes l on l.matricula=p.matricula and l.geom is not null
    where (p_consorcio is null or p.consorcio=p_consorcio)
      and (p_incluir_sem_troca or coalesce(p.troca_efetiva,false))
      and (p_categoria is null or p.categoria=p_categoria)
      and (p_situacao='todas' or (p_situacao='ativa' and p.situacao_lig='R') or (p_situacao='inativa' and coalesce(p.situacao_lig,'X') in ('I','F','P')))
      and (p_interno is null or p.interno_externo=p_interno)
      and (p_cap is null or p.cap=p_cap)
      and (p_adequacao is null or p.adequacao=p_adequacao)
      and (p_codigo is null or p.codigo_servico=p_codigo)
      and (p_idades is null or (case when p.idade_medidor is null then -1 when p.idade_medidor>=30 then 30 else p.idade_medidor end) = any(p_idades))
      and (p_idade_min is null or p.idade_medidor >= p_idade_min)
      and (p_idade_max is null or p.idade_medidor <= p_idade_max)
      and (v_poly is null or st_contains(v_poly, l.geom))
    order by p.ips desc nulls last
    limit greatest(1,least(p_limit,20000))) r),'[]');
end $function$;

revoke all on function public.app_nrw_hd_resumo(text,text,text,text,text,text,text,text,text,integer[],integer,integer,boolean) from public, anon;
revoke all on function public.app_nrw_hd_ranking(text,text,text,text,text,text,text,integer,integer,text,text,text,boolean,boolean,integer[],integer,integer) from public, anon;
revoke all on function public.app_nrw_hd_mapa(text,text,text,text,text,integer,text,text,text,integer[],integer,integer,boolean) from public, anon;
grant execute on function public.app_nrw_hd_resumo(text,text,text,text,text,text,text,text,text,integer[],integer,integer,boolean) to authenticated;
grant execute on function public.app_nrw_hd_ranking(text,text,text,text,text,text,text,integer,integer,text,text,text,boolean,boolean,integer[],integer,integer) to authenticated;
grant execute on function public.app_nrw_hd_mapa(text,text,text,text,text,integer,text,text,text,integer[],integer,integer,boolean) to authenticated;
