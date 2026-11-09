-- =====================================================================================
-- RDO diário (2026-11-09) — o que foi EXECUTADO ou está EM ANDAMENTO num dia × ZA,
-- juntando os relatórios SIGOS e o que foi lançado no AcquaHub.
--
-- Decisões do usuário (09/11/2026): só consulta no app (sem PDF/Excel); sem efetivo, sem
-- equipamentos; rascunho automático → alguém revisa (edita/oculta/acrescenta) e FECHA o dia;
-- se o banco muda depois do fechamento (ex.: carga SIGOS atrasada) o dia fica "desatualizado".
-- Desde 01/09/2026 (a base SIGOS cobre Contagem a partir de 11/09 e Betim de 22/09).
--
-- public.rdo_eventos(de, ate) é a FONTE ÚNICA de eventos do dia (a Vitrine vai passar a usá-la).
-- Cada linha tem uma `chave` estável (é por ela que a edição/ocultação do revisor se prende).
-- Sem contar duas vezes: a recomposição de pavimento que o SIGOS executou fica só na linha do SIGOS;
-- OS de VRP que também está no SIGOS é anotada na linha da VRP.
-- =====================================================================================

-- 1) Fonte única de eventos do dia -----------------------------------------------------------
create or replace function public.rdo_eventos(p_de date, p_ate date)
returns table(dia date, za text, chave text, tipo text, fonte text, ordem int, descricao text, qtd numeric, detalhe jsonb)
language plpgsql stable security definer set search_path to 'public' as $$
#variable_conflict use_column
begin
  return query
  with
  -- SIGOS: executadas e encerradas sem execução, por serviço
  sg as (
    select (s.data_execucao)::date d, s.consorcio z, s.desc_servico srv, s.situacao sit, s.status_sigos st,
           s.numero, s.base, s.resultado
      from "17 - sigos".vw_os_situacao s
     where s.data_execucao is not null and s.situacao in ('executada', 'encerrada_sem_execucao')
       and (s.data_execucao)::date between p_de and p_ate
  ),
  sg_extra as (   -- endereço/matrícula só p/ o detalhe (vem da encerrada ou da aberta)
    select sg.*, coalesce(e.matricula, a.matricula) mat, coalesce(e.endereco, a.endereco) ender
      from sg
      left join "17 - sigos".os_encerrada e on e.numero = sg.numero
      left join "17 - sigos".os_aberta a on a.numero = sg.numero and e.numero is null
  ),
  l_sigos as (
    select d, z, 'sigos:exec:' || srv as k, 'Execução' as tp, 'SIGOS' as fo, 10 as ord,
           srv || ' — ' || count(*) || case when count(*) = 1 then ' OS executada' else ' OS executadas' end,
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('os', numero, 'mat', mat, 'end', ender, 'res', resultado) order by numero)
      from sg_extra where sit = 'executada' group by d, z, srv
    union all
    select d, z, 'sigos:nexec:' || srv, 'Pendência', 'SIGOS', 60,
           srv || ' — ' || count(*) || case when count(*) = 1 then ' OS encerrada' else ' OS encerradas' end || ' sem execução ('
             || concat_ws(', ', nullif(count(*) filter (where st ilike '%C/ VISITA%'), 0) || ' com visita',
                                nullif(count(*) filter (where st ilike '%S/ VISITA%'), 0) || ' sem visita') || ')',
           count(*)::numeric,
           jsonb_agg(jsonb_build_object('os', numero, 'mat', mat, 'end', ender, 'st', st) order by numero)
      from sg_extra where sit = 'encerrada_sem_execucao' group by d, z, srv
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
    select coalesce(p.d, o.d), coalesce(p.z, o.z), 'app:pesquisa', 'Execução', 'AcquaHub', 20,
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
    select m.data_hora::date, m.consorcio, 'app:pressao', 'Execução', 'AcquaHub', 30,
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
    select d, z, 'app:loggers', 'Execução', 'AcquaHub', 31,
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
    select (v.visitado_em at time zone 'America/Sao_Paulo')::date, v.consorcio, 'app:vrp_visita', 'Execução', 'AcquaHub', 40,
           'Visita primária a VRP — ' || count(*) || case when count(*) = 1 then ' VRP visitada' else ' VRPs visitadas' end
             || coalesce(' (' || nullif(count(*) filter (where not coalesce(v.localizada, true)), 0) || ' não localizada' || case when count(*) filter (where not coalesce(v.localizada, true)) > 1 then 's' else '' end || ')', ''),
           count(*)::numeric, jsonb_agg(jsonb_build_object('vrp', v.num_vrp, 'sit', v.situacao))
      from "8 - coleta_campo".vrp_visita v
     where (v.visitado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate group by 1, 2
    union all
    select (o.executado_em at time zone 'America/Sao_Paulo')::date, o.consorcio, 'app:vrp_os', 'Execução', 'AcquaHub', 41,
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
    select d, z, 'app:pav_lev', 'Execução', 'AcquaHub', 50,
           'Pavimento a recompor — ' || count(*) || case when count(*) = 1 then ' ponto levantado' else ' pontos levantados' end,
           count(*)::numeric, jsonb_agg(jsonb_build_object('origem', so, 'tipos', tp, 'os', os))
      from (select min((r.created_at at time zone 'America/Sao_Paulo')::date) d, min(r.consorcio) z, min(r.servico_origem) so,
                   string_agg(r.tipo_pavimento, ', ' order by r.tipo_pavimento) tp, min(r.os_sigos) os
              from "8 - coleta_campo".pav_recomposicao r group by r.grupo) g
     where d between p_de and p_ate group by d, z
    union all
    select r.execucao_data, r.consorcio, 'app:pav_exec', 'Execução', 'AcquaHub', 51,
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
    select (e.created_at at time zone 'America/Sao_Paulo')::date, coalesce(r.consorcio, ivc.za), 'app:reaterro', 'Execução', 'AcquaHub', 52,
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
           'AcquaHub', 70,
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
    select d, z, 'app:atendimento', 'Execução', 'AcquaHub', 80,
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

-- 2) Revisão e fechamento ----------------------------------------------------------------------
create table if not exists "12 - retaguarda".rdo_item (
  id uuid primary key default gen_random_uuid(),
  dia date not null, za text not null check (za in ('ZA0200', 'ZA1004')),
  chave text,                         -- linha automática editada/ocultada; null = linha manual
  tipo text not null default 'Nota' check (tipo in ('Execução', 'Em andamento', 'Pendência', 'Ocorrência', 'Nota')),
  descricao text,                     -- texto revisado (null = mantém o automático)
  oculto boolean not null default false,
  por_uuid uuid, por_nome text, em timestamptz not null default now()
);
create unique index if not exists rdo_item_chave_uq on "12 - retaguarda".rdo_item (dia, za, chave) where chave is not null;
create index if not exists rdo_item_dia_idx on "12 - retaguarda".rdo_item (dia, za);

create table if not exists "12 - retaguarda".rdo_dia (
  dia date not null, za text not null check (za in ('ZA0200', 'ZA1004')),
  fechado_por uuid, fechado_nome text, fechado_em timestamptz not null default now(),
  hash text not null,                 -- assinatura das linhas automáticas no fechamento
  snapshot jsonb not null,            -- linhas como foram fechadas
  primary key (dia, za)
);
alter table "12 - retaguarda".rdo_item enable row level security;
alter table "12 - retaguarda".rdo_dia  enable row level security;

-- assinatura das linhas automáticas de um dia (muda quando a carga SIGOS ou um lançamento mexe no dia)
create or replace function public.rdo_hash(p_dia date, p_za text)
returns text language sql stable security definer set search_path to 'public' as $$
  select md5(coalesce(string_agg(e.chave || '|' || e.descricao, '§' order by e.chave), ''))
    from public.rdo_eventos(p_dia, p_dia) e where e.za = p_za;
$$;
revoke all on function public.rdo_hash(date, text) from public, anon, authenticated;

-- linhas do dia já com a revisão aplicada, numeradas
create or replace function public.rdo_linhas(p_dia date, p_za text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with a as (
    select e.chave, coalesce(i.tipo, e.tipo) tipo, e.fonte, e.ordem, coalesce(i.descricao, e.descricao) descricao,
           e.descricao auto, coalesce(i.oculto, false) oculto, (i.descricao is not null and i.descricao <> e.descricao) editada,
           e.detalhe, false manual, null::uuid id
      from public.rdo_eventos(p_dia, p_dia) e
      left join "12 - retaguarda".rdo_item i on i.dia = p_dia and i.za = p_za and i.chave = e.chave
     where e.za = p_za
    union all
    select null, i.tipo, 'Manual', 90, i.descricao, null, i.oculto, false, null, true, i.id
      from "12 - retaguarda".rdo_item i where i.dia = p_dia and i.za = p_za and i.chave is null
  )
  select coalesce(jsonb_agg(jsonb_build_object('chave', chave, 'id', id, 'tipo', tipo, 'fonte', fonte, 'desc', descricao,
           'auto', auto, 'oculto', oculto, 'editada', editada, 'manual', manual, 'det', detalhe)
         order by oculto, case tipo when 'Execução' then 1 when 'Em andamento' then 2 when 'Ocorrência' then 3 when 'Pendência' then 4 else 5 end,
                  ordem, descricao), '[]'::jsonb)
    from a;
$$;
revoke all on function public.rdo_linhas(date, text) from public, anon, authenticated;

-- 3) RPCs do app (gate = Auxiliar de Programação: aux_acesso ou admin) -------------------------
-- Calendário do mês: status de cada dia
create or replace function public.app_rdo_mes(p_mes date, p_za text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_de date := date_trunc('month', p_mes)::date; v_ate date; r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  v_ate := least((v_de + interval '1 month - 1 day')::date, (now() at time zone 'America/Sao_Paulo')::date);
  with ev as (select * from public.rdo_eventos(v_de, v_ate) e where e.za = p_za),
  dias as (select generate_series(v_de, v_ate, interval '1 day')::date d),
  cob as (select * from "17 - sigos".vw_carga_cobertura where za = p_za),
  h as (select e.dia, md5(coalesce(string_agg(e.chave || '|' || e.descricao, '§' order by e.chave), '')) hash,
               count(*) n, count(*) filter (where e.fonte = 'SIGOS') n_sigos
          from ev e group by e.dia)
  select coalesce(jsonb_agg(jsonb_build_object(
           'dia', d.d, 'n', coalesce(h.n, 0), 'n_sigos', coalesce(h.n_sigos, 0),
           'status', case when f.dia is not null and f.hash is distinct from coalesce(h.hash, md5('')) then 'desatualizado'
                          when f.dia is not null then 'fechado'
                          when coalesce(h.n, 0) = 0 and not exists (select 1 from "12 - retaguarda".rdo_item i where i.dia = d.d and i.za = p_za) then 'vazio'
                          else 'rascunho' end,
           'sigos', case when c.encerradas_desde is null or d.d < c.encerradas_desde then 'sem_base'
                         when c.encerradas_ate is null or d.d > c.encerradas_ate then 'aguardando' else 'ok' end
         ) order by d.d), '[]'::jsonb)
    into r
    from dias d cross join cob c
    left join h on h.dia = d.d
    left join "12 - retaguarda".rdo_dia f on f.dia = d.d and f.za = p_za;
  return jsonb_build_object('za', p_za, 'de', v_de, 'ate', v_ate, 'dias', r);
end $$;
revoke all on function public.app_rdo_mes(date, text) from public, anon;
grant execute on function public.app_rdo_mes(date, text) to authenticated;

-- Um dia: linhas atuais (com revisão) + fechamento
create or replace function public.app_rdo_dia(p_dia date, p_za text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare f record; c record;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into f from "12 - retaguarda".rdo_dia where dia = p_dia and za = p_za;
  select * into c from "17 - sigos".vw_carga_cobertura where za = p_za;
  return jsonb_build_object(
    'dia', p_dia, 'za', p_za,
    'linhas', public.rdo_linhas(p_dia, p_za),
    'sigos', case when c.encerradas_desde is null or p_dia < c.encerradas_desde then 'sem_base'
                  when c.encerradas_ate is null or p_dia > c.encerradas_ate then 'aguardando' else 'ok' end,
    'cobertura', jsonb_build_object('relacao_em', c.relacao_em, 'encerradas_ate', c.encerradas_ate, 'encerradas_desde', c.encerradas_desde),
    'fechado', case when f.dia is null then null else jsonb_build_object(
                 'por', f.fechado_nome, 'em', f.fechado_em, 'snapshot', f.snapshot,
                 'desatualizado', f.hash is distinct from public.rdo_hash(p_dia, p_za)) end);
end $$;
revoke all on function public.app_rdo_dia(date, text) from public, anon;
grant execute on function public.app_rdo_dia(date, text) to authenticated;

-- Revisar uma linha automática (p_chave) ou criar/editar uma manual (p_id / nenhum)
create or replace function public.app_rdo_item_salvar(p_dia date, p_za text, p_chave text, p_id uuid,
                                                       p_tipo text, p_descricao text, p_oculto boolean)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_nome text; v_id uuid;
begin
  if not public.sigos_pode_ver(v_uid) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "12 - retaguarda".rdo_dia where dia = p_dia and za = p_za) then
    raise exception 'dia fechado — reabra para revisar'; end if;
  if p_dia < date '2026-09-01' or p_dia > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'dia fora do período do RDO'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  if p_chave is not null then
    insert into "12 - retaguarda".rdo_item (dia, za, chave, tipo, descricao, oculto, por_uuid, por_nome)
    values (p_dia, p_za, p_chave, coalesce(p_tipo, 'Execução'), nullif(btrim(p_descricao), ''), coalesce(p_oculto, false), v_uid, v_nome)
    on conflict (dia, za, chave) where chave is not null
    do update set tipo = excluded.tipo, descricao = excluded.descricao, oculto = excluded.oculto,
                  por_uuid = excluded.por_uuid, por_nome = excluded.por_nome, em = now()
    returning id into v_id;
  else
    if nullif(btrim(p_descricao), '') is null then raise exception 'escreva a descrição'; end if;
    if p_id is null then
      insert into "12 - retaguarda".rdo_item (dia, za, chave, tipo, descricao, oculto, por_uuid, por_nome)
      values (p_dia, p_za, null, coalesce(p_tipo, 'Nota'), btrim(p_descricao), false, v_uid, v_nome) returning id into v_id;
    else
      update "12 - retaguarda".rdo_item set tipo = coalesce(p_tipo, tipo), descricao = btrim(p_descricao),
             oculto = coalesce(p_oculto, oculto), por_uuid = v_uid, por_nome = v_nome, em = now()
       where id = p_id and dia = p_dia and za = p_za and chave is null returning id into v_id;
    end if;
  end if;
  return v_id;
end $$;
revoke all on function public.app_rdo_item_salvar(date, text, text, uuid, text, text, boolean) from public, anon;
grant execute on function public.app_rdo_item_salvar(date, text, text, uuid, text, text, boolean) to authenticated;

-- Excluir linha manual / desfazer revisão de linha automática
create or replace function public.app_rdo_item_excluir(p_dia date, p_za text, p_chave text, p_id uuid)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "12 - retaguarda".rdo_dia where dia = p_dia and za = p_za) then
    raise exception 'dia fechado — reabra para revisar'; end if;
  delete from "12 - retaguarda".rdo_item
   where dia = p_dia and za = p_za and ((p_chave is not null and chave = p_chave) or (p_id is not null and id = p_id and chave is null));
  get diagnostics n = row_count; return n;
end $$;
revoke all on function public.app_rdo_item_excluir(date, text, text, uuid) from public, anon;
grant execute on function public.app_rdo_item_excluir(date, text, text, uuid) to authenticated;

-- Fechar / reabrir o dia
create or replace function public.app_rdo_fechar(p_dia date, p_za text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_nome text;
begin
  if not public.sigos_pode_ver(v_uid) then raise exception 'sem permissão'; end if;
  if p_dia < date '2026-09-01' or p_dia > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'dia fora do período do RDO'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;
  insert into "12 - retaguarda".rdo_dia (dia, za, fechado_por, fechado_nome, fechado_em, hash, snapshot)
  values (p_dia, p_za, v_uid, v_nome, now(), public.rdo_hash(p_dia, p_za), public.rdo_linhas(p_dia, p_za))
  on conflict (dia, za) do update set fechado_por = excluded.fechado_por, fechado_nome = excluded.fechado_nome,
         fechado_em = excluded.fechado_em, hash = excluded.hash, snapshot = excluded.snapshot;
  return jsonb_build_object('ok', true, 'por', v_nome);
end $$;
revoke all on function public.app_rdo_fechar(date, text) from public, anon;
grant execute on function public.app_rdo_fechar(date, text) to authenticated;

create or replace function public.app_rdo_reabrir(p_dia date, p_za text)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  delete from "12 - retaguarda".rdo_dia where dia = p_dia and za = p_za;
  get diagnostics n = row_count; return n;
end $$;
revoke all on function public.app_rdo_reabrir(date, text) from public, anon;
grant execute on function public.app_rdo_reabrir(date, text) to authenticated;
