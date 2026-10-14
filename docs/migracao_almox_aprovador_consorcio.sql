-- Migração: almox_aprovador_consorcio — mostra o APROVADOR (e, na entrega de EPI, consórcio+data)
-- nas filas do almoxarife. Só ADITIVO: cada RPC passa a devolver 'aprovador' (nome) via join em
-- public.perfil por aprovador_uuid; sup_epi_fila_entrega ganha 'consorcio'. Ver docs/MODULOS.md §5.
-- Aplicar via MCP apply_migration (name: almox_aprovador_consorcio). Rollback = recriar sem o join/campos.

-- Insumos (não-ferramenta)
create or replace function public.sup_fila_almoxarife()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select case when not "9 - suprimentos".sup_e_almox(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'status',s.status,'solicitante',p.nome,'consorcio',p.consorcio,'aprovador',pa.nome,'criado_em',s.criado_em,'codigo_retirada',s.codigo_retirada,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_aprovada',i.qt_aprovada,'qt_segregada',i.qt_segregada,'situacao',i.situacao))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s
      left join public.perfil p on p.id=s.solicitante_uuid
      left join public.perfil pa on pa.id=s.aprovador_uuid
      where s.status in ('aprovada','em_separacao','segregada')
        and not exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                       where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb) end;
$function$;

-- Ferramentas
create or replace function public.sup_ferramenta_fila_almoxarife()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select case when not "9 - suprimentos".sup_e_almox(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(obj order by criado_em) from (
      select s.criado_em, jsonb_build_object('id',s.id,'status',s.status,'solicitante',p.nome,'consorcio',p.consorcio,'aprovador',pa.nome,'criado_em',s.criado_em,'codigo_retirada',s.codigo_retirada,
        'itens',(select jsonb_agg(jsonb_build_object('material_id',i.material_id,'material',m.descricao,'unidade',m.unidade,'qt_aprovada',i.qt_aprovada,'qt_segregada',i.qt_segregada,'situacao',i.situacao))
                 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id where i.solicitacao_id=s.id)) as obj
      from "9 - suprimentos".sup_solicitacao s
      left join public.perfil p on p.id=s.solicitante_uuid
      left join public.perfil pa on pa.id=s.aprovador_uuid
      where s.status in ('aprovada','em_separacao','segregada')
        and exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                   where i.solicitacao_id=s.id and m.ferramenta)
    ) t),'[]'::jsonb) end;
$function$;

-- EPI: separar
create or replace function public.sup_epi_fila_segregar()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select case when not "9 - suprimentos".sup_e_almox(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'solicitante',p.nome,'consorcio',p.consorcio,'aprovador',pa.nome,'solicitante_uuid',s.solicitante_uuid,'criado_em',s.criado_em,'obs',s.obs,
      'itens',(select jsonb_agg(jsonb_build_object('item_id',i.id,'epi_id',e.id,'epi',e.nome,'ca',e.ca,'qt',coalesce(i.qt_aprovada,i.qt_solicitada),'tamanho',i.tamanho))
               from "9 - suprimentos".sup_epi_solicitacao_item i join "9 - suprimentos".sup_epi e on e.id=i.epi_id
               where i.solicitacao_id=s.id and coalesce(i.qt_aprovada, i.qt_solicitada) > 0)) order by s.criado_em)
      from "9 - suprimentos".sup_epi_solicitacao s
      left join public.perfil p on p.id=s.solicitante_uuid
      left join public.perfil pa on pa.id=s.aprovador_uuid
      where s.status='aprovada'),'[]'::jsonb) end;
$function$;

-- EPI: entregar (ganha consorcio + aprovador; criado_em já existia)
create or replace function public.sup_epi_fila_entrega()
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select case when not "9 - suprimentos".sup_e_almox(auth.uid()) then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'solicitante',p.nome,'consorcio',p.consorcio,'aprovador',pa.nome,'solicitante_uuid',s.solicitante_uuid,'criado_em',s.criado_em,'obs',s.obs,'codigo',s.codigo,
      'itens',(select jsonb_agg(jsonb_build_object('epi_id',e.id,'epi',e.nome,'ca',e.ca,'qt',i.qt_segregada,'tamanho',i.tamanho,'validade_dias',coalesce(i.validade_dias,e.validade_dias)))
               from "9 - suprimentos".sup_epi_solicitacao_item i join "9 - suprimentos".sup_epi e on e.id=i.epi_id
               where i.solicitacao_id=s.id and coalesce(i.qt_segregada,0) > 0)) order by s.criado_em)
      from "9 - suprimentos".sup_epi_solicitacao s
      left join public.perfil p on p.id=s.solicitante_uuid
      left join public.perfil pa on pa.id=s.aprovador_uuid
      where s.status='segregada'),'[]'::jsonb) end;
$function$;

notify pgrst, 'reload schema';
