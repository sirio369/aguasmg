-- Solicitação de serviços — código 117 79 00 (Substituição de Hidrômetro).
-- O front (#as_tipo) já oferece value="1177900"; sem este `when` o `tipo_label` gravava "1177900".
-- Mesma assinatura da RPC em produção (create or replace NÃO cria overload) e mesmos grants — só acrescenta o `when`.
-- Idempotente. Não altera registros existentes (nenhum usa 1177900 antes desta mudança).

create or replace function public.app_abertura_servico_registrar(p_id uuid, p_tipo text, p_matricula text, p_numero_hd text, p_foto_hd text,
  p_lat double precision default null::double precision, p_lon double precision default null::double precision, p_precisao numeric default null::numeric,
  p_consorcio text default null::text, p_dispositivo text default null::text, p_observacao text default null::text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare v_uid uuid := auth.uid(); v_label text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if coalesce(trim(p_tipo),'')='' then raise exception 'informe o tipo de serviço'; end if;
  v_label := case p_tipo
    when '106000' then 'Mudança de Padrão'
    when '1480000' then 'Vazamento de água na rua'
    when '1490000' then 'Vazamento de água no padrão de água'
    when '1177900' then 'Substituição de Hidrômetro'
    when 'FAT0900' then 'Alteração de titularidade'
    when '3020000' then 'Vistoria de ligação de esgoto'
    else p_tipo end;
  insert into "12 - retaguarda".abertura_servico(id,tipo_codigo,tipo_label,matricula,numero_hd,foto_hd,consorcio,usuario,observacao,lat,lon,gps_precisao,geom,dispositivo)
  values (p_id, trim(p_tipo), v_label, nullif(trim(p_matricula),''), nullif(trim(p_numero_hd),''), nullif(trim(p_foto_hd),''),
          nullif(p_consorcio,''), v_uid, nullif(trim(p_observacao),''), p_lat, p_lon, p_precisao,
          case when p_lat is not null and p_lon is not null then ST_Transform(ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326),31983) else null end,
          p_dispositivo)
  on conflict (id) do nothing;
  return jsonb_build_object('id',p_id,'ok',true);
end; $function$;

notify pgrst, 'reload schema';
