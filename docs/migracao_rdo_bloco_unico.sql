-- RDO: bloco único SIGOS+AcquaHub e nome legível do serviço (2026-11-09, sw v345)
--  * public.sigos_servico_nome(desc): nome legível do serviço do SIGOS (manutenção, substituição, instalação de logger…).
--  * Título da linha do SIGOS sempre diz o tipo: "VRP — 2 OS executadas: 2 manutenção".
--  * Manutenção de VRP do app cuja OS SIGOS já está executada sai da linha do AcquaHub e entra no bloco do SIGOS,
--    com a VRP ao lado da OS no detalhe ("1637900: 00127848460901 (VRP024)"). A linha do app fica só com o que o SIGOS
--    ainda não trouxe. (Pavimento já fazia isso; loggers não têm OS SIGOS no app.)
-- Dias já fechados guardam o snapshot antigo (reabrir e fechar de novo atualiza).

create or replace function public.sigos_servico_nome(p_desc text)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when d ~ 'VALVULA CONTROL' and d ~ 'MANUT' then 'manutenção'
    when d ~ 'VALVULA CONTROL' and d ~ 'SUBST' then 'substituição'
    when d ~ 'VALVULA CONTROL' and d ~ 'INST'  then 'instalação'
    when d ~ 'ABERTURA REGISTRO'   then 'abertura de registro'
    when d ~ 'FECHAMENTO REGISTRO' then 'fechamento de registro'
    when d ~ 'MEDICAO DE PRESSAO' and d ~ 'INST' then 'instalação de logger'
    when d ~ 'MEDICAO DE PRESSAO' and d ~ 'RET'  then 'retirada de logger'
    when d ~ 'DETECC.*VAZ'  then 'detecção de vazamento não visível'
    when d ~ 'COR\.?VAZ' and d ~ 'PASSEIO' then 'correção de vazamento (passeio)'
    when d ~ 'COR\.?VAZ' and d ~ 'RUA'     then 'correção de vazamento (rua)'
    when d ~ 'COR\.?VAZ' then 'correção de vazamento'
    when d ~ 'REATERRO' then 'reaterro de vala'
    when d ~ 'RECOMPOSICAO' and d ~ 'PASSEIO' then 'recomposição de passeio'
    when d ~ 'RECOMPOSICAO' and d ~ '(RUA|ASFALTO)' then 'recomposição de asfalto'
    when d ~ 'SUBST.*HIDROMETRO' then 'substituição de hidrômetro' || coalesce(' cap. ' || substring(d from 'CAP\s+([A-Z0-9]+)'), '')
    when d ~ 'TELEMETRIA' and d ~ 'INST' then 'instalação de telemetria'
    when d ~ 'TELEMETRIA' then 'telemetria'
    when d ~ 'LIG\.?CLAND' then 'ligação clandestina'
    when d ~ 'INFRACAO|VIOL' then 'violação (sem retirada do HD)'
    when d ~ 'RAMAL' and d ~ 'SUBST' then 'substituição de ramal'
    when d ~ 'VISTORIA' then 'vistoria de imóvel'
    when d ~ 'REVISAO CADASTRO|RECADAST' then 'revisão de cadastro'
    else lower(public.sigos_servico_curto(p_desc)) end
  from (select upper(coalesce(p_desc, '')) d) t
$$;
revoke all on function public.sigos_servico_nome(text) from public, anon;
grant execute on function public.sigos_servico_nome(text) to authenticated;

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
           s.numero, s.base, s.resultado, s.cod_servico cod, s.desc_servico
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
  sg_app as (   -- o que o AcquaHub registrou para a mesma OS (vai entre parênteses ao lado da OS)
    select public.sigos_os_base(o.os_sigos) base, string_agg(distinct case when o.num_vrp ~* 'VRP' then o.num_vrp else 'VRP ' || o.num_vrp end, ', ') ref
      from "8 - coleta_campo".vrp_os o
     where o.os_sigos is not null and o.status in ('concluida', 'concluida_pendencia', 'improdutiva')
     group by 1
  ),
  sg_det as (   -- detalhe: um item por código de serviço com todas as OS separadas por vírgula
    select d, z, grp, sit, jsonb_agg(jsonb_build_object('cod', cod, 'oss', oss) order by cod) det
      from (select sg.d, sg.z, sg.grp, sg.sit, coalesce(sg.cod::text, '—') cod,
                   string_agg(sg.numero::text || coalesce(' (' || ap.ref || ')', ''), ', ' order by sg.numero) oss
              from sg left join sg_app ap on ap.base = sg.base
             group by 1, 2, 3, 4, 5) t
     group by 1, 2, 3, 4
  ),
  sg_srv as (   -- quebra por tipo de serviço (nome legível), sempre — diz se é manutenção, substituição, instalação…
    select d, z, grp, sit, public.sigos_servico_nome(desc_servico) srv, count(*) n from sg_extra group by 1, 2, 3, 4, 5
  ),
  sg_que as (
    select d, z, grp, sit, ': ' || string_agg(n || ' ' || srv, ', ' order by n desc, srv) q
      from sg_srv group by 1, 2, 3, 4
  ),
  l_sigos as (
    select x.d, x.z, 'sigos:exec:' || x.grp as k, 'Execução' as tp, 'SIGOS' as fo, public.rdo_familia_ordem(x.grp) * 10 as ord,
           x.grp || ' — ' || count(*) || case when count(*) = 1 then ' OS executada' else ' OS executadas' end || min(q.q),
           count(*)::numeric,
           sd.det
      from sg_extra x join sg_que q on q.d = x.d and q.z = x.z and q.grp = x.grp and q.sit = x.sit
      join sg_det sd on sd.d = x.d and sd.z = x.z and sd.grp = x.grp and sd.sit = x.sit
     where x.sit = 'executada' group by x.d, x.z, x.grp, sd.det
    union all
    select x.d, x.z, 'sigos:nexec:' || x.grp, 'Pendência', 'SIGOS', public.rdo_familia_ordem(x.grp) * 10,
           x.grp || ' — ' || count(*) || case when count(*) = 1 then ' OS encerrada' else ' OS encerradas' end || ' sem execução'
             || ' (' || concat_ws(', ', nullif(count(*) filter (where x.st ilike '%C/ VISITA%'), 0) || ' com visita',
                                       nullif(count(*) filter (where x.st ilike '%S/ VISITA%'), 0) || ' sem visita') || ')'
             || min(q.q),
           count(*)::numeric,
           sd.det
      from sg_extra x join sg_que q on q.d = x.d and q.z = x.z and q.grp = x.grp and q.sit = x.sit
      join sg_det sd on sd.d = x.d and sd.z = x.z and sd.grp = x.grp and sd.sit = x.sit
     where x.sit = 'encerrada_sem_execucao' group by x.d, x.z, x.grp, sd.det
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
             || ' (' || concat_ws(', ',
                  nullif(count(*) filter (where o.os_sigos is null), 0) || ' sem OS SIGOS informada',
                  nullif(count(*) filter (where o.os_sigos is not null), 0) || ' aguardando execução no SIGOS') || ')',
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('os', o.os_numero, 'vrp', o.num_vrp, 'st', o.status, 'sigos', o.os_sigos))
      from "8 - coleta_campo".vrp_os o
     where o.status in ('concluida', 'concluida_pendencia', 'improdutiva')
       and not exists (select 1 from "17 - sigos".vw_os_situacao s
                        where s.base = public.sigos_os_base(o.os_sigos) and s.situacao = 'executada')
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
           concat_ws(' — ', coalesce(min(u.iv_cod), '—'), min(v.tipo_origem), coalesce(min(u.iv_local), min(v.projeto)))
             || case when (st.concluida_em at time zone 'America/Sao_Paulo')::date = u.d then ' — concluída (100%)'
                     when st.exec_pct is not null then ' — avanço total ' || round(st.exec_pct) || '%' else '' end,
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('item', u.caminho, 'valor', u.valor, 'un', u.unidade) order by u.caminho)
      from av_ult u
      left join "13 - projetos_obra".intervencao_estado st on st.kind = u.kind and st.gid = u.gid
      left join "13 - projetos_obra".vw_iv v on v.kind = u.kind and v.gid = u.gid
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
