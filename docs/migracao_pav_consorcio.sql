-- Gestão de Pavimento: consórcio do registro passa a vir do PONTO (limite da ZA). 2026-10-27.
-- Bug: o app mandava p_consorcio = localStorage 'consorcio', que só é gravado pela tela de Pressão —
-- quem nunca lançou pressão gravava NULL (22 de 23 registros) e o filtro Betim/Contagem do pavprog
-- (app_pav_listar, consorcio = p_consorcio) não achava nada.
-- Regra: consórcio = ZA cujo limite contém o ponto → senão o que o app mandou → senão perfil.consorcio.
-- Idempotente.

-- 1) gravação
create or replace function public.app_pav_registrar(p_id uuid, p_grupo uuid, p_servico_origem text, p_os_sigos text,
  p_tipo text, p_dimensao text, p_foto1 text, p_foto2 text, p_lat numeric, p_lon numeric, p_precisao numeric,
  p_consorcio text, p_dispositivo text)
returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_email text:=coalesce(auth.jwt()->>'email',''); v_nome text; v_cons_perfil text;
  v_geom geometry; v_cons text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  select nome, consorcio into v_nome, v_cons_perfil from public.perfil where id=v_id;
  v_geom := case when p_lat is not null and p_lon is not null then st_setsrid(st_makepoint(p_lon,p_lat),4326) else null end;
  v_cons := coalesce(
    (select z.consorcio from "1 - suporte_geografico".limite_za z
      where v_geom is not null and st_intersects(z.geom, st_transform(v_geom, st_srid(z.geom))) limit 1),
    nullif(btrim(p_consorcio),''), v_cons_perfil);
  insert into "8 - coleta_campo".pav_recomposicao
    (id,grupo,servico_origem,os_sigos,tipo_pavimento,dimensao,foto1,foto2,lat,lon,gps_precisao,
     geom,consorcio,dispositivo,usuario_uuid,usuario_email,usuario_nome)
  values (p_id,p_grupo,p_servico_origem,nullif(btrim(p_os_sigos),''),p_tipo,p_dimensao,
     nullif(p_foto1,''),nullif(p_foto2,''),p_lat,p_lon,p_precisao,
     v_geom, v_cons, p_dispositivo,v_id,v_email,v_nome)
  on conflict (id) do nothing;
  return p_id;
end$function$;

-- 2) corrige os registros já gravados sem consórcio (backup só da chave; reverter:
--    update ... set consorcio=null where id in (select id from "8 - coleta_campo"._bkp_pav_consorcio_20261027))
create table if not exists "8 - coleta_campo"._bkp_pav_consorcio_20261027 as
  select id, consorcio from "8 - coleta_campo".pav_recomposicao where consorcio is null;
alter table "8 - coleta_campo"._bkp_pav_consorcio_20261027 enable row level security;
update "8 - coleta_campo".pav_recomposicao r set consorcio = coalesce(
    (select z.consorcio from "1 - suporte_geografico".limite_za z
      where r.geom is not null and st_intersects(z.geom, st_transform(r.geom, st_srid(z.geom))) limit 1),
    (select p.consorcio from public.perfil p where p.id=r.usuario_uuid))
  where r.consorcio is null;
