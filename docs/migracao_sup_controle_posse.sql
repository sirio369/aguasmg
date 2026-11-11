-- Almoxarifado › 📋 Controle › "Itens em posse por colaborador" (2026-11-11)
-- Nova área de acesso 'controle' (engrenagem admin, igual 'baixas') + 2 RPCs de leitura:
--   app_sup_controle_colaboradores()  → todos os perfis (inclui inativos/demitidos) c/ contagem por categoria
--   app_sup_controle_posse(p_uuid)     → o que está com a pessoa: insumos, ferramentas, equipamentos, EPI/uniforme
-- 'controle' NÃO dá poder de almoxarife: sup_e_almox passa a ignorar essa área.

-- 1) sup_e_almox: área 'controle' é só leitura (não libera ações de almoxarifado)
create or replace function "9 - suprimentos".sup_e_almox(p_uid uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select coalesce("9 - suprimentos".sup_funcao(p_uid) in ('admin','almoxarife'), false)
      or exists(select 1 from "9 - suprimentos".sup_acesso_area a where a.colaborador_uuid=p_uid and a.area<>'controle');
$function$;

-- 2) engrenagem aceita a área nova
create or replace function public.app_sup_area_listar(p_area text)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_fun text;
begin
  v_fun := coalesce((select funcao from public.perfil where id=auth.uid()),'');
  if v_fun <> 'admin' then raise exception 'sem permissao'; end if;
  if p_area not in ('baixas','insumo','equip','epi','ferramenta','controle') then raise exception 'area invalida'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'nome',p.nome,'email',p.email,'cargo',p.cargo,'funcao',p.funcao,
      'acesso',(p.funcao='admin' or exists(select 1 from "9 - suprimentos".sup_acesso_area a where a.colaborador_uuid=p.id and a.area=p_area)),
      'acesso_pelo_cargo',(p.funcao='admin')) order by p.nome, p.email)
    from public.perfil p where coalesce(p.ativo,true)), '[]'::jsonb);
end; $function$;

create or replace function public.app_sup_area_set(p_area text, p_uuid uuid, p_on boolean)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_fun text;
begin
  v_fun := coalesce((select funcao from public.perfil where id=auth.uid()),'');
  if v_fun <> 'admin' then raise exception 'sem permissao'; end if;
  if p_area not in ('baixas','insumo','equip','epi','ferramenta','controle') then raise exception 'area invalida'; end if;
  if coalesce(p_on,false) then
    insert into "9 - suprimentos".sup_acesso_area(colaborador_uuid, area) values (p_uuid, p_area) on conflict do nothing;
  else
    delete from "9 - suprimentos".sup_acesso_area where colaborador_uuid=p_uuid and area=p_area;
  end if;
  return jsonb_build_object('area',p_area,'uuid',p_uuid,'acesso',coalesce(p_on,false));
end; $function$;

-- 3) app_me: sup_areas.controle
create or replace function public.app_me()
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_id uuid := auth.uid(); v_email text := coalesce(auth.jwt() ->> 'email',''); v_p public.perfil%rowtype; v_adm boolean; v_areas text[];
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  insert into public.perfil (id, email, nome, funcao) values (v_id, v_email, nullif(initcap(replace(split_part(v_email,'@',1),'.',' ')),''), 'campo') on conflict (id) do nothing;
  select * into v_p from public.perfil where id=v_id;
  v_adm := (v_p.funcao='admin');
  v_areas := array(select area from "9 - suprimentos".sup_acesso_area where colaborador_uuid=v_id);
  return jsonb_build_object('id',v_p.id,'email',v_p.email,'nome',v_p.nome,'cargo',v_p.cargo,'funcao',v_p.funcao,
    'is_admin',v_adm, 'is_almoxarife',(v_p.funcao in ('almoxarife','admin')), 'pode_aprovar',(v_p.funcao in ('aprovador','admin')),
    'frota_admin',coalesce(v_p.frota_admin,false), 'pessoas_admin',coalesce(v_p.pessoas_admin,false),
    'dev_acesso',(v_adm or coalesce(v_p.dev_acesso,false)),
    'proj_sup',(v_adm or coalesce(v_p.proj_sup_acesso,false)),
    'proj_obras',"13 - projetos_obra".proj_obras_pode(v_id),
    'vrp_gestao',(v_adm or coalesce(v_p.vrp_gestao_acesso,false) or coalesce(v_p.aux_acesso,false)),
    'aux_acesso',(v_adm or coalesce(v_p.aux_acesso,false)),
    'qsms',"16 - qsms".qsms_pode(v_id),
    'qsms_campo',"16 - qsms".sst_campo_pode(v_id),
    'qualidade',"8 - coleta_campo".pav_qualidade_pode(v_id),
    'epi_gestor',"9 - suprimentos".sup_epi_gestor(v_id),
    'sup_areas', jsonb_build_object('baixas', v_adm or ('baixas'=any(v_areas)), 'insumo', v_adm or ('insumo'=any(v_areas)), 'equip', v_adm or ('equip'=any(v_areas)), 'epi', v_adm or ('epi'=any(v_areas)), 'ferramenta', v_adm or ('ferramenta'=any(v_areas)), 'controle', v_adm or ('controle'=any(v_areas))),
    'equipes','[]'::jsonb);
end $function$;

-- 4) lista de colaboradores com contagem do que está em posse
create or replace function public.app_sup_controle_colaboradores()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not "9 - suprimentos".sup_tem_area(auth.uid(),'controle') then raise exception 'sem permissao'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'nome')) from (
    select jsonb_build_object('id',p.id,'nome',coalesce(p.nome,p.email),'email',p.email,'cargo',coalesce(c.nome,p.cargo),
      'ativo',coalesce(p.ativo,true),'demissao',p.demissao,'consorcio',p.consorcio,
      'insumos',(select count(*) from "9 - suprimentos".sup_saldo s join "9 - suprimentos".sup_material m on m.id=s.material_id where s.colaborador_uuid=p.id and s.saldo>0 and not m.ferramenta),
      'ferramentas',(select count(*) from "9 - suprimentos".sup_saldo s join "9 - suprimentos".sup_material m on m.id=s.material_id where s.colaborador_uuid=p.id and s.saldo>0 and m.ferramenta),
      'equipamentos',(select count(*) from "9 - suprimentos".sup_termo t where t.colaborador_uuid=p.id and t.status in ('pendente','ativo')),
      'epis',(select count(*) from "9 - suprimentos".sup_epi_entrega_item it join "9 - suprimentos".sup_epi_entrega e on e.id=it.entrega_id where e.colaborador_uuid=p.id and it.substituido_em is null and it.devolvido_em is null)
    ) x
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id=p.cargo_id) q), '[]'::jsonb);
end; $function$;

-- 5) detalhe: tudo que está com a pessoa
create or replace function public.app_sup_controle_posse(p_uuid uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not "9 - suprimentos".sup_tem_area(auth.uid(),'controle') then raise exception 'sem permissao'; end if;
  return jsonb_build_object(
    'colaborador',(select jsonb_build_object('id',p.id,'nome',coalesce(p.nome,p.email),'email',p.email,'cargo',coalesce(c.nome,p.cargo),
        'matricula',p.matricula,'consorcio',p.consorcio,'ativo',coalesce(p.ativo,true),'admissao',p.admissao,'demissao',p.demissao)
      from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id=p.cargo_id where p.id=p_uuid),
    'insumos',coalesce((select jsonb_agg(jsonb_build_object('material_id',m.id,'sku',m.sku,'material',m.descricao,'unidade',m.unidade,'saldo',s.saldo,
        'ultima_entrada',(select max(mv.criado_em) from "9 - suprimentos".sup_movimento mv where mv.colaborador_uuid=p_uuid and mv.material_id=m.id and mv.quantidade>0)) order by m.descricao)
      from "9 - suprimentos".sup_saldo s join "9 - suprimentos".sup_material m on m.id=s.material_id
      where s.colaborador_uuid=p_uuid and s.saldo>0 and not m.ferramenta),'[]'::jsonb),
    'ferramentas',coalesce((select jsonb_agg(jsonb_build_object('material_id',m.id,'sku',m.sku,'material',m.descricao,'unidade',m.unidade,'saldo',s.saldo,
        'ultima_entrada',(select max(mv.criado_em) from "9 - suprimentos".sup_movimento mv where mv.colaborador_uuid=p_uuid and mv.material_id=m.id and mv.quantidade>0),
        'devolucao_pendente',(select coalesce(sum(di.quantidade),0) from "9 - suprimentos".sup_ferramenta_devolucao d join "9 - suprimentos".sup_ferramenta_devolucao_item di on di.devolucao_id=d.id
           where d.colaborador_uuid=p_uuid and di.material_id=m.id and d.status not in ('confirmada','cancelada'))) order by m.descricao)
      from "9 - suprimentos".sup_saldo s join "9 - suprimentos".sup_material m on m.id=s.material_id
      where s.colaborador_uuid=p_uuid and s.saldo>0 and m.ferramenta),'[]'::jsonb),
    'equipamentos',coalesce((select jsonb_agg(jsonb_build_object('termo_id',t.id,'termo_status',t.status,'emitido_em',t.emitido_em,'aceito_em',t.aceito_em,
        'equipamento_id',e.id,'nome',e.nome,'tipo',coalesce(tp.nome,e.tipo),'num_serie',e.num_serie,'consorcio',e.consorcio,
        'devolucao_solicitada',(t.devolucao_codigo is not null)) order by e.nome)
      from "9 - suprimentos".sup_termo t join "9 - suprimentos".sup_equipamento e on e.id=t.equipamento_id
      left join "9 - suprimentos".sup_equip_tipo tp on tp.id=e.tipo_id
      where t.colaborador_uuid=p_uuid and t.status in ('pendente','ativo')),'[]'::jsonb),
    'epis',coalesce((select jsonb_agg(jsonb_build_object('entrega_item_id',it.id,'epi',ep.nome,'ca',coalesce(it.ca,ep.ca),'tamanho',it.tamanho,'quantidade',it.quantidade,
        'entregue_em',ent.entregue_em,'vence_em',it.vence_em,
        'devolucao_pendente',exists(select 1 from "9 - suprimentos".sup_epi_baixa_pedido b where b.entrega_item_id=it.id and b.status in ('solicitada','aguardando_aprovacao'))) order by ep.nome)
      from "9 - suprimentos".sup_epi_entrega_item it join "9 - suprimentos".sup_epi_entrega ent on ent.id=it.entrega_id
      join "9 - suprimentos".sup_epi ep on ep.id=it.epi_id
      where ent.colaborador_uuid=p_uuid and it.substituido_em is null and it.devolvido_em is null),'[]'::jsonb)
  );
end; $function$;

revoke all on function public.app_sup_controle_colaboradores() from public, anon;
revoke all on function public.app_sup_controle_posse(uuid) from public, anon;
grant execute on function public.app_sup_controle_colaboradores() to authenticated;
grant execute on function public.app_sup_controle_posse(uuid) to authenticated;
