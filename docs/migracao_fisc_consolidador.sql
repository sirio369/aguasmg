-- =====================================================================================================================
-- Consolidador para a Fiscalização COPASA (12/11/2026)
-- Tabela por dia × ZA: uma linha por atividade (com acumulado desde 01/09/2026) e, dentro dela, cada execução com
-- detalhe, fotos e localização. Obras (projetos) em andamento têm linha permanente com o % reconstruído dia a dia.
-- Validação: valida-se cada linha e depois o dia (snapshot congelado = o que a COPASA verá). Dado novo depois da
-- validação muda o hash → a linha volta a pendente e o dia fica "desatualizado".
--
-- Regras (decisões do usuário, 12/11/2026):
--  * 1 execução = 1 registro, na DATA DO CAMPO. A OS SIGOS casada (base de 10 dígitos) vira atributo da execução do
--    app; OS SIGOS sem lançamento no app entra pela data do SIGOS. Nada muda de dia depois.
--  * Loggers: o registro é o do app. OS SIGOS de logger só aparece como atributo (os_copasa_instalacao/remocao);
--    OS de logger sem vínculo NÃO vira linha (contaria 2×).
--  * Vazamento: "Pesquisa de vazamento" = rede pesquisada (km, pp_execucao) + detecção SIGOS 2487900;
--    "Correção de vazamento" = OS SIGOS COR.VAZ (2587901/04/05) EXECUTADAS. Vazamento localizado (ocorrência do app)
--    sem correção executada NUNCA aparece — a ocorrência só empresta foto/local à correção da mesma OS.
--  * Fora: pontos de pavimento levantados (pendência), atendimento comercial (solicitações/ocorrências), encerradas
--    sem execução que não contam (sigos_conta / regra do BI).
-- Leitura: sigos_pode_ver (admin ou aux_acesso). Validação: só admin.
-- =====================================================================================================================

-- ---------- ordem das atividades (estende rdo_familia_ordem sem mexer nela) ----------
create or replace function public.fisc_ordem(p_atividade text)
returns integer language sql immutable set search_path = public as $$
  select case p_atividade
    when 'Pesquisa de vazamento' then 10 when 'Correção de vazamento' then 12
    when 'Loggers de pressão' then 20 when 'Mapeamento de pressão' then 22
    else public.rdo_familia_ordem(p_atividade) end;
$$;

-- família p/ a fiscalização: a família SIGOS "Pesquisa de vazamento" mistura detecção e correção
create or replace function public.fisc_familia(p_cod text, p_desc text, p_abertura timestamp)
returns text language sql stable set search_path = public as $$
  select case when p_desc ilike '%COR.VAZ%' then 'Correção de vazamento'
              else public.sigos_familia(p_cod, p_desc, p_abertura) end;
$$;

-- caminhos das fotos (objeto jsonb {chave: caminho} ou array) → text[]
create or replace function public.fisc_fotos_json(p jsonb)
returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(v order by k), '{}')
    from (select key k, value v from jsonb_each_text(case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end)
          union all
          select lpad(ordinality::text, 4, '0'), value from jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality) t
   where v is not null and v <> '';
$$;

create or replace function public.fisc_vrp(p text)
returns text language sql immutable set search_path = public as $$
  select case when p is null or p = '' then null when p ~* '^\s*VRP' then btrim(p) else 'VRP ' || btrim(p) end;
$$;

create or replace function public.fisc_pt(p_lat double precision, p_lon double precision)
returns jsonb language sql immutable set search_path = public as $$
  select case when p_lat is null or p_lon is null or p_lat = 0 or p_lon = 0 then null
              else jsonb_build_object('type', 'Point', 'coordinates', jsonb_build_array(round(p_lon::numeric, 6), round(p_lat::numeric, 6))) end;
$$;

-- =====================================================================================================================
-- Feed por execução
-- =====================================================================================================================
create or replace function public.fisc_execucoes(p_de date, p_ate date)
returns table(dia date, za text, atividade text, ordem integer, exec_id text, origem text, servico text, descricao text,
              local text, equipe text, hora text, qtd numeric, unidade text, os_app text, os_sigos text, sigos_sit text,
              fotos text[], geo jsonb, extra jsonb)
language plpgsql stable security definer set search_path = public as $$
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
    union select public.sigos_os_base(r.os_recomposicao) from "8 - coleta_campo".pav_recomposicao r where r.execucao_data is not null
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
           public.fisc_fotos_json(o.fotos) ft, public.fisc_pt(o.gps_lat, o.gps_lon) g,
           jsonb_strip_nulls(jsonb_build_object('Estabilizada', case when o.estabilizada then 'sim' when o.estabilizada = false then 'não' end, 'Obs.', nullif(o.obs, ''))) ex
      from "8 - coleta_campo".vrp_os o
      left join public.perfil p on p.id = o.executado_por
      left join sg_txt t on t.base = public.sigos_os_base(o.os_sigos)
     where o.status in ('concluida', 'concluida_pendencia', 'improdutiva') and o.executado_em is not null
  ),
  e_vrp_vis as (
    select (v.visitado_em at time zone 'America/Sao_Paulo')::date, v.consorcio, 'VRP', 'app:vrp_visita:' || v.id, 'AcquaHub',
           'Visita primária a VRP',
           coalesce(public.fisc_vrp(v.num_vrp), 'VRP —') || ' — ' || coalesce(v.situacao, 'visitada') || case when v.localizada = false then ' (não localizada)' else '' end,
           coalesce(public.fisc_vrp(v.num_vrp), v.cd_no_agua), p.nome, to_char(v.visitado_em at time zone 'America/Sao_Paulo', 'HH24:MI'),
           1::numeric, 'visita', null::text, null::text, null::text,
           public.fisc_fotos_json(v.fotos), public.fisc_pt(v.gps_lat, v.gps_lon), '{}'::jsonb
      from "8 - coleta_campo".vrp_visita v left join public.perfil p on p.id = v.visitado_por
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
  -- ---------------- Pavimento: recomposição executada (1 por OS de recomposição) + ensaios ----------------
  pav as (
    select coalesce(public.sigos_os_base(r.os_recomposicao), r.id::text) k, min(r.execucao_data) d, min(r.consorcio) z,
           min(r.os_recomposicao) os, string_agg(distinct r.tipo_pavimento, ', ') tipos, string_agg(distinct r.servico_origem, ', ') orig,
           string_agg(distinct r.dimensao, ', ') dim, min(r.execucao_por) quem,
           array_remove(array_agg(r.foto1) || array_agg(r.foto2), null) ft,
           st_asgeojson(st_transform(st_centroid(st_collect(r.geom)), 4326), 6)::jsonb g
      from "8 - coleta_campo".pav_recomposicao r where r.execucao_data is not null group by 1
  ),
  e_pav as (
    select v.d, v.z, 'Recomposição de pavimento', 'app:pav:' || v.k, 'AcquaHub',
           'Recomposição de pavimento',
           'Recomposição — ' || coalesce(v.tipos, '—') || coalesce(' (' || v.dim || ')', ''),
           v.orig, v.quem, null::text, 1::numeric, 'OS', null::text, v.os,
           coalesce(t.txt, case when v.os is null then 'sem OS SIGOS informada' else 'aguardando execução no SIGOS' end),
           v.ft, v.g, '{}'::jsonb
      from pav v left join sg_txt t on t.base = public.sigos_os_base(v.os)
    union all
    select (e.created_at at time zone 'America/Sao_Paulo')::date, coalesce(r.consorcio, iv.consorcio), 'Recomposição de pavimento', 'app:ensaio:' || e.id, 'AcquaHub',
           'Ensaio de compactação do reaterro',
           'Ensaio ' || coalesce(e.resultado, '—') || coalesce(' — ' || e.metodo, '') || coalesce(' — GC ' || replace(e.gc_medido::text, '.', ',') || '%', ''),
           null::text, e.usuario_nome, to_char(e.created_at at time zone 'America/Sao_Paulo', 'HH24:MI'),
           1::numeric, 'ensaio', null::text, null::text, null::text,
           array_remove(array[e.foto1, e.foto2, e.laudo], null), public.fisc_pt(e.lat::float8, e.lon::float8), '{}'::jsonb
      from "8 - coleta_campo".pav_reaterro_ensaio e
      left join "8 - coleta_campo".pav_recomposicao r on r.id = e.pav_id
      left join "13 - projetos_obra".proj_reaterro pr on pr.id = e.proj_reaterro_id
      left join "13 - projetos_obra".vw_iv iv on iv.kind = pr.kind and iv.gid = pr.gid
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
      from sgc s
      left join "17 - sigos".os_encerrada e on e.numero = s.numero
      left join "17 - sigos".os_aberta a on a.numero = s.numero and e.numero is null
      left join oc on s.fam = 'Correção de vazamento' and oc.b = s.base
     where s.d between p_de and p_ate
       and s.fam <> 'Loggers de pressão'                                -- logger: só o registro do app
       and not exists (select 1 from app_os x where x.b = s.base)        -- já é atributo de uma execução do app
  ),
  todas as (
    select * from e_vrp_os union all select * from e_vrp_vis union all select * from e_log union all select * from e_pres
    union all select * from e_pesq union all select * from e_pav union all select * from e_sig
  )
  select t.d, t.z, t.atv, public.fisc_ordem(t.atv), t.eid, t.ori, t.srv, t.dsc, t.loc, t.eq, t.hr, t.q, t.un, t.osa, t.oss, t.sst, t.ft, t.g, t.ex
    from todas t(d, z, atv, eid, ori, srv, dsc, loc, eq, hr, q, un, osa, oss, sst, ft, g, ex)
   where t.d between p_de and p_ate and t.z in ('ZA0200', 'ZA1004');
end $$;
revoke all on function public.fisc_execucoes(date, date) from public, anon, authenticated;

-- =====================================================================================================================
-- Validação (tabelas)
-- =====================================================================================================================
create table if not exists "12 - retaguarda".fisc_linha_val (
  dia date not null, za text not null, chave text not null,
  status text not null check (status in ('validada', 'oculta')),
  hash text, obs text, por uuid, por_nome text, em timestamptz not null default now(),
  primary key (dia, za, chave));
create table if not exists "12 - retaguarda".fisc_exec_oculta (
  exec_id text primary key, motivo text, por uuid, por_nome text, em timestamptz not null default now());
create table if not exists "12 - retaguarda".fisc_dia (
  dia date not null, za text not null, validado_por uuid, validado_nome text, validado_em timestamptz not null default now(),
  hash text, snapshot jsonb, primary key (dia, za));
alter table "12 - retaguarda".fisc_linha_val enable row level security;
alter table "12 - retaguarda".fisc_exec_oculta enable row level security;
alter table "12 - retaguarda".fisc_dia enable row level security;
revoke all on "12 - retaguarda".fisc_linha_val, "12 - retaguarda".fisc_exec_oculta, "12 - retaguarda".fisc_dia from anon, authenticated;

create or replace function public.fisc_pode_validar(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_uid is not null and exists(select 1 from public.perfil where id = p_uid and coalesce(ativo, true) and funcao = 'admin');
$$;
revoke all on function public.fisc_pode_validar(uuid) from public, anon;

-- =====================================================================================================================
-- Obras (projetos): % reconstruído na data
-- =====================================================================================================================
-- tira de cada folha da árvore o que foi lançado DEPOIS da data (aj = {caminho: soma}) → árvore como estava no dia
create or replace function public.fisc_arv_ajusta(n jsonb, prefixo text, aj jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare cam text; f jsonb; out jsonb := '[]'::jsonb; d numeric;
begin
  if n is null or jsonb_typeof(n) <> 'object' then return n; end if;
  cam := case when prefixo is null then n->>'n' else prefixo || ' › ' || (n->>'n') end;
  d := coalesce((aj->>cam)::numeric, 0);
  if n->>'k' = '%' and d <> 0 then return jsonb_set(n, '{p}', to_jsonb(coalesce((n->>'p')::numeric, 0) - d));
  elsif n->>'k' = 'm' and d <> 0 then return jsonb_set(n, '{exec}', to_jsonb(coalesce((n->>'exec')::numeric, 0) - d));
  elsif n->>'k' = 'g' then
    for f in select value from jsonb_array_elements(coalesce(n->'f', '[]'::jsonb)) loop
      out := out || jsonb_build_array(public.fisc_arv_ajusta(f, cam, aj));
    end loop;
    return jsonb_set(n, '{f}', out);
  end if;
  return n;
end $$;

create or replace function public.fisc_proj_pct(p_kind text, p_gid bigint, p_dia date)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v_arv jsonb; v_aj jsonb; v_out jsonb := '[]'::jsonb; f jsonb;
begin
  select arv into v_arv from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  if v_arv is null or jsonb_typeof(v_arv) <> 'array' then return null; end if;
  select coalesce(jsonb_object_agg(caminho, s), '{}'::jsonb) into v_aj
    from (select a.caminho, sum(a.valor) s from "13 - projetos_obra".intervencao_avanco a
           where a.kind = p_kind and a.gid = p_gid and (a.ts at time zone 'America/Sao_Paulo')::date > p_dia group by 1) t;
  if v_aj = '{}'::jsonb then return "13 - projetos_obra".proj_arv_pct(v_arv); end if;
  for f in select value from jsonb_array_elements(v_arv) loop v_out := v_out || jsonb_build_array(public.fisc_arv_ajusta(f, null, v_aj)); end loop;
  return "13 - projetos_obra".proj_arv_pct(v_out);
end $$;
revoke all on function public.fisc_proj_pct(text, bigint, date) from public, anon, authenticated;

-- árvore achatada p/ o detalhe: uma linha por nó (nível, nome, tipo, valor acumulado, %); 'reg'/'sel' = informação
create or replace function public.fisc_arv_linhas(n jsonb, nivel integer)
returns jsonb language plpgsql immutable set search_path = public as $$
declare k text; out jsonb := '[]'::jsonb; f jsonb;
begin
  if n is null or jsonb_typeof(n) <> 'object' or n->>'ativo' = 'false' then return out; end if;
  k := n->>'k';
  if k = '%' then
    out := jsonb_build_array(jsonb_build_object('nivel', nivel, 'nome', n->>'n', 'k', k, 'pct', "13 - projetos_obra".proj_no_pct(n)));
  elsif k = 'm' then
    out := jsonb_build_array(jsonb_build_object('nivel', nivel, 'nome', n->>'n', 'k', k, 'exec', greatest(coalesce((n->>'exec')::numeric, 0), 0),
             'meta', (n->>'meta')::numeric, 'un', coalesce(n->>'un', 'm'), 'pct', "13 - projetos_obra".proj_no_pct(n)));
  elsif k in ('reg', 'sel') then
    if coalesce(n->>'v', '') not in ('', '—') then out := jsonb_build_array(jsonb_build_object('nivel', nivel, 'nome', n->>'n', 'k', k, 'v', n->>'v')); end if;
  elsif k = 'g' then
    out := jsonb_build_array(jsonb_build_object('nivel', nivel, 'nome', n->>'n', 'k', k, 'pct', "13 - projetos_obra".proj_no_pct(n)));
    for f in select value from jsonb_array_elements(coalesce(n->'f', '[]'::jsonb)) loop
      out := out || public.fisc_arv_linhas(f, nivel + 1);
    end loop;
  end if;
  return out;
end $$;

-- intervenções em andamento em cada dia do período (linha permanente até o dia da conclusão)
create or replace function public.fisc_projetos(p_de date, p_ate date, p_za text)
returns table(dia date, za text, chave text, kind text, gid bigint, codigo text, tipo text, local text, inicio date,
              pct numeric, pct_ant numeric, concluida boolean, avancos jsonb, fotos text[], geo jsonb, hash text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  return query
  with iv as (
    select e.kind, e.gid, e.concluida_em, v.id cod, v.tipo_origem, v.projeto,
           coalesce(v.consorcio, (select case a.consorcio when 'Águas Integradas' then 'ZA1004' when 'Eficiência Hídrica' then 'ZA0200' else a.consorcio end
                                    from "13 - projetos_obra".intervencao_avanco a where a.kind = e.kind and a.gid = e.gid limit 1)) z,
           least(coalesce((e.fase4_em at time zone 'America/Sao_Paulo')::date, '9999-12-31'),
                 coalesce((select min((a.ts at time zone 'America/Sao_Paulo')::date) from "13 - projetos_obra".intervencao_avanco a where a.kind = e.kind and a.gid = e.gid), '9999-12-31')) ini,
           (e.concluida_em at time zone 'America/Sao_Paulo')::date fim
      from "13 - projetos_obra".intervencao_estado e
      join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
     where e.status in ('run', 'done') or e.concluida_em is not null
  ),
  dd as (
    select d::date d, iv.* from iv, generate_series(greatest(p_de, iv.ini), least(p_ate, coalesce(iv.fim, p_ate)), interval '1 day') d
     where iv.ini <= p_ate and iv.z = p_za
  ),
  av as (
    select a.kind, a.gid, (a.ts at time zone 'America/Sao_Paulo')::date d,
           jsonb_agg(jsonb_build_object('id', a.id, 'item', a.caminho, 'valor', a.valor, 'un', a.unidade, 'obs', nullif(a.obs, ''),
                                        'hora', to_char(a.ts at time zone 'America/Sao_Paulo', 'HH24:MI'), 'por', a.autor_nome, 'equipe', a.equipe,
                                        'fotos', coalesce(to_jsonb(a.fotos), '[]'::jsonb)) order by a.ts) j,
           array_agg(a.id order by a.id) ids
      from "13 - projetos_obra".intervencao_avanco a
     where (a.ts at time zone 'America/Sao_Paulo')::date between p_de and p_ate
     group by a.kind, a.gid, 3
  ),
  avf as (
    select a.kind, a.gid, (a.ts at time zone 'America/Sao_Paulo')::date d, array_agg(f order by a.ts) ft
      from "13 - projetos_obra".intervencao_avanco a, unnest(a.fotos) f
     where (a.ts at time zone 'America/Sao_Paulo')::date between p_de and p_ate
     group by 1, 2, 3
  ),
  geo as (
    select 'ponto'::text kind, gid, st_asgeojson(st_transform(geom, 4326), 6)::jsonb g from "7 - setorizacao".intervencoes_pontuais
    union all select 'linha', gid, st_asgeojson(st_transform(st_simplify(geom, 0.5), 4326), 6)::jsonb from "7 - setorizacao".intervencoes_lineares
  ),
  -- o % só muda em dia com lançamento: calcula na véspera do período e em cada dia com avanço, e repete nos demais
  kd as (
    select distinct dd.kind, dd.gid, p_de - 1 d from dd
    union select av.kind, av.gid, av.d from av where exists (select 1 from dd where dd.kind = av.kind and dd.gid = av.gid)
  ),
  kp as (select kd.*, public.fisc_proj_pct(kd.kind, kd.gid, kd.d) p from kd),
  x as (
    select dd.*,
           (select kp.p from kp where kp.kind = dd.kind and kp.gid = dd.gid and kp.d <= dd.d order by kp.d desc limit 1) p,
           (select kp.p from kp where kp.kind = dd.kind and kp.gid = dd.gid and kp.d <= dd.d - 1 order by kp.d desc limit 1) p0,
           av.j, av.ids, avf.ft
      from dd left join av on av.kind = dd.kind and av.gid = dd.gid and av.d = dd.d
      left join avf on avf.kind = dd.kind and avf.gid = dd.gid and avf.d = dd.d
  )
  select x.d, x.z, 'proj:' || x.kind || ':' || x.gid, x.kind, x.gid, x.cod, x.tipo_origem, x.projeto, case when x.ini = '9999-12-31' then null else x.ini end,
         x.p, x.p0, coalesce(x.fim = x.d, false), coalesce(x.j, '[]'::jsonb), coalesce(x.ft, '{}'), g.g,
         md5(coalesce(x.p::text, '') || '|' || coalesce(array_to_string(x.ids, ','), '') || '|' || coalesce(x.fim = x.d, false)::text)
    from x left join geo g on g.kind = x.kind and g.gid = x.gid;
end $$;
revoke all on function public.fisc_projetos(date, date, text) from public, anon, authenticated;

-- =====================================================================================================================
-- Linhas por dia (atividade) com acumulado, execuções e hash
-- =====================================================================================================================
create or replace function public.fisc_linhas(p_de date, p_ate date, p_za text)
returns table(dia date, za text, chave text, atividade text, ordem integer, medidas jsonb, execs jsonb, n integer, hash text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  return query
  with e as (
    select x.* from public.fisc_execucoes(date '2026-09-01', p_ate) x
     where x.za = p_za and not exists (select 1 from "12 - retaguarda".fisc_exec_oculta o where o.exec_id = x.exec_id)
  ),
  m as (select e.dia, e.atividade, e.unidade, sum(e.qtd) q, count(*) c from e group by 1, 2, 3),
  ma as (select m.*, sum(m.q) over (partition by m.atividade, m.unidade order by m.dia) acum from m),
  med as (
    select ma.dia, ma.atividade, jsonb_agg(jsonb_build_object('un', ma.unidade, 'dia', ma.q, 'acum', ma.acum) order by ma.c desc, ma.unidade) j
      from ma where ma.dia between p_de and p_ate group by 1, 2
  ),
  ex as (
    select e.dia, e.atividade, min(e.ordem) ord, count(*)::int n,
           jsonb_agg(jsonb_build_object('id', e.exec_id, 'origem', e.origem, 'servico', e.servico, 'desc', e.descricao, 'local', e.local,
                                        'equipe', e.equipe, 'hora', e.hora, 'qtd', e.qtd, 'un', e.unidade, 'os_app', e.os_app, 'os_sigos', e.os_sigos,
                                        'sigos', e.sigos_sit, 'fotos', to_jsonb(e.fotos), 'geo', e.geo, 'extra', e.extra)
                     order by e.servico, e.hora nulls last, e.exec_id) j,
           md5(string_agg(e.exec_id || '|' || coalesce(e.descricao, '') || '|' || e.qtd || '|' || coalesce(e.sigos_sit, ''), '§' order by e.exec_id)) h
      from e where e.dia between p_de and p_ate group by 1, 2
  )
  select ex.dia, p_za, 'atv:' || ex.atividade, ex.atividade, ex.ord, med.j, ex.j, ex.n, ex.h
    from ex join med on med.dia = ex.dia and med.atividade = ex.atividade;
end $$;
revoke all on function public.fisc_linhas(date, date, text) from public, anon, authenticated;

-- dia × ZA completo (o que a tela mostra e o que vira snapshot)
create or replace function public.fisc_dia_dados(p_dia date, p_za text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_l jsonb; v_p jsonb; v_oc jsonb;
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
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from p.hash) end)
           order by p.codigo), '[]'::jsonb)
    into v_p
    from public.fisc_projetos(p_dia, p_dia, p_za) p
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = p.chave;
  return jsonb_build_object('dia', p_dia, 'za', p_za, 'linhas', v_l, 'projetos', v_p);
end $$;
revoke all on function public.fisc_dia_dados(date, text) from public, anon, authenticated;

-- hash do dia = hash de todas as linhas (atividades + obras)
create or replace function public.fisc_dia_hash(d jsonb)
returns text language sql immutable set search_path = public as $$
  select md5(coalesce((select string_agg(x->>'chave' || ':' || (x->>'hash'), '§' order by x->>'chave')
                         from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) x), ''));
$$;

-- =====================================================================================================================
-- RPCs
-- =====================================================================================================================
-- mês: por dia, nº de linhas e status (vazio / pendente / pronto / validado / desatualizado) + cobertura SIGOS
create or replace function public.app_fisc_mes(p_mes date, p_za text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_de date := greatest(date_trunc('month', p_mes)::date, date '2026-09-01'); v_ate date; r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  v_ate := least((date_trunc('month', p_mes) + interval '1 month - 1 day')::date, (now() at time zone 'America/Sao_Paulo')::date);
  if v_ate < v_de then return jsonb_build_object('za', p_za, 'dias', '[]'::jsonb); end if;
  with l as (select l.dia, l.chave, l.hash from public.fisc_linhas(v_de, v_ate, p_za) l
             union all select p.dia, p.chave, p.hash from public.fisc_projetos(v_de, v_ate, p_za) p),
  s as (select l.dia, count(*) n,
               count(*) filter (where v.chave is null or v.hash is distinct from l.hash) pend,
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
end $$;

create or replace function public.app_fisc_dia(p_dia date, p_za text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d jsonb; f record; c record; v_oc jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  d := public.fisc_dia_dados(p_dia, p_za);
  select * into f from "12 - retaguarda".fisc_dia where dia = p_dia and za = p_za;
  select * into c from "17 - sigos".vw_carga_cobertura where za = p_za;
  -- execuções ocultas do dia (p/ o admin poder reexibir)
  select coalesce(jsonb_agg(jsonb_build_object('id', o.exec_id, 'motivo', o.motivo, 'por', o.por_nome, 'em', o.em, 'atividade', x.atividade, 'desc', x.descricao)), '[]'::jsonb)
    into v_oc
    from "12 - retaguarda".fisc_exec_oculta o
    join public.fisc_execucoes(p_dia, p_dia) x on x.exec_id = o.exec_id and x.za = p_za;
  return d || jsonb_build_object(
    'ocultas', v_oc,
    'pode_validar', public.fisc_pode_validar(auth.uid()),
    'sigos', case when c.encerradas_desde is null or p_dia < c.encerradas_desde then 'sem_base'
                  when c.encerradas_ate is null or p_dia > c.encerradas_ate then 'aguardando' else 'ok' end,
    'cobertura', jsonb_build_object('encerradas_ate', c.encerradas_ate, 'encerradas_desde', c.encerradas_desde),
    'validado', case when f.dia is null then null else jsonb_build_object('por', f.validado_nome, 'em', f.validado_em,
                     'desatualizado', f.hash is distinct from public.fisc_dia_hash(d)) end);
end $$;

-- validar / ocultar uma linha (atividade ou obra) — grava o hash do momento
create or replace function public.app_fisc_linha_validar(p_dia date, p_za text, p_chave text, p_status text, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; v_hash text; v_nome text;
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "12 - retaguarda".fisc_dia where dia = p_dia and za = p_za) then raise exception 'dia já validado — reabra antes'; end if;
  if p_status is null then
    delete from "12 - retaguarda".fisc_linha_val where dia = p_dia and za = p_za and chave = p_chave;
    return jsonb_build_object('ok', true);
  end if;
  if p_status not in ('validada', 'oculta') then raise exception 'status inválido'; end if;
  if p_status = 'oculta' and coalesce(btrim(p_obs), '') = '' then raise exception 'informe o motivo para ocultar a linha'; end if;
  d := public.fisc_dia_dados(p_dia, p_za);
  select x->>'hash' into v_hash from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) x where x->>'chave' = p_chave;
  if v_hash is null then raise exception 'linha não encontrada neste dia'; end if;
  select nome into v_nome from public.perfil where id = auth.uid();
  insert into "12 - retaguarda".fisc_linha_val(dia, za, chave, status, hash, obs, por, por_nome, em)
  values (p_dia, p_za, p_chave, p_status, v_hash, nullif(btrim(p_obs), ''), auth.uid(), v_nome, now())
  on conflict (dia, za, chave) do update set status = excluded.status, hash = excluded.hash, obs = excluded.obs,
    por = excluded.por, por_nome = excluded.por_nome, em = excluded.em;
  return jsonb_build_object('ok', true);
end $$;

-- validar todas as linhas pendentes do dia de uma vez
create or replace function public.app_fisc_linhas_validar_todas(p_dia date, p_za text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; v_nome text; n int;
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "12 - retaguarda".fisc_dia where dia = p_dia and za = p_za) then raise exception 'dia já validado — reabra antes'; end if;
  d := public.fisc_dia_dados(p_dia, p_za);
  select nome into v_nome from public.perfil where id = auth.uid();
  with x as (select y->>'chave' chave, y->>'hash' hash, y->'val' val from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) y)
  insert into "12 - retaguarda".fisc_linha_val(dia, za, chave, status, hash, por, por_nome, em)
  select p_dia, p_za, x.chave, 'validada', x.hash, auth.uid(), v_nome, now() from x
   where x.val is null or jsonb_typeof(x.val) = 'null' or (x.val->>'ok')::boolean is not true
  on conflict (dia, za, chave) do update set status = case when "12 - retaguarda".fisc_linha_val.status = 'oculta' then 'oculta' else 'validada' end,
    hash = excluded.hash, por = excluded.por, por_nome = excluded.por_nome, em = excluded.em;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'n', n);
end $$;

-- ocultar / reexibir uma execução (registro de teste ou errado)
create or replace function public.app_fisc_exec_ocultar(p_exec_id text, p_motivo text, p_ocultar boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nome text;
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  if not p_ocultar then delete from "12 - retaguarda".fisc_exec_oculta where exec_id = p_exec_id; return jsonb_build_object('ok', true); end if;
  if coalesce(btrim(p_motivo), '') = '' then raise exception 'informe o motivo'; end if;
  select nome into v_nome from public.perfil where id = auth.uid();
  insert into "12 - retaguarda".fisc_exec_oculta(exec_id, motivo, por, por_nome) values (p_exec_id, btrim(p_motivo), auth.uid(), v_nome)
  on conflict (exec_id) do update set motivo = excluded.motivo, por = excluded.por, por_nome = excluded.por_nome, em = now();
  return jsonb_build_object('ok', true);
end $$;

-- validar o dia: todas as linhas validadas/ocultas com hash em dia; SIGOS precisa cobrir o dia
create or replace function public.app_fisc_dia_validar(p_dia date, p_za text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; c record; v_pend int; v_nome text; v_snap jsonb;
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "17 - sigos".vw_carga_cobertura where za = p_za;
  if c.encerradas_ate is null or p_dia > c.encerradas_ate then raise exception 'o SIGOS ainda não cobre este dia — aguarde a próxima carga'; end if;
  d := public.fisc_dia_dados(p_dia, p_za);
  select count(*) into v_pend from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) x
   where x->'val' is null or jsonb_typeof(x->'val') = 'null' or (x->'val'->>'ok')::boolean is not true;
  if v_pend > 0 then raise exception '% linha(s) ainda sem validar', v_pend; end if;
  select nome into v_nome from public.perfil where id = auth.uid();
  -- snapshot = só o que a fiscalização verá: linhas validadas (ocultas saem) e sem a marcação interna
  v_snap := jsonb_build_object('dia', p_dia, 'za', p_za,
    'linhas', coalesce((select jsonb_agg(x - 'val' - 'hash') from jsonb_array_elements(d->'linhas') x where x->'val'->>'status' = 'validada'), '[]'::jsonb),
    'projetos', coalesce((select jsonb_agg(x - 'val' - 'hash') from jsonb_array_elements(d->'projetos') x where x->'val'->>'status' = 'validada'), '[]'::jsonb));
  insert into "12 - retaguarda".fisc_dia(dia, za, validado_por, validado_nome, validado_em, hash, snapshot)
  values (p_dia, p_za, auth.uid(), v_nome, now(), public.fisc_dia_hash(d), v_snap)
  on conflict (dia, za) do update set validado_por = excluded.validado_por, validado_nome = excluded.validado_nome,
    validado_em = excluded.validado_em, hash = excluded.hash, snapshot = excluded.snapshot;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.app_fisc_dia_reabrir(p_dia date, p_za text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  delete from "12 - retaguarda".fisc_dia where dia = p_dia and za = p_za;
  return jsonb_build_object('ok', true);
end $$;

-- Excel: período × ZA — dia validado sai do snapshot; os demais, do vivo (com status)
create or replace function public.app_fisc_periodo(p_de date, p_ate date, p_za text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  if p_ate - p_de > 92 then raise exception 'período máximo de 3 meses'; end if;
  with l as (select * from public.fisc_linhas(p_de, p_ate, p_za)),
       p as (select * from public.fisc_projetos(p_de, p_ate, p_za)),
       dias as (select distinct dia from l union select distinct dia from p),
       vivo as (
         select dd.dia, jsonb_build_object(
           'linhas', coalesce((select jsonb_agg(jsonb_build_object('chave', l.chave, 'atividade', l.atividade, 'ordem', l.ordem, 'medidas', l.medidas, 'execs', l.execs, 'n', l.n,
                              'status', case when v.chave is null or v.hash is distinct from l.hash then 'pendente' else v.status end) order by l.ordem, l.atividade)
                               from l left join "12 - retaguarda".fisc_linha_val v on v.dia = l.dia and v.za = p_za and v.chave = l.chave where l.dia = dd.dia), '[]'::jsonb),
           'projetos', coalesce((select jsonb_agg(jsonb_build_object('chave', p.chave, 'codigo', p.codigo, 'tipo', p.tipo, 'local', p.local, 'inicio', p.inicio, 'pct', p.pct, 'pct_ant', p.pct_ant,
                              'concluida', p.concluida, 'avancos', p.avancos,
                              'status', case when v.chave is null or v.hash is distinct from p.hash then 'pendente' else v.status end) order by p.codigo)
                               from p left join "12 - retaguarda".fisc_linha_val v on v.dia = p.dia and v.za = p_za and v.chave = p.chave where p.dia = dd.dia), '[]'::jsonb)) j
           from dias dd)
  select coalesce(jsonb_agg(case when f.dia is not null then f.snapshot || jsonb_build_object('validado', true, 'validado_por', f.validado_nome, 'validado_em', f.validado_em)
                                 else vivo.j || jsonb_build_object('dia', vivo.dia, 'za', p_za, 'validado', false) end order by vivo.dia), '[]'::jsonb)
    into r
    from vivo left join "12 - retaguarda".fisc_dia f on f.dia = vivo.dia and f.za = p_za;
  return r;
end $$;

revoke all on function public.app_fisc_mes(date, text), public.app_fisc_dia(date, text),
  public.app_fisc_linha_validar(date, text, text, text, text), public.app_fisc_linhas_validar_todas(date, text),
  public.app_fisc_exec_ocultar(text, text, boolean), public.app_fisc_dia_validar(date, text), public.app_fisc_dia_reabrir(date, text),
  public.app_fisc_periodo(date, date, text) from public, anon;
grant execute on function public.app_fisc_mes(date, text), public.app_fisc_dia(date, text),
  public.app_fisc_linha_validar(date, text, text, text, text), public.app_fisc_linhas_validar_todas(date, text),
  public.app_fisc_exec_ocultar(text, text, boolean), public.app_fisc_dia_validar(date, text), public.app_fisc_dia_reabrir(date, text),
  public.app_fisc_periodo(date, date, text) to authenticated;

-- detalhe acumulado de uma obra NA DATA: árvore como estava no fim do dia, SÓ os anexos já feitos até o dia
-- (documentos + links informados; o que falta não aparece),
-- todos os avanços até o dia (com fotos)
create or replace function public.app_fisc_proj_detalhe(p_kind text, p_gid bigint, p_dia date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_arv jsonb; v_aj jsonb; v_adj jsonb := '[]'::jsonb; f jsonb; v_tipo text; v_lin jsonb := '[]'::jsonb; v_fim timestamptz;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  v_fim := ((p_dia + 1)::timestamp at time zone 'America/Sao_Paulo');
  select e.arv, v.tipo into v_arv, v_tipo
    from "13 - projetos_obra".intervencao_estado e join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
   where e.kind = p_kind and e.gid = p_gid;
  if jsonb_typeof(v_arv) = 'array' then
    select coalesce(jsonb_object_agg(caminho, s), '{}'::jsonb) into v_aj
      from (select a.caminho, sum(a.valor) s from "13 - projetos_obra".intervencao_avanco a
             where a.kind = p_kind and a.gid = p_gid and a.ts >= v_fim group by 1) t;
    for f in select value from jsonb_array_elements(v_arv) loop
      f := public.fisc_arv_ajusta(f, null, v_aj); v_adj := v_adj || jsonb_build_array(f);
      v_lin := v_lin || public.fisc_arv_linhas(f, 0);
    end loop;
  end if;
  return jsonb_build_object(
    'pct', case when jsonb_typeof(v_arv) = 'array' then "13 - projetos_obra".proj_arv_pct(v_adj) end,
    'arvore', v_lin,
    'anexos', coalesce((
      select jsonb_agg(x.j order by x.fase nulls last, x.ordem nulls last, x.em) from (
        select m.fase, m.ordem, d.atualizado_em em,
               jsonb_build_object('fase', m.fase, 'nome', coalesce(m.nome, d.tipo), 'arquivo', d.nome, 'path', d.path, 'folha', d.folha,
                                  'em', d.atualizado_em, 'por', case when e2.status_em < v_fim then e2.por_nome end) j
          from "13 - projetos_obra".intervencao_documento d
          left join "13 - projetos_obra".etapa_modelo m on m.tipo = v_tipo and m.chave = d.tipo
          left join "13 - projetos_obra".intervencao_etapa e2 on e2.kind = d.kind and e2.gid = d.gid and e2.chave = d.tipo
         where d.kind = p_kind and d.gid = p_gid and d.path is not null and d.atualizado_em < v_fim
        union all
        select m.fase, m.ordem, e.status_em,
               jsonb_build_object('fase', m.fase, 'nome', m.nome, 'link', e.valor, 'em', e.status_em, 'por', e.por_nome)
          from "13 - projetos_obra".intervencao_etapa e
          join "13 - projetos_obra".etapa_modelo m on m.tipo = v_tipo and m.chave = e.chave
         where e.kind = p_kind and e.gid = p_gid and e.status_em < v_fim and e.valor ~* '^https?://') x), '[]'::jsonb),
    'avancos', coalesce((
      select jsonb_agg(jsonb_build_object('dia', (a.ts at time zone 'America/Sao_Paulo')::date, 'hora', to_char(a.ts at time zone 'America/Sao_Paulo', 'HH24:MI'),
               'item', a.caminho, 'valor', a.valor, 'un', a.unidade, 'obs', nullif(a.obs, ''), 'por', a.autor_nome, 'equipe', a.equipe,
               'fotos', coalesce(to_jsonb(a.fotos), '[]'::jsonb)) order by a.ts desc)
        from "13 - projetos_obra".intervencao_avanco a where a.kind = p_kind and a.gid = p_gid and a.ts < v_fim), '[]'::jsonb));
end $$;
revoke all on function public.app_fisc_proj_detalhe(text, bigint, date) from public, anon;
grant execute on function public.app_fisc_proj_detalhe(text, bigint, date) to authenticated;
