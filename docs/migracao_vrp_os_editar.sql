-- Gestão de VRPs — lápis na ficha da OS: o gestor corrige o que foi lançado errado (2026-11-13)
-- Edita respostas do formulário (chegada, pressões, condição, serviço, finalização) + colunas espelhadas
-- (press_*, estabilizada, vazamento_pos, liberada). NÃO mexe em status, pendências, fotos nem GPS.
-- Cada edição fica registrada (antes/depois + motivo) em vrp_os_edicao — append-only, app-only.

create table if not exists "8 - coleta_campo".vrp_os_edicao (
  id uuid primary key default gen_random_uuid(),
  os_id uuid not null references "8 - coleta_campo".vrp_os(id) on delete cascade,
  editado_por uuid not null,
  editado_em timestamptz not null default now(),
  motivo text not null,
  antes jsonb not null,
  depois jsonb not null
);
create index if not exists vrp_os_edicao_os_idx on "8 - coleta_campo".vrp_os_edicao(os_id, editado_em);
alter table "8 - coleta_campo".vrp_os_edicao enable row level security;  -- sem policy: só via RPC definer
revoke all on "8 - coleta_campo".vrp_os_edicao from anon, authenticated, public;

create or replace function public.app_vrp_os_editar(p_os_id uuid, p_respostas jsonb, p_campos jsonb, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v record; v_antes jsonb; v_depois jsonb;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not public.vrp_pode_gestao() then raise exception 'sem permissao para editar OS de VRP'; end if;
  if nullif(trim(coalesce(p_motivo,'')),'') is null then raise exception 'informe o motivo da correcao'; end if;
  select * into v from "8 - coleta_campo".vrp_os where id=p_os_id for update;
  if not found then raise exception 'OS inexistente'; end if;
  if v.status='programada' then raise exception 'OS ainda nao executada — nada para corrigir'; end if;
  v_antes := jsonb_build_object('respostas',v.respostas,'press_mont_enc',v.press_mont_enc,'press_jus_enc',v.press_jus_enc,
    'press_mont_fin',v.press_mont_fin,'press_jus_fin',v.press_jus_fin,'press_pc_fin',v.press_pc_fin,
    'estabilizada',v.estabilizada,'vazamento_pos',v.vazamento_pos,'liberada',v.liberada,'obs',v.obs);
  update "8 - coleta_campo".vrp_os set
    respostas = coalesce(respostas,'{}'::jsonb) || coalesce(p_respostas,'{}'::jsonb),  -- preserva chaves não editáveis (vrp_anterior/nova…)
    press_mont_enc = nullif(replace(p_campos->>'press_mont_enc',',','.'),'')::numeric,
    press_jus_enc  = nullif(replace(p_campos->>'press_jus_enc',',','.'),'')::numeric,
    press_mont_fin = nullif(replace(p_campos->>'press_mont_fin',',','.'),'')::numeric,
    press_jus_fin  = nullif(replace(p_campos->>'press_jus_fin',',','.'),'')::numeric,
    press_pc_fin   = nullif(replace(p_campos->>'press_pc_fin',',','.'),'')::numeric,
    estabilizada   = (p_campos->>'estabilizada')::boolean,
    vazamento_pos  = (p_campos->>'vazamento_pos')::boolean,
    liberada       = (p_campos->>'liberada')::boolean,
    obs            = nullif(trim(coalesce(p_campos->>'obs','')),'')
  where id=p_os_id
  returning jsonb_build_object('respostas',respostas,'press_mont_enc',press_mont_enc,'press_jus_enc',press_jus_enc,
    'press_mont_fin',press_mont_fin,'press_jus_fin',press_jus_fin,'press_pc_fin',press_pc_fin,
    'estabilizada',estabilizada,'vazamento_pos',vazamento_pos,'liberada',liberada,'obs',obs) into v_depois;
  insert into "8 - coleta_campo".vrp_os_edicao(os_id,editado_por,motivo,antes,depois)
    values (p_os_id, v_uid, trim(p_motivo), v_antes, v_depois);
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.app_vrp_os_editar(uuid,jsonb,jsonb,text) from public, anon;
grant execute on function public.app_vrp_os_editar(uuid,jsonb,jsonb,text) to authenticated;

-- app_vrp_os_ver: + obs e + 'edicoes' (histórico de correções do gestor)
create or replace function public.app_vrp_os_ver(p_os_id uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_uid uuid := auth.uid(); v jsonb; v_pend_id uuid; v_corrige jsonb;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  select o.pendencia_id into v_pend_id from "8 - coleta_campo".vrp_os o where o.id=p_os_id;
  select jsonb_build_object('id',o.id,'os_numero',o.os_numero,'os_sigos',o.os_sigos,'vrp_id',o.vrp_id,
    'consorcio',o.consorcio,'num_vrp',o.num_vrp,'cd_no_agua',o.cd_no_agua,'dmc',o.dmc,'origem',o.origem,'status',o.status,
    'atribuido',pa.nome,'programada_para',o.programada_para,'aberto_em',o.aberto_em,'executado_em',o.executado_em,'executor',pex.nome,
    'gps_lat',o.gps_lat,'gps_lon',o.gps_lon,
    'modelo',o.modelo,'tem_controlador',o.tem_controlador,'controlador_modelo',o.controlador_modelo,'ponto_critico_ref',o.ponto_critico_ref,
    'press_mont_enc',o.press_mont_enc,'press_jus_enc',o.press_jus_enc,'press_mont_fin',o.press_mont_fin,'press_jus_fin',o.press_jus_fin,'press_pc_fin',o.press_pc_fin,
    'estabilizada',o.estabilizada,'vazamento_pos',o.vazamento_pos,'liberada',o.liberada,
    'respostas',o.respostas,'fotos',o.fotos,'obs',o.obs,'pendencia_id',o.pendencia_id)
    into v from "8 - coleta_campo".vrp_os o
    left join public.perfil pa on pa.id=o.atribuido_uuid left join public.perfil pex on pex.id=o.executado_por
    where o.id=p_os_id;
  if v is null then raise exception 'OS inexistente'; end if;
  if v_pend_id is not null then
    select jsonb_build_object('pendencia_id',pp.id,'descricao',pp.descricao,'tipo',pp.tipo,'os_pai_id',pp.os_id,'os_pai_numero',oo.os_numero)
      into v_corrige from "8 - coleta_campo".vrp_pendencia pp left join "8 - coleta_campo".vrp_os oo on oo.id=pp.os_id where pp.id=v_pend_id;
  end if;
  return v
    || jsonb_build_object('corrige', coalesce(v_corrige,'null'::jsonb))
    || jsonb_build_object('pendencias', coalesce((
       select jsonb_agg(jsonb_build_object('id',pe2.id,'tipo',pe2.tipo,'lado',pe2.lado,'descricao',pe2.descricao,'status',pe2.status,
          'os_correcao_id',pe2.os_correcao_id,'os_correcao_numero',oc.os_numero,'resolvida_os_id',pe2.resolvida_os_id)
          order by pe2.aberta_em)
       from "8 - coleta_campo".vrp_pendencia pe2
       left join "8 - coleta_campo".vrp_os oc on oc.id=pe2.os_correcao_id
       where pe2.os_id=p_os_id),'[]'::jsonb))
    || jsonb_build_object('edicoes', coalesce((
       select jsonb_agg(jsonb_build_object('em',e.editado_em,'por',pe.nome,'motivo',e.motivo) order by e.editado_em desc)
       from "8 - coleta_campo".vrp_os_edicao e left join public.perfil pe on pe.id=e.editado_por
       where e.os_id=p_os_id),'[]'::jsonb));
end $function$;
