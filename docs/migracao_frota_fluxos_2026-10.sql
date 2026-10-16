-- Frota — ajustes de fluxo pedidos pela Amanda (e-mail de 2026-10-16).
-- 1) Multas, ocorrências e avarias: a equipe de frotas (Lucas) cadastra; aviso SÓ ao colaborador e ao gestor dele.
-- 2) Lavagem: fluxo igual; só corrige o aviso de "lavagem solicitada", que não chegava a quem tem a
--    engrenagem frota_admin sem cargo admin (caso do Lucas).
-- 3) Manutenção preventiva: frotas agenda direto (sem aprovação); aviso ao colaborador vinculado e ao gestor, com a data.
-- 4) Checklist: ocorrência marcada no checklist passa a avisar também a equipe de frotas (link p/ Checklists da equipe).
--    De quebra: manutenção corretiva aprovada pelo gestor avisa a equipe de frotas que há algo a agendar.
-- Idempotente (pode rodar de novo). Não apaga dado nenhum.

-- ---------- helpers ----------
-- Quem é "a equipe de frotas": engrenagem frota_admin + cargos frotas/admin (mantém quem já recebia hoje).
create or replace function "10 - Frotas".frota_responsaveis()
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(id), '{}') from public.perfil
  where coalesce(ativo,true) and (coalesce(frota_admin,false) or funcao in ('frotas','admin'));
$$;

-- Gestor direto (aprovador 1 e 2 do perfil), SEM o fallback "todos os aprovadores" do sup_aprovadores_de —
-- o e-mail pede aviso apenas ao gestor da pessoa.
create or replace function "10 - Frotas".frota_gestores_de(p_uid uuid)
returns uuid[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(ap.id), '{}') from public.perfil p
  join public.perfil ap on ap.id in (p.aprovador_uuid, p.aprovador2_uuid) and coalesce(ap.ativo,true)
  where p.id = p_uid;
$$;

-- ---------- 3) preventiva: novo tipo ----------
alter table "10 - Frotas".frota_manutencao drop constraint if exists frota_manutencao_tipo_problema_check;
alter table "10 - Frotas".frota_manutencao add constraint frota_manutencao_tipo_problema_check check (
  tipo_problema is null or tipo_problema = any (array['pneu_furado','freio','motor','eletrica','suspensao','bateria',
  'ar_condicionado','vidro_retrovisor','checklist','preventiva','outro']));

-- Frotas agenda a preventiva já como 'agendado'. reportado_por = colaborador vinculado hoje (assim ela aparece
-- em "Manutenção" dele e ele mesmo dá baixa, igual à corretiva); sem vínculo → fica no nome de quem agendou.
-- Não muda o status do veículo pra 'manutencao' (a data pode ser semanas à frente e isso travaria o checklist).
create or replace function public.app_frota_preventiva_agendar(p_veiculo_id bigint, p_data date, p_descricao text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_ok boolean; v_cond uuid; v_nome text; v_mid bigint;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao in ('frotas','admin') or coalesce(frota_admin,false)) into v_ok from public.perfil where id=v_id;
  if not coalesce(v_ok,false) then raise exception 'sem permissão'; end if;
  if p_veiculo_id is null then raise exception 'informe o veículo'; end if;
  if p_data is null then raise exception 'informe a data'; end if;
  if not exists(select 1 from "10 - Frotas".frota_veiculo where id=p_veiculo_id) then raise exception 'veículo inexistente'; end if;
  select vi.condutor_id, pc.nome into v_cond, v_nome
    from "10 - Frotas".frota_veiculo_vinculo vi left join public.perfil pc on pc.id=vi.condutor_id
    where vi.veiculo_id=p_veiculo_id and vi.desvinculado_em is null limit 1;
  insert into "10 - Frotas".frota_manutencao(veiculo_id,tipo_problema,servico_solicitado,status,reportado_por,reportado_em,
    aprovado_por,aprovado_em,data_agendada)
  values (p_veiculo_id,'preventiva',nullif(trim(coalesce(p_descricao,'')),''),'agendado',coalesce(v_cond,v_id),now(),v_id,now(),p_data)
  returning id into v_mid;
  return jsonb_build_object('id',v_mid,'condutor_id',v_cond,'condutor_nome',v_nome);
end; $$;
revoke all on function public.app_frota_preventiva_agendar(bigint,date,text) from public, anon;
grant execute on function public.app_frota_preventiva_agendar(bigint,date,text) to authenticated;

-- ---------- triggers de manutenção (3 + 4) ----------
create or replace function "10 - Frotas".trg_frota_manutencao()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_ator uuid := auth.uid(); v_placa text;
begin
  select v.placa into v_placa from "10 - Frotas".frota_veiculo v where v.id=NEW.veiculo_id;
  if TG_OP='INSERT' then
    if NEW.tipo_problema='preventiva' then
      -- preventiva agendada pela equipe de frotas: colaborador vinculado + gestor dele, com a data
      perform "9 - suprimentos".sup_notificar(
        array[NEW.reportado_por] || "10 - Frotas".frota_gestores_de(NEW.reportado_por), 'frota',
        'Manutenção preventiva agendada — veículo '||coalesce(v_placa,''),
        'Data programada: '||to_char(NEW.data_agendada,'DD/MM/YYYY')||coalesce(' — '||NEW.servico_solicitado,''),
        'frota_manutencao', v_ator);
      return NEW;
    end if;
    perform "9 - suprimentos".sup_notificar(
      "9 - suprimentos".sup_aprovadores_de(NEW.reportado_por), 'frota',
      'Manutenção solicitada — veículo '||coalesce(v_placa,''),
      coalesce(NEW.servico_solicitado,''), 'frota_manutencao_aprovar', v_ator);
    if NEW.tipo_problema='checklist' then
      -- ocorrência marcada no checklist diário: equipe de frotas também é avisada
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

-- ---------- 2) lavagem: aviso de "solicitada" vai pra equipe de frotas (inclui frota_admin) ----------
create or replace function "10 - Frotas".trg_frota_lavagem()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_ator uuid := auth.uid(); v_placa text; v_nome text;
begin
  select placa into v_placa from "10 - Frotas".frota_veiculo where id=NEW.veiculo_id;
  select nome into v_nome from public.perfil where id=NEW.condutor_id;
  if TG_OP='INSERT' then
    perform "9 - suprimentos".sup_notificar("10 - Frotas".frota_responsaveis(),
      'frota','Lavagem solicitada — veículo '||coalesce(v_placa,''),
      coalesce(v_nome,'Colaborador')||' solicitou lavagem.', 'frota_lavagem_agendar', v_ator);
    return NEW;
  end if;
  if TG_OP='UPDATE' and NEW.status is distinct from OLD.status then
    if NEW.status='agendada' then
      perform "9 - suprimentos".sup_notificar(array[NEW.condutor_id], 'frota',
        'Lavagem agendada — veículo '||coalesce(v_placa,''),
        'Data '||to_char(NEW.data_agendada,'DD/MM/YYYY')||coalesce(' às '||to_char(NEW.horario_agendado,'HH24:MI'),'')||coalesce(' — '||NEW.local_agendado,''),
        'frota_minhas_lavagens');
    end if;
  end if;
  return NEW;
end; $function$;

-- ---------- 1) multas, ocorrências e avarias ----------
create table if not exists "10 - Frotas".frota_registro (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('multa','ocorrencia','avaria')),
  veiculo_id bigint references "10 - Frotas".frota_veiculo(id),
  condutor_id uuid not null references public.perfil(id),
  data_fato date not null,
  local text,
  numero_auto text,          -- nº do auto de infração (multa)
  valor numeric,
  descricao text not null,
  anexos text[],             -- paths no bucket fotos-campo (pasta frota/registros)
  registrado_por uuid not null references public.perfil(id),
  registrado_em timestamptz not null default now()
);
alter table "10 - Frotas".frota_registro enable row level security;  -- app-only: acesso só pelas RPCs definer
revoke all on "10 - Frotas".frota_registro from anon, authenticated;
create index if not exists frota_registro_condutor_idx on "10 - Frotas".frota_registro(condutor_id);

create or replace function "10 - Frotas".trg_frota_registro()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_placa text; v_tipo text;
begin
  select placa into v_placa from "10 - Frotas".frota_veiculo where id=NEW.veiculo_id;
  v_tipo := case NEW.tipo when 'multa' then 'Multa' when 'avaria' then 'Avaria' else 'Ocorrência' end;
  perform "9 - suprimentos".sup_notificar(
    array[NEW.condutor_id] || "10 - Frotas".frota_gestores_de(NEW.condutor_id), 'frota',
    v_tipo||' registrada'||coalesce(' — veículo '||v_placa,''),
    to_char(NEW.data_fato,'DD/MM/YYYY')||' — '||NEW.descricao, 'frota_registros', NEW.registrado_por);
  return NEW;
end; $function$;
drop trigger if exists trg_frota_registro on "10 - Frotas".frota_registro;
create trigger trg_frota_registro after insert on "10 - Frotas".frota_registro
  for each row execute function "10 - Frotas".trg_frota_registro();

create or replace function public.app_frota_registro_salvar(p_tipo text, p_veiculo_id bigint, p_condutor_id uuid,
  p_data_fato date, p_descricao text, p_valor numeric default null, p_numero_auto text default null,
  p_local text default null, p_anexos text[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_ok boolean; v_rid bigint;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao in ('frotas','admin') or coalesce(frota_admin,false)) into v_ok from public.perfil where id=v_id;
  if not coalesce(v_ok,false) then raise exception 'sem permissão'; end if;
  if p_tipo not in ('multa','ocorrencia','avaria') then raise exception 'tipo inválido'; end if;
  if p_condutor_id is null then raise exception 'informe o colaborador envolvido'; end if;
  if p_data_fato is null then raise exception 'informe a data'; end if;
  if coalesce(trim(p_descricao),'')='' then raise exception 'informe a descrição'; end if;
  insert into "10 - Frotas".frota_registro(tipo,veiculo_id,condutor_id,data_fato,local,numero_auto,valor,descricao,anexos,registrado_por)
  values (p_tipo,p_veiculo_id,p_condutor_id,p_data_fato,nullif(trim(coalesce(p_local,'')),''),
    nullif(trim(coalesce(p_numero_auto,'')),''),p_valor,trim(p_descricao),p_anexos,v_id)
  returning id into v_rid;
  return jsonb_build_object('id',v_rid);
end; $$;

-- Lista com escopo: equipe de frotas vê tudo; gestor vê a equipe dele (aprovador 1/2); colaborador vê os próprios.
create or replace function public.app_frota_registros_listar(p_tipo text default null, p_data_ini date default null, p_data_fim date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_adm boolean;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao in ('frotas','admin') or coalesce(frota_admin,false)) into v_adm from public.perfil where id=v_id;
  v_adm := coalesce(v_adm,false);
  return jsonb_build_object('adm', v_adm, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',r.id,'tipo',r.tipo,'veiculo_id',r.veiculo_id,'placa',v.placa,'condutor_id',r.condutor_id,
      'condutor_nome',coalesce(pc.nome,pc.email),'data_fato',r.data_fato,'local',r.local,'numero_auto',r.numero_auto,
      'valor',r.valor,'descricao',r.descricao,'anexos',r.anexos,'registrado_por_nome',pr.nome,'registrado_em',r.registrado_em
    ) order by r.data_fato desc, r.id desc)
    from "10 - Frotas".frota_registro r
    left join "10 - Frotas".frota_veiculo v on v.id=r.veiculo_id
    join public.perfil pc on pc.id=r.condutor_id
    left join public.perfil pr on pr.id=r.registrado_por
    where (v_adm or r.condutor_id=v_id or pc.aprovador_uuid=v_id or pc.aprovador2_uuid=v_id)
      and (p_tipo is null or r.tipo=p_tipo)
      and (p_data_ini is null or r.data_fato>=p_data_ini)
      and (p_data_fim is null or r.data_fato<=p_data_fim)
  ),'[]'::jsonb));
end; $$;

-- Quem estava com o veículo numa data (pra sugerir o colaborador da multa).
create or replace function public.app_frota_condutor_na_data(p_veiculo_id bigint, p_data date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_ok boolean; r record;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao in ('frotas','admin') or coalesce(frota_admin,false)) into v_ok from public.perfil where id=v_id;
  if not coalesce(v_ok,false) then raise exception 'sem permissão'; end if;
  select vi.condutor_id id, coalesce(pc.nome,pc.email) nome into r
    from "10 - Frotas".frota_veiculo_vinculo vi left join public.perfil pc on pc.id=vi.condutor_id
    where vi.veiculo_id=p_veiculo_id and vi.vinculado_em::date<=p_data
      and (vi.desvinculado_em is null or vi.desvinculado_em::date>=p_data)
    order by vi.vinculado_em desc limit 1;
  if r.id is null then return null; end if;
  return jsonb_build_object('id',r.id,'nome',r.nome);
end; $$;

revoke all on function public.app_frota_registro_salvar(text,bigint,uuid,date,text,numeric,text,text,text[]) from public, anon;
revoke all on function public.app_frota_registros_listar(text,date,date) from public, anon;
revoke all on function public.app_frota_condutor_na_data(bigint,date) from public, anon;
grant execute on function public.app_frota_registro_salvar(text,bigint,uuid,date,text,numeric,text,text,text[]) to authenticated;
grant execute on function public.app_frota_registros_listar(text,date,date) to authenticated;
grant execute on function public.app_frota_condutor_na_data(bigint,date) to authenticated;

notify pgrst, 'reload schema';
