-- =====================================================================================
-- RDO agrupado por família de serviço + SIGOS na Vitrine (2026-11-09)
--  1) public.sigos_servico_grupo(desc) / sigos_servico_curto(desc) / rdo_familia_ordem(grupo):
--     serviços SIGOS parecidos viram uma família (ex.: ABERTURA e FECHAMENTO REGISTRO EXT → "Manobra de registro");
--     serviço novo que não casa com nenhuma regra fica com o próprio nome (não some).
--  2) public.rdo_eventos refeita: linha do SIGOS por FAMÍLIA (chave sigos:exec:<família>), com a quebra por serviço
--     no texto e o serviço/equipe no detalhe; linhas do AcquaHub ordenadas logo depois do SIGOS da mesma família.
--     (Em 09/11 não havia nenhuma revisão nem dia fechado — trocar as chaves não perde nada.)
--  3) app_vitrine_sigos(desde) — números, mapa, carteira e equipes do SIGOS para a Vitrine (gate da Vitrine).
-- =====================================================================================

-- 1) Famílias de serviço ------------------------------------------------------------------------------
create or replace function public.sigos_servico_grupo(p_desc text)
returns text language sql immutable as $$
  select case
    when p_desc is null then 'Outros'
    when p_desc ~* '^PDC REVISAO CADASTRO' then 'Recadastramento'
    when p_desc ~* '^SUBST\.?\s*HIDROMET' then 'Troca de hidrômetro'
    when p_desc ~* '^CONF\.? DE INFRACAO' then 'Fiscalização de irregularidade'
    when p_desc ~* '^VISTORIA DE IMOVEL' then 'Vistoria de imóvel'
    when p_desc ~* '^(SUBST\.?\s*RAMAL|MANUTENCAO NO RAMAL)' then 'Ramal predial'
    when p_desc ~* '^(RECOMPOSICAO|REATERRO)' then 'Recomposição de pavimento'
    when p_desc ~* 'TELEMETRIA' then 'Telemetria'
    when p_desc ~* '^VALVULA CONTROL' then 'VRP'
    when p_desc ~* '^MEDICAO DE PRESSAO' then 'Loggers de pressão'
    when p_desc ~* '^(DETECC\.?\s*VAZ|PESQUISA VAZAMENTO)' then 'Pesquisa de vazamento'
    when p_desc ~* '^(ABERTURA|FECHAMENTO) REGISTRO' then 'Manobra de registro'
    when p_desc ~* '^(MUDANCA PADRAO|PADRONIZACAO)' then 'Padrão de ligação'
    when p_desc ~* 'REDE AGUA' then 'Rede de água'
    else p_desc end;
$$;

-- nome curto do serviço (tira o "CONT.PERF.PERDAS" / "CT.PERF.COMB.PERDAS" / "CONTRATO MANUT.AGUA"…)
create or replace function public.sigos_servico_curto(p_desc text)
returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(coalesce(p_desc, ''),
    '[\s\.]*(CONT\.?|CT[\./ ]?|CONTRATO\s)\s*(PERF|MANUT|VEGET)[^\s]*(\s+(COMB\.?\s*)?PERDAS?|\s+PE)?\.?(\s+(MND|AGUA))?', ' ', 'g'), '\s+', ' ', 'g'));
$$;

-- ordem das famílias no RDO (SIGOS = ordem*10; linha do AcquaHub da mesma família = ordem*10 + 5)
create or replace function public.rdo_familia_ordem(p_grupo text)
returns int language sql immutable as $$
  select case p_grupo
    when 'Pesquisa de vazamento' then 10 when 'Loggers de pressão' then 20 when 'VRP' then 30 when 'Telemetria' then 35
    when 'Recomposição de pavimento' then 40 when 'Ramal predial' then 45 when 'Manobra de registro' then 47 when 'Rede de água' then 48
    when 'Troca de hidrômetro' then 50 when 'Fiscalização de irregularidade' then 60 when 'Vistoria de imóvel' then 65
    when 'Recadastramento' then 70 when 'Padrão de ligação' then 75 when 'Atendimento comercial' then 80 when 'Obras (projetos)' then 90
    else 85 end;
$$;

-- 2) Eventos do dia, agrupados por família --------------------------------------------------------------
create or replace function public.rdo_eventos(p_de date, p_ate date)
returns table(dia date, za text, chave text, tipo text, fonte text, ordem int, descricao text, qtd numeric, detalhe jsonb)
language plpgsql stable security definer set search_path to 'public' as $$
#variable_conflict use_column
begin
  return query
  with
  -- SIGOS: executadas e encerradas sem execução, por serviço
  sg as (
    select (s.data_execucao)::date d, s.consorcio z, public.sigos_servico_grupo(s.desc_servico) grp, public.sigos_servico_curto(s.desc_servico) srv,
           s.situacao sit, s.status_sigos st,
           s.numero, s.base, s.resultado
      from "17 - sigos".vw_os_situacao s
     where s.data_execucao is not null and s.situacao in ('executada', 'encerrada_sem_execucao')
       and (s.data_execucao)::date between p_de and p_ate
  ),
  sg_extra as (   -- endereço/matrícula só p/ o detalhe (vem da encerrada ou da aberta)
    select sg.*, coalesce(e.matricula, a.matricula) mat, coalesce(e.endereco, a.endereco) ender, coalesce(e.equipe, a.equipe) eqp
      from sg
      left join "17 - sigos".os_encerrada e on e.numero = sg.numero
      left join "17 - sigos".os_aberta a on a.numero = sg.numero and e.numero is null
  ),
  sg_srv as (   -- quebra por serviço dentro do grupo (só aparece quando o grupo junta serviços diferentes)
    select d, z, grp, sit, srv, count(*) n from sg_extra group by 1, 2, 3, 4, 5
  ),
  sg_que as (
    select d, z, grp, sit, case when count(*) > 1 then ' (' || string_agg(n || ' ' || srv, ', ' order by n desc, srv) || ')' else '' end q
      from sg_srv group by 1, 2, 3, 4
  ),
  l_sigos as (
    select x.d, x.z, 'sigos:exec:' || x.grp as k, 'Execução' as tp, 'SIGOS' as fo, public.rdo_familia_ordem(x.grp) * 10 as ord,
           x.grp || ' — ' || count(*) || case when count(*) = 1 then ' OS executada' else ' OS executadas' end || min(q.q),
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('os', x.numero, 'srv', x.srv, 'mat', x.mat, 'end', x.ender, 'eqp', x.eqp, 'res', x.resultado) order by x.srv, x.numero)
      from sg_extra x join sg_que q on q.d = x.d and q.z = x.z and q.grp = x.grp and q.sit = x.sit
     where x.sit = 'executada' group by x.d, x.z, x.grp
    union all
    select x.d, x.z, 'sigos:nexec:' || x.grp, 'Pendência', 'SIGOS', public.rdo_familia_ordem(x.grp) * 10,
           x.grp || ' — ' || count(*) || case when count(*) = 1 then ' OS encerrada' else ' OS encerradas' end || ' sem execução'
             || ' (' || concat_ws(', ', nullif(count(*) filter (where x.st ilike '%C/ VISITA%'), 0) || ' com visita',
                                       nullif(count(*) filter (where x.st ilike '%S/ VISITA%'), 0) || ' sem visita') || ')'
             || case when min(q.q) <> '' then ' —' || min(q.q) else '' end,
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('os', x.numero, 'srv', x.srv, 'mat', x.mat, 'end', x.ender, 'eqp', x.eqp, 'st', x.st) order by x.srv, x.numero)
      from sg_extra x join sg_que q on q.d = x.d and q.z = x.z and q.grp = x.grp and q.sit = x.sit
     where x.sit = 'encerrada_sem_execucao' group by x.d, x.z, x.grp
  ),
  -- Pesquisa de vazamento (km) + ocorrências do dia
  pq as (
    select t.inicio_ts::date d,
           coalesce(t.consorcio, (select l.consorcio from "1 - suporte_geografico".limite_za l where st_intersects(l.geom, t.geom) limit 1)) z,
           coalesce(t.comprimento_m, 0) m
      from "8 - coleta_campo".pesquisa_trecho t where t.inicio_ts::date between p_de and p_ate
  ),
  oc as (
    select o.data_hora::date d, o.consorcio z, (o.tipo ilike 'Fraude%') fraude, o.tipo, o.local_ref, o.os_numero
      from "8 - coleta_campo".ocorrencia o where o.data_hora::date between p_de and p_ate
  ),
  l_pesq as (
    select coalesce(p.d, o.d), coalesce(p.z, o.z), 'app:pesquisa', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Pesquisa de vazamento') * 10 + 5,
           'Pesquisa de vazamento' || coalesce(' — ' || replace(round(p.km, 1)::text, '.', ',') || ' km de rede pesquisados', '')
             || coalesce('; ' || nullif(o.vaz, 0) || case when o.vaz = 1 then ' vazamento registrado' else ' vazamentos registrados' end, '')
             || coalesce('; ' || nullif(o.fr, 0) || case when o.fr = 1 then ' fraude registrada' else ' fraudes registradas' end, ''),
           coalesce(p.km, 0),
           o.det
      from (select d, z, sum(m) / 1000.0 km from pq group by 1, 2) p
      full join (select d, z, count(*) filter (where not fraude) vaz, count(*) filter (where fraude) fr,
                        jsonb_agg(jsonb_build_object('tipo', tipo, 'local', local_ref, 'os', os_numero)) det
                   from oc group by 1, 2) o on o.d = p.d and o.z = p.z
  ),
  -- Mapeamento de pressão
  l_pres as (
    select m.data_hora::date, m.consorcio, 'app:pressao', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Loggers de pressão') * 10 + 5,
           'Mapeamento de pressão — ' || count(*) || case when count(*) = 1 then ' leitura' else ' leituras' end, count(*)::numeric, null::jsonb
      from "8 - coleta_campo".mapeamento_pressao m where m.data_hora::date between p_de and p_ate group by 1, 2
  ),
  -- Loggers (instalação / remoção / dados concluídos, cada etapa na sua data)
  lg as (
    select l.data_instalacao::date d, l.consorcio z, 'inst' k, l.numero_logger n, l.zone zn from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_instalacao::date between p_de and p_ate
    union all select l.data_remocao::date, l.consorcio, 'rem', l.numero_logger, l.zone from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_remocao::date between p_de and p_ate
    union all select l.data_finalizacao::date, l.consorcio, 'fin', l.numero_logger, l.zone from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_finalizacao::date between p_de and p_ate
  ),
  l_log as (
    select d, z, 'app:loggers', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Loggers de pressão') * 10 + 5,
           'Loggers de pressão — ' || concat_ws(', ',
              nullif(count(*) filter (where k = 'inst'), 0) || case when count(*) filter (where k = 'inst') = 1 then ' instalado' else ' instalados' end,
              nullif(count(*) filter (where k = 'rem'), 0) || case when count(*) filter (where k = 'rem') = 1 then ' removido' else ' removidos' end,
              nullif(count(*) filter (where k = 'fin'), 0) || case when count(*) filter (where k = 'fin') = 1 then ' com dados concluídos' else ' com dados concluídos' end),
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('etapa', k, 'logger', n, 'zona', zn))
      from lg group by d, z
  ),
  -- VRP: visita primária + OS de manutenção concluídas
  l_vrp as (
    select (v.visitado_em at time zone 'America/Sao_Paulo')::date, v.consorcio, 'app:vrp_visita', 'Execução', 'AcquaHub', public.rdo_familia_ordem('VRP') * 10 + 5,
           'Visita primária a VRP — ' || count(*) || case when count(*) = 1 then ' VRP visitada' else ' VRPs visitadas' end
             || coalesce(' (' || nullif(count(*) filter (where not coalesce(v.localizada, true)), 0) || ' não localizada' || case when count(*) filter (where not coalesce(v.localizada, true)) > 1 then 's' else '' end || ')', ''),
           count(*)::numeric, jsonb_agg(jsonb_build_object('vrp', v.num_vrp, 'sit', v.situacao))
      from "8 - coleta_campo".vrp_visita v
     where (v.visitado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate group by 1, 2
    union all
    select (o.executado_em at time zone 'America/Sao_Paulo')::date, o.consorcio, 'app:vrp_os', 'Execução', 'AcquaHub', public.rdo_familia_ordem('VRP') * 10 + 5,
           'Manutenção de VRP — ' || concat_ws(', ',
              nullif(count(*) filter (where o.status = 'concluida'), 0) || case when count(*) filter (where o.status = 'concluida') = 1 then ' OS concluída' else ' OS concluídas' end,
              nullif(count(*) filter (where o.status = 'concluida_pendencia'), 0) || ' concluída(s) com pendência',
              nullif(count(*) filter (where o.status = 'improdutiva'), 0) || ' improdutiva(s)')
             || coalesce(' — ' || nullif(count(*) filter (where s.situacao = 'executada'), 0) || ' também no SIGOS', ''),
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('os', o.os_numero, 'vrp', o.num_vrp, 'st', o.status, 'sigos', o.os_sigos))
      from "8 - coleta_campo".vrp_os o
      left join "17 - sigos".vw_os_situacao s on s.base = public.sigos_os_base(o.os_sigos)
     where o.status in ('concluida', 'concluida_pendencia', 'improdutiva')
       and (o.executado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate group by 1, 2
  ),
  -- Pavimento: pontos levantados, recomposições executadas (as do SIGOS ficam só na linha do SIGOS), ensaios
  l_pav as (
    select d, z, 'app:pav_lev', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Recomposição de pavimento') * 10 + 5,
           'Pavimento a recompor — ' || count(*) || case when count(*) = 1 then ' ponto levantado' else ' pontos levantados' end,
           count(*)::numeric, jsonb_agg(jsonb_build_object('origem', so, 'tipos', tp, 'os', os))
      from (select min((r.created_at at time zone 'America/Sao_Paulo')::date) d, min(r.consorcio) z, min(r.servico_origem) so,
                   string_agg(r.tipo_pavimento, ', ' order by r.tipo_pavimento) tp, min(r.os_sigos) os
              from "8 - coleta_campo".pav_recomposicao r group by r.grupo) g
     where d between p_de and p_ate group by d, z
    union all
    select r.execucao_data, r.consorcio, 'app:pav_exec', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Recomposição de pavimento') * 10 + 5,
           'Recomposição de pavimento — ' || count(*) || case when count(*) = 1 then ' tipo executado' else ' tipos executados' end
             || ' (' || string_agg(distinct r.tipo_pavimento, ', ') || ')',
           count(*)::numeric, jsonb_agg(jsonb_build_object('tipo', r.tipo_pavimento, 'os', r.os_recomposicao))
      from "8 - coleta_campo".pav_recomposicao r
     where r.execucao_data between p_de and p_ate
       and r.execucao_fonte is distinct from 'sigos'
       and not exists (select 1 from "17 - sigos".vw_os_situacao s
                        where s.base = public.sigos_os_base(r.os_recomposicao) and s.situacao = 'executada'
                          and (s.data_execucao)::date = r.execucao_data)
     group by 1, 2
    union all
    select (e.created_at at time zone 'America/Sao_Paulo')::date, coalesce(r.consorcio, ivc.za), 'app:reaterro', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Recomposição de pavimento') * 10 + 5,
           'Ensaio de compactação do reaterro — ' || count(*) || case when count(*) = 1 then ' ensaio' else ' ensaios' end
             || coalesce(' (' || concat_ws(', ', nullif(count(*) filter (where e.resultado = 'aprovado'), 0) || ' aprovado(s)',
                                               nullif(count(*) filter (where e.resultado = 'reprovado'), 0) || ' reprovado(s)') || ')', ''),
           count(*)::numeric, jsonb_agg(jsonb_build_object('res', e.resultado, 'metodo', e.metodo, 'gc', e.gc_medido))
      from "8 - coleta_campo".pav_reaterro_ensaio e
      left join "8 - coleta_campo".pav_recomposicao r on r.id = e.pav_id
      left join "13 - projetos_obra".proj_reaterro pr on pr.id = e.proj_reaterro_id
      left join lateral (select iv.consorcio za from "13 - projetos_obra".vw_iv iv where iv.kind = pr.kind and iv.gid = pr.gid) ivc on true
     where (e.created_at at time zone 'America/Sao_Paulo')::date between p_de and p_ate group by 1, 2
  ),
  -- Projetos: avanço lançado no dia por intervenção (concluída no dia = Execução; senão Em andamento)
  av as (
    select (a.ts at time zone 'America/Sao_Paulo')::date d,
           case a.consorcio when 'Águas Integradas' then 'ZA1004' when 'Eficiência Hídrica' then 'ZA0200' else a.consorcio end z,
           a.kind, a.gid, a.iv_cod, a.iv_local, a.caminho, a.valor, a.unidade, a.ts
      from "13 - projetos_obra".intervencao_avanco a
     where (a.ts at time zone 'America/Sao_Paulo')::date between p_de and p_ate
  ),
  av_ult as (select distinct on (d, kind, gid, caminho) * from av order by d, kind, gid, caminho, ts desc),
  l_proj as (
    select u.d, u.z, 'app:projeto:' || u.kind || ':' || u.gid,
           case when (st.concluida_em at time zone 'America/Sao_Paulo')::date = u.d then 'Execução' else 'Em andamento' end,
           'AcquaHub', public.rdo_familia_ordem('Obras (projetos)') * 10 + 5,
           coalesce(min(u.iv_cod), '') || coalesce(' (' || min(u.iv_local) || ')', '') || ' — '
             || string_agg(case when u.caminho ~ '›.*›' then regexp_replace(u.caminho, '^[^›]*›\s*', '') else regexp_replace(u.caminho, '^.*›\s*', '') end
                        || ' ' || replace(trim_scale(u.valor)::text, '.', ',') || case when u.unidade = '%' then '%' else ' ' || coalesce(u.unidade, '') end, '; ' order by u.caminho)
             || case when (st.concluida_em at time zone 'America/Sao_Paulo')::date = u.d then ' — intervenção concluída'
                     when st.exec_pct is not null then ' — execução em ' || round(st.exec_pct) || '%' else '' end,
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('item', u.caminho, 'valor', u.valor, 'un', u.unidade) order by u.caminho)
      from av_ult u
      left join "13 - projetos_obra".intervencao_estado st on st.kind = u.kind and st.gid = u.gid
     group by u.d, u.z, u.kind, u.gid, st.concluida_em, st.exec_pct
  ),
  -- Atendimento comercial de campo (entrevistadores)
  ac as (
    select (s.data_hora at time zone 'America/Sao_Paulo')::date d, s.consorcio z, 'sol' k from "12 - retaguarda".abertura_servico s
     where (s.data_hora at time zone 'America/Sao_Paulo')::date between p_de and p_ate
    union all select (e.data_hora at time zone 'America/Sao_Paulo')::date, e.consorcio, 'oc' from "12 - retaguarda".entrevista_ocorrencia e
     where (e.data_hora at time zone 'America/Sao_Paulo')::date between p_de and p_ate
    union all select c.data_hora::date, c.consorcio, 'cap' from "12 - retaguarda".captacao_cliente c where c.data_hora::date between p_de and p_ate
  ),
  l_ac as (
    select d, z, 'app:atendimento', 'Execução', 'AcquaHub', public.rdo_familia_ordem('Atendimento comercial') * 10 + 5,
           'Atendimento comercial em campo — ' || concat_ws(', ',
              nullif(count(*) filter (where k = 'cap'), 0) || ' captação(ões) de cliente',
              nullif(count(*) filter (where k = 'sol'), 0) || ' solicitação(ões) de serviço',
              nullif(count(*) filter (where k = 'oc'), 0) || ' ocorrência(s) registrada(s)'),
           count(*)::numeric, null::jsonb
      from ac group by d, z
  ),
  todas as (
    select * from l_sigos union all select * from l_pesq union all select * from l_pres union all select * from l_log
    union all select * from l_vrp union all select * from l_pav union all select * from l_proj union all select * from l_ac
  )
  select t.* from todas t where t.d is not null and t.z in ('ZA0200', 'ZA1004');
end $$;
revoke all on function public.rdo_eventos(date, date) from public, anon, authenticated;

-- 3) SIGOS na Vitrine ---------------------------------------------------------------------------------
-- desde = mesmo padrão do app_vitrine_dados (última sexta-feira); mes = 1º dia do mês corrente.
create or replace function public.app_vitrine_sigos(p_desde date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_desde date; v_mes date; v_ini date;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id = v_id and (funcao = 'admin' or coalesce(dev_acesso, false))) then
    raise exception 'sem permissão'; end if;
  v_desde := coalesce(p_desde, v_hoje - ((extract(isodow from v_hoje)::int + 2) % 7));
  v_mes := date_trunc('month', v_hoje)::date;
  v_ini := least(v_desde, v_mes, v_hoje - 29);
  return (
  with s as (
    select x.consorcio za, public.sigos_servico_grupo(x.desc_servico) grp, x.situacao sit, (x.data_execucao)::date dia
      from "17 - sigos".vw_os_situacao x
     where x.situacao in ('executada', 'encerrada_sem_execucao') and (x.data_execucao)::date between v_ini and v_hoje
  ),
  por_grupo as (
    select za, grp,
           count(*) filter (where sit = 'executada' and dia >= v_desde) per_exe,
           count(*) filter (where sit <> 'executada' and dia >= v_desde) per_nex,
           count(*) filter (where sit = 'executada' and dia >= v_mes) mes_exe,
           count(*) filter (where sit <> 'executada' and dia >= v_mes) mes_nex
      from s group by 1, 2
  ),
  por_dia as (
    select dia, za, count(*) filter (where sit = 'executada') exe, count(*) filter (where sit <> 'executada') nex
      from s where dia >= v_hoje - 29 group by 1, 2
  ),
  pts as (   -- OS executadas com coordenada (foto do serviço; sem ela, o imóvel) — desde o mais cedo entre "desde" e 7 dias atrás
    select e.consorcio za, public.sigos_servico_grupo(e.desc_servico) grp, public.sigos_servico_curto(e.desc_servico) srv,
           e.execucao::date dia, to_char(e.execucao, 'HH24:MI') hora,
           round(coalesce(e.lat_foto, e.lat_imovel)::numeric, 6) lat, round(coalesce(e.lon_foto, e.lon_imovel)::numeric, 6) lon
      from "17 - sigos".os_encerrada e
     where e.status = 'EXECUTADA' and e.execucao::date between least(v_desde, v_hoje - 6) and v_hoje
       and coalesce(e.lat_foto, e.lat_imovel) is not null
  ),
  cart as (   -- carteira aberta de verdade: tira o que já aparece nas Encerradas
    select a.consorcio za, public.sigos_servico_grupo(a.desc_servico) grp, count(*) n,
           count(*) filter (where a.limite < now() at time zone 'America/Sao_Paulo') vencidas,
           round(avg(v_hoje - a.abertura::date)) idade
      from "17 - sigos".os_aberta a
     where a.status not ilike 'EXECUTADA%'
       and not exists (select 1 from "17 - sigos".os_encerrada e where public.sigos_os_base(e.numero) = public.sigos_os_base(a.numero))
     group by 1, 2
  ),
  eqp as (
    select e.consorcio za, coalesce(nullif(btrim(e.equipe), ''), nullif(btrim(e.responsavel), ''), '(sem equipe)') equipe,
           count(*) filter (where e.status = 'EXECUTADA') exe, count(*) filter (where e.status <> 'EXECUTADA') nex
      from "17 - sigos".os_encerrada e where e.execucao::date between v_mes and v_hoje group by 1, 2
  )
  select jsonb_build_object(
    'desde', v_desde, 'mes', v_mes, 'hoje', v_hoje,
    'cobertura', (select jsonb_object_agg(c.za, jsonb_build_object('relacao_em', c.relacao_em, 'encerradas_ate', c.encerradas_ate)) from "17 - sigos".vw_carga_cobertura c),
    'grupos', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'g', grp, 'pe', per_exe, 'pn', per_nex, 'me', mes_exe, 'mn', mes_nex)) from por_grupo), '[]'::jsonb),
    'dias', coalesce((select jsonb_agg(jsonb_build_object('dia', dia, 'za', za, 'e', exe, 'n', nex) order by dia) from por_dia), '[]'::jsonb),
    'pts', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'g', grp, 's', srv, 'dia', dia, 'h', hora, 'lat', lat, 'lon', lon)) from (select * from pts order by dia desc limit 5000) p), '[]'::jsonb),
    'carteira', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'g', grp, 'n', n, 'venc', vencidas, 'idade', idade)) from cart), '[]'::jsonb),
    'equipes', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'eq', equipe, 'e', exe, 'n', nex) order by exe desc) from (select * from eqp order by exe desc limit 16) q), '[]'::jsonb)
  ));
end $$;
revoke all on function public.app_vitrine_sigos(date) from public, anon;
grant execute on function public.app_vitrine_sigos(date) to authenticated;
