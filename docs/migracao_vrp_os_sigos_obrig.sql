-- Gestão de VRPs — OS SIGOS obrigatória ao programar (2026-11-11)
-- Fase 1 (aplicar ANTES do merge do front): as RPCs de programar ganham p_os_sigos (default null, para o app
-- antigo em cache seguir funcionando); se vier, o número precisa estar no padrão SIGOS (sigos_os_base).
-- A edição da OS SIGOS (app_vrp_os_set_sigos) não aceita mais apagar o número nem número fora do padrão.
-- Fase 2 (aplicar DEPOIS do front em produção): bloco no fim do arquivo torna p_os_sigos obrigatório no banco.

drop function if exists public.app_vrp_os_programar(bigint, uuid, date, text);
create function public.app_vrp_os_programar(p_vrp_id bigint, p_atribuido_uuid uuid default null, p_data date default null,
  p_origem text default 'preventiva', p_os_sigos text default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'extensions'
as $function$
declare v_cons text; v_num text; v_cd text; v_dmc text; v_ano int := extract(year from now())::int; v_seq int; v_os text; v_id uuid;
  v_orig text := coalesce(p_origem,'preventiva'); v_sig text := nullif(btrim(p_os_sigos),'');
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  if v_sig is not null and public.sigos_os_base(v_sig) is null then
    raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  select consorcio,num_vrp,cd_no_agua into v_cons,v_num,v_cd from "2 - infra_agua".vrps where id=p_vrp_id;
  if not found then raise exception 'VRP inexistente'; end if;
  if exists(select 1 from "8 - coleta_campo".vrp_os where vrp_id=p_vrp_id and status in ('programada','em_execucao')) then
    raise exception 'Esta VRP já tem uma OS em aberto. Conclua-a antes de programar outra.';
  end if;
  -- substituição pode ser programada mesmo com pendência (ela resolve a necessidade); os demais tipos não
  if v_orig <> 'substituicao' and exists(select 1 from "8 - coleta_campo".vrp_pendencia where vrp_id=p_vrp_id and status in ('aberta','em_andamento')) then
    raise exception 'Esta VRP tem pendência em aberto - resolva pela OS corretiva antes de programar outra.';
  end if;
  v_dmc := public.vrp_dmc_de(p_vrp_id);
  insert into "8 - coleta_campo".vrp_os_contador(ano,n) values (v_ano,1)
    on conflict (ano) do update set n="8 - coleta_campo".vrp_os_contador.n+1 returning n into v_seq;
  v_os := 'VRP-OS-'||v_ano||'-'||lpad(v_seq::text,4,'0');
  insert into "8 - coleta_campo".vrp_os(os_numero,os_sigos,vrp_id,consorcio,num_vrp,cd_no_agua,dmc,origem,status,atribuido_uuid,programada_para,aberto_por,
     pendencia_id)
  values (v_os,v_sig,p_vrp_id,v_cons,v_num,v_cd,v_dmc,v_orig,'programada',p_atribuido_uuid,p_data,auth.uid(),
     case when v_orig='substituicao' then (select id from "8 - coleta_campo".vrp_pendencia where vrp_id=p_vrp_id and tipo='substituicao' and status='aberta' and os_correcao_id is null order by aberta_em limit 1) else null end)
  returning id into v_id;
  -- vincula as pendências de substituição abertas a esta OS de substituição
  if v_orig='substituicao' then
    update "8 - coleta_campo".vrp_pendencia set status='em_andamento', os_correcao_id=v_id
      where vrp_id=p_vrp_id and tipo='substituicao' and status='aberta' and os_correcao_id is null;
  end if;
  return jsonb_build_object('os_id',v_id,'os_numero',v_os,'os_sigos',v_sig);
end $function$;

drop function if exists public.app_vrp_pendencia_gerar_os(uuid, uuid, date, text);
create function public.app_vrp_pendencia_gerar_os(p_pendencia_id uuid, p_atribuido_uuid uuid default null, p_data date default null,
  p_origem text default 'corretiva', p_os_sigos text default null)
 returns jsonb language plpgsql security definer set search_path to 'public', 'extensions'
as $function$
declare v record; v_cd text; v_ano int := extract(year from now())::int; v_seq int; v_os text; v_id uuid; v_obs text; v_cnt int; v_orig text;
  v_sig text := nullif(btrim(p_os_sigos),'');
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  if v_sig is not null and public.sigos_os_base(v_sig) is null then
    raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  v_orig := case when lower(coalesce(p_origem,'')) in ('corretiva','preventiva','substituicao') then lower(p_origem) else 'corretiva' end;
  select * into v from "8 - coleta_campo".vrp_pendencia where id=p_pendencia_id;
  if not found then raise exception 'pendência inexistente'; end if;
  if v.status in ('resolvida','cancelada') then raise exception 'pendência já %', v.status; end if;
  if v.os_correcao_id is not null then raise exception 'pendência já tem OS em andamento'; end if;
  select cd_no_agua into v_cd from "2 - infra_agua".vrps where id=v.vrp_id;
  -- cobre todas as pendências abertas da VRP ainda sem OS (o tipo da OS é a escolha do usuário)
  select string_agg(coalesce(nullif(descricao,''),tipo), '; '), count(*) into v_obs, v_cnt
    from "8 - coleta_campo".vrp_pendencia where vrp_id=v.vrp_id and status='aberta' and os_correcao_id is null;
  insert into "8 - coleta_campo".vrp_os_contador(ano,n) values (v_ano,1)
    on conflict (ano) do update set n="8 - coleta_campo".vrp_os_contador.n+1 returning n into v_seq;
  v_os := 'VRP-OS-'||v_ano||'-'||lpad(v_seq::text,4,'0');
  insert into "8 - coleta_campo".vrp_os(os_numero,os_sigos,vrp_id,consorcio,num_vrp,cd_no_agua,dmc,origem,status,atribuido_uuid,programada_para,aberto_por,pendencia_id,obs)
  values (v_os,v_sig,v.vrp_id,v.consorcio,v.num_vrp,v_cd,v.dmc,v_orig,'programada',p_atribuido_uuid,p_data,auth.uid(),p_pendencia_id,
          initcap(v_orig)||' — resolve '||coalesce(v_cnt,1)||' pendência(s): '||coalesce(v_obs,v.descricao,v.tipo))
  returning id into v_id;
  update "8 - coleta_campo".vrp_pendencia set status='em_andamento', os_correcao_id=v_id
    where vrp_id=v.vrp_id and status='aberta' and os_correcao_id is null;
  return jsonb_build_object('os_id',v_id,'os_numero',v_os,'os_sigos',v_sig,'pendencia_id',p_pendencia_id,'pendencias_cobertas',coalesce(v_cnt,1),'origem',v_orig);
end $function$;

create or replace function public.app_vrp_os_set_sigos(p_os_id uuid, p_os_sigos text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_sig text := nullif(btrim(p_os_sigos),'');
begin
  if not public.vrp_pode_gestao() then raise exception 'sem permissão'; end if;
  if v_sig is null then raise exception 'Informe o número da OS SIGOS (não é possível deixar a OS sem número).'; end if;
  if public.sigos_os_base(v_sig) is null then raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  update "8 - coleta_campo".vrp_os set os_sigos=v_sig where id=p_os_id;
  if not found then raise exception 'OS inexistente'; end if;
  return jsonb_build_object('ok',true,'os_sigos',v_sig);
end $function$;

revoke all on function public.app_vrp_os_programar(bigint, uuid, date, text, text) from public, anon;
revoke all on function public.app_vrp_pendencia_gerar_os(uuid, uuid, date, text, text) from public, anon;
revoke all on function public.app_vrp_os_set_sigos(uuid, text) from public, anon;
grant execute on function public.app_vrp_os_programar(bigint, uuid, date, text, text) to authenticated;
grant execute on function public.app_vrp_pendencia_gerar_os(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.app_vrp_os_set_sigos(uuid, text) to authenticated;

-- ===================== Fase 2 — só depois do front (sw v361+) em produção =====================
-- Torna a OS SIGOS obrigatória também no banco (o app antigo, sem o campo, passaria a receber erro).
-- Rodar como migração separada `vrp_os_sigos_obrig_fase2`: em app_vrp_os_programar e app_vrp_pendencia_gerar_os, trocar
--     if v_sig is not null and public.sigos_os_base(v_sig) is null then
-- por
--     if v_sig is null then raise exception 'Informe o número da OS SIGOS para programar o serviço.'; end if;
--     if public.sigos_os_base(v_sig) is null then
