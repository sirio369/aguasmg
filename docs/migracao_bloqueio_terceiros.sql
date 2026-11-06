-- Bloqueio de módulos para terceiros (2026-11-06)
-- app_me passa a devolver 'terceiro' (perfil.modalidade = 'TERCEIRO'). O app esconde e bloqueia
-- Frota, Loggers, Pesquisa, Entrevistadores, Mapeamento de pressão e VRPs para esse perfil.
-- Corpo igual ao app_me em produção em 06/11/2026; única mudança: a chave 'terceiro'.
CREATE OR REPLACE FUNCTION public.app_me()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'terceiro',(upper(coalesce(v_p.modalidade,''))='TERCEIRO'),
    'dev_acesso',(v_adm or coalesce(v_p.dev_acesso,false)),
    'proj_sup',(v_adm or coalesce(v_p.proj_sup_acesso,false)),
    'proj_obras',"13 - projetos_obra".proj_obras_pode(v_id),
    'vrp_gestao',(v_adm or coalesce(v_p.vrp_gestao_acesso,false) or coalesce(v_p.aux_acesso,false)),
    'aux_acesso',(v_adm or coalesce(v_p.aux_acesso,false)),
    'qsms',"16 - qsms".qsms_pode(v_id),
    'qsms_campo',"16 - qsms".sst_campo_pode(v_id),
    'qualidade',"8 - coleta_campo".pav_qualidade_pode(v_id),
    'epi_gestor',"9 - suprimentos".sup_epi_gestor(v_id),
    'sup_areas', jsonb_build_object('baixas', v_adm or ('baixas'=any(v_areas)), 'insumo', v_adm or ('insumo'=any(v_areas)), 'equip', v_adm or ('equip'=any(v_areas)), 'epi', v_adm or ('epi'=any(v_areas)), 'ferramenta', v_adm or ('ferramenta'=any(v_areas))),
    'equipes','[]'::jsonb);
end $function$;
