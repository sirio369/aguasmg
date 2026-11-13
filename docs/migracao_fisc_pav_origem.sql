-- Consolidador: recomposição de pavimento vinculada ao SERVIÇO DE ORIGEM (2026-11-13)
-- Cada OS SIGOS de recomposição ganha, em extra._origem, a OS que abriu o buraco e do que ela se trata.
-- Ordem de busca (a 1ª que achar vale):
--   1. SIGOS  — campo "OS origem" da própria OS de recomposição (os_encerrada/os_aberta.os_origem);
--   2. AcquaHub — registro da Gestão de Pavimento cuja OS da recomposição (os_recomposicao) é esta → os_sigos de origem;
--   3. provável — OS SIGOS de ramal / correção de vazamento / manobra / VRP executada na MESMA matrícula (ou mesmo
--      endereço) até 120 dias antes da recomposição (a mais recente).
-- Só muda `extra` (fora do hash da linha) → dias já validados NÃO ficam "mudou". Assinatura igual (create or replace).

CREATE OR REPLACE FUNCTION public.fisc_execucoes(p_de date, p_ate date)
 RETURNS TABLE(dia date, za text, atividade text, ordem integer, exec_id text, origem text, servico text, descricao text, local text, equipe text, hora text, qtd numeric, unidade text, os_app text, os_sigos text, sigos_sit text, fotos text[], geo jsonb, extra jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
  return query
  with
  -- SIGOS: tudo que conta (executada; fiscalização também NÃO EXEC. C/ VISITA), sem filtro de data (casamento)
  sg as (
    select s.base, s.numero, s.consorcio z, s.situacao sit, s.status_sigos st, s.cod_servico cod, s.desc_servico dsc,
           (s.data_execucao)::date d, s.data_execucao dt, s.resultado,
           public.fisc_familia(s.cod_servico, s.desc_servico, s.abertura) fam
      from "17 - sigos".vw_os_situacao s
     where s.data_execucao is not null and s.situacao in ('executada', 'encerrada_sem_execucao')
  ),
  sgc as (select * from sg where public.sigos_conta(case when sg.fam = 'Correção de vazamento' then 'x' else sg.fam end, sg.sit, sg.st)),
  -- OS SIGOS citadas pelas execuções do app (não viram linha própria)
  app_os as (
    select public.sigos_os_base(o.os_sigos) b from "8 - coleta_campo".vrp_os o
     where o.status in ('concluida', 'concluida_pendencia', 'improdutiva') and o.executado_em is not null
    union select public.sigos_os_base(l.os_copasa_instalacao) from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_instalacao is not null
    union select public.sigos_os_base(l.os_copasa_remocao) from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_remocao is not null
  ),
  sg_txt as (   -- situação da OS SIGOS p/ mostrar ao lado da execução do app
    select distinct on (base) base, numero,
           case when sit = 'executada' then 'executada no SIGOS em ' || to_char(d, 'DD/MM/YYYY')
                else 'encerrada sem execução no SIGOS em ' || to_char(d, 'DD/MM/YYYY') end txt
      from sg order by base, (sit = 'executada') desc, d
  ),
  -- ---------------- VRP ----------------
  e_vrp_os as (
    select (o.executado_em at time zone 'America/Sao_Paulo')::date d, o.consorcio z, 'VRP'::text atv, 'app:vrp_os:' || o.id eid,
           'AcquaHub'::text ori,
           'Manutenção de VRP'::text srv,
           coalesce(public.fisc_vrp(o.num_vrp), 'VRP —') || ' — ' || case o.status when 'concluida' then 'concluída' when 'concluida_pendencia' then 'concluída com pendência' else 'improdutiva' end
             || coalesce('; montante ' || o.press_mont_fin || ' / jusante ' || o.press_jus_fin || ' mca', '') dsc,
           coalesce(public.fisc_vrp(o.num_vrp), o.cd_no_agua) loc, p.nome eq, to_char(o.executado_em at time zone 'America/Sao_Paulo', 'HH24:MI') hr,
           1::numeric q, 'OS'::text un, o.os_numero osa, o.os_sigos oss,
           coalesce(t.txt, case when o.os_sigos is null then 'sem OS SIGOS informada' else 'aguardando execução no SIGOS' end) sst,
           public.fisc_fotos_json(o.fotos) ft, coalesce(vc.g, public.fisc_pt(o.gps_lat, o.gps_lon)) g,
           jsonb_strip_nulls(jsonb_build_object('Estabilizada', case when o.estabilizada then 'sim' when o.estabilizada = false then 'não' end, 'Obs.', nullif(o.obs, ''))) ex
      from "8 - coleta_campo".vrp_os o
      left join public.perfil p on p.id = o.executado_por
      left join sg_txt t on t.base = public.sigos_os_base(o.os_sigos)
      -- ponto do mapa = posição da VRP no cadastro técnico; o GPS do app (de quem concluiu a OS) só se a VRP não estiver no
      -- cadastro — 19 de 57 OS tinham o GPS a mais de 500 m da VRP (concluídas longe do campo), decisão do usuário 12/11/2026
      left join lateral (select st_asgeojson(st_transform(c.geom, 4326), 6)::jsonb g from "2 - infra_agua".vrps c
                          where c.num_vrp = o.num_vrp and c.geom is not null order by (c.consorcio = o.consorcio) desc, c.id limit 1) vc on true
     where o.status in ('concluida', 'concluida_pendencia', 'improdutiva') and o.executado_em is not null
  ),
  e_vrp_vis as (
    select (v.visitado_em at time zone 'America/Sao_Paulo')::date, v.consorcio, 'VRP', 'app:vrp_visita:' || v.id, 'AcquaHub',
           'Visita primária a VRP',
           coalesce(public.fisc_vrp(v.num_vrp), 'VRP —') || ' — ' || coalesce(v.situacao, 'visitada') || case when v.localizada = false then ' (não localizada)' else '' end,
           coalesce(public.fisc_vrp(v.num_vrp), v.cd_no_agua), p.nome, to_char(v.visitado_em at time zone 'America/Sao_Paulo', 'HH24:MI'),
           1::numeric, 'visita', null::text, null::text, null::text,
           public.fisc_fotos_json(v.fotos), coalesce(vc.g, public.fisc_pt(v.gps_lat, v.gps_lon)), '{}'::jsonb
      from "8 - coleta_campo".vrp_visita v left join public.perfil p on p.id = v.visitado_por
      left join lateral (select st_asgeojson(st_transform(c.geom, 4326), 6)::jsonb g from "2 - infra_agua".vrps c
                          where c.num_vrp = v.num_vrp and c.geom is not null order by (c.consorcio = v.consorcio) desc, c.id limit 1) vc on true
     where v.visitado_em is not null
  ),
  -- ---------------- Loggers (instalação / remoção) ----------------
  e_log as (
    select l.data_instalacao::date, l.consorcio, 'Loggers de pressão', 'app:logger:inst:' || l.id, 'AcquaHub',
           'Instalação de logger',
           'Logger ' || coalesce(l.numero_logger, '—') || ' instalado' || coalesce(' — HD ' || l.numero_hd, ''),
           coalesce('Zona ' || l.zone, l.label), l.usuario_instalacao, to_char(l.data_instalacao, 'HH24:MI'),
           1::numeric, 'un', null::text, l.os_copasa_instalacao,
           coalesce(t.txt, case when l.os_copasa_instalacao is null then 'sem OS SIGOS informada' else 'aguardando execução no SIGOS' end),
           array_remove(array[l.foto_cavalete_instalacao, l.foto_fachada, l.foto_hd_instalacao, l.foto_leitura_hd_instalacao, l.foto_numeracao_hd_instalacao, l.foto_extra], null),
           coalesce(public.fisc_pt(l.gps_lat_inst::float8, l.gps_lon_inst::float8), st_asgeojson(st_transform(l.geom, 4326), 6)::jsonb),
           jsonb_strip_nulls(jsonb_build_object('Leitura do HD', l.leitura_hd_instalacao, 'Obs.', nullif(l.observacao_instalacao, '')))
      from "8 - coleta_campo".instalacao_logger_calibracao l
      left join sg_txt t on t.base = public.sigos_os_base(l.os_copasa_instalacao)
     where l.data_instalacao is not null
    union all
    select l.data_remocao::date, l.consorcio, 'Loggers de pressão', 'app:logger:rem:' || l.id, 'AcquaHub',
           'Remoção de logger',
           'Logger ' || coalesce(l.numero_logger, '—') || ' removido' || coalesce(' — HD ' || l.numero_hd, ''),
           coalesce('Zona ' || l.zone, l.label), l.usuario_remocao, to_char(l.data_remocao, 'HH24:MI'),
           1::numeric, 'un', null::text, l.os_copasa_remocao,
           coalesce(t.txt, case when l.os_copasa_remocao is null then 'sem OS SIGOS informada' else 'aguardando execução no SIGOS' end),
           array_remove(array[l.foto_cavalete_remocao, l.foto_hd_remocao], null),
           coalesce(public.fisc_pt(l.gps_lat_rem::float8, l.gps_lon_rem::float8), st_asgeojson(st_transform(l.geom, 4326), 6)::jsonb),
           jsonb_strip_nulls(jsonb_build_object('Leitura do HD', l.leitura_hd_remocao, 'Obs.', nullif(l.observacao_remocao, '')))
      from "8 - coleta_campo".instalacao_logger_calibracao l
      left join sg_txt t on t.base = public.sigos_os_base(l.os_copasa_remocao)
     where l.data_remocao is not null
  ),
  -- ---------------- Mapeamento de pressão ----------------
  e_pres as (
    select m.data_hora::date, m.consorcio, 'Mapeamento de pressão', 'app:pressao:' || m.id, 'AcquaHub',
           'Leitura de pressão',
           'Pressão ' || coalesce(replace(round(m.pressao_mca, 1)::text, '.', ','), '—') || ' mca' || coalesce(' — HD ' || m.numero_hd, ''),
           null::text, m.usuario, to_char(m.data_hora, 'HH24:MI'),
           1::numeric, 'leitura', null::text, null::text, null::text,
           array_remove(array[m.foto, m.foto_hd], null), public.fisc_pt(m.gps_lat::float8, m.gps_lon::float8), '{}'::jsonb
      from "8 - coleta_campo".mapeamento_pressao m where m.data_hora is not null
  ),
  -- ---------------- Pesquisa: km de rede pesquisada por pesquisador × dia ----------------
  e_pq as (
    select (e.executado_em at time zone 'America/Sao_Paulo')::date d, r.consorcio z, e.colaborador_uuid u,
           sum(coalesce(e.comprimento_m, st_length(e.geom)::numeric)) m, count(*) n,
           min(e.executado_em) t0, max(e.executado_em) t1,
           st_asgeojson(st_transform(st_simplify(st_collect(e.geom), 1), 4326), 6)::jsonb g
      from "8 - coleta_campo".pp_execucao e
      join "2 - infra_agua".rede r on r.id = e.rede_id
     where e.executado_em is not null
       and (e.executado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
     group by 1, 2, 3
  ),
  e_pesq as (
    select q.d, q.z, 'Pesquisa de vazamento', 'app:pesquisa:' || coalesce(q.u::text, '-') || ':' || q.d, 'AcquaHub',
           'Rede pesquisada',
           replace(round(q.m / 1000.0, 2)::text, '.', ',') || ' km de rede pesquisados (' || q.n || ' trecho' || case when q.n = 1 then '' else 's' end || ')',
           null::text, p.nome,
           to_char(q.t0 at time zone 'America/Sao_Paulo', 'HH24:MI') || '–' || to_char(q.t1 at time zone 'America/Sao_Paulo', 'HH24:MI'),
           round(q.m / 1000.0, 3), 'km', null::text, null::text, null::text, '{}'::text[], q.g, '{}'::jsonb
      from e_pq q left join public.perfil p on p.id = q.u
  ),
  -- ---------------- Pavimento: só as OS SIGOS (entram em e_sig); nada do AcquaHub ----------------
  -- serviço de origem de cada OS SIGOS de recomposição (vai em extra._origem; fora do hash da linha)
  pav as (
    select s.numero, s.base, s.dt, coalesce(e.matricula, a.matricula) mat, coalesce(e.endereco, a.endereco) ender,
           nullif(trim(coalesce(e.os_origem, a.os_origem)), '') oo, coalesce(e.cod_os_origem, a.cod_os_origem) oc, coalesce(e.desc_os_origem, a.desc_os_origem) od
      from sgc s
      left join "17 - sigos".os_encerrada e on e.numero = s.numero
      left join "17 - sigos".os_aberta a on a.numero = s.numero and e.numero is null
     where s.fam = 'Recomposição de pavimento' and s.d between p_de and p_ate
  ),
  pav_app as (   -- registro da Gestão de Pavimento: OS da recomposição (pode ter "A, B") → OS de origem do campo
    select distinct public.sigos_os_base(trim(o)) b, nullif(trim(p.os_sigos), '') os, p.servico_origem srv
      from "8 - coleta_campo".pav_recomposicao p, regexp_split_to_table(coalesce(p.os_recomposicao, ''), '[,;/ ]+') o
     where trim(o) <> '' and nullif(trim(p.os_sigos), '') is not null
  ),
  pav_c as (
    select pav.numero, 1 pr, pav.oo os, pav.oc cod, pav.od dsc, null::text srv, 'SIGOS'::text fonte from pav where pav.oo is not null
    union all
    select pav.numero, 2, r.os, null, null, r.srv, 'AcquaHub' from pav join pav_app r on r.b = pav.base
    union all
    select pav.numero, 3, x.numero, x.cod_servico, x.desc_servico, null, 'provavel' from pav
      join lateral (select o.numero, o.cod_servico, o.desc_servico from "17 - sigos".os_encerrada o
                     where o.numero <> pav.numero and o.status = 'EXECUTADA'
                       and o.execucao <= pav.dt and o.execucao > pav.dt - interval '120 days'
                       and ((pav.mat is not null and pav.mat <> 0 and o.matricula = pav.mat) or (pav.ender is not null and o.endereco = pav.ender))
                       and public.fisc_familia(o.cod_servico, o.desc_servico, o.data_geracao) in ('Ramal predial', 'Correção de vazamento', 'Manobra de registro', 'VRP')
                     order by (o.matricula = pav.mat) desc, o.execucao desc limit 1) x on true
  ),
  pav_o as (
    select distinct on (c.numero) c.numero,
           jsonb_strip_nulls(jsonb_build_object(
             'os', c.os, 'fonte', c.fonte,
             'cod', coalesce(v.cod_servico, c.cod),
             'servico', coalesce(public.sigos_servico_nome(coalesce(v.desc_servico, c.dsc)),
                                 case c.srv when 'vazamento' then 'Correção de vazamento' when 'ramal' then 'Ramal predial'
                                            when 'fiscalizacao' then 'Fiscalização' when 'vrp' then 'VRP' when 'rede_vca' then 'Rede VCA'
                                            when 'rede_hdd' then 'Rede HDD' when 'dmc' then 'DMC' else c.srv end),
             'desc', coalesce(v.desc_servico, c.dsc),
             'familia', case when coalesce(v.desc_servico, c.dsc) is not null then public.fisc_familia(coalesce(v.cod_servico, c.cod), coalesce(v.desc_servico, c.dsc), v.abertura) end,
             'situacao', case v.situacao when 'executada' then 'executada' || coalesce(' em ' || to_char(v.data_execucao, 'DD/MM/YYYY'), '')
                                         when 'pendente' then 'em aberto no SIGOS' || coalesce(' (' || v.status_sigos || ')', '')
                                         when 'encerrada_sem_execucao' then 'encerrada sem execução' || coalesce(' (' || v.status_sigos || ')', '')
                                         else 'não encontrada no SIGOS' end,
             'resultado', nullif(v.resultado, ''))) j
      from pav_c c
      left join "17 - sigos".vw_os_situacao v on v.base = public.sigos_os_base(c.os)
     -- origem que aponta para outra OS de recomposição (registro do app com OS de origem = OS da recomposição) não vale → próxima fonte
     where coalesce(public.fisc_familia(coalesce(v.cod_servico, c.cod), coalesce(v.desc_servico, c.dsc), v.abertura), '') <> 'Recomposição de pavimento'
     order by c.numero, c.pr
  ),
  -- ---------------- SIGOS sem lançamento no app (entra pela data do SIGOS) ----------------
  oc as (   -- foto/local do vazamento localizado no app, só p/ a correção da MESMA OS
    select public.sigos_os_base(o.os_numero) b, min(o.foto) foto, min(o.local_ref) loc, min(o.lat) lat, min(o.lon) lon
      from "8 - coleta_campo".ocorrencia o where o.os_numero is not null group by 1
  ),
  e_sig as (
    select s.d, s.z, s.fam, 'sigos:' || s.numero, 'SIGOS',
           public.sigos_servico_nome(s.dsc),
           coalesce(s.cod, '—') || ' — ' || public.sigos_servico_curto(s.dsc)
             || case when s.sit <> 'executada' then ' (não executada com visita)' else '' end,
           coalesce(oc.loc, e.endereco, a.endereco), coalesce(e.equipe, a.equipe), to_char(coalesce(e.execucao, s.dt), 'HH24:MI'),
           1::numeric, 'OS', null::text, s.numero,
           case when s.sit = 'executada' then 'executada' else coalesce(s.st, 'encerrada') end,
           array_remove(array[oc.foto], null),
           coalesce(public.fisc_pt(coalesce(e.lat_imovel, e.lat_foto)::float8, coalesce(e.lon_imovel, e.lon_foto)::float8), public.fisc_pt(oc.lat, oc.lon)),
           jsonb_strip_nulls(jsonb_build_object('Matrícula', nullif(coalesce(e.matricula, a.matricula), 0), 'Resultado', nullif(s.resultado, ''), 'Status SIGOS', s.st))
             || case when po.j is not null then jsonb_build_object('_origem', po.j)
                     when s.fam = 'Recomposição de pavimento' then jsonb_build_object('_origem', jsonb_build_object('fonte', 'nenhuma'))
                     else '{}'::jsonb end
      from sgc s
      left join "17 - sigos".os_encerrada e on e.numero = s.numero
      left join "17 - sigos".os_aberta a on a.numero = s.numero and e.numero is null
      left join oc on s.fam = 'Correção de vazamento' and oc.b = s.base
      left join pav_o po on po.numero = s.numero
     where s.d between p_de and p_ate
       and s.fam <> 'Loggers de pressão'                                -- logger: só o registro do app
       and not exists (select 1 from app_os x where x.b = s.base)        -- já é atributo de uma execução do app
  ),
  todas as (
    select * from e_vrp_os union all select * from e_vrp_vis union all select * from e_log union all select * from e_pres
    union all select * from e_pesq union all select * from e_sig
  )
  select t.d, t.z, t.atv, public.fisc_ordem(t.atv), t.eid, t.ori, t.srv, t.dsc, t.loc, t.eq, t.hr, t.q, t.un, t.osa, t.oss, t.sst, t.ft, t.g, t.ex
    from todas t(d, z, atv, eid, ori, srv, dsc, loc, eq, hr, q, un, osa, oss, sst, ft, g, ex)
   where t.d between p_de and p_ate and t.z in ('ZA0200', 'ZA1004');
end $function$;
