-- Migração: entrevista_ocorrencia (Entrevistadores › Registro de ocorrência) — ver docs/MODULOS.md §3.4
-- Aplicar via Supabase MCP `apply_migration` (name: entrevista_ocorrencia). Só ADICIONA objetos.
-- Rollback:
--   drop function public.app_entrevista_ocorrencia_listar(date,date);
--   drop function public.app_entrevista_ocorrencia_registrar(uuid,text,text,boolean,text,text,double precision,double precision,numeric,text,text);
--   drop table "12 - retaguarda".entrevista_ocorrencia;

-- Tabela app-only: matrícula + relato do cliente → schema 12 (RLS sem policy, acesso só via RPC)
create table "12 - retaguarda".entrevista_ocorrencia (
  id uuid primary key,
  matricula text not null,
  tipo_codigo text not null check (tipo_codigo in ('cliente_nao_informado','resistencia','ligou_copasa','policia')),
  tipo_label text not null,
  ligou_copasa boolean,
  orientacao_copasa text,
  detalhamento text,
  consorcio text,
  usuario uuid not null references public.perfil(id),
  lat double precision,
  lon double precision,
  gps_precisao numeric,
  geom geometry(Point,31983),
  dispositivo text,
  data_hora timestamptz not null default now(),
  constraint entrevista_ocorrencia_copasa_chk check (
    (tipo_codigo = 'ligou_copasa' and ligou_copasa is not null
       and (ligou_copasa = false or coalesce(trim(orientacao_copasa),'') <> ''))
    or (tipo_codigo <> 'ligou_copasa' and ligou_copasa is null and orientacao_copasa is null))
);
alter table "12 - retaguarda".entrevista_ocorrencia enable row level security;
create index entrevista_ocorrencia_data_idx on "12 - retaguarda".entrevista_ocorrencia (data_hora desc);
comment on table "12 - retaguarda".entrevista_ocorrencia is
  'Entrevistadores › Registro de ocorrência. Acesso só via RPC: app_entrevista_ocorrencia_registrar (qualquer autenticado) e app_entrevista_ocorrencia_listar (aprovador/admin).';

create function public.app_entrevista_ocorrencia_registrar(
  p_id uuid, p_matricula text, p_tipo text,
  p_ligou_copasa boolean default null, p_orientacao_copasa text default null, p_detalhamento text default null,
  p_lat double precision default null, p_lon double precision default null, p_precisao numeric default null,
  p_consorcio text default null, p_dispositivo text default null)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare v_uid uuid := auth.uid(); v_label text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if coalesce(trim(p_matricula),'')='' then raise exception 'informe a matrícula do imóvel'; end if;
  v_label := case p_tipo
    when 'cliente_nao_informado' then 'Cliente não informado'
    when 'resistencia' then 'Resistência do cliente em passar informações'
    when 'ligou_copasa' then 'Cliente ligou para a COPASA'
    when 'policia' then 'Polícia acionada' end;
  if v_label is null then raise exception 'tipo de ocorrência inválido'; end if;
  if p_tipo='ligou_copasa' then
    if p_ligou_copasa is null then raise exception 'informe se o cliente ligou para a COPASA'; end if;
    if p_ligou_copasa and coalesce(trim(p_orientacao_copasa),'')='' then raise exception 'descreva o que a COPASA orientou'; end if;
  end if;
  insert into "12 - retaguarda".entrevista_ocorrencia(id,matricula,tipo_codigo,tipo_label,ligou_copasa,orientacao_copasa,detalhamento,
      consorcio,usuario,lat,lon,gps_precisao,geom,dispositivo)
  values (p_id, trim(p_matricula), p_tipo, v_label,
      case when p_tipo='ligou_copasa' then p_ligou_copasa end,
      case when p_tipo='ligou_copasa' and p_ligou_copasa then nullif(trim(p_orientacao_copasa),'') end,
      nullif(trim(p_detalhamento),''), nullif(p_consorcio,''), v_uid, p_lat, p_lon, p_precisao,
      case when p_lat is not null and p_lon is not null then ST_Transform(ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326),31983) end,
      p_dispositivo)
  on conflict (id) do nothing;
  return jsonb_build_object('id',p_id,'ok',true);
end; $$;

-- Lista para gestores (aprovador/admin). Datas inclusivas, no fuso de SP.
create function public.app_entrevista_ocorrencia_listar(p_de date default null, p_ate date default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when coalesce("9 - suprimentos".sup_funcao(auth.uid()),'') not in ('aprovador','admin') then '[]'::jsonb else
  coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'data_hora',o.data_hora,'matricula',o.matricula,'tipo_codigo',o.tipo_codigo,'tipo',o.tipo_label,
      'ligou_copasa',o.ligou_copasa,'orientacao_copasa',o.orientacao_copasa,'detalhamento',o.detalhamento,
      'consorcio',o.consorcio,'entrevistador',p.nome,'email',p.email,'lat',o.lat,'lon',o.lon,'gps_precisao',o.gps_precisao)
      order by o.data_hora desc)
    from "12 - retaguarda".entrevista_ocorrencia o
    left join public.perfil p on p.id=o.usuario
    where (p_de is null or (o.data_hora at time zone 'America/Sao_Paulo')::date >= p_de)
      and (p_ate is null or (o.data_hora at time zone 'America/Sao_Paulo')::date <= p_ate)
  ),'[]'::jsonb) end;
$$;

revoke all on function public.app_entrevista_ocorrencia_registrar(uuid,text,text,boolean,text,text,double precision,double precision,numeric,text,text) from public, anon;
revoke all on function public.app_entrevista_ocorrencia_listar(date,date) from public, anon;
grant execute on function public.app_entrevista_ocorrencia_registrar(uuid,text,text,boolean,text,text,double precision,double precision,numeric,text,text) to authenticated;
grant execute on function public.app_entrevista_ocorrencia_listar(date,date) to authenticated;
notify pgrst, 'reload schema';
