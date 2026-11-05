-- Indicadores SST — ajustes do QSMS campo (2026-11-05)
-- Inspeção: sai "Você inspeciona como" (cargo vem do perfil de quem inspeciona); entram OS da intervenção e
--           responsável pela intervenção (pessoa do perfil + assinatura).
-- DDS: a lista de presença é feita no papel -> o app manda só o nº de participantes + foto da lista (foto_lista).
-- Ocorrência: sem mudança no banco (área segue texto; setor_local fica nulo; tipo segue texto livre).
-- Compatível com o app antigo em cache (cargo e participantes[] continuam aceitos).

alter table "16 - qsms".sst_inspecao
  add column if not exists os text,
  add column if not exists interv_resp_uuid uuid,
  add column if not exists interv_resp_nome text,
  add column if not exists interv_resp_assinatura text,
  add column if not exists interv_resp_assinado_em timestamptz;

alter table "16 - qsms".sst_dds
  add column if not exists participantes_qtd int check (participantes_qtd is null or participantes_qtd >= 0);

-- cargo do indicador a partir do cargo cadastrado da pessoa
create or replace function "16 - qsms".sst_cargo_ind(p_uid uuid)
returns text language sql stable security definer set search_path to 'public' as $$
  select case when c ~ 'gerente' then 'Gerente' when c ~ 'coordenador' then 'Coordenador'
              when c ~ 'supervisor' then 'Supervisor' else 'TST' end
  from (select lower(coalesce((select sc.nome from public.perfil pe left join "9 - suprimentos".sup_cargo sc on sc.id = pe.cargo_id where pe.id = p_uid),
                              (select pe.cargo from public.perfil pe where pe.id = p_uid), '')) c) t;
$$;
revoke all on function "16 - qsms".sst_cargo_ind(uuid) from public, anon;

-- BI: participantes = importado > informado no app > contagem da presença (app antigo). Mesmas colunas (contrato do BI).
create or replace view "16 - qsms".bi_sst_dds as
 select (id)::text as "ID", data as "Data", area as "Área", consorcio as "Consórcio", tema as "Tema",
    responsavel_nome as "Responsável",
    (coalesce((participantes_imp)::bigint, (participantes_qtd)::bigint,
      (select count(*) from "16 - qsms".sst_dds_presenca p where p.dds_id = d.id)))::double precision as "Participantes",
    (coalesce(efetivo, 0))::double precision as "Efetivo da Área",
    (coalesce(duracao_min, 0))::double precision as "Duração (min)"
   from "16 - qsms".sst_dds d
  where anulado_em is null;

create or replace function public.app_sst_inspecao_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_cargo text;
  it jsonb; i int := 0; v_al jsonb := '[]'::jsonb; v_res text; v_foto text; v_trat boolean;
  v_ruid uuid; v_rnome text; v_rsig text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_inspecao where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  v_lat := nullif(d->>'lat','')::numeric; v_lon := nullif(d->>'lon','')::numeric;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  if v_geom is null then v_al := v_al || jsonb_build_array('Sem GPS'); end if;
  v_loc := "16 - qsms".qsms_local(v_geom);
  -- app antigo manda o cargo escolhido; o novo não manda -> vem do cadastro de quem inspeciona
  v_cargo := case when d->>'cargo' in ('TST','Supervisor','Coordenador','Gerente') then d->>'cargo' else "16 - qsms".sst_cargo_ind(v_uid) end;
  v_ruid := nullif(d->>'resp_interv_uuid','')::uuid;
  v_rnome := coalesce(nullif(btrim(d->>'resp_interv_nome'),''), (select coalesce(nome,email) from public.perfil where id = v_ruid));
  v_rsig := case when nullif(d->>'resp_interv_sig','') is not null then v_anx->>(d->>'resp_interv_sig') end;
  if d ? 'resp_interv_nome' then
    if v_rnome is null then v_al := v_al || jsonb_build_array('Sem responsável pela intervenção');
    elsif v_rsig is null then v_al := v_al || jsonb_build_array('Responsável pela intervenção sem assinatura'); end if;
  end if;

  insert into "16 - qsms".sst_inspecao(id, data, consorcio, area, local, os, responsavel_uuid, responsavel_nome, responsavel_cargo,
    interv_resp_uuid, interv_resp_nome, interv_resp_assinatura, interv_resp_assinado_em, observacoes,
    lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, usuario_uuid, usuario_nome, dispositivo)
  values (p_id, v_data, coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid)),
    nullif(btrim(d->>'area'),''), nullif(btrim(d->>'local'),''), nullif(btrim(d->>'os'),''), v_uid, v_nome, v_cargo,
    v_ruid, v_rnome, v_rsig, case when v_rsig is not null then nullif(d->>'resp_interv_assinado_em','')::timestamptz end,
    nullif(btrim(d->>'observacoes'),''),
    v_lat, v_lon, nullif(d->>'precisao','')::numeric, v_geom, v_loc->>'endereco', v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_uid, v_nome, left(d->>'dispositivo', 120));

  for it in select * from jsonb_array_elements(coalesce(d->'itens','[]'::jsonb)) loop
    i := i + 1;
    v_res := upper(coalesce(it->>'resultado',''));
    if v_res not in ('C','NC','NA') then
      v_al := v_al || jsonb_build_array(format('Item %s sem resultado (gravado como NA)', i)); v_res := 'NA';
    end if;
    v_foto := case when nullif(it->>'foto','') is not null then v_anx->>(it->>'foto') end;
    v_trat := coalesce((it->>'tratada_no_local')::boolean, false);
    if v_res = 'NC' and v_foto is null then v_al := v_al || jsonb_build_array(format('NC no item %s sem foto', i)); end if;
    if v_res = 'NC' and nullif(btrim(it->>'descricao'),'') is null then v_al := v_al || jsonb_build_array(format('NC no item %s sem descrição', i)); end if;
    insert into "16 - qsms".sst_inspecao_item(inspecao_id, ordem, modelo_id, grupo, item, resultado, descricao, foto, prazo,
      trat_status, trat_obs, trat_em, trat_por, trat_por_nome)
    values (p_id, i, nullif(it->>'modelo_id','')::int, nullif(btrim(it->>'grupo'),''), coalesce(nullif(btrim(it->>'item'),''), '(item sem nome)'),
      v_res, nullif(btrim(it->>'descricao'),''), v_foto, nullif(it->>'prazo','')::date,
      case when v_res = 'NC' then case when v_trat then 'tratada' else 'pendente' end end,
      case when v_res = 'NC' and v_trat then nullif(btrim(it->>'tratativa'),'') end,
      case when v_res = 'NC' and v_trat then now() end,
      case when v_res = 'NC' and v_trat then v_uid end,
      case when v_res = 'NC' and v_trat then v_nome end);
  end loop;
  if i = 0 then v_al := v_al || jsonb_build_array('Inspeção sem itens'); end if;
  update "16 - qsms".sst_inspecao set alertas = v_al where id = p_id;
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $function$;

create or replace function public.app_sst_dds_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_cons text; v_area text;
  p jsonb; i int := 0; v_al jsonb := '[]'::jsonb; v_pid uuid; v_mat text; v_fun text; v_qtd int;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_dds where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  v_lat := nullif(d->>'lat','')::numeric; v_lon := nullif(d->>'lon','')::numeric;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  if v_geom is null then v_al := v_al || jsonb_build_array('Sem GPS'); end if;
  v_loc := "16 - qsms".qsms_local(v_geom);
  v_cons := coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid));
  v_area := coalesce(nullif(btrim(d->>'area'),''), 'Geral');
  v_qtd := nullif(d->>'participantes_qtd','')::int;
  if nullif(btrim(d->>'tema'),'') is null then v_al := v_al || jsonb_build_array('DDS sem tema'); end if;

  insert into "16 - qsms".sst_dds(id, data, consorcio, area, tema, responsavel_uuid, responsavel_nome, duracao_min, efetivo, participantes_qtd,
    observacoes, lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, usuario_uuid, usuario_nome, dispositivo)
  values (p_id, v_data, v_cons, v_area, coalesce(nullif(btrim(d->>'tema'),''), '(sem tema)'), v_uid, v_nome,
    nullif(d->>'duracao_min','')::int, "16 - qsms".sst_efetivo(v_cons, v_area, v_data), v_qtd, nullif(btrim(d->>'observacoes'),''),
    v_lat, v_lon, nullif(d->>'precisao','')::numeric, v_geom, v_loc->>'endereco', v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_uid, v_nome, left(d->>'dispositivo', 120));

  -- app antigo (em cache) ainda manda a lista com assinaturas
  for p in select * from jsonb_array_elements(coalesce(d->'participantes','[]'::jsonb)) loop
    i := i + 1;
    v_pid := nullif(p->>'pessoa_uuid','')::uuid; v_mat := null; v_fun := null;
    select pe.matricula, coalesce(c.nome, pe.cargo) into v_mat, v_fun
      from public.perfil pe left join "9 - suprimentos".sup_cargo c on c.id = pe.cargo_id where pe.id = v_pid;
    if nullif(p->>'sig','') is null or v_anx->>(p->>'sig') is null then
      v_al := v_al || jsonb_build_array(format('Participante %s sem assinatura', coalesce(nullif(btrim(p->>'nome'),''), i::text)));
    end if;
    insert into "16 - qsms".sst_dds_presenca(dds_id, ordem, pessoa_uuid, nome, matricula, funcao, assinatura, assinado_em)
    values (p_id, i, v_pid, coalesce(nullif(btrim(p->>'nome'),''), '(sem nome)'), v_mat, v_fun,
      case when nullif(p->>'sig','') is not null then v_anx->>(p->>'sig') end, nullif(p->>'assinado_em','')::timestamptz)
    on conflict do nothing;
  end loop;
  if i = 0 and coalesce(v_qtd, 0) = 0 then v_al := v_al || jsonb_build_array('DDS sem participantes'); end if;
  if v_qtd is not null and v_anx->>'foto_lista' is null then v_al := v_al || jsonb_build_array('DDS sem foto da lista de presença'); end if;
  update "16 - qsms".sst_dds set alertas = v_al where id = p_id;
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $function$;

create or replace function public.app_sst_minhas(p_dias integer default 30)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_de date := "16 - qsms".sst_hoje() - greatest(coalesce(p_dias,30),1);
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'inspecoes', coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'data',i.data,'area',i.area,'local',i.local,'endereco',i.endereco,'os',i.os,
        'itens',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado<>'NA'),
        'ncs',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.resultado='NC'),
        'pendentes',(select count(*) from "16 - qsms".sst_inspecao_item x where x.inspecao_id=i.id and x.trat_status='pendente'),
        'alertas',i.alertas) order by i.data desc, i.criado_em desc)
      from "16 - qsms".sst_inspecao i where i.usuario_uuid=v_uid and i.anulado_em is null and i.data>=v_de), '[]'::jsonb),
    'dds', coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'data',x.data,'area',x.area,'tema',x.tema,
        'participantes',coalesce(x.participantes_qtd,(select count(*) from "16 - qsms".sst_dds_presenca pp where pp.dds_id=x.id)::int),'efetivo',x.efetivo,'alertas',x.alertas)
        order by x.data desc, x.criado_em desc)
      from "16 - qsms".sst_dds x where x.usuario_uuid=v_uid and x.anulado_em is null and x.data>=v_de), '[]'::jsonb),
    'ocorrencias', coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'data',o.data,'natureza',o.natureza,'area',o.area,
        'vitima',o.vitima_nome,'status',o.status,'alertas',o.alertas) order by o.data desc, o.criado_em desc)
      from "16 - qsms".sst_ocorrencia o where o.usuario_uuid=v_uid and o.anulado_em is null and o.data>=v_de), '[]'::jsonb));
end $function$;
