-- Gestão de VRPs: cd_no_agua passa a ser o identificador exibido (2026-11-25)
-- Aditivo: as 5 RPCs de listagem da gestão passam a devolver 'cd_no_agua' (fonte: "2 - infra_agua".vrps)
-- e ordenam por ele. 'num_vrp' continua no retorno (exibido como nome secundário).
-- Mesma assinatura -> create or replace basta (sem overload novo).

create or replace function public.app_vrp_ficha_listar(p_consorcio text default null, p_dmc text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public','extensions'
as $function$
begin
  if auth.uid() is null then raise exception 'sem permissão'; end if;
  return coalesce((
    with base as (
      select v.id, v.num_vrp, v.cd_no_agua, v.consorcio, public.vrp_dmc_de(v.id) as dmc,
        ST_Y(ST_Transform(v.geom,4326)) lat, ST_X(ST_Transform(v.geom,4326)) lon,
        (select count(*) from "8 - coleta_campo".vrp_os o where o.vrp_id=v.id and o.status in ('concluida','concluida_pendencia')) n_os,
        (select max(executado_em) from "8 - coleta_campo".vrp_os o where o.vrp_id=v.id and o.status in ('concluida','concluida_pendencia')) ult_os,
        (select count(*) from "8 - coleta_campo".vrp_visita x where x.vrp_id=v.id) n_visitas,
        (select max(visitado_em) from "8 - coleta_campo".vrp_visita x where x.vrp_id=v.id) ult_visita,
        (select count(*) from "8 - coleta_campo".vrp_pendencia p where p.vrp_id=v.id and p.status in ('aberta','em_andamento')) pend
      from "2 - infra_agua".vrps v
      where (p_consorcio is null or v.consorcio=p_consorcio)
    )
    select jsonb_agg(jsonb_build_object('vrp_id',id,'num_vrp',num_vrp,'cd_no_agua',cd_no_agua,'consorcio',consorcio,'dmc',dmc,'lat',lat,'lon',lon,
      'n_os',n_os,'n_visitas',n_visitas,'pend',pend,
      'ultimo', nullif(greatest(coalesce(ult_os,'-infinity'::timestamptz),coalesce(ult_visita,'-infinity'::timestamptz)),'-infinity'::timestamptz))
      order by coalesce(cd_no_agua,num_vrp))
    from base where (p_dmc is null or dmc=p_dmc)
  ),'[]'::jsonb);
end $function$;

create or replace function public.app_vrp_os_listar(p_consorcio text default null, p_status text default null, p_atribuido uuid default null,
  p_de date default null, p_ate date default null, p_vrp text default null, p_origem text default null, p_dmc text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public','extensions'
as $function$
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'os_id',o.id,'os_numero',o.os_numero,'os_sigos',o.os_sigos,'vrp_id',o.vrp_id,'num_vrp',o.num_vrp,
    'cd_no_agua',coalesce(vr.cd_no_agua,o.cd_no_agua),
    'consorcio',o.consorcio,'dmc',o.dmc,'status',o.status,'origem',o.origem,
    'programada_para',o.programada_para,'aberto_em',o.aberto_em,'executado_em',o.executado_em,'executor',pr.nome,'atribuido',pa.nome,
    'lat', ST_Y(ST_Transform(coalesce(o.geom,vr.geom),4326)), 'lon', ST_X(ST_Transform(coalesce(o.geom,vr.geom),4326)))
    order by coalesce(o.executado_em,o.aberto_em) desc)
   from "8 - coleta_campo".vrp_os o
   left join public.perfil pr on pr.id=o.executado_por
   left join public.perfil pa on pa.id=o.atribuido_uuid
   left join "2 - infra_agua".vrps vr on vr.id=o.vrp_id
   where (p_consorcio is null or o.consorcio=p_consorcio) and (p_status is null or o.status=p_status)
     and (p_atribuido is null or o.atribuido_uuid=p_atribuido)
     and (p_de is null or coalesce(o.executado_em,o.aberto_em)::date >= p_de)
     and (p_ate is null or coalesce(o.executado_em,o.aberto_em)::date <= p_ate)
     and (p_vrp is null or o.num_vrp=p_vrp or coalesce(vr.cd_no_agua,o.cd_no_agua)=p_vrp) and (p_origem is null or o.origem=p_origem)
     and (p_dmc is null or o.dmc=p_dmc)
  ),'[]'::jsonb);
end $function$;

create or replace function public.app_vrp_os_programaveis(p_consorcio text default null, p_dmc text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public','extensions'
as $function$
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('vrp_id',v.id,'num_vrp',v.num_vrp,'cd_no_agua',v.cd_no_agua,'consorcio',v.consorcio,'dmc',public.vrp_dmc_de(v.id))
      order by coalesce(v.cd_no_agua,v.num_vrp))
    from "2 - infra_agua".vrps v
    where not exists(select 1 from "8 - coleta_campo".vrp_os o where o.vrp_id=v.id and o.status in ('programada','em_execucao'))
      and not exists(select 1 from "8 - coleta_campo".vrp_pendencia pe where pe.vrp_id=v.id and pe.status in ('aberta','em_andamento'))
      and (p_consorcio is null or v.consorcio=p_consorcio)
      and (p_dmc is null or public.vrp_dmc_de(v.id)=p_dmc)
  ),'[]'::jsonb);
end $function$;

create or replace function public.app_vrp_pendencias_listar(p_consorcio text default null, p_status text default null, p_tipo text default null, p_dmc text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',pe.id,'vrp_id',pe.vrp_id,'num_vrp',pe.num_vrp,'cd_no_agua',vr.cd_no_agua,'consorcio',pe.consorcio,'dmc',pe.dmc,'lado',pe.lado,'tipo',pe.tipo,
    'descricao',pe.descricao,'status',pe.status,'aberta_em',pe.aberta_em,'resolvida_em',pe.resolvida_em,
    'os_id',pe.os_id,'os_numero',opa.os_numero,'os_status',opa.status,
    'os_correcao_id',pe.os_correcao_id,'os_correcao_numero',oc.os_numero,'os_correcao_status',oc.status,
    'resolvida_os_id',pe.resolvida_os_id,'resolvida_numero',orr.os_numero)
    order by pe.aberta_em desc)
   from "8 - coleta_campo".vrp_pendencia pe
   left join "2 - infra_agua".vrps vr on vr.id=pe.vrp_id
   left join "8 - coleta_campo".vrp_os opa on opa.id=pe.os_id
   left join "8 - coleta_campo".vrp_os oc  on oc.id=pe.os_correcao_id
   left join "8 - coleta_campo".vrp_os orr on orr.id=pe.resolvida_os_id
   where (p_consorcio is null or pe.consorcio=p_consorcio) and (p_status is null or pe.status=p_status)
     and (p_tipo is null or pe.tipo=p_tipo) and (p_dmc is null or pe.dmc=p_dmc)
  ),'[]'::jsonb);
end $function$;

create or replace function public.app_vrp_prev_farol(p_consorcio text default null, p_dmc text default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public','extensions'
as $function$
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  return coalesce((
   with base as (
     select v.id, v.num_vrp, v.cd_no_agua, v.consorcio, public.vrp_dmc_de(v.id) as dmc,
       ST_Y(ST_Transform(v.geom,4326)) as lat, ST_X(ST_Transform(v.geom,4326)) as lon,
       (select max(executado_em) from "8 - coleta_campo".vrp_os o where o.vrp_id=v.id and o.status in ('concluida','concluida_pendencia')) as ultima,
       coalesce(ov.intervalo_dias, cfg.intervalo_dias, 180) as itv, coalesce(cfg.aviso_dias, 30) as av
     from "2 - infra_agua".vrps v
     left join "8 - coleta_campo".vrp_prev_vrp ov on ov.vrp_id=v.id and ov.ativo
     left join "8 - coleta_campo".vrp_prev_config cfg on cfg.consorcio=v.consorcio
     where (p_consorcio is null or v.consorcio=p_consorcio)
   )
   select jsonb_agg(jsonb_build_object(
     'vrp_id',id,'num_vrp',num_vrp,'cd_no_agua',cd_no_agua,'consorcio',consorcio,'dmc',dmc,'lat',lat,'lon',lon,'ultima',ultima,'intervalo',itv,
     'proxima', case when ultima is null then null else (ultima::date + itv) end,
     'status_farol', case when ultima is null then 'sem_historico'
        when (ultima::date + itv) < current_date then 'vencida'
        when (ultima::date + itv) <= current_date + av then 'a_vencer' else 'em_dia' end,
     'dias', case when ultima is null then null else ((ultima::date + itv) - current_date) end,
     'programada', exists(select 1 from "8 - coleta_campo".vrp_os o2 where o2.vrp_id=base.id and o2.status='programada'))
     order by (case when ultima is null then 3 when (ultima::date+itv)<current_date then 0 when (ultima::date+itv)<=current_date+av then 1 else 2 end), coalesce(cd_no_agua,num_vrp))
   from base where (p_dmc is null or dmc=p_dmc)),'[]'::jsonb);
end $function$;
