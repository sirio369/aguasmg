-- =====================================================================================
-- Vínculo OS SIGOS × AcquaHub  (2026-11-09)
--
-- Liga todo campo "OS SIGOS" do app à base carregada dos relatórios SIGOS (schema 17)
-- e devolve a situação de cada OS: executada / encerrada sem execução / pendente /
-- aguardando relatório / suspeita de erro / formato inválido.
--
-- Regra de casamento: o número SIGOS tem 14 dígitos = '00' + BASE (10) + sufixo (2).
-- A base é única na base SIGOS (conferido em 09/11: 6.657 OS, nenhuma base repetida), então
-- casamos pela base — assim tanto "00127516560801" quanto "1275165608" acham a mesma OS.
--
-- Suspeita de erro: a Relação SUBSTITUI a carteira da ZA e as Encerradas ACUMULAM. Se, depois
-- do lançamento, chegou uma Relação nova E as Encerradas da ZA cobrem até ela, uma OS que não
-- aparece em nenhuma das duas não existe (digitação errada / ZA errada). Enquanto as cargas não
-- cobrem o lançamento, fica "aguardando relatório" (absorve o atraso dos relatórios).
--
-- Avanço automático (decisão do usuário 09/11): a única etapa "foi executada?" sem evidência
-- de campo é a execução da recomposição de pavimento. Quando a OS da recomposição aparece
-- EXECUTADA no SIGOS, a execução é marcada sozinha com a data do SIGOS (execucao_fonte='sigos').
-- VRP (checklist + fotos), Projetos (OS só fecha no fim do pipeline), APR, Suprimentos e
-- Pesquisa só mostram a situação e o alerta — não há etapa a avançar sem evidência de campo.
-- =====================================================================================

-- 1) Normalização ------------------------------------------------------------------------
create or replace function public.sigos_os_base(p text)
returns text language plpgsql immutable parallel safe set search_path to '' as $$
declare d text;
begin
  d := pg_catalog.ltrim(pg_catalog.regexp_replace(coalesce(p, ''), '\D', '', 'g'), '0');
  if pg_catalog.length(d) = 12 then return pg_catalog.left(d, 10); end if;
  if pg_catalog.length(d) = 10 then return d; end if;
  return null;   -- vazio ou formato inválido
end $$;
revoke all on function public.sigos_os_base(text) from public, anon;
grant execute on function public.sigos_os_base(text) to authenticated;

create index if not exists os_aberta_base_idx    on "17 - sigos".os_aberta    (public.sigos_os_base(numero));
create index if not exists os_encerrada_base_idx on "17 - sigos".os_encerrada (public.sigos_os_base(numero));

-- 2) Situação de cada OS na base SIGOS (uma linha por base; encerrada vence aberta) ----------
create or replace view "17 - sigos".vw_os_situacao with (security_invoker = true) as
select distinct on (base) *
from (
  select public.sigos_os_base(e.numero) as base, e.numero, e.consorcio,
         case when e.status = 'EXECUTADA' then 'executada' else 'encerrada_sem_execucao' end as situacao,
         e.status as status_sigos, e.cod_servico, e.desc_servico,
         e.data_geracao as abertura, e.execucao as data_execucao, e.resultado, 1 as prio
    from "17 - sigos".os_encerrada e
  union all
  select public.sigos_os_base(a.numero), a.numero, a.consorcio,
         case when a.status ilike 'EXECUTADA%' and a.enc_realizado is not null then 'executada' else 'pendente' end,
         a.status, a.cod_servico, a.desc_servico,
         a.abertura, case when a.status ilike 'EXECUTADA%' then a.enc_realizado end, null, 2
    from "17 - sigos".os_aberta a
) s
where base is not null
order by base, prio;

-- Cobertura das cargas por ZA: até quando a Relação e as Encerradas estão atualizadas
create or replace view "17 - sigos".vw_carga_cobertura with (security_invoker = true) as
select z.za,
       (select max(f.enviado_em) from "17 - sigos".arquivo f
         where f.slot_tipo = 'relacao' and f.slot_za = z.za and f.status = 'ok') as relacao_em,
       (select max(f.periodo_fim) from "17 - sigos".arquivo f
         where f.slot_tipo = 'encerradas' and f.slot_za = z.za and f.status = 'ok') as encerradas_ate,
       (select min(e.execucao)::date from "17 - sigos".os_encerrada e where e.consorcio = z.za) as encerradas_desde
from (values ('ZA0200'), ('ZA1004')) z(za);

-- 3) Campo de pavimento: de onde veio a execução ------------------------------------------------
alter table "8 - coleta_campo".pav_recomposicao add column if not exists execucao_fonte text;
comment on column "8 - coleta_campo".pav_recomposicao.execucao_fonte is
  'null/manual = marcada no app; sigos = marcada automaticamente pela carga SIGOS';

-- 4) Todos os campos de OS do app num lugar só -------------------------------------------------
create or replace view "17 - sigos".vw_os_vinculo with (security_invoker = true) as
with campos as (
  select 'pavimento'::text modulo, 'OS de origem'::text campo, r.id::text ref, r.grupo::text grupo,
         r.consorcio, r.os_sigos os_digitada, r.created_at lancado_em,
         coalesce(r.servico_origem, '') || ' · ' || coalesce(r.tipo_pavimento, '') contexto,
         null::text estado_app
    from "8 - coleta_campo".pav_recomposicao r where btrim(coalesce(r.os_sigos, '')) <> ''
  union all
  select 'pavimento', 'OS da recomposição', r.id::text, r.grupo::text, r.consorcio, r.os_recomposicao,
         coalesce(r.os_recomp_em, r.created_at), coalesce(r.tipo_pavimento, ''),
         case when r.execucao_data is not null then 'executada' end
    from "8 - coleta_campo".pav_recomposicao r where btrim(coalesce(r.os_recomposicao, '')) <> ''
  union all
  select 'projetos', 'OS SIGOS', e.kind || ':' || e.gid, null, iv.consorcio, e.valor,
         coalesce(e.status_em, e.atualizado_em), coalesce(iv.id, '') || ' · ' || coalesce(iv.tipo, ''),
         case when st.concluida_em is not null then 'concluida' end
    from "13 - projetos_obra".intervencao_etapa e
    left join "13 - projetos_obra".vw_iv iv on iv.kind = e.kind and iv.gid = e.gid
    left join "13 - projetos_obra".intervencao_estado st on st.kind = e.kind and st.gid = e.gid
   where e.chave = 'os_sigos' and btrim(coalesce(e.valor, '')) <> ''
  union all
  select 'vrp', 'OS SIGOS', o.id::text, null, o.consorcio, o.os_sigos, coalesce(o.aberto_em, o.created_at),
         coalesce(o.os_numero, '') || ' · VRP ' || coalesce(o.num_vrp, ''), o.status
    from "8 - coleta_campo".vrp_os o where btrim(coalesce(o.os_sigos, '')) <> ''
  union all
  select 'pesquisa', 'OS da ocorrência', c.id::text, null, c.consorcio, c.os_numero,
         coalesce(c.os_criada_em, c.created_at at time zone 'America/Sao_Paulo'), coalesce(c.tipo, ''), null
    from "8 - coleta_campo".ocorrencia c where btrim(coalesce(c.os_numero, '')) <> ''
  union all
  select 'abertura de serviço', 'OS', s.id::text, null, s.consorcio, s.os_numero, coalesce(s.os_criada_em, s.data_hora),
         coalesce(s.tipo_label, ''), null
    from "12 - retaguarda".abertura_servico s where btrim(coalesce(s.os_numero, '')) <> ''
  union all
  select 'relatório diário pesquisa', 'OS do dia', d.colaborador_uuid::text || ':' || d.dia, null, d.consorcio, d.os_sigos,
         coalesce(d.os_em, d.dia::timestamptz), d.dia::text, null
    from "12 - retaguarda".pesquisa_dia_os d where btrim(coalesce(d.os_sigos, '')) <> ''
  union all
  select 'apr', 'OS SIGOS', a.id::text, null, a.consorcio, a.os_sigos, coalesce(a.iniciada_em, a.created_at),
         coalesce(a.tipo_intervencao, '') || ' · ' || left(coalesce(a.descricao, ''), 80), null
    from "16 - qsms".qsms_atividade a where btrim(coalesce(a.os_sigos, '')) <> ''
  union all
  select 'inspeção sst', 'OS', i.id::text, null, i.consorcio, i.os, i.criado_em, coalesce(i.local, ''), null
    from "16 - qsms".sst_inspecao i where btrim(coalesce(i.os, '')) <> '' and i.anulado_em is null
  union all
  select 'suprimentos', 'OS do consumo', m.id::text, null, null, m.os, m.criado_em, null, null
    from "9 - suprimentos".sup_movimento m where btrim(coalesce(m.os, '')) <> ''
  union all
  select 'loggers', x.campo, l.id::text, null, l.consorcio, x.v, coalesce(l.created_at, l.data_instalacao::timestamptz),
         coalesce(l.numero_logger, ''), null
    from "8 - coleta_campo".instalacao_logger_calibracao l
    cross join lateral (values ('OS SIGOS', l.os_sigos), ('OS COPASA instalação', l.os_copasa_instalacao),
                               ('OS COPASA remoção', l.os_copasa_remocao), ('OS COPASA social', l.os_copasa_social)) x(campo, v)
   where btrim(coalesce(x.v, '')) <> ''
),
cob as (select * from "17 - sigos".vw_carga_cobertura),
j as (
  select c.*, public.sigos_os_base(c.os_digitada) base,
         s.numero numero_sigos, s.consorcio za_sigos, s.situacao sit, s.status_sigos, s.desc_servico,
         s.abertura abertura_sigos, s.data_execucao, s.resultado,
         -- cobertura: a da ZA do registro; sem ZA, a mais atrasada das duas (conservador)
         coalesce(cz.relacao_em, (select min(relacao_em) from cob)) relacao_em,
         coalesce(cz.encerradas_ate, (select min(encerradas_ate) from cob)) encerradas_ate,
         coalesce(cz.encerradas_desde, (select max(encerradas_desde) from cob)) encerradas_desde
    from campos c
    left join "17 - sigos".vw_os_situacao s on s.base = public.sigos_os_base(c.os_digitada)
    left join cob cz on cz.za = c.consorcio
)
select j.*,
  case
    when base is null then 'invalida'
    when sit is not null then sit
    when lancado_em::date < encerradas_desde then 'fora_janela'
    when relacao_em is not null and encerradas_ate is not null
         and (lancado_em + interval '2 days') < relacao_em
         and (relacao_em at time zone 'America/Sao_Paulo')::date <= encerradas_ate + 2 then 'suspeita'
    else 'aguardando'
  end as vinculo,
  case
    when modulo = 'pavimento' and campo = 'OS da recomposição' and estado_app = 'executada'
         and sit in ('pendente', 'encerrada_sem_execucao') then 'Executada no AcquaHub, mas o SIGOS diz: ' || status_sigos
    when modulo = 'projetos' and sit = 'executada' and estado_app is distinct from 'concluida'
         then 'SIGOS executou a OS antes do projeto concluir no AcquaHub'
    when modulo = 'vrp' and sit = 'executada' and coalesce(estado_app, '') not like 'concluida%'
         then 'SIGOS executou a OS, mas a OS da VRP não está concluída no AcquaHub'
  end as divergencia,
  ((now() at time zone 'America/Sao_Paulo')::date - (lancado_em at time zone 'America/Sao_Paulo')::date) as dias
from j;

-- 5) Avanço automático do pavimento ------------------------------------------------------------
create or replace function public.sigos_pav_auto()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  update "8 - coleta_campo".pav_recomposicao r
     set execucao_data  = (s.data_execucao)::date,
         execucao_em    = now(),
         execucao_por   = 'SIGOS (automático)',
         execucao_fonte = 'sigos'
    from "17 - sigos".vw_os_situacao s
   where r.execucao_data is null
     and r.os_recomposicao is not null
     and s.base = public.sigos_os_base(r.os_recomposicao)
     and s.situacao = 'executada'
     and s.data_execucao is not null
     and (s.data_execucao)::date >= (r.created_at at time zone 'America/Sao_Paulo')::date;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.sigos_pav_auto() from public, anon, authenticated;

-- dispara depois de cada carga (statement-level: uma vez por arquivo processado)
create or replace function "17 - sigos".tg_pos_carga()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.sigos_pav_auto(); return null; end $$;

drop trigger if exists pos_carga_pav on "17 - sigos".os_encerrada;
create trigger pos_carga_pav after insert on "17 - sigos".os_encerrada
  for each statement execute function "17 - sigos".tg_pos_carga();
drop trigger if exists pos_carga_pav on "17 - sigos".os_aberta;
create trigger pos_carga_pav after insert on "17 - sigos".os_aberta
  for each statement execute function "17 - sigos".tg_pos_carga();

-- e quando alguém lança a OS da recomposição de uma OS que o SIGOS já deu como executada
create or replace function "8 - coleta_campo".tg_pav_os_sigos()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_dt date;
begin
  if new.os_recomposicao is null or new.execucao_data is not null then return new; end if;
  select (s.data_execucao)::date into v_dt from "17 - sigos".vw_os_situacao s
   where s.base = public.sigos_os_base(new.os_recomposicao) and s.situacao = 'executada' and s.data_execucao is not null;
  if v_dt is not null and v_dt >= (new.created_at at time zone 'America/Sao_Paulo')::date then
    new.execucao_data := v_dt; new.execucao_em := now();
    new.execucao_por := 'SIGOS (automático)'; new.execucao_fonte := 'sigos';
  end if;
  return new;
end $$;
drop trigger if exists pav_os_sigos on "8 - coleta_campo".pav_recomposicao;
create trigger pav_os_sigos before update of os_recomposicao on "8 - coleta_campo".pav_recomposicao
  for each row when (new.os_recomposicao is distinct from old.os_recomposicao)
  execute function "8 - coleta_campo".tg_pav_os_sigos();

-- marcação manual volta a ser "manual" (app_pav_executar não conhece a coluna nova)
create or replace function "8 - coleta_campo".tg_pav_exec_manual()
returns trigger language plpgsql set search_path to '' as $$
begin
  if new.execucao_por is distinct from 'SIGOS (automático)' then new.execucao_fonte := null; end if;
  return new;
end $$;
drop trigger if exists pav_exec_manual on "8 - coleta_campo".pav_recomposicao;
create trigger pav_exec_manual before update of execucao_data on "8 - coleta_campo".pav_recomposicao
  for each row when (new.execucao_data is distinct from old.execucao_data)
  execute function "8 - coleta_campo".tg_pav_exec_manual();

-- 6) RPCs do app -------------------------------------------------------------------------------
-- Situação de uma lista de OS (selos nas telas e aviso ao digitar). Qualquer usuário ativo:
-- devolve só serviço/status/datas da OS, nada de cliente, endereço ou responsável.
create or replace function public.app_sigos_os_status(p_os text[])
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.perfil where id = auth.uid() and coalesce(ativo, true))
    then raise exception 'sem permissão'; end if;
  select jsonb_build_object(
    'cobertura', (select jsonb_object_agg(za, jsonb_build_object('relacao_em', relacao_em, 'encerradas_ate', encerradas_ate))
                    from "17 - sigos".vw_carga_cobertura),
    'os', coalesce(jsonb_object_agg(q.os, jsonb_build_object(
            'base', q.base,
            'sit', case when q.base is null then 'invalida' when s.base is null then 'nao_encontrada' else s.situacao end,
            'n', s.numero, 'za', s.consorcio, 'st', s.status_sigos, 'srv', s.desc_servico,
            'ab', s.abertura, 'ex', s.data_execucao, 'res', s.resultado)), '{}'::jsonb))
  into r
  from (select distinct btrim(x) os, public.sigos_os_base(x) base
          from unnest(coalesce(p_os, '{}')) x where btrim(coalesce(x, '')) <> '' limit 500) q
  left join "17 - sigos".vw_os_situacao s on s.base = q.base;
  return r;
end $$;
revoke all on function public.app_sigos_os_status(text[]) from public, anon;
grant execute on function public.app_sigos_os_status(text[]) to authenticated;

-- Painel de vínculos (Auxiliar de Programação)
create or replace function public.app_sigos_vinculos()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  select jsonb_build_object(
    'gerado_em', now(),
    'cobertura', (select jsonb_object_agg(za, jsonb_build_object('relacao_em', relacao_em,
                     'encerradas_ate', encerradas_ate, 'encerradas_desde', encerradas_desde))
                    from "17 - sigos".vw_carga_cobertura),
    'itens', coalesce(jsonb_agg(jsonb_build_object(
       'mod', modulo, 'campo', campo, 'ref', ref, 'grupo', grupo, 'za', consorcio, 'os', os_digitada,
       'base', base, 'em', lancado_em, 'ctx', contexto, 'app', estado_app,
       'n', numero_sigos, 'zas', za_sigos, 'st', status_sigos, 'srv', desc_servico,
       'ab', abertura_sigos, 'ex', data_execucao, 'res', resultado,
       'v', vinculo, 'div', divergencia, 'dias', dias
     ) order by lancado_em desc), '[]'::jsonb))
  into r from "17 - sigos".vw_os_vinculo;
  return r;
end $$;
revoke all on function public.app_sigos_vinculos() from public, anon;
grant execute on function public.app_sigos_vinculos() to authenticated;

-- BI (grupo de leitura do SIGOS já existente)
grant select on "17 - sigos".vw_os_situacao, "17 - sigos".vw_os_vinculo, "17 - sigos".vw_carga_cobertura to bi_sigos_leitura;

-- 7) Retroalimenta o que já está no banco -------------------------------------------------------
select public.sigos_pav_auto();
