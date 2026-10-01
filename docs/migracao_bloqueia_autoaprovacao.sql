-- Migração: bloqueia_autoaprovacao — ninguém aprova o próprio pedido (auditoria 2026-10-01: 7 autoaprovações).
-- Aprovar: Insumos/Ferramentas (sup_aprovar), EPI (sup_epi_aprovar), Troca de EPI (sup_epi_troca_aprovar),
-- Manutenção de frota (app_frota_manutencao_aprovar, inclusive admin) e Condutor/CNH (app_condutor_aprovar, inclusive admin).
-- Filas de aprovação deixam de listar o próprio pedido. Assinaturas inalteradas (create or replace).
-- Base: definições de produção de 2026-10-01; só foram acrescentadas as checagens de autoaprovação.
-- ===== app_condutor_aprovar
CREATE OR REPLACE FUNCTION public.app_condutor_aprovar(p_condutor_id uuid, p_aprovado boolean, p_motivo text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare v_id uuid := auth.uid(); v_admin boolean; v_aps uuid[]; begin if v_id is null then raise exception 'não autenticado'; end if; select (funcao='admin') into v_admin from public.perfil where id=v_id; if p_condutor_id = v_id then raise exception 'autoaprovacao nao permitida: o pedido precisa ser aprovado pelo seu aprovador 1/2'; end if; v_aps := "9 - suprimentos".sup_aprovadores_de(p_condutor_id); if not (coalesce(v_admin,false) or v_id = any(v_aps)) then raise exception 'sem permissão para aprovar este condutor'; end if; if p_aprovado then update "10 - Frotas".frota_condutor set status='apto', aprovado_por=v_id, aprovado_em=now(), prazo_treinamento=(current_date + 10), motivo_reprovacao=null, atualizado_em=now() where id=p_condutor_id; else update "10 - Frotas".frota_condutor set status='reprovado', aprovado_por=v_id, aprovado_em=now(), motivo_reprovacao=p_motivo, atualizado_em=now() where id=p_condutor_id; end if; end; $function$
;

-- ===== app_frota_manutencao_aprovar
CREATE OR REPLACE FUNCTION public.app_frota_manutencao_aprovar(p_id bigint, p_aprovado boolean, p_motivo text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_admin boolean; v_alvo uuid; v_aps uuid[];
begin
  if v_id is null then raise exception 'não autenticado'; end if;
  select (funcao='admin') into v_admin from public.perfil where id=v_id;
  select coalesce(v.condutor_exclusivo_id, m.reportado_por) into v_alvo
  from "10 - Frotas".frota_manutencao m join "10 - Frotas".frota_veiculo v on v.id=m.veiculo_id where m.id=p_id;
  if exists(select 1 from "10 - Frotas".frota_manutencao where id=p_id and reportado_por=v_id) then raise exception 'autoaprovacao nao permitida: o pedido precisa ser aprovado pelo seu aprovador 1/2'; end if;
  v_aps := "9 - suprimentos".sup_aprovadores_de(v_alvo);
  if not (coalesce(v_admin,false) or v_id = any(v_aps)) then raise exception 'sem permissão para aprovar'; end if;
  update "10 - Frotas".frota_manutencao
  set status = case when p_aprovado then 'aprovado' else 'reprovado' end,
      aprovado_por=v_id, aprovado_em=now(),
      motivo_reprovacao = case when p_aprovado then null else p_motivo end
  where id=p_id;
end;
$function$
;

-- ===== sup_aprovar
CREATE OR REPLACE FUNCTION public.sup_aprovar(p_solicitacao_id bigint, p_ajustes jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_st text; v_it jsonb; v_sol uuid;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  if not "9 - suprimentos".sup_pode_aprovar(v_uid) then raise exception 'sem permissao para aprovar'; end if;
  select status::text, solicitante_uuid into v_st, v_sol from "9 - suprimentos".sup_solicitacao where id=p_solicitacao_id;
  if v_sol = v_uid then raise exception 'autoaprovacao nao permitida: o pedido precisa ser aprovado pelo seu aprovador 1/2'; end if;
  if v_st is null then raise exception 'solicitacao inexistente'; end if;
  if v_st <> 'solicitada' then raise exception 'solicitacao ja foi tratada (status=%)', v_st; end if;
  update "9 - suprimentos".sup_solicitacao_item set qt_aprovada=qt_solicitada where solicitacao_id=p_solicitacao_id;
  if p_ajustes is not null then
    for v_it in select * from jsonb_array_elements(p_ajustes) loop
      update "9 - suprimentos".sup_solicitacao_item
        set qt_aprovada = greatest(0, coalesce((v_it->>'qtd')::numeric, qt_solicitada))
      where solicitacao_id=p_solicitacao_id and material_id=(v_it->>'material_id')::bigint;
    end loop;
  end if;
  if not exists(select 1 from "9 - suprimentos".sup_solicitacao_item where solicitacao_id=p_solicitacao_id and coalesce(qt_aprovada,0)>0) then
    raise exception 'nenhum item aprovado — rejeite a solicitacao em vez de aprovar';
  end if;
  update "9 - suprimentos".sup_solicitacao set status='aprovada', aprovador_uuid=v_uid, aprovado_em=now() where id=p_solicitacao_id;
  return jsonb_build_object('id',p_solicitacao_id,'status','aprovada');
end; $function$
;

-- ===== sup_epi_aprovar
CREATE OR REPLACE FUNCTION public.sup_epi_aprovar(p_solicitacao_id bigint, p_itens jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_st text; v_sol uuid;
begin
  if not "9 - suprimentos".sup_epi_gestor(v_uid) then raise exception 'sem permissao para aprovar'; end if;
  select status, solicitante_uuid into v_st, v_sol from "9 - suprimentos".sup_epi_solicitacao where id=p_solicitacao_id;
  if v_sol = v_uid then raise exception 'autoaprovacao nao permitida: o pedido precisa ser aprovado pelo seu aprovador 1/2'; end if;
  if v_st is null then raise exception 'solicitacao inexistente'; end if;
  if v_st<>'solicitada' then raise exception 'solicitacao ja tratada (%)', v_st; end if;
  if p_itens is not null then
    update "9 - suprimentos".sup_epi_solicitacao_item si
      set qt_aprovada = greatest(0, coalesce((x->>'qt')::numeric, si.qt_solicitada))
      from jsonb_array_elements(p_itens) x
      where si.solicitacao_id=p_solicitacao_id and si.id=(x->>'item_id')::bigint;
    update "9 - suprimentos".sup_epi_solicitacao_item
      set qt_aprovada=qt_solicitada where solicitacao_id=p_solicitacao_id and qt_aprovada is null;
  else
    update "9 - suprimentos".sup_epi_solicitacao_item set qt_aprovada=qt_solicitada where solicitacao_id=p_solicitacao_id;
  end if;
  if not exists(select 1 from "9 - suprimentos".sup_epi_solicitacao_item where solicitacao_id=p_solicitacao_id and coalesce(qt_aprovada,0)>0) then
    raise exception 'nenhum item aprovado — rejeite a solicitacao em vez de aprovar';
  end if;
  update "9 - suprimentos".sup_epi_solicitacao set status='aprovada', aprovador_uuid=v_uid, aprovado_em=now() where id=p_solicitacao_id;
  return jsonb_build_object('id',p_solicitacao_id,'status','aprovada');
end; $function$
;

-- ===== sup_epi_fila_aprovacao
CREATE OR REPLACE FUNCTION public.sup_epi_fila_aprovacao()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not "9 - suprimentos".sup_epi_gestor(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
      'itens',(select jsonb_agg(jsonb_build_object('item_id',i.id,'epi',e.nome,'qt',i.qt_solicitada,'tamanho',i.tamanho,
                 'na_cesta', exists(select 1 from "9 - suprimentos".sup_epi_cesta ce where ce.cargo_id=p.cargo_id and ce.epi_id=i.epi_id))
                 order by e.nome)
               from "9 - suprimentos".sup_epi_solicitacao_item i join "9 - suprimentos".sup_epi e on e.id=i.epi_id where i.solicitacao_id=s.id)) order by s.criado_em)
      from "9 - suprimentos".sup_epi_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid where s.status='solicitada' and s.solicitante_uuid is distinct from auth.uid()),'[]'::jsonb) end;
$function$
;

-- ===== sup_epi_troca_aprovar
CREATE OR REPLACE FUNCTION public.sup_epi_troca_aprovar(p_pedido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not "9 - suprimentos".sup_epi_gestor(auth.uid()) then raise exception 'sem permissao'; end if;
  if exists(select 1 from "9 - suprimentos".sup_epi_baixa_pedido where id=p_pedido_id and colaborador_uuid=auth.uid()) then raise exception 'autoaprovacao nao permitida: o pedido precisa ser aprovado pelo seu aprovador 1/2'; end if;
  update "9 - suprimentos".sup_epi_baixa_pedido set status='solicitada', aprovador_uuid=auth.uid(), aprovado_em=now()
    where id=p_pedido_id and tipo='troca' and status='aguardando_aprovacao';
  if not found then raise exception 'pedido inexistente ou ja tratado'; end if;
  return jsonb_build_object('id',p_pedido_id,'status','solicitada');
end; $function$
;

-- ===== sup_epi_troca_fila_aprovacao
CREATE OR REPLACE FUNCTION public.sup_epi_troca_fila_aprovacao()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not "9 - suprimentos".sup_epi_gestor(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'criado_em',b.criado_em,'colaborador',p.nome,
        'epi',e.nome,'ca',coalesce(it.ca,e.ca),'tamanho',it.tamanho,'quantidade',it.quantidade,
        'vence_em',it.vence_em,'vencido',(it.vence_em is not null and it.vence_em<=current_date),
        'obs',b.obs,'foto',b.foto_solicitacao_path) order by b.criado_em)
      from "9 - suprimentos".sup_epi_baixa_pedido b
      join "9 - suprimentos".sup_epi_entrega_item it on it.id=b.entrega_item_id
      join "9 - suprimentos".sup_epi e on e.id=it.epi_id
      left join public.perfil p on p.id=b.colaborador_uuid
      where b.tipo='troca' and b.status='aguardando_aprovacao' and b.colaborador_uuid is distinct from auth.uid()),'[]'::jsonb) end;
$function$
;

-- ===== sup_ferramenta_fila_aprovacao
CREATE OR REPLACE FUNCTION public.sup_ferramenta_fila_aprovacao()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not "9 - suprimentos".sup_pode_aprovar(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_solicitada',i.qt_solicitada))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
      where s.status='solicitada' and s.solicitante_uuid is distinct from auth.uid()
        and exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                   where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb) end;
$function$
;

-- ===== sup_fila_aprovacao
CREATE OR REPLACE FUNCTION public.sup_fila_aprovacao()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not "9 - suprimentos".sup_pode_aprovar(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_solicitada',i.qt_solicitada))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
      where s.status='solicitada' and s.solicitante_uuid is distinct from auth.uid()
        and not exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                       where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb) end;
$function$
;

notify pgrst, 'reload schema';
