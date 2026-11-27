-- Checklists POP-022 (reaterro e recomposição): o Nº da OS passa a ser opcional. 2026-11-26.
-- Redefine só app_sst_ck_registrar, igual à docs/migracao_sst_ck_manual_reaterro.sql sem o alerta "Sem OS".
-- Compatível com o app antigo (que ainda manda a OS). Pode rodar mais de uma vez.
create or replace function public.app_sst_ck_registrar(p_id uuid, p_dados jsonb, p_anexos jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); v_anx jsonb := coalesce(p_anexos,'{}'::jsonb);
  v_nome text; v_data date; v_lat numeric; v_lon numeric; v_geom geometry; v_loc jsonb; v_tipo text; v_res text;
  it jsonb; i int := 0; n_nc int := 0; v_al jsonb := '[]'::jsonb; v_r text; v_foto text;
  v_euid uuid; v_enome text; v_esig text; v_fsig text; v_manual boolean; v_endman text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "16 - qsms".sst_campo_pode(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "16 - qsms".sst_checklist where id = p_id) then
    return jsonb_build_object('id', p_id, 'duplicado', true);
  end if;
  v_tipo := d->>'tipo'; if v_tipo is null or v_tipo not in ('reaterro','recomposicao') then raise exception 'tipo de checklist inválido'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  v_data := coalesce(nullif(d->>'data','')::date, "16 - qsms".sst_hoje());
  if v_data > "16 - qsms".sst_hoje() then v_al := v_al || jsonb_build_array('Data no futuro'); end if;
  -- Preenchimento manual (os dois checklists): a localização não é registrada e o endereço digitado é o que vale
  v_manual := coalesce(d->>'preenchimento_manual','') = 'true';
  v_endman := case when v_manual then nullif(btrim(d->>'local'),'') end;
  v_lat := case when not v_manual then nullif(d->>'lat','')::numeric end; v_lon := case when not v_manual then nullif(d->>'lon','')::numeric end;
  v_geom := case when v_lat is not null and v_lon is not null then st_transform(st_setsrid(st_makepoint(v_lon, v_lat), 4326), 31983) end;
  if v_manual then
    if v_endman is null then v_al := v_al || jsonb_build_array('Preenchimento manual sem endereço'); end if;
  elsif v_geom is null then v_al := v_al || jsonb_build_array('Sem GPS'); end if;
  v_loc := "16 - qsms".qsms_local(v_geom);
  -- Nº da OS é opcional nos checklists (26/11/2026): sem OS não gera alerta
  v_res := d->>'resultado'; if v_res is null or v_res not in ('conforme','nao_conforme','pendente') then v_res := 'pendente'; v_al := v_al || jsonb_build_array('Sem resultado (gravado como pendente)'); end if;
  v_euid := nullif(d->>'encarregado_uuid','')::uuid;
  v_enome := coalesce(nullif(btrim(d->>'encarregado_nome'),''), (select coalesce(nome,email) from public.perfil where id = v_euid));
  v_esig := case when nullif(d->>'encarregado_sig','') is not null then v_anx->>(d->>'encarregado_sig') end;
  v_fsig := case when nullif(d->>'fiscal_sig','') is not null then v_anx->>(d->>'fiscal_sig') end;
  -- assinatura do encarregado é opcional (26/11/2026): não gera alerta
  if v_enome is null then v_al := v_al || jsonb_build_array('Sem encarregado'); end if;
  if v_fsig is null then v_al := v_al || jsonb_build_array('Fiscalização sem assinatura'); end if;

  insert into "16 - qsms".sst_checklist(id, tipo, data, consorcio, os, tipo_intervencao, equipe, local, tipo_pavimento, resultado, observacoes,
    encarregado_uuid, encarregado_nome, encarregado_assinatura, encarregado_assinado_em, fiscal_assinatura, fiscal_assinado_em,
    lat, lon, gps_precisao, geom, endereco, bairro, municipio, fotos, usuario_uuid, usuario_nome, dispositivo, preenchimento_manual)
  values (p_id, v_tipo, v_data, coalesce(v_loc->>'consorcio', "16 - qsms".qsms_consorcio(null, d->>'consorcio', v_uid)),
    nullif(btrim(d->>'os'),''), nullif(btrim(d->>'tipo_intervencao'),''), nullif(btrim(d->>'equipe'),''), case when not v_manual then nullif(btrim(d->>'local'),'') end,
    case when v_tipo = 'recomposicao' then nullif(btrim(d->>'tipo_pavimento'),'') end, v_res, nullif(btrim(d->>'observacoes'),''),
    v_euid, v_enome, v_esig, case when v_esig is not null then nullif(d->>'encarregado_assinado_em','')::timestamptz end,
    v_fsig, case when v_fsig is not null then nullif(d->>'fiscal_assinado_em','')::timestamptz end,
    v_lat, v_lon, case when not v_manual then nullif(d->>'precisao','')::numeric end, v_geom,
    case when v_manual then v_endman else v_loc->>'endereco' end, v_loc->>'bairro', v_loc->>'municipio',
    (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_anx) where key like 'foto\_%' and jsonb_typeof(value) = 'string'),
    v_uid, v_nome, left(d->>'dispositivo', 120), v_manual);

  for it in select * from jsonb_array_elements(coalesce(d->'itens','[]'::jsonb)) loop
    i := i + 1;
    v_r := upper(coalesce(it->>'resultado',''));
    if v_r not in ('C','NC','NA') then v_al := v_al || jsonb_build_array(format('Item %s sem resposta (gravado como NA)', i)); v_r := 'NA'; end if;
    if v_r = 'NC' then n_nc := n_nc + 1;
      if nullif(btrim(it->>'obs'),'') is null then v_al := v_al || jsonb_build_array(format('NC no item %s sem observação', i)); end if; end if;
    v_foto := case when nullif(it->>'foto','') is not null then v_anx->>(it->>'foto') end;
    insert into "16 - qsms".sst_checklist_item(checklist_id, ordem, codigo, grupo, item, resultado, obs, foto)
    values (p_id, i, nullif(it->>'codigo',''), nullif(btrim(it->>'grupo'),''), coalesce(nullif(btrim(it->>'item'),''), '(item sem nome)'),
      v_r, nullif(btrim(it->>'obs'),''), v_foto);
  end loop;
  if i = 0 then v_al := v_al || jsonb_build_array('Checklist sem itens'); end if;
  if v_res = 'conforme' and n_nc > 0 then v_al := v_al || jsonb_build_array('Resultado "conforme" com item não conforme'); end if;
  update "16 - qsms".sst_checklist set alertas = v_al where id = p_id;
  return jsonb_build_object('id', p_id, 'alertas', v_al);
end $$;

revoke all on function public.app_sst_ck_registrar(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.app_sst_ck_registrar(uuid, jsonb, jsonb) to authenticated;
