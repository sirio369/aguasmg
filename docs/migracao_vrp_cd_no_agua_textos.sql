-- VRP identificada pelo cd_no_agua nos textos fora da Gestão de VRPs (2026-11-25)
-- Cadastro técnico (busca), Consolidador (fisc_execucoes), RDO (rdo_eventos) e Vitrine (app_vitrine_feed/_dados).
-- Troca textual pontual na definição atual de cada função (cada trecho existe 1x; aborta se não achar).
-- vrp_os e vrp_visita já têm cd_no_agua preenchido em 100% das linhas. num_vrp segue como fallback.
-- Snapshots já fechados (fisc_dia validado, RDO fechado) ficam com o texto antigo.
do $mig$
declare
  r record; src text; novo text;
  trocas jsonb := jsonb_build_array(
    jsonb_build_array('app_cadastro_buscar',
      $q$'VRP '||coalesce(t.num_vrp,'?')||coalesce(' · '||t.cd_no_agua,'')$q$,
      $q$coalesce(nullif(btrim(t.cd_no_agua),''),public.fisc_vrp(t.num_vrp),'VRP ?')||coalesce(' · '||t.num_vrp,'')$q$),  -- cd_no_agua como está (145 começam com VRP, 3 com VRR)
    jsonb_build_array('app_vitrine_feed',
      $q$concat_ws(' · ', o.num_vrp,$q$, $q$concat_ws(' · ', coalesce(o.cd_no_agua, o.num_vrp),$q$),
    jsonb_build_array('app_vitrine_dados',
      $q$concat_ws(' · ', o.num_vrp,$q$, $q$concat_ws(' · ', coalesce(o.cd_no_agua, o.num_vrp),$q$),
    jsonb_build_array('fisc_execucoes',
      $q$coalesce(public.fisc_vrp(o.num_vrp), 'VRP —')$q$, $q$coalesce(nullif(btrim(o.cd_no_agua), ''), public.fisc_vrp(o.num_vrp), 'VRP —')$q$),
    jsonb_build_array('fisc_execucoes',
      $q$coalesce(public.fisc_vrp(v.num_vrp), 'VRP —')$q$, $q$coalesce(nullif(btrim(v.cd_no_agua), ''), public.fisc_vrp(v.num_vrp), 'VRP —')$q$),
    jsonb_build_array('rdo_eventos',
      $q$string_agg(distinct case when o.num_vrp ~* 'VRP' then o.num_vrp else 'VRP ' || o.num_vrp end, ', ')$q$,
      $q$string_agg(distinct coalesce(o.cd_no_agua, case when o.num_vrp ~* 'VRP' then o.num_vrp else 'VRP ' || o.num_vrp end), ', ')$q$),
    jsonb_build_array('rdo_eventos', $q$'vrp', v.num_vrp$q$, $q$'vrp', coalesce(v.cd_no_agua, v.num_vrp)$q$),
    jsonb_build_array('rdo_eventos', $q$'vrp', o.num_vrp$q$, $q$'vrp', coalesce(o.cd_no_agua, o.num_vrp)$q$)
  );
  t jsonb; f text; de text; para text; n int;
begin
  for t in select * from jsonb_array_elements(trocas) loop
    f := t->>0; de := t->>1; para := t->>2;
    select pg_get_functiondef(p.oid) into src from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=f;
    if src is null then raise exception 'função % não encontrada', f; end if;
    n := (length(src)-length(replace(src,de,'')))/length(de);
    if n <> 1 then raise exception '% : trecho encontrado % vez(es): %', f, n, de; end if;
    execute replace(src, de, para);
  end loop;
end $mig$;
