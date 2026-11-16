-- Consolidador: linha validada que SAIU do dia + para onde foi a execução (2026-11-16)
-- Complemento de docs/migracao_fisc_mudou_detalhe.sql. O detalhe do "mudou" só cobria linhas que ainda existem no dia;
-- quando a linha inteira some (ex.: 21/10 ZA0200 "Telemetria": a OS SIGOS 2807900 passou a ser a instalação do logger fixo
-- lançada no app em 22/10 — fix "logger fixo = telemetria"), o dia ficava "mudou" sem nenhuma linha marcada.
-- fisc_dia_dados ganha:
--   sumiram  = linhas validadas neste dia que não existem mais (chave, por, em, antes)
--   destinos = {exec_id: {dia, atividade, desc, id}} das execuções validadas que saíram do dia (das linhas que sumiram e das
--              que mudaram), procuradas ±45 dias pelo mesmo id ou pela mesma OS SIGOS (base de 10 dígitos). Só é calculado
--              quando há execução sumida (custo de uma chamada extra a fisc_execucoes).
-- Não mexe no hash do dia (fisc_dia_hash só lê linhas/projetos), no snapshot nem no que a fiscalização vê.

create or replace function public.fisc_dia_dados(p_dia date, p_za text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_l jsonb; v_p jsonb; v_s jsonb; v_d jsonb; v_sai jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('chave', l.chave, 'atividade', l.atividade, 'ordem', l.ordem, 'medidas', l.medidas,
           'execs', l.execs, 'n', l.n, 'hash', l.hash,
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from l.hash)
                    || case when v.hash is distinct from l.hash then jsonb_build_object('antes', v.antes) else '{}'::jsonb end end)
           order by l.ordem, l.atividade), '[]'::jsonb)
    into v_l
    from public.fisc_linhas(p_dia, p_dia, p_za) l
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = l.chave;
  select coalesce(jsonb_agg(jsonb_build_object('chave', p.chave, 'kind', p.kind, 'gid', p.gid, 'codigo', p.codigo, 'tipo', p.tipo, 'local', p.local,
           'inicio', p.inicio, 'pct', p.pct, 'pct_ant', p.pct_ant, 'concluida', p.concluida, 'avancos', p.avancos, 'fotos', to_jsonb(p.fotos), 'geo', p.geo, 'hash', p.hash,
           'ext', public.fisc_proj_ext(p.kind, p.gid, p_dia),
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from p.hash)
                    || case when v.hash is distinct from p.hash then jsonb_build_object('antes', v.antes) else '{}'::jsonb end end)
           order by p.codigo), '[]'::jsonb)
    into v_p
    from public.fisc_projetos(p_dia, p_dia, p_za) p
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = p.chave;
  -- linhas validadas que não existem mais no dia
  select jsonb_agg(jsonb_build_object('chave', v.chave, 'por', v.por_nome, 'em', v.em, 'antes', v.antes) order by v.chave)
    into v_s
    from "12 - retaguarda".fisc_linha_val v
   where v.dia = p_dia and v.za = p_za
     and not exists (select 1 from jsonb_array_elements(v_l || v_p) x where x->>'chave' = v.chave);
  -- execuções validadas que saíram do dia (das linhas que mudaram e das que sumiram) → onde estão hoje
  select jsonb_agg(jsonb_build_object('id', e->>'id', 'b', public.sigos_os_base(e->>'os_sigos'))) into v_sai
    from (select x->'val'->'antes' a from jsonb_array_elements(v_l || v_p) x where x->'val' ? 'antes'
          union all select s->'antes' from jsonb_array_elements(coalesce(v_s, '[]')) s) t,
         jsonb_array_elements(coalesce(t.a->'execs', '[]')) e
   where not exists (select 1 from jsonb_array_elements(v_l) x, jsonb_array_elements(x->'execs') c where c->>'id' = e->>'id');
  if v_sai is not null then   -- 1 chamada extra a fisc_execucoes, só quando há execução sumida
    with sai as (select y->>'id' id, y->>'b' b from jsonb_array_elements(v_sai) y),
    fx as (select x.dia, x.atividade, x.descricao, x.exec_id, public.sigos_os_base(x.os_sigos) b
             from public.fisc_execucoes(p_dia - 45, p_dia + 45) x where x.za = p_za and x.dia <> p_dia),
    m as (select distinct on (s.id) s.id, jsonb_build_object('dia', f.dia, 'atividade', f.atividade, 'desc', f.descricao, 'id', f.exec_id) j
            from sai s join fx f on f.exec_id = s.id or (s.b is not null and f.b = s.b)
           order by s.id, (f.exec_id = s.id) desc, abs(f.dia - p_dia))
    select jsonb_object_agg(m.id, m.j) into v_d from m;
  end if;
  return jsonb_build_object('dia', p_dia, 'za', p_za, 'linhas', v_l, 'projetos', v_p)
      || case when v_s is null then '{}'::jsonb else jsonb_build_object('sumiram', v_s) end
      || case when v_d is null then '{}'::jsonb else jsonb_build_object('destinos', v_d) end;
end $function$;
