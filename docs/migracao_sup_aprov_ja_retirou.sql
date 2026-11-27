-- Aprovações do Almoxarifado (Insumos, Ferramentas, EPI/Uniforme): aviso "já retirou este item"
-- 2026-11-26 — cada item das filas de aprovação ganha o objeto `anterior` (null se nunca retirou):
--   insumo/ferramenta: {em: data da última retirada (sup_solicitacao.entregue_em), qt: qtd entregue nela,
--                       sol: nº da solicitação, posse: saldo atual do colaborador nesse material (kardex)}
--   EPI:               {em: data da última entrega/troca (sup_epi_entrega.entregue_em), qt, tamanho,
--                       posse: qtd ainda em posse (sem substituido_em/devolvido_em), vence_em: troca prevista}
-- Aditivo: mesma assinatura (sem args, jsonb), o app antigo só ignora o campo novo.
-- Helpers internos no schema 9 (sem grant; chamados só pelas RPCs definer).

create or replace function "9 - suprimentos".sup_ja_retirou_material(p_uid uuid, p_material bigint, p_sol_atual bigint)
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object('em', s.entregue_em, 'qt', i.qt_entregue, 'sol', s.id,
           'posse', (select coalesce(sum(mv.quantidade),0) from "9 - suprimentos".sup_movimento mv
                     where mv.colaborador_uuid=p_uid and mv.material_id=p_material))
  from "9 - suprimentos".sup_solicitacao s
  join "9 - suprimentos".sup_solicitacao_item i on i.solicitacao_id=s.id
  where s.solicitante_uuid=p_uid and i.material_id=p_material and s.id<>p_sol_atual
    and s.status='entregue' and coalesce(i.qt_entregue,0)>0
  order by s.entregue_em desc nulls last, s.id desc
  limit 1;
$function$;

create or replace function "9 - suprimentos".sup_ja_retirou_epi(p_uid uuid, p_epi bigint, p_sol_atual bigint)
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object('em', e.entregue_em, 'qt', ei.quantidade, 'tamanho', ei.tamanho, 'tipo', e.tipo,
           'posse', (select coalesce(sum(x.quantidade),0) from "9 - suprimentos".sup_epi_entrega_item x
                     join "9 - suprimentos".sup_epi_entrega y on y.id=x.entrega_id
                     where y.colaborador_uuid=p_uid and x.epi_id=p_epi and y.tipo in ('entrega','substituicao')
                       and x.substituido_em is null and x.devolvido_em is null),
           'vence_em', (select min(x.vence_em) from "9 - suprimentos".sup_epi_entrega_item x
                     join "9 - suprimentos".sup_epi_entrega y on y.id=x.entrega_id
                     where y.colaborador_uuid=p_uid and x.epi_id=p_epi and y.tipo in ('entrega','substituicao')
                       and x.substituido_em is null and x.devolvido_em is null))
  from "9 - suprimentos".sup_epi_entrega e
  join "9 - suprimentos".sup_epi_entrega_item ei on ei.entrega_id=e.id
  where e.colaborador_uuid=p_uid and ei.epi_id=p_epi and e.tipo in ('entrega','substituicao')
    and coalesce(e.solicitacao_id,-1)<>p_sol_atual
  order by e.entregue_em desc nulls last, e.id desc
  limit 1;
$function$;

revoke all on function "9 - suprimentos".sup_ja_retirou_material(uuid,bigint,bigint) from public, anon, authenticated;
revoke all on function "9 - suprimentos".sup_ja_retirou_epi(uuid,bigint,bigint) from public, anon, authenticated;

create or replace function public.sup_fila_aprovacao()
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_solicitada',i.qt_solicitada,
                   'anterior',"9 - suprimentos".sup_ja_retirou_material(s.solicitante_uuid, i.material_id, s.id)))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
      where s.status='solicitada'
        and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), s.solicitante_uuid)
        and not exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                       where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb);
$function$;

create or replace function public.sup_ferramenta_fila_aprovacao()
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_solicitada',i.qt_solicitada,
                   'anterior',"9 - suprimentos".sup_ja_retirou_material(s.solicitante_uuid, i.material_id, s.id)))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
      where s.status='solicitada'
        and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), s.solicitante_uuid)
        and exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                   where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb);
$function$;

create or replace function public.sup_epi_fila_aprovacao()
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'solicitante',p.nome,'criado_em',s.criado_em,'obs',s.obs,
      'itens',(select jsonb_agg(jsonb_build_object('item_id',i.id,'epi',e.nome,'qt',i.qt_solicitada,'tamanho',i.tamanho,
                 'na_cesta', exists(select 1 from "9 - suprimentos".sup_epi_cesta ce where ce.cargo_id=p.cargo_id and ce.epi_id=i.epi_id),
                 'anterior', "9 - suprimentos".sup_ja_retirou_epi(s.solicitante_uuid, i.epi_id, s.id))
                 order by e.nome)
               from "9 - suprimentos".sup_epi_solicitacao_item i join "9 - suprimentos".sup_epi e on e.id=i.epi_id where i.solicitacao_id=s.id)) order by s.criado_em)
    from "9 - suprimentos".sup_epi_solicitacao s left join public.perfil p on p.id=s.solicitante_uuid
    where s.status='solicitada' and "9 - suprimentos".sup_e_aprovador_de(auth.uid(), s.solicitante_uuid)),'[]'::jsonb);
$function$;
