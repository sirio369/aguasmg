-- Smoke test do módulo Indicadores SST (rollback garantido: termina com raise exception).
-- Rodar DEPOIS da migração docs/migracao_sst_indicadores.sql (ou concatenado a ela dentro de begin;).
do $$
declare
  tst uuid := '82fb9367-11ec-471a-9338-51f3e36e28eb';   -- TST (cargo) → campo + gestão
  sem uuid := 'ff37e0e2-a6f8-4fd6-bfe2-a2ca2252be96';   -- campo comum, sem acesso QSMS
  v_insp uuid := gen_random_uuid(); v_dds uuid := gen_random_uuid(); v_oc uuid := gen_random_uuid();
  r jsonb; v_item uuid; v_acao uuid; v_aso uuid; v_tr uuid; v_m uuid; v_reu uuid; ok text := ''; n int; v_err text;
begin
  -- 1) campo comum não entra
  perform set_config('request.jwt.claims', json_build_object('sub', sem, 'role', 'authenticated')::text, true);
  if (public.app_me()->>'qsms_campo')::boolean then raise exception 'FALHA: campo comum com qsms_campo'; end if;
  begin
    perform public.app_sst_inspecao_registrar(gen_random_uuid(), '{}'::jsonb, '{}'::jsonb);
    raise exception 'FALHA: campo comum registrou inspeção';
  exception when others then
    if sqlerrm not like '%sem permissão%' then raise; end if;
  end;
  begin
    perform public.app_sst_painel(current_date - 30, current_date, null);
    raise exception 'FALHA: campo comum leu painel';
  exception when others then
    if sqlerrm not like '%sem permissão%' then raise; end if;
  end;
  ok := ok || 'gate_ok ';

  -- 2) TST lança em campo
  perform set_config('request.jwt.claims', json_build_object('sub', tst, 'role', 'authenticated')::text, true);
  if not (public.app_me()->>'qsms_campo')::boolean then raise exception 'FALHA: TST sem qsms_campo'; end if;
  r := public.app_sst_inspecao_registrar(v_insp, jsonb_build_object('area','Obras - HDD','local','Rua teste','cargo','TST',
        'lat',-19.9677,'lon',-44.1983,'precisao',5,
        'itens', jsonb_build_array(
          jsonb_build_object('item','Sinalização','grupo','Sinalização','resultado','C'),
          jsonb_build_object('item','EPI','grupo','EPI','resultado','NC','descricao','sem luva','foto','foto_1','prazo',(current_date-1)::text),
          jsonb_build_object('item','Veículo','resultado','NC','descricao','na faixa','tratada_no_local',true,'tratativa','removido'),
          jsonb_build_object('item','Escavação','resultado','NA'))),
        jsonb_build_object('foto_1','seg/teste.jpg'));
  if jsonb_array_length(r->'alertas') <> 1 then raise exception 'FALHA: alertas inspeção %', r; end if;   -- NC sem foto (item 3)
  if not (public.app_sst_inspecao_registrar(v_insp, '{}'::jsonb, '{}'::jsonb)->>'duplicado')::boolean then raise exception 'FALHA: idempotência'; end if;
  select to_jsonb(b) into r from "16 - qsms".bi_sst_inspecoes b where "ID" = v_insp::text;
  if (r->>'Itens Verificados')::numeric <> 3 or (r->>'NCs Encontradas')::numeric <> 2 or (r->>'NCs Tratadas')::numeric <> 1
     or r->>'Consórcio' is null then raise exception 'FALHA: totais da inspeção %', r; end if;
  ok := ok || 'insp_ok ';

  r := public.app_sst_dds_registrar(v_dds, jsonb_build_object('area','Geral','tema','Proteção das mãos','duracao_min',10,
        'lat',-19.9677,'lon',-44.1983,
        'participantes', jsonb_build_array(
          jsonb_build_object('pessoa_uuid', sem, 'nome','x','sig','sig_1'),
          jsonb_build_object('pessoa_uuid', sem, 'nome','x dup','sig','sig_1'),
          jsonb_build_object('pessoa_uuid', tst, 'nome','y'))),
        jsonb_build_object('sig_1','seg/sig.png'));
  select count(*) into n from "16 - qsms".sst_dds_presenca where dds_id = v_dds;
  if n <> 2 then raise exception 'FALHA: presença dedup (% linhas)', n; end if;
  if (select "Efetivo da Área" from "16 - qsms".bi_sst_dds where "ID"=v_dds::text) < 1 then raise exception 'FALHA: efetivo'; end if;
  ok := ok || 'dds_ok ';

  r := public.app_sst_ocorrencia_registrar(v_oc, jsonb_build_object('natureza','Acidente','tipo','Típico','area','Obras - HDD',
        'vitima_uuid', sem, 'parte_corpo','Mão','descricao','corte leve','lat',-19.9677,'lon',-44.1983), '{}'::jsonb);
  if (select "Vínculo" from "16 - qsms".bi_sst_acidentes_vinculo where "ID"=v_oc::text) <> 'Próprio' then raise exception 'FALHA: vínculo'; end if;
  r := public.app_sst_minhas(30);
  if jsonb_array_length(r->'inspecoes') < 1 or jsonb_array_length(r->'dds') < 1 or jsonb_array_length(r->'ocorrencias') < 1 then raise exception 'FALHA: minhas %', r; end if;
  ok := ok || 'oc_ok ';

  -- 3) gestão
  select id into v_item from "16 - qsms".sst_inspecao_item where inspecao_id = v_insp and trat_status = 'pendente';
  r := public.app_sst_painel(current_date - 30, current_date, null);
  if (r->'nc_pendentes'->>'vencidas')::int < 1 then raise exception 'FALHA: NC vencida no painel %', r->'nc_pendentes'; end if;
  perform public.app_sst_nc_tratar(v_item, 'tratada', 'luva entregue', null);
  if (select "NCs Tratadas" from "16 - qsms".bi_sst_inspecoes where "ID"=v_insp::text) <> 2 then raise exception 'FALHA: tratadas'; end if;
  if (select count(*) from "16 - qsms".sst_evento where registro_id = v_item::text) < 1 then raise exception 'FALHA: auditoria'; end if;
  perform public.app_sst_ocorrencia_validar(v_oc, jsonb_build_object('classificacao','Sem Afastamento','gravidade','Leve','cat_emitida',false));
  v_acao := public.app_sst_acao_salvar(null, v_oc, jsonb_build_object('descricao','Reforçar uso de luva','prazo',(current_date-2)::text,'responsavel_uuid',tst));
  if (select "Ação Vencida" from "16 - qsms".bi_sst_acidentes_vinculo where "ID"=v_oc::text) <> 'Sim' then raise exception 'FALHA: ação vencida'; end if;
  perform public.app_sst_acao_salvar(v_acao, v_oc, jsonb_build_object('descricao','Reforçar uso de luva','status','Concluída'));
  if (select "Status da Ação" from "16 - qsms".bi_sst_acidentes_vinculo where "ID"=v_oc::text) <> 'Concluída' then raise exception 'FALHA: ação concluída'; end if;
  r := public.app_sst_ver('ocorrencia', v_oc);
  if r->>'status' <> 'validada' or jsonb_array_length(r->'acoes') <> 1 then raise exception 'FALHA: ver ocorrência'; end if;
  ok := ok || 'gestao_ok ';

  v_aso := public.app_sst_aso_salvar(null, jsonb_build_object('pessoa_uuid', sem, 'tipo_exame','Periódico','data_exame',(current_date-350)::text));
  if (select "Situação ASO" from "16 - qsms".bi_sst_saude where "ID"=v_aso::text) <> 'A vencer (30 dias)' then raise exception 'FALHA: ASO a vencer'; end if;
  v_tr := public.app_sst_trein_salvar(null, jsonb_build_object('pessoa_uuid', sem, 'tipo_id',(select id from "16 - qsms".sst_treinamento_tipo where nome like 'Trabalho em Altura%'),'data_realizacao',(current_date-30)::text));
  if (select "Situação" from "16 - qsms".bi_sst_treinamentos where "ID"=v_tr::text) <> 'Válido' then raise exception 'FALHA: treinamento'; end if;
  r := public.app_sst_trein_matriz(null);
  if jsonb_array_length(r->'tipos') <> 4 then raise exception 'FALHA: matriz tipos'; end if;
  v_m := public.app_sst_cipa_membro_salvar(null, jsonb_build_object('nome','Fulano','representacao','Empregados','tipo','Titular','consorcio','ZA0200','fim_mandato',(current_date+300)::text));
  v_reu := public.app_sst_cipa_reuniao_salvar(null, jsonb_build_object('data',current_date::text,'consorcio','ZA0200','presentes',3,'total_membros',4));
  r := public.app_sst_painel(current_date - 30, current_date, 'ZA0200');
  if (r->'cipa'->>'presenca')::numeric <> 0.75 then raise exception 'FALHA: presença CIPA %', r->'cipa'; end if;
  ok := ok || 'cadastros_ok ';

  perform public.app_sst_anular('dds', v_dds, 'teste');
  if exists (select 1 from "16 - qsms".bi_sst_dds where "ID"=v_dds::text) then raise exception 'FALHA: anulado na view'; end if;
  begin
    delete from "16 - qsms".sst_inspecao where id = v_insp;
    raise exception 'FALHA: delete passou';
  exception when others then
    if sqlerrm not like '%não podem ser apagados%' then raise; end if;
  end;
  ok := ok || 'anular_ok ';

  -- 4) papel do BI: lê view, não lê tabela
  -- (postgres no Supabase não pode SET ROLE; confere os privilégios direto)
  select count(*) into n from information_schema.views where table_schema = '16 - qsms' and table_name like 'bi\_sst\_%'
    and has_table_privilege('bi_qsms_leitura', format('%I.%I', table_schema, table_name), 'select');
  if n <> 10 then raise exception 'FALHA: BI lê % de 10 views', n; end if;
  if has_table_privilege('bi_qsms_leitura', '"16 - qsms".sst_inspecao', 'select')
     or has_table_privilege('bi_qsms_leitura', '"16 - qsms".qsms_atividade', 'select')
     or has_table_privilege('anon', '"16 - qsms".bi_sst_saude', 'select')
     or has_table_privilege('authenticated', '"16 - qsms".bi_sst_saude', 'select') then
    raise exception 'FALHA: privilégio a mais';
  end if;
  select count(*) into n from "16 - qsms".bi_sst_area;
  select count(*) into n from "16 - qsms".bi_sst_info;
  ok := ok || 'bi_ok ';

  raise exception 'ROLLBACK_OK :: %', ok;
end $$;
