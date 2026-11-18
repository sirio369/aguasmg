-- Projetos › lançamento de avanço com data de execução livre (2026-11-18)
-- Antes (docs/migracao_proj_hdd_valas_ontem.sql) o retroativo só aceitava ONTEM. Agora p_executado_em aceita qualquer
-- data/hora que não esteja no futuro (tolerância de 5 min p/ relógio do aparelho). Mesma assinatura; resto da função igual.

CREATE OR REPLACE FUNCTION public.app_proj_avanco_registrar(p_kind text, p_gid bigint, p_iv_cod text, p_iv_local text, p_consorcio text, p_tipo text, p_caminho text, p_atividade text, p_sub text, p_valor numeric, p_unidade text, p_obs text DEFAULT NULL::text, p_fotos text[] DEFAULT '{}'::text[], p_equipe text DEFAULT NULL::text, p_executado_em timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', '13 - projetos_obra'
AS $function$
declare v_id uuid := auth.uid(); v_nome text; v_row "13 - projetos_obra".intervencao_avanco; c jsonb;
  v_segs text[]; v_pth text[]; v_tipo text; v_arv jsonb; v_rea jsonb;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  -- data de execução livre (2026-11-18): qualquer data/hora, só não pode estar no futuro
  if p_executado_em is not null and p_executado_em > now() + interval '5 minutes' then
    raise exception 'A data de execução não pode estar no futuro';
  end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then raise exception 'intervenção não encontrada'; end if;
  if not coalesce((c->'aberta'->>'4')::boolean, false) then raise exception 'a execução desta intervenção ainda não foi liberada'; end if;
  v_segs := string_to_array(coalesce(p_caminho, ''), ' › ');
  if v_segs[cardinality(v_segs)] = 'Recomposição de pavimento' then
    v_pth := v_segs[1:cardinality(v_segs)-1];
    select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
    select arv into v_arv from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
    v_rea := "13 - projetos_obra".proj_reat_no("13 - projetos_obra".proj_reat_filhos(v_tipo, v_arv, v_pth), 'rea');
    if v_rea is not null and coalesce((v_rea->>'ativo')::boolean, true)
       and not exists (select 1 from "13 - projetos_obra".proj_reaterro r
                        where r.kind = p_kind and r.gid = p_gid and r.status in ('aprovado','legado','dispensado')
                          and r.bloco = "13 - projetos_obra".proj_reat_bloco_key(v_tipo, v_pth)) then
      raise exception 'Recomposição de pavimento travada: falta o ensaio de compactação do reaterro aprovado pela Qualidade';
    end if;
  end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  insert into "13 - projetos_obra".intervencao_avanco(kind,gid,iv_cod,iv_local,consorcio,tipo,caminho,atividade,sub,valor,unidade,obs,fotos,autor,autor_nome,equipe,ts,registrado_em,retroativo)
  values(p_kind,p_gid,p_iv_cod,p_iv_local,p_consorcio,p_tipo,p_caminho,p_atividade,p_sub,p_valor,p_unidade,p_obs,coalesce(p_fotos,'{}'),v_id,v_nome,coalesce(p_equipe,v_nome),
         coalesce(p_executado_em, now()), now(), p_executado_em is not null)
  returning * into v_row;
  return to_jsonb(v_row);
end $function$;
