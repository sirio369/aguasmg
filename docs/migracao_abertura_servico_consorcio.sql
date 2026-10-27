-- Solicitação de serviços (abertura_servico): consórcio passa a vir do PONTO (limite da ZA). 2026-10-27.
-- Mesmo bug do Pavimento (docs/migracao_pav_consorcio.sql): o app manda p_consorcio = localStorage 'consorcio',
-- que só a tela de Pressão grava → 7 de 7 solicitações sem consórcio. O perfil do usuário NÃO serve de fonte
-- principal: os entrevistadores atendem as duas ZAs (4 de 7 divergiam do perfil); o ponto bateu com o
-- consórcio da matrícula no cadastro (`"3 - comercial".ligacoes`) em 7 de 7.
-- Regra: consórcio = ZA cujo limite contém o ponto → senão o que o app mandou → senão perfil.consorcio.
-- Idempotente.

-- 1) gravação (mesma assinatura → mantém grants)
create or replace function public.app_abertura_servico_registrar(p_id uuid, p_tipo text, p_matricula text, p_numero_hd text, p_foto_hd text,
  p_lat double precision default null, p_lon double precision default null, p_precisao numeric default null,
  p_consorcio text default null, p_dispositivo text default null, p_observacao text default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare v_uid uuid := auth.uid(); v_label text; v_geom geometry; v_cons text;
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
  v_geom := case when p_lat is not null and p_lon is not null then ST_Transform(ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326),31983) else null end;
  -- consórcio do PONTO (limite da ZA) → senão o que o app mandou → senão o do perfil (o localStorage do app só é gravado pela Pressão)
  v_cons := coalesce(
    (select z.consorcio from "1 - suporte_geografico".limite_za z
      where v_geom is not null and st_intersects(z.geom, st_transform(v_geom, st_srid(z.geom))) limit 1),
    nullif(btrim(p_consorcio),''), (select consorcio from public.perfil where id=v_uid));
  insert into "12 - retaguarda".abertura_servico(id,tipo_codigo,tipo_label,matricula,numero_hd,foto_hd,consorcio,usuario,observacao,lat,lon,gps_precisao,geom,dispositivo)
  values (p_id, trim(p_tipo), v_label, nullif(trim(p_matricula),''), nullif(trim(p_numero_hd),''), nullif(trim(p_foto_hd),''),
          v_cons, v_uid, nullif(trim(p_observacao),''), p_lat, p_lon, p_precisao, v_geom, p_dispositivo)
  on conflict (id) do nothing;
  return jsonb_build_object('id',p_id,'ok',true);
end; $function$;

-- 2) corrige as já gravadas sem consórcio (backup só da chave; reverter:
--    update ... set consorcio=null where id in (select id from "12 - retaguarda"._bkp_abertura_consorcio_20261027))
create table if not exists "12 - retaguarda"._bkp_abertura_consorcio_20261027 as
  select id, consorcio from "12 - retaguarda".abertura_servico where consorcio is null;
alter table "12 - retaguarda"._bkp_abertura_consorcio_20261027 enable row level security;
update "12 - retaguarda".abertura_servico a set consorcio = coalesce(
    (select z.consorcio from "1 - suporte_geografico".limite_za z
      where a.geom is not null and st_intersects(z.geom, st_transform(a.geom, st_srid(z.geom))) limit 1),
    (select p.consorcio from public.perfil p where p.id=a.usuario))
  where a.consorcio is null;
