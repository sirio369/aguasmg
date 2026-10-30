-- Checklist diário: só grava no veículo em que a pessoa está vinculada AGORA. 2026-10-30.
-- Caso real: Roberto trocou de carro (desvinculou TZW8B57 10:27, vinculou UVU2H21 10:29) com a tela do checklist aberta;
-- o envio às 10:30 foi gravado no carro antigo. Agora o servidor recusa e o app recarrega a tela com o carro certo.
-- Mesma função de antes + bloco "vínculo atual". Idempotente.
CREATE OR REPLACE FUNCTION public.app_frota_situacao_salvar(p_veiculo_id bigint, p_km numeric, p_status text, p_pneus_ok boolean, p_freios_ok boolean, p_oleo_ok boolean, p_luzes_ok boolean, p_extintor_ok boolean, p_triangulo_macaco_estepe_ok boolean, p_avarias text, p_observacoes text, p_fotos text[], p_gps_lat numeric, p_gps_lon numeric, p_consorcio text, p_foto2 text DEFAULT NULL::text, p_foto3 text DEFAULT NULL::text, p_foto4 text DEFAULT NULL::text, p_foto5 text DEFAULT NULL::text, p_foto6 text DEFAULT NULL::text, p_faces jsonb DEFAULT '[]'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid:=auth.uid(); v_new_id bigint; v_veic_status text; v_fotos text[]; v_occ jsonb; v_srv text; v_fa text[]; v_status text;
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  -- vínculo atual: o checklist é sempre do carro que está com a pessoa agora
  if not exists (select 1 from "10 - Frotas".frota_veiculo_vinculo vv
                 where vv.veiculo_id=p_veiculo_id and vv.condutor_id=v_id and vv.desvinculado_em is null) then
    raise exception 'VEICULO_TROCADO: você não está mais vinculado a este veículo — a tela será recarregada com o seu veículo atual';
  end if;
  select status into v_veic_status from "10 - Frotas".frota_veiculo where id=p_veiculo_id;
  if v_veic_status='manutencao' then raise exception 'veículo está em manutenção no momento — não é possível registrar checklist agora'; end if;
  v_fotos := coalesce(p_fotos,'{}') || array_remove(array[p_foto2,p_foto3,p_foto4,p_foto5,p_foto6], null);
  select coalesce(jsonb_agg(e),'[]'::jsonb) into v_occ
    from jsonb_array_elements(coalesce(p_faces,'[]'::jsonb)) e where coalesce((e->>'ocorrencia')::boolean,false);
  v_status := coalesce(p_status, case when jsonb_array_length(v_occ)>0 then 'com_pendencia' else 'ok' end);
  insert into "10 - Frotas".frota_checklist_situacao(veiculo_id,km,status,pneus_ok,freios_ok,oleo_ok,luzes_ok,extintor_ok,triangulo_macaco_estepe_ok,avarias,observacoes,fotos,gps_lat,gps_lon,consorcio,reportado_por,faces)
  values(p_veiculo_id,p_km,v_status,p_pneus_ok,p_freios_ok,p_oleo_ok,p_luzes_ok,p_extintor_ok,p_triangulo_macaco_estepe_ok,p_avarias,p_observacoes,v_fotos,p_gps_lat,p_gps_lon,p_consorcio,v_id,coalesce(p_faces,'[]'::jsonb))
  returning id into v_new_id;
  update "10 - Frotas".frota_veiculo set km_atual=greatest(coalesce(km_atual,0),coalesce(p_km,0)) where id=p_veiculo_id;
  if jsonb_array_length(v_occ)>0 then
    select string_agg(coalesce(e->>'label',e->>'face')||coalesce(': '||nullif(e->>'descricao',''),''), E'\n')
      into v_srv from jsonb_array_elements(v_occ) e;
    select array_remove(array_agg(e->>'foto'),null) into v_fa from jsonb_array_elements(v_occ) e where nullif(e->>'foto','') is not null;
    insert into "10 - Frotas".frota_manutencao(veiculo_id,tipo_problema,servico_solicitado,fotos_antes,status,reportado_por,reportado_em)
    values(p_veiculo_id,'checklist','Ocorrências do checklist:'||E'\n'||coalesce(v_srv,''),coalesce(v_fa,'{}'),'pendente',v_id,now());
  end if;
  return v_new_id;
end; $function$;
notify pgrst, 'reload schema';
