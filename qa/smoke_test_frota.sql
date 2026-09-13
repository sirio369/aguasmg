-- ============================================================================
-- Smoke test dos ciclos críticos do módulo Frota (schema "10 - Frotas")
-- ============================================================================
-- Como rodar: cole o bloco inteiro no SQL Editor do Supabase (ou via MCP
-- execute_sql) do projeto lwttadkctfznidzvmury e execute. Cada bloco `do $$`
-- roda dentro de uma transação que sempre termina em ROLLBACK (o
-- `raise exception 'ROLLBACK_OK...'` no fim de cada bloco garante isso) —
-- nada fica gravado no banco, mesmo passando. Se algo estiver quebrado, o
-- bloco falha com uma mensagem "FALHA: ..." em vez de "ROLLBACK_OK".
--
-- Rode isso depois de qualquer mudança nas RPCs de Frota (principalmente
-- vínculo, manutenção e lavagem) e sempre depois de mudar assinatura de RPC
-- (some junto uma checagem de overload órfão, ver bloco 0).
--
-- Idealmente isso rodaria contra uma branch de banco isolada, não produção —
-- não configurei isso porque criar branch no Supabase tem custo real e exige
-- confirmação própria (`confirm_cost`) que não está disponível nas
-- ferramentas desta sessão. Rodar contra produção é seguro aqui só porque
-- todo bloco é 100% rollback — não é a forma ideal a longo prazo, ver
-- docs/MODULOS.md §6 "Cuidados".
--
-- IDs usados abaixo (ajuste se essas pessoas/veículo saírem da base):
--   veículo QCB3510 = id 18 (único veículo real cadastrado até 2026-09)
--   Sander Sirio (admin/frotas) = 7917913b-787f-4a0e-a0b9-f9a52282f641
--   Cibely Felix de Lima (funcao='campo', sem papel de aprovação) = ff37e0e2-a6f8-4fd6-bfe2-a2ca2252be96
--   Kayan Santos (funcao='campo', terceiro sem relação nenhuma) = fcf24ec3-2efe-4990-b8e4-364c813673d6
-- ============================================================================


-- ---------------------------------------------------------------------------
-- Bloco 0: nenhuma RPC de Frota deve ter overload órfão (mesmo nome, listas
-- de parâmetros diferentes) — sintoma de CREATE OR REPLACE que só acrescentou
-- parâmetro em vez de dropar+recriar (ver docs/MODULOS.md §6 "Cuidados").
-- ---------------------------------------------------------------------------
do $$
declare v_qtd int;
begin
  select count(*) into v_qtd from (
    select p.proname
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and (p.proname like 'app_frota%' or p.proname like 'app_condutor%')
    group by p.proname having count(*)>1
  ) x;
  if v_qtd>0 then raise exception 'FALHA: % função(ões) de Frota com overload duplicado — rode a query de auditoria completa (docs/MODULOS.md §6)', v_qtd; end if;
  raise exception 'ROLLBACK_OK :: bloco 0 (overloads órfãos) — nenhum encontrado';
end $$;


-- ---------------------------------------------------------------------------
-- Bloco 1: nenhuma RPC de Frota deve ter EXECUTE liberado pra anon/public
-- (invariante de grants, §0 do CLAUDE.md).
-- ---------------------------------------------------------------------------
do $$
declare v_qtd int;
begin
  select count(*) into v_qtd
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and (p.proname like 'app_frota%' or p.proname like 'app_condutor%')
    and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('public', p.oid, 'EXECUTE'));
  if v_qtd>0 then raise exception 'FALHA: % função(ões) de Frota com EXECUTE liberado pra anon/public', v_qtd; end if;
  raise exception 'ROLLBACK_OK :: bloco 1 (grants) — nenhum vazamento encontrado';
end $$;


-- ---------------------------------------------------------------------------
-- Bloco 2: ciclo de vínculo — vincular_me / desvincular_me e o efeito
-- colateral em frota_veiculo.status (disponivel<->em_uso).
-- ---------------------------------------------------------------------------
do $$
declare
  v_condutor uuid := 'fcf24ec3-2efe-4990-b8e4-364c813673d6';
  v_veiculo_id bigint := 18;
  v_status_antes text;
  v_status_depois text;
begin
  select status into v_status_antes from "10 - Frotas".frota_veiculo where id=v_veiculo_id;
  -- este teste só faz sentido se o veículo estiver livre; se já tiver dono, avisa e sai sem falhar
  if v_status_antes <> 'disponivel' then
    raise exception 'ROLLBACK_OK :: bloco 2 pulado — veículo % não está disponível agora (status=%), sem como testar vínculo sem desfazer o vínculo real', v_veiculo_id, v_status_antes;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub',v_condutor::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  perform public.app_frota_veiculo_vincular_me(v_veiculo_id);
  perform set_config('role','postgres', true);

  select status into v_status_depois from "10 - Frotas".frota_veiculo where id=v_veiculo_id;
  if v_status_depois <> 'em_uso' then raise exception 'FALHA: vincular_me não deixou o veículo em_uso (está %)', v_status_depois; end if;

  perform set_config('request.jwt.claims', json_build_object('sub',v_condutor::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  perform public.app_frota_veiculo_desvincular_me();
  perform set_config('role','postgres', true);

  select status into v_status_depois from "10 - Frotas".frota_veiculo where id=v_veiculo_id;
  if v_status_depois <> 'disponivel' then raise exception 'FALHA: desvincular_me não deixou o veículo disponivel (está %)', v_status_depois; end if;

  raise exception 'ROLLBACK_OK :: bloco 2 (vínculo/desvínculo + status do veículo) — tudo certo';
end $$;


-- ---------------------------------------------------------------------------
-- Bloco 3: ciclo completo de manutenção — solicitar -> aprovar -> agendar
-- (2 parâmetros, sem custo, marca veículo 'manutencao') -> concluir (pelo
-- próprio colaborador que reportou, com custo, restaura status do veículo).
-- Também confere que um terceiro sem relação é recusado no concluir.
-- ---------------------------------------------------------------------------
do $$
declare
  v_reporter uuid := 'ff37e0e2-a6f8-4fd6-bfe2-a2ca2252be96';
  v_terceiro uuid := 'fcf24ec3-2efe-4990-b8e4-364c813673d6';
  v_admin uuid := '7917913b-787f-4a0e-a0b9-f9a52282f641';
  v_veiculo_id bigint := 18;
  v_manut_id bigint;
  v_status_veic text;
  v_status_manut text;
  v_orcamento numeric;
  v_negou boolean := false;
begin
  insert into "10 - Frotas".frota_manutencao(veiculo_id,tipo_problema,servico_solicitado,status,reportado_por,reportado_em)
  values (v_veiculo_id,'freio','[smoke test] ruído no freio','pendente',v_reporter,now())
  returning id into v_manut_id;

  update "10 - Frotas".frota_manutencao set status='aprovado', aprovado_por=v_admin, aprovado_em=now() where id=v_manut_id;

  perform set_config('request.jwt.claims', json_build_object('sub',v_admin::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  perform public.app_frota_manutencao_agendar(v_manut_id, current_date);
  perform set_config('role','postgres', true);

  select status into v_status_veic from "10 - Frotas".frota_veiculo where id=v_veiculo_id;
  if v_status_veic <> 'manutencao' then raise exception 'FALHA: agendar não marcou o veículo como manutencao (está %)', v_status_veic; end if;

  -- terceiro sem relação (nem reportou, nem é frotas/admin) tem que ser recusado
  perform set_config('request.jwt.claims', json_build_object('sub',v_terceiro::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  begin
    perform public.app_frota_manutencao_concluir(v_manut_id, current_date, null, 999);
  exception when others then
    if sqlerrm = 'sem permissão' then v_negou := true; else raise; end if;
  end;
  perform set_config('role','postgres', true);
  if not v_negou then raise exception 'FALHA: terceiro sem relação conseguiu concluir a manutenção de outro colaborador'; end if;

  -- o próprio reportante conclui, com custo
  perform set_config('request.jwt.claims', json_build_object('sub',v_reporter::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  perform public.app_frota_manutencao_concluir(v_manut_id, current_date, null, 275.50);
  perform set_config('role','postgres', true);

  select status, orcamento_valor into v_status_manut, v_orcamento from "10 - Frotas".frota_manutencao where id=v_manut_id;
  if v_status_manut <> 'concluido' then raise exception 'FALHA: status final não é concluido (é %)', v_status_manut; end if;
  if v_orcamento is distinct from 275.50 then raise exception 'FALHA: custo final não gravado corretamente (está %)', v_orcamento; end if;

  select status into v_status_veic from "10 - Frotas".frota_veiculo where id=v_veiculo_id;
  if v_status_veic = 'manutencao' then raise exception 'FALHA: concluir não restaurou o status do veículo (continua manutencao)'; end if;

  raise exception 'ROLLBACK_OK :: bloco 3 (ciclo completo de manutenção + permissão + status do veículo) — tudo certo';
end $$;


-- ---------------------------------------------------------------------------
-- Bloco 4: checklist e abastecimento devem ser recusados enquanto o veículo
-- está em 'manutencao' (gate novo — ver docs/MODULOS.md §6 "Cuidados").
-- ---------------------------------------------------------------------------
do $$
declare
  v_condutor uuid := '7917913b-787f-4a0e-a0b9-f9a52282f641';
  v_veiculo_id bigint := 18;
  v_status_original text;
  v_negou_checklist boolean := false;
  v_negou_abastecimento boolean := false;
begin
  select status into v_status_original from "10 - Frotas".frota_veiculo where id=v_veiculo_id;
  update "10 - Frotas".frota_veiculo set status='manutencao' where id=v_veiculo_id;

  perform set_config('request.jwt.claims', json_build_object('sub',v_condutor::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  begin
    perform public.app_frota_situacao_salvar(v_veiculo_id, 48000, 'ok', true,true,true,true,true,true, null, null, null, null, null, null);
  exception when others then v_negou_checklist := true;
  end;
  begin
    perform public.app_frota_abastecimento_salvar(v_veiculo_id, 48000, 'etanol', 10, 5, 50, null, null, null, null, null, null);
  exception when others then v_negou_abastecimento := true;
  end;
  perform set_config('role','postgres', true);

  update "10 - Frotas".frota_veiculo set status=v_status_original where id=v_veiculo_id;

  if not v_negou_checklist then raise exception 'FALHA: checklist foi aceito com o veículo em manutencao'; end if;
  if not v_negou_abastecimento then raise exception 'FALHA: abastecimento foi aceito com o veículo em manutencao'; end if;

  raise exception 'ROLLBACK_OK :: bloco 4 (bloqueio de checklist/abastecimento em manutenção) — tudo certo';
end $$;


-- ---------------------------------------------------------------------------
-- Bloco 5: ciclo completo de lavagem — solicitar -> agendar -> realizar.
-- ---------------------------------------------------------------------------
do $$
declare
  v_condutor uuid := '7917913b-787f-4a0e-a0b9-f9a52282f641';
  v_admin uuid := '7917913b-787f-4a0e-a0b9-f9a52282f641';
  v_veiculo_id bigint := 18;
  v_lav_id bigint;
  v_status text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub',v_condutor::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  select (public.app_frota_lavagem_solicitar(v_veiculo_id)->>'id')::bigint into v_lav_id;
  perform set_config('role','postgres', true);

  perform set_config('request.jwt.claims', json_build_object('sub',v_admin::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  perform public.app_frota_lavagem_agendar(v_lav_id, current_date, '09:00', '[smoke test] lava-rápido');
  perform set_config('role','postgres', true);

  select status into v_status from "10 - Frotas".frota_lavagem where id=v_lav_id;
  if v_status <> 'agendada' then raise exception 'FALHA: agendar não deixou a lavagem agendada (está %)', v_status; end if;

  perform set_config('request.jwt.claims', json_build_object('sub',v_condutor::text,'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);
  perform public.app_frota_lavagem_realizar(v_lav_id, 40, null);
  perform set_config('role','postgres', true);

  select status into v_status from "10 - Frotas".frota_lavagem where id=v_lav_id;
  if v_status <> 'realizada' then raise exception 'FALHA: realizar não deixou a lavagem realizada (está %)', v_status; end if;

  raise exception 'ROLLBACK_OK :: bloco 5 (ciclo completo de lavagem) — tudo certo';
end $$;
