-- Consolidador — calendário do mês mais leve (2026-11-26, aplicado em produção 26/11 com OK do usuário)
-- app_fisc_mes chamava fisc_linhas, que recalcula as execuções desde a 1ª instalação de logger (jul/2026) só para o
-- acumulado de loggers — que o calendário não usa. ~4 s por ZA; as duas ZAs em paralelo estouravam os 8 s do banco.
-- Agora o hash de cada linha é calculado direto de fisc_execucoes(só o mês), com a MESMA fórmula de fisc_linhas
-- (se a fórmula de hash de fisc_linhas mudar, mudar aqui também). Saída conferida idêntica set–nov/2026 × ZA0200/ZA1004.
-- Backup da versão anterior: "12 - retaguarda"._bkp_funcdef_20261126.
CREATE OR REPLACE FUNCTION public.app_fisc_mes(p_mes date, p_za text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_de date := greatest(date_trunc('month', p_mes)::date, date '2026-09-01'); v_ate date; r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  v_ate := least((date_trunc('month', p_mes) + interval '1 month - 1 day')::date, (now() at time zone 'America/Sao_Paulo')::date);
  if v_ate < v_de then return jsonb_build_object('za', p_za, 'dias', '[]'::jsonb); end if;
  -- calendário só precisa do hash de cada linha (mesma fórmula de fisc_linhas), sem o acumulado de loggers desde jul/2026
  with e as (select x.* from public.fisc_execucoes(v_de, v_ate) x where x.za = p_za),
  l as (select e.dia, 'atv:' || e.atividade chave,
               md5(coalesce(string_agg(e.exec_id || '|' || coalesce(e.descricao, '') || '|' || e.qtd || '|' || coalesce(e.sigos_sit, ''), '§' order by e.exec_id)
                     filter (where not coalesce(e.extra ? '_aguarda', false)), '')) hash, false sa
          from e group by e.dia, e.atividade
        union all select p.dia, p.chave, p.hash, (p.avancos = '[]'::jsonb and not p.concluida) from public.fisc_projetos(v_de, v_ate, p_za) p),
  s as (select l.dia, count(*) filter (where not l.sa) n,
               count(*) filter (where not l.sa and (v.chave is null or v.hash is distinct from l.hash)) pend,
               md5(string_agg(l.chave || ':' || l.hash, '§' order by l.chave)) h
          from l left join "12 - retaguarda".fisc_linha_val v on v.dia = l.dia and v.za = p_za and v.chave = l.chave group by l.dia),
  dias as (select generate_series(v_de, v_ate, interval '1 day')::date d),
  cob as (select * from "17 - sigos".vw_carga_cobertura where za = p_za)
  select coalesce(jsonb_agg(jsonb_build_object('dia', d.d, 'n', coalesce(s.n, 0), 'pend', coalesce(s.pend, 0),
           'status', case when f.dia is not null and f.hash is distinct from coalesce(s.h, md5('')) then 'desatualizado'
                          when f.dia is not null then 'validado'
                          when coalesce(s.n, 0) = 0 then 'vazio'
                          when s.pend = 0 then 'pronto' else 'pendente' end,
           'sigos', case when c.encerradas_desde is null or d.d < c.encerradas_desde then 'sem_base'
                         when c.encerradas_ate is null or d.d > c.encerradas_ate then 'aguardando' else 'ok' end) order by d.d), '[]'::jsonb)
    into r
    from dias d cross join cob c left join s on s.dia = d.d
    left join "12 - retaguarda".fisc_dia f on f.dia = d.d and f.za = p_za;
  return jsonb_build_object('za', p_za, 'de', v_de, 'ate', v_ate, 'dias', r, 'pode_validar', public.fisc_pode_validar(auth.uid()));
end $function$;
