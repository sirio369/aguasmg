-- Consolidador › Obras em andamento: EXTENSÃO FEITA de cada intervenção (2026-11-13)
-- fisc_proj_ext(kind, gid, dia) = metros de REDE INSTALADA como estavam no FIM DO DIA (mesma reconstrução de trás p/ frente
-- do fisc_proj_pct): {exec, meta}. Mesma regra do Resumo de Projetos (pjRsEhMetroRede, §8): só "Puxamento da tubulação
-- (pullback)" no HDD e "Assentamento de tubulação" na VCA — piloto, escavação etc. não entram. Sem esse item → null.
-- fisc_dia_dados passa a devolver `ext` em cada obra. Fora do hash (fisc_dia_hash usa só chave+hash) → dias validados não mudam;
-- o snapshot dos dias já validados fica sem `ext` (a tela só não mostra a linha). Front antigo ignora a chave nova.

create or replace function public.fisc_proj_ext(p_kind text, p_gid bigint, p_dia date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_arv jsonb; v_aj jsonb; v_out jsonb := '[]'::jsonb; f jsonb;
begin
  select arv into v_arv from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  if v_arv is null or jsonb_typeof(v_arv) <> 'array' then return null; end if;
  select coalesce(jsonb_object_agg(caminho, s), '{}'::jsonb) into v_aj
    from (select a.caminho, sum(a.valor) s from "13 - projetos_obra".intervencao_avanco a
           where a.kind = p_kind and a.gid = p_gid and (a.ts at time zone 'America/Sao_Paulo')::date > p_dia group by 1) t;
  for f in select value from jsonb_array_elements(v_arv) loop
    v_out := v_out || public.fisc_arv_linhas(case when v_aj = '{}'::jsonb then f else public.fisc_arv_ajusta(f, null, v_aj) end, 0);
  end loop;
  return (select jsonb_build_object('exec', sum((x->>'exec')::numeric), 'meta', sum((x->>'meta')::numeric))
            from jsonb_array_elements(v_out) x
           where x->>'k' = 'm' and (x->>'nome' ilike '%puxamento%' or x->>'nome' ilike '%assentamento de tubula%')
          having count(*) > 0);
end $function$;
revoke all on function public.fisc_proj_ext(text, bigint, date) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fisc_dia_dados(p_dia date, p_za text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_l jsonb; v_p jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('chave', l.chave, 'atividade', l.atividade, 'ordem', l.ordem, 'medidas', l.medidas,
           'execs', l.execs, 'n', l.n, 'hash', l.hash,
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from l.hash) end)
           order by l.ordem, l.atividade), '[]'::jsonb)
    into v_l
    from public.fisc_linhas(p_dia, p_dia, p_za) l
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = l.chave;
  select coalesce(jsonb_agg(jsonb_build_object('chave', p.chave, 'kind', p.kind, 'gid', p.gid, 'codigo', p.codigo, 'tipo', p.tipo, 'local', p.local,
           'inicio', p.inicio, 'pct', p.pct, 'pct_ant', p.pct_ant, 'concluida', p.concluida, 'avancos', p.avancos, 'fotos', to_jsonb(p.fotos), 'geo', p.geo, 'hash', p.hash,
           'ext', public.fisc_proj_ext(p.kind, p.gid, p_dia),
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from p.hash) end)
           order by p.codigo), '[]'::jsonb)
    into v_p
    from public.fisc_projetos(p_dia, p_dia, p_za) p
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = p.chave;
  return jsonb_build_object('dia', p_dia, 'za', p_za, 'linhas', v_l, 'projetos', v_p);
end $function$;
