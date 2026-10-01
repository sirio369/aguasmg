-- Migração: aprovacao_por_aprovador — Insumos, Ferramentas, EPI e Troca de EPI passam a seguir a
-- engrenagem Aprovador 1/2 (perfil.aprovador_uuid/aprovador2_uuid via sup_aprovadores_de, com o
-- fallback de sempre: sem aprovador configurado → todo aprovador/admin ativo). Ver docs/MODULOS.md §5.0.
-- Antes: qualquer aprovador/admin (e, no EPI, qualquer epi_gestor) via e aprovava pedido de qualquer pessoa.
-- Agora: a fila só mostra — e aprovar/rejeitar só aceita — pedidos de quem tem o usuário como Aprovador 1/2.
-- Assinaturas idênticas às atuais → create or replace (sem overload, frontend não muda).
-- Aplicar via MCP apply_migration (name: aprovacao_por_aprovador).
-- Rollback: reaplicar as definições anteriores (sup_pode_aprovar / sup_epi_gestor no lugar de
-- sup_e_aprovador_de, filas sem o filtro por solicitante) e `drop function "9 - suprimentos".sup_e_aprovador_de(uuid,uuid);`

-- Regra única: p_aprovador é Aprovador 1/2 (ativo) de p_solicitante (ou fallback, se ele não tiver nenhum).
create or replace function "9 - suprimentos".sup_e_aprovador_de(p_aprovador uuid, p_solicitante uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_aprovador is not null and p_solicitante is not null
     and p_aprovador <> p_solicitante   -- nunca autoaprovação (ver migracao_bloqueia_autoaprovacao.sql)
     and p_aprovador = any("9 - suprimentos".sup_aprovadores_de(p_solicitante));
$$;
revoke all on function "9 - suprimentos".sup_e_aprovador_de(uuid,uuid) from public, anon;
grant execute on function "9 - suprimentos".sup_e_aprovador_de(uuid,uuid) to authenticated;

-- ===== Insumos =====
CREATE OR REPLACE FUNCTION public.sup_fila_aprovacao()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_solicitada',i.qt_solicitada))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
      where s.status='solicitada'
        and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), s.solicitante_uuid)
        and not exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                       where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION public.sup_aprovar(p_solicitacao_id bigint, p_ajustes jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_st text; v_sol uuid; v_it jsonb;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  select status::text, solicitante_uuid into v_st, v_sol from "9 - suprimentos".sup_solicitacao where id=p_solicitacao_id;
  if v_st is null then raise exception 'solicitacao inexistente'; end if;
  if not "9 - suprimentos".sup_e_aprovador_de(v_uid, v_sol) then raise exception 'sem permissao: voce nao e aprovador 1/2 deste solicitante'; end if;
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
end; $function$;

CREATE OR REPLACE FUNCTION public.sup_rejeitar(p_solicitacao_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_st text; v_sol uuid;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  select status::text, solicitante_uuid into v_st, v_sol from "9 - suprimentos".sup_solicitacao where id=p_solicitacao_id;
  if v_st is null then raise exception 'solicitacao inexistente'; end if;
  if not "9 - suprimentos".sup_e_aprovador_de(v_uid, v_sol) then raise exception 'sem permissao: voce nao e aprovador 1/2 deste solicitante'; end if;
  if v_st <> 'solicitada' then raise exception 'solicitacao ja foi tratada (status=%)', v_st; end if;
  update "9 - suprimentos".sup_solicitacao set status='rejeitada', aprovador_uuid=v_uid, aprovado_em=now(),
    obs = coalesce(obs,'') || case when p_motivo is null then '' else ' | rejeitado: '||p_motivo end
  where id=p_solicitacao_id;
  return jsonb_build_object('id',p_solicitacao_id,'status','rejeitada');
end; $function$;

-- ===== Ferramentas (mesma tabela de insumos; aprovar/rejeitar = sup_aprovar/sup_rejeitar) =====
CREATE OR REPLACE FUNCTION public.sup_ferramenta_fila_aprovacao()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_solicitada',i.qt_solicitada))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
      where s.status='solicitada'
        and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), s.solicitante_uuid)
        and exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                   where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb);
$function$;

-- ===== EPI =====
CREATE OR REPLACE FUNCTION public.sup_epi_fila_aprovacao()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
      'itens',(select jsonb_agg(jsonb_build_object('item_id',i.id,'epi',e.nome,'qt',i.qt_solicitada,'tamanho',i.tamanho,
                 'na_cesta', exists(select 1 from "9 - suprimentos".sup_epi_cesta ce where ce.cargo_id=p.cargo_id and ce.epi_id=i.epi_id))
                 order by e.nome)
               from "9 - suprimentos".sup_epi_solicitacao_item i join "9 - suprimentos".sup_epi e on e.id=i.epi_id where i.solicitacao_id=s.id)) order by s.criado_em)
    from "9 - suprimentos".sup_epi_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
    where s.status='solicitada' and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), s.solicitante_uuid)),'[]'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION public.sup_epi_aprovar(p_solicitacao_id bigint, p_itens jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_uid uuid := auth.uid(); v_st text; v_sol uuid;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  select status, solicitante_uuid into v_st, v_sol from "9 - suprimentos".sup_epi_solicitacao where id=p_solicitacao_id;
  if v_st is null then raise exception 'solicitacao inexistente'; end if;
  if not "9 - suprimentos".sup_e_aprovador_de(v_uid, v_sol) then raise exception 'sem permissao: voce nao e aprovador 1/2 deste solicitante'; end if;
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
end; $function$;

CREATE OR REPLACE FUNCTION public.sup_epi_rejeitar(p_solicitacao_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_sol uuid;
begin
  select solicitante_uuid into v_sol from "9 - suprimentos".sup_epi_solicitacao where id=p_solicitacao_id;
  if not "9 - suprimentos".sup_e_aprovador_de(auth.uid(), v_sol) then raise exception 'sem permissao'; end if;
  update "9 - suprimentos".sup_epi_solicitacao set status='rejeitada', aprovador_uuid=auth.uid(), aprovado_em=now()
    where id=p_solicitacao_id and status='solicitada';
  if not found then raise exception 'solicitacao ja tratada'; end if;
  return jsonb_build_object('ok',true);
end; $function$;

-- ===== Troca de EPI =====
CREATE OR REPLACE FUNCTION public.sup_epi_troca_fila_aprovacao()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'criado_em',b.criado_em,'colaborador',p.nome,
        'epi',e.nome,'ca',coalesce(it.ca,e.ca),'tamanho',it.tamanho,'quantidade',it.quantidade,
        'vence_em',it.vence_em,'vencido',(it.vence_em is not null and it.vence_em<=current_date),
        'obs',b.obs,'foto',b.foto_solicitacao_path) order by b.criado_em)
      from "9 - suprimentos".sup_epi_baixa_pedido b
      join "9 - suprimentos".sup_epi_entrega_item it on it.id=b.entrega_item_id
      join "9 - suprimentos".sup_epi e on e.id=it.epi_id
      left join public.perfil p on p.id=b.colaborador_uuid
      where b.tipo='troca' and b.status='aguardando_aprovacao'
        and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), b.colaborador_uuid)),'[]'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION public.sup_epi_troca_aprovar(p_pedido_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_col uuid;
begin
  select colaborador_uuid into v_col from "9 - suprimentos".sup_epi_baixa_pedido where id=p_pedido_id;
  if not "9 - suprimentos".sup_e_aprovador_de(auth.uid(), v_col) then raise exception 'sem permissao'; end if;
  update "9 - suprimentos".sup_epi_baixa_pedido set status='solicitada', aprovador_uuid=auth.uid(), aprovado_em=now()
    where id=p_pedido_id and tipo='troca' and status='aguardando_aprovacao';
  if not found then raise exception 'pedido inexistente ou ja tratado'; end if;
  return jsonb_build_object('id',p_pedido_id,'status','solicitada');
end; $function$;

CREATE OR REPLACE FUNCTION public.sup_epi_troca_rejeitar(p_pedido_id bigint, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_col uuid;
begin
  select colaborador_uuid into v_col from "9 - suprimentos".sup_epi_baixa_pedido where id=p_pedido_id;
  if not "9 - suprimentos".sup_e_aprovador_de(auth.uid(), v_col) then raise exception 'sem permissao'; end if;
  update "9 - suprimentos".sup_epi_baixa_pedido
    set status='rejeitada', aprovador_uuid=auth.uid(), aprovado_em=now(),
        obs = coalesce(obs,'') || case when coalesce(trim(p_motivo),'')<>'' then ' | Rejeitada: '||trim(p_motivo) else '' end
    where id=p_pedido_id and tipo='troca' and status='aguardando_aprovacao';
  if not found then raise exception 'pedido inexistente ou ja tratado'; end if;
  return jsonb_build_object('id',p_pedido_id,'status','rejeitada');
end; $function$;

notify pgrst, 'reload schema';
