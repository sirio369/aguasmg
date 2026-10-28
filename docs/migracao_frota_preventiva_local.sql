-- Frota — preventiva com horário, local e observação (igual ao agendamento de lavagem). 2026-10-23.
-- Idempotente. Não apaga dado.
alter table "10 - Frotas".frota_manutencao add column if not exists horario_agendado time;
alter table "10 - Frotas".frota_manutencao add column if not exists local_agendado text;
alter table "10 - Frotas".frota_manutencao add column if not exists obs_agendamento text;

-- §0.6: trocar a assinatura = drop + create (senão vira overload)
drop function if exists public.app_frota_preventiva_agendar(bigint, date, text);
create or replace function public.app_frota_preventiva_agendar(p_veiculo_id bigint, p_data date, p_descricao text default null,
  p_horario time default null, p_local text default null, p_obs text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_ok boolean; v_cond uuid; v_nome text; v_mid bigint;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao in ('frotas','admin') or coalesce(frota_admin,false)) into v_ok from public.perfil where id=v_id;
  if not coalesce(v_ok,false) then raise exception 'sem permissão'; end if;
  if p_veiculo_id is null then raise exception 'informe o veículo'; end if;
  if p_data is null then raise exception 'informe a data'; end if;
  -- local é obrigatório na tela (igual lavagem); a RPC aceita null p/ a versão antiga do app continuar funcionando
  if not exists(select 1 from "10 - Frotas".frota_veiculo where id=p_veiculo_id) then raise exception 'veículo inexistente'; end if;
  select vi.condutor_id, pc.nome into v_cond, v_nome
    from "10 - Frotas".frota_veiculo_vinculo vi left join public.perfil pc on pc.id=vi.condutor_id
    where vi.veiculo_id=p_veiculo_id and vi.desvinculado_em is null limit 1;
  insert into "10 - Frotas".frota_manutencao(veiculo_id,tipo_problema,servico_solicitado,status,reportado_por,reportado_em,
    aprovado_por,aprovado_em,data_agendada,horario_agendado,local_agendado,obs_agendamento)
  values (p_veiculo_id,'preventiva',nullif(trim(coalesce(p_descricao,'')),''),'agendado',coalesce(v_cond,v_id),now(),v_id,now(),p_data,
    p_horario,nullif(trim(coalesce(p_local,'')),''),nullif(trim(coalesce(p_obs,'')),''))
  returning id into v_mid;
  return jsonb_build_object('id',v_mid,'condutor_id',v_cond,'condutor_nome',v_nome);
end; $$;
revoke all on function public.app_frota_preventiva_agendar(bigint,date,text,time,text,text) from public, anon;
grant execute on function public.app_frota_preventiva_agendar(bigint,date,text,time,text,text) to authenticated;

-- Aviso da preventiva passa a levar horário, local e observação
create or replace function "10 - Frotas".trg_frota_manutencao()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_ator uuid := auth.uid(); v_placa text;
begin
  select v.placa into v_placa from "10 - Frotas".frota_veiculo v where v.id=NEW.veiculo_id;
  if TG_OP='INSERT' then
    if NEW.tipo_problema='preventiva' then
      -- preventiva agendada pela equipe de frotas: colaborador vinculado + gestor dele, com data/horário/local/obs
      perform "9 - suprimentos".sup_notificar(
        array[NEW.reportado_por] || "10 - Frotas".frota_gestores_de(NEW.reportado_por), 'frota',
        'Manutenção preventiva agendada — veículo '||coalesce(v_placa,''),
        'Data '||to_char(NEW.data_agendada,'DD/MM/YYYY')||coalesce(' às '||to_char(NEW.horario_agendado,'HH24:MI'),'')
          ||coalesce(' — '||NEW.local_agendado,'')||coalesce(' — '||NEW.servico_solicitado,'')||coalesce(' — Obs: '||NEW.obs_agendamento,''),
        'frota_manutencao', v_ator);
      return NEW;
    end if;
    perform "9 - suprimentos".sup_notificar(
      "9 - suprimentos".sup_aprovadores_de(NEW.reportado_por), 'frota',
      'Manutenção solicitada — veículo '||coalesce(v_placa,''),
      coalesce(NEW.servico_solicitado,''), 'frota_manutencao_aprovar', v_ator);
    if NEW.tipo_problema='checklist' then
      perform "9 - suprimentos".sup_notificar(
        "10 - Frotas".frota_responsaveis(), 'frota',
        'Ocorrência no checklist — veículo '||coalesce(v_placa,''),
        coalesce(NEW.servico_solicitado,''), 'frota_chk_equipe', v_ator);
    end if;
    return NEW;
  end if;
  if TG_OP='UPDATE' and NEW.status is distinct from OLD.status then
    if NEW.status in ('aprovado','reprovado') then
      perform "9 - suprimentos".sup_notificar(array[NEW.reportado_por], 'frota',
        'Manutenção '||(case when NEW.status='aprovado' then 'aprovada' else 'reprovada' end)||' — veículo '||coalesce(v_placa,''),
        coalesce(NEW.motivo_reprovacao,''), 'frota_manutencao');
      if NEW.status='aprovado' then
        perform "9 - suprimentos".sup_notificar("10 - Frotas".frota_responsaveis(), 'frota',
          'Manutenção a agendar — veículo '||coalesce(v_placa,''),
          coalesce(NEW.servico_solicitado,''), 'frota_manutencao_fila', v_ator);
      end if;
    elsif NEW.status='agendado' then
      perform "9 - suprimentos".sup_notificar(array[NEW.reportado_por], 'frota',
        'Manutenção agendada — veículo '||coalesce(v_placa,''),
        'Agendada para '||to_char(NEW.data_agendada,'DD/MM/YYYY'), 'frota_manutencao');
    elsif NEW.status='concluido' then
      perform "9 - suprimentos".sup_notificar(array[NEW.reportado_por], 'frota',
        'Manutenção concluída — veículo '||coalesce(v_placa,''),
        'O veículo já está liberado.', 'frota_manutencao');
    end if;
  end if;
  return NEW;
end;
$function$;

-- Listas devolvem horário/local/obs (mesma assinatura → create or replace basta)
create or replace function public.app_frota_manutencoes_listar(p_veiculo_id bigint default null, p_condutor_id uuid default null,
  p_data_ini date default null, p_data_fim date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid(); v_ok boolean;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao in ('frotas','admin') or coalesce(frota_admin,false)) into v_ok from public.perfil where id=v_id;
  if not coalesce(v_ok,false) then raise exception 'sem permissão'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,'veiculo_id',m.veiculo_id,'placa',v.placa,'tipo_problema',m.tipo_problema,
      'servico_solicitado',m.servico_solicitado,'orcamento_valor',m.orcamento_valor,'status',m.status,
      'reportado_por_nome',rp.nome,'reportado_em',m.reportado_em,
      'aprovado_por_nome',ap.nome,'aprovado_em',m.aprovado_em,'motivo_reprovacao',m.motivo_reprovacao,
      'data_agendada',m.data_agendada,'data_liberacao',m.data_liberacao,'concluido_em',m.concluido_em,
      'horario_agendado',m.horario_agendado,'local_agendado',m.local_agendado,'obs_agendamento',m.obs_agendamento
    ) order by m.reportado_em desc)
    from "10 - Frotas".frota_manutencao m
    join "10 - Frotas".frota_veiculo v on v.id=m.veiculo_id
    left join public.perfil rp on rp.id=m.reportado_por
    left join public.perfil ap on ap.id=m.aprovado_por
    where (p_veiculo_id is null or m.veiculo_id=p_veiculo_id)
      and (p_condutor_id is null or m.reportado_por=p_condutor_id)
      and (p_data_ini is null or m.reportado_em::date>=p_data_ini)
      and (p_data_fim is null or m.reportado_em::date<=p_data_fim)
  ), '[]'::jsonb);
end; $function$;

create or replace function public.app_frota_minhas_manutencoes()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_id uuid := auth.uid(); v jsonb;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'veiculo_id',m.veiculo_id,'placa',ve.placa,'tipo_problema',m.tipo_problema,
    'servico_solicitado',m.servico_solicitado,'status',m.status,'reportado_em',m.reportado_em,
    'aprovado_em',m.aprovado_em,'motivo_reprovacao',m.motivo_reprovacao,
    'data_agendada',m.data_agendada,'orcamento_valor',m.orcamento_valor,
    'data_liberacao',m.data_liberacao,'concluido_em',m.concluido_em,
    'horario_agendado',m.horario_agendado,'local_agendado',m.local_agendado,'obs_agendamento',m.obs_agendamento
  ) order by m.reportado_em desc),'[]'::jsonb) into v
  from "10 - Frotas".frota_manutencao m
  join "10 - Frotas".frota_veiculo ve on ve.id=m.veiculo_id
  where m.reportado_por=v_id;
  return v;
end; $function$;

notify pgrst, 'reload schema';
