-- RH · Validação gestor: desligamento vale para os dias seguintes (2026-11-17, sw v412)
-- O 1º dia que o gestor justifica com o motivo "Desligado da empresa" vira a ORIGEM: todo dia com inconsistência DEPOIS dele, do mesmo
-- colaborador, recebe a mesma tratativa automaticamente (justificar / "Desligado da empresa", auto_de = data da origem) e segue a
-- situação da origem — tratado (aguarda RH), validado (com a mesma RH/data) ou devolvido. Dias que chegarem em cargas futuras do
-- Kairos entram sozinhos (gatilho quando o arquivo da carga fica ok). Dia que o gestor tratou à mão não é tocado; se ele refizer um dia
-- automático, o dia vira manual (auto_de = null). Se a origem deixar de ser desligamento, os automáticos dela são apagados.

alter table "18 - rh".tratativa add column if not exists auto_de date;
comment on column "18 - rh".tratativa.auto_de is 'Preenchido automaticamente a partir do desligamento informado neste dia (origem).';

create or replace function "18 - rh".rh_deslig_sync(p_funcionario bigint default null)
 returns int language plpgsql security definer
 set search_path to 'public', '18 - rh'
as $function$
declare o record; v_max date; n int := 0; k int;
begin
  -- automáticos cuja origem deixou de ser desligamento (ou foi apagada) saem
  delete from "18 - rh".tratativa a
   where a.auto_de is not null and (p_funcionario is null or a.funcionario_id = p_funcionario)
     and not exists (select 1 from "18 - rh".tratativa o2 where o2.funcionario_id = a.funcionario_id and o2.data = a.auto_de
                       and o2.auto_de is null and o2.acao = 'justificar' and o2.motivo = 'Desligado da empresa');
  for o in
    select distinct on (t.funcionario_id) t.*
      from "18 - rh".tratativa t
     where t.auto_de is null and t.acao = 'justificar' and t.motivo = 'Desligado da empresa'
       and (p_funcionario is null or t.funcionario_id = p_funcionario)
     order by t.funcionario_id, t.data
  loop
    -- automáticos de uma origem que não é mais a 1ª (o gestor informou um dia anterior) passam para a nova origem
    update "18 - rh".tratativa set auto_de = o.data where funcionario_id = o.funcionario_id and auto_de is not null and auto_de <> o.data;
    select max(data) into v_max from "18 - rh".ponto_dia where funcionario_id = o.funcionario_id;
    if v_max is null or v_max <= o.data then continue; end if;
    insert into "18 - rh".tratativa (funcionario_id, data, tipos, acao, marcacoes, motivo, obs, versao_dia, status,
                                     gestor_uuid, gestor_em, rh_uuid, rh_em, rh_obs, auto_de)
    select i.funcionario_id, i.data, i.tipos, 'justificar', null, o.motivo,
           'Desligado desde ' || to_char(o.data, 'DD/MM/YYYY') || ' (automático)', pd.versao, o.status,
           o.gestor_uuid, o.gestor_em, o.rh_uuid, o.rh_em, o.rh_obs, o.data
      from "18 - rh".inconsistencias(o.data + 1, v_max) i
      join "18 - rh".ponto_dia pd on pd.funcionario_id = i.funcionario_id and pd.data = i.data
     where i.funcionario_id = o.funcionario_id
    on conflict (funcionario_id, data) do nothing;
    get diagnostics k = row_count; n := n + k;
    -- os automáticos acompanham a situação da origem (validação/devolução da RH)
    update "18 - rh".tratativa a set status = o.status, gestor_uuid = o.gestor_uuid, gestor_em = o.gestor_em,
           rh_uuid = o.rh_uuid, rh_em = o.rh_em, rh_obs = o.rh_obs
     where a.funcionario_id = o.funcionario_id and a.auto_de = o.data
       and (a.status, a.rh_em) is distinct from (o.status, o.rh_em);
  end loop;
  return n;
end $function$;
revoke all on function "18 - rh".rh_deslig_sync(bigint) from public, anon, authenticated;

-- cargas novas do Kairos: quando um arquivo termina de processar (status ok), os dias depois do desligamento entram sozinhos.
-- (gatilho no arquivo, não em ponto_dia: o processamento grava dia a dia num loop e dispararia a sincronização centenas de vezes)
create or replace function "18 - rh".trg_deslig_sync() returns trigger language plpgsql security definer
 set search_path to 'public', '18 - rh'
as $function$ begin perform "18 - rh".rh_deslig_sync(null); return null; end $function$;
revoke all on function "18 - rh".trg_deslig_sync() from public, anon, authenticated;
drop trigger if exists trg_arquivo_deslig on "18 - rh".arquivo;
create trigger trg_arquivo_deslig after update of status on "18 - rh".arquivo
  for each row when (new.status = 'ok') execute function "18 - rh".trg_deslig_sync();

-- gestor: tratar à mão torna o dia manual (auto_de = null) e sincroniza o desligamento; devolve quantos dias foram preenchidos
create or replace function public.app_rh_val_tratar(p_funcionario bigint, p_data date, p_acao text, p_marcacoes text[] default null::text[], p_motivo text default null::text, p_obs text default null::text)
 returns jsonb language plpgsql security definer
 set search_path to 'public', '18 - rh'
as $function$
declare v_uid uuid := auth.uid(); v_tipos text[]; v_ver int; v_st text; m text; prev int := -1; v_auto int := 0;
begin
  if v_uid is null or not public.rh_tela(v_uid, 'val') or not exists(select 1 from func_visiveis(v_uid) where funcionario_id = p_funcionario) then
    raise exception 'sem permissão para este colaborador'; end if;
  if p_acao not in ('ajustar','falta','justificar','ok') then raise exception 'ação inválida'; end if;
  select status into v_st from "18 - rh".tratativa where funcionario_id = p_funcionario and data = p_data;
  if v_st = 'validado' then raise exception 'dia já validado pela RH'; end if;
  select versao into v_ver from "18 - rh".ponto_dia where funcionario_id = p_funcionario and data = p_data;
  if v_ver is null then raise exception 'dia não encontrado'; end if;
  if p_acao = 'ajustar' then
    if coalesce(cardinality(p_marcacoes), 0) = 0 or cardinality(p_marcacoes) % 2 = 1 then
      raise exception 'informe pares de entrada e saída'; end if;
    foreach m in array p_marcacoes loop
      if hm(m) is null or hm(m) >= 1440 then raise exception 'horário inválido: %', m; end if;
      if hm(m) <= prev then raise exception 'os horários precisam estar em ordem crescente'; end if;
      prev := hm(m);
    end loop;
  else p_marcacoes := null; end if;
  if p_acao = 'justificar' and coalesce(trim(p_motivo), '') = '' then raise exception 'informe o motivo'; end if;
  select i.tipos into v_tipos from "18 - rh".inconsistencias(p_data, p_data) i where i.funcionario_id = p_funcionario;
  insert into "18 - rh".tratativa as t (funcionario_id, data, tipos, acao, marcacoes, motivo, obs, versao_dia, status, gestor_uuid, gestor_em)
  values (p_funcionario, p_data, coalesce(v_tipos, '{}'), p_acao, p_marcacoes, nullif(trim(p_motivo), ''), nullif(trim(p_obs), ''),
          v_ver, 'tratado', v_uid, now())
  on conflict (funcionario_id, data) do update set tipos = excluded.tipos, acao = excluded.acao, marcacoes = excluded.marcacoes,
    motivo = excluded.motivo, obs = excluded.obs, versao_dia = excluded.versao_dia, status = 'tratado',
    gestor_uuid = excluded.gestor_uuid, gestor_em = now(), rh_uuid = null, rh_em = null, rh_obs = null, auto_de = null;
  insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
  values (p_funcionario, p_data, 'tratado', jsonb_build_object('acao', p_acao, 'marcacoes', p_marcacoes, 'motivo', p_motivo, 'obs', p_obs, 'tipos', v_tipos), v_uid);
  v_auto := "18 - rh".rh_deslig_sync(p_funcionario);
  return jsonb_build_object('ok', true, 'auto', v_auto);
end $function$;

-- RH: dia automático segue a origem — valida/devolve o dia em que o desligamento foi informado (os seguintes vão juntos)
create or replace function public.app_rh_val_rh(p_funcionario bigint, p_data date, p_validar boolean, p_obs text default null::text)
 returns jsonb language plpgsql security definer
 set search_path to 'public', '18 - rh'
as $function$
declare v_uid uuid := auth.uid(); v_st text; v_auto date;
begin
  if not public.rh_pode_carregar(v_uid) or not public.rh_tela(v_uid, 'val') then raise exception 'sem permissão'; end if;
  select status, auto_de into v_st, v_auto from "18 - rh".tratativa where funcionario_id = p_funcionario and data = p_data for update;
  if v_st is null then raise exception 'o gestor ainda não tratou este dia'; end if;
  if v_auto is not null then raise exception 'dia preenchido pelo desligamento de %: valide ou devolva aquele dia', to_char(v_auto, 'DD/MM/YYYY'); end if;
  if not p_validar and coalesce(trim(p_obs), '') = '' then raise exception 'diga ao gestor o que falta'; end if;
  update "18 - rh".tratativa set status = case when p_validar then 'validado' else 'devolvido' end,
         rh_uuid = v_uid, rh_em = now(), rh_obs = nullif(trim(p_obs), '')
   where funcionario_id = p_funcionario and data = p_data;
  insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
  values (p_funcionario, p_data, case when p_validar then 'validado' else 'devolvido' end, jsonb_build_object('obs', p_obs), v_uid);
  perform "18 - rh".rh_deslig_sync(p_funcionario);
  return jsonb_build_object('ok', true);
end $function$;

-- lista: expõe auto_de na tratativa (a tela mostra o dia como automático e esconde Validar/Devolver nele)
do $mig$ declare d text; n text;
begin
  d := pg_get_functiondef('public.app_rh_val_lista(date,date,boolean)'::regprocedure);
  n := replace(d, $a$'rh_obs', t.rh_obs,$a$, $b$'rh_obs', t.rh_obs, 'auto_de', t.auto_de,$b$);
  if n = d then raise exception 'replace falhou'; end if;
  execute n;
end $mig$;
