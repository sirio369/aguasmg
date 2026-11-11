-- Loggers · OS SIGOS + pipeline do logger fixo (2026-11-11)
--  · app_logger_instalar / app_logger_criar ganham p_os_sigos (opcional, default null → app em cache segue funcionando)
--  · app_logger_set_os_sigos: lançar/corrigir a OS SIGOS depois (qualquer usuário autenticado; não aceita apagar)
--  · app_logger_finalizar: OS em branco não apaga mais a OS já lançada
--  · app_logger_remover: logger FIXO não tem remoção (pipeline termina em "instalado")
-- Formato validado por public.sigos_os_base (14 dígitos, ex.: 00127516560801, ou a base de 10).

drop function if exists public.app_logger_instalar(bigint,numeric,text,text,text,double precision,double precision,numeric,text,text,text,timestamptz,text,text,text,text);
create function public.app_logger_instalar(p_id bigint, p_leitura numeric, p_foto_hd text, p_foto_cavalete text, p_foto_fachada text, p_lat double precision, p_lon double precision, p_precisao numeric DEFAULT NULL::numeric, p_numero_logger text DEFAULT NULL::text, p_numero_hd text DEFAULT NULL::text, p_observacao text DEFAULT NULL::text, p_gps_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_dispositivo text DEFAULT NULL::text, p_foto_leitura_hd text DEFAULT NULL::text, p_foto_numeracao_hd text DEFAULT NULL::text, p_foto_extra text DEFAULT NULL::text, p_os_sigos text DEFAULT NULL::text)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
declare v_user text; v_inst timestamp; v_rem timestamp; v_sig text := nullif(btrim(p_os_sigos),'');
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if p_foto_hd is null then raise exception 'foto do HD obrigatoria'; end if;
  if p_leitura is null then raise exception 'leitura obrigatoria'; end if;
  if v_sig is not null and public.sigos_os_base(v_sig) is null then raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  select data_instalacao, data_remocao into v_inst, v_rem
    from "8 - coleta_campo".instalacao_logger_calibracao where id = p_id;
  if not found then raise exception 'ponto inexistente'; end if;
  if v_rem  is not null then raise exception 'ponto ja foi removido'; end if;
  if v_inst is not null then raise exception 'ponto ja instalado'; end if;
  v_user := coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name', auth.jwt() ->> 'email');
  update "8 - coleta_campo".instalacao_logger_calibracao set
    data_instalacao = (coalesce(p_gps_ts, now()) at time zone 'America/Sao_Paulo'),
    usuario_instalacao = v_user, leitura_hd_instalacao = p_leitura,
    foto_hd_instalacao = p_foto_hd, foto_cavalete_instalacao = p_foto_cavalete, foto_fachada = p_foto_fachada,
    foto_leitura_hd_instalacao = p_foto_leitura_hd, foto_numeracao_hd_instalacao = p_foto_numeracao_hd,
    foto_extra = p_foto_extra,
    numero_logger = p_numero_logger, numero_hd = p_numero_hd, observacao_instalacao = p_observacao,
    gps_precisao_inst = p_precisao, gps_lat_inst = p_lat, gps_lon_inst = p_lon, dispositivo_inst = p_dispositivo,
    os_sigos = coalesce(v_sig, os_sigos)
  where id = p_id;
  return 'instalado';
end $function$;

drop function if exists public.app_logger_criar(uuid,text,text,text,text,text,numeric,text,text,text,double precision,double precision,numeric,text,timestamptz,text,text,text,text,boolean);
create function public.app_logger_criar(p_client_uuid uuid, p_label text DEFAULT NULL::text, p_consorcio text DEFAULT NULL::text, p_zona text DEFAULT NULL::text, p_numero_logger text DEFAULT NULL::text, p_numero_hd text DEFAULT NULL::text, p_leitura numeric DEFAULT NULL::numeric, p_foto_hd text DEFAULT NULL::text, p_foto_cavalete text DEFAULT NULL::text, p_foto_fachada text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lon double precision DEFAULT NULL::double precision, p_precisao numeric DEFAULT NULL::numeric, p_observacao text DEFAULT NULL::text, p_gps_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_dispositivo text DEFAULT NULL::text, p_foto_leitura_hd text DEFAULT NULL::text, p_foto_numeracao_hd text DEFAULT NULL::text, p_foto_extra text DEFAULT NULL::text, p_temporario boolean DEFAULT true, p_os_sigos text DEFAULT NULL::text)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
declare v_user text; v_ts timestamp; v_id bigint; v_sig text := nullif(btrim(p_os_sigos),'');
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if p_lat is null or p_lon is null then raise exception 'GPS obrigatorio'; end if;
  if coalesce(p_numero_logger,'')='' then raise exception 'numero do logger obrigatorio'; end if;
  if p_leitura is null then raise exception 'leitura do HD obrigatoria'; end if;
  if p_foto_hd is null then raise exception 'foto do HD obrigatoria'; end if;
  if v_sig is not null and public.sigos_os_base(v_sig) is null then raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  if p_client_uuid is not null then
    select id into v_id from "8 - coleta_campo".instalacao_logger_calibracao where client_uuid=p_client_uuid;
    if v_id is not null then return v_id; end if;
  end if;
  v_user := coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name', auth.jwt() ->> 'email');
  v_ts := (coalesce(p_gps_ts, now()) at time zone 'America/Sao_Paulo');
  insert into "8 - coleta_campo".instalacao_logger_calibracao
    (client_uuid, avulso, label, consorcio, zone, numero_logger, numero_hd,
     data_instalacao, usuario_instalacao, leitura_hd_instalacao,
     foto_hd_instalacao, foto_cavalete_instalacao, foto_fachada,
     foto_leitura_hd_instalacao, foto_numeracao_hd_instalacao, foto_extra,
     gps_precisao_inst, gps_lat_inst, gps_lon_inst, dispositivo_inst,
     observacao_instalacao, geom, logger_temporario, os_sigos)
  values
    (p_client_uuid, true, coalesce(nullif(p_label,''),'Avulso'), p_consorcio, p_zona, p_numero_logger, p_numero_hd,
     v_ts, v_user, p_leitura,
     p_foto_hd, p_foto_cavalete, p_foto_fachada,
     p_foto_leitura_hd, p_foto_numeracao_hd, p_foto_extra,
     p_precisao, p_lat, p_lon, p_dispositivo,
     p_observacao, ST_Transform(ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326),31983), coalesce(p_temporario,true), v_sig)
  on conflict (client_uuid) do nothing
  returning id into v_id;
  if v_id is null and p_client_uuid is not null then
    select id into v_id from "8 - coleta_campo".instalacao_logger_calibracao where client_uuid=p_client_uuid;
  end if;
  return v_id;
end $function$;

create or replace function public.app_logger_set_os_sigos(p_id bigint, p_os_sigos text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_sig text := nullif(btrim(p_os_sigos),''); v_inst timestamp;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if v_sig is null then raise exception 'Informe o número da OS SIGOS (não é possível deixar o logger sem número).'; end if;
  if public.sigos_os_base(v_sig) is null then raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  select data_instalacao into v_inst from "8 - coleta_campo".instalacao_logger_calibracao where id=p_id;
  if not found then raise exception 'ponto inexistente'; end if;
  update "8 - coleta_campo".instalacao_logger_calibracao set os_sigos=v_sig where id=p_id;
  return jsonb_build_object('ok',true,'os_sigos',v_sig);
end $function$;

create or replace function public.app_logger_finalizar(p_id bigint, p_os_sigos text DEFAULT NULL::text)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
declare v_user text; v_rem timestamp; v_n int; v_sig text := nullif(btrim(p_os_sigos),'');
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if v_sig is not null and public.sigos_os_base(v_sig) is null then raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
  select data_remocao into v_rem from "8 - coleta_campo".instalacao_logger_calibracao where id=p_id;
  if not found then raise exception 'ponto inexistente'; end if;
  if v_rem is null then raise exception 'ponto ainda nao foi removido'; end if;
  select count(*) into v_n from "8 - coleta_campo".logger_pressao where logger_id=p_id;
  if v_n=0 then raise exception 'anexe o arquivo de dados do logger antes de concluir'; end if;
  v_user := coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name', auth.jwt() ->> 'email');
  update "8 - coleta_campo".instalacao_logger_calibracao set
    os_sigos=coalesce(v_sig, os_sigos),
    data_finalizacao=(now() at time zone 'America/Sao_Paulo'), usuario_finalizacao=v_user
  where id=p_id;
  return 'concluido';
end $function$;

create or replace function public.app_logger_remover(p_id bigint, p_leitura numeric, p_foto_hd text, p_foto_cavalete text, p_lat double precision, p_lon double precision, p_precisao numeric DEFAULT NULL::numeric, p_observacao text DEFAULT NULL::text, p_gps_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_dispositivo text DEFAULT NULL::text)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
declare v_user text; v_inst timestamp; v_rem timestamp; v_temp boolean;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if p_foto_hd is null then raise exception 'foto do HD obrigatoria'; end if;
  if p_leitura is null then raise exception 'leitura obrigatoria'; end if;
  select data_instalacao, data_remocao, logger_temporario into v_inst, v_rem, v_temp
    from "8 - coleta_campo".instalacao_logger_calibracao where id = p_id;
  if not found then raise exception 'ponto inexistente'; end if;
  if not coalesce(v_temp,false) then raise exception 'logger fixo nao tem remocao (o ciclo termina em instalado)'; end if;
  if v_inst is null     then raise exception 'ponto ainda nao instalado'; end if;
  if v_rem  is not null then raise exception 'ponto ja foi removido'; end if;
  v_user := coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name', auth.jwt() ->> 'email');
  update "8 - coleta_campo".instalacao_logger_calibracao set
    data_remocao = (coalesce(p_gps_ts, now()) at time zone 'America/Sao_Paulo'),
    usuario_remocao = v_user, leitura_hd_remocao = p_leitura,
    foto_hd_remocao = p_foto_hd, foto_cavalete_remocao = p_foto_cavalete, observacao_remocao = p_observacao,
    gps_precisao_rem = p_precisao, gps_lat_rem = p_lat, gps_lon_rem = p_lon, dispositivo_rem = p_dispositivo
  where id = p_id;
  return 'removido';
end $function$;

revoke all on function public.app_logger_instalar(bigint,numeric,text,text,text,double precision,double precision,numeric,text,text,text,timestamptz,text,text,text,text,text) from public, anon;
revoke all on function public.app_logger_criar(uuid,text,text,text,text,text,numeric,text,text,text,double precision,double precision,numeric,text,timestamptz,text,text,text,text,boolean,text) from public, anon;
revoke all on function public.app_logger_set_os_sigos(bigint,text) from public, anon;
grant execute on function public.app_logger_instalar(bigint,numeric,text,text,text,double precision,double precision,numeric,text,text,text,timestamptz,text,text,text,text,text) to authenticated;
grant execute on function public.app_logger_criar(uuid,text,text,text,text,text,numeric,text,text,text,double precision,double precision,numeric,text,timestamptz,text,text,text,text,boolean,text) to authenticated;
grant execute on function public.app_logger_set_os_sigos(bigint,text) to authenticated;

-- ============================================================================================
-- FASE 2 — PENDENTE: OS SIGOS obrigatória também no servidor (decisão do usuário 11/11/2026).
-- Aplicar SÓ depois que o PR do front (sw v366+) estiver em produção e a fila offline dos
-- celulares tiver esvaziado (app em cache antigo manda instalação sem OS → ficaria presa na fila).
-- Troca, em app_logger_instalar e app_logger_criar, a linha de validação do formato por:
--
--   if v_sig is null then raise exception 'Informe o número da OS SIGOS.'; end if;
--   if public.sigos_os_base(v_sig) is null then raise exception 'Número da OS SIGOS fora do padrão (14 dígitos, ex.: 00127516560801).'; end if;
--
-- (create or replace com a MESMA assinatura acima — não muda parâmetros, não cria overload.)
-- ============================================================================================
