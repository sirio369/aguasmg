-- BI de Pessoas (Headcount) dentro do AcquaHub (Gestão de Pessoas) + cargas dos arquivos de apoio (2026-11-19)
-- Substitui o Power BI "Headcount" (páginas Visão Geral, Pessoas e Rotatividade; o Ponto já tem as telas do RH no app). Fontes (3 arquivos Excel):
--   • Base_Contratados.xlsx ...... aba CONTRATADOS (um registro por colaborador CLT/PJ; DEMISSÃO + STATUS quando sair);
--   • Base_Orcamento.xlsx ........ aba ORÇAMENTO (headcount planejado por posição × mês, jul/26 a jun/31);
--   • De_Para_Cargo_Area.xlsx .... aba DE_PARA (ÁREA + FUNÇÃO da folha → CARGO ORÇAMENTO).
-- CPF, matrícula e data de nascimento NÃO são gravados (o BI não usa). Regra da usuária: cada arquivo novo SUBSTITUI o anterior do mesmo tipo.
-- Regras de transformação do Power Query (de-para de cargo, mapa de cargos da folha → Orçamento Aprovado, motoristas, MENOR APRENDIZ fora,
-- Analista de RH só em Águas Integradas, Contagem/Betim → empresa, "Ambos" = posição comum) rodam na consulta (app_pes_bi), não na carga.
-- Fluxo: app_pes_carga_iniciar → app_pes_carga_lote (por tabela) → app_pes_carga_finalizar | app_pes_carga_falha.

alter table public.perfil add column if not exists pes_bi_acesso boolean not null default false;     -- vê a Gestão de Pessoas
alter table public.perfil add column if not exists pes_carga_acesso boolean not null default false;  -- sobe os arquivos

create or replace function "18 - rh".pes_bi_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo and (p.funcao = 'admin' or p.pes_bi_acesso or p.pes_carga_acesso))
$$;
create or replace function "18 - rh".pes_carga_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo and (p.funcao = 'admin' or p.pes_carga_acesso))
$$;
create or replace function "18 - rh".pes_bi_hoje() returns date language sql stable as $$
  select coalesce(nullif(current_setting('app.pes_hoje', true), '')::date, (now() at time zone 'America/Sao_Paulo')::date)
$$;

-- ───────────── tabelas (app-only) ─────────────
create table if not exists "18 - rh".pes_bi_carga (
  id bigserial primary key,
  tipo text not null check (tipo in ('contratados','orcamento','depara')),
  nome_original text, sha256 text, linhas int,
  status text not null default 'pendente' check (status in ('pendente','ok','erro')),
  ativa boolean not null default false, aviso text, erro text,
  enviado_por uuid default auth.uid(), enviado_em timestamptz not null default now(), concluido_em timestamptz
);
create table if not exists "18 - rh".pes_bi_contratado (carga_id bigint not null references "18 - rh".pes_bi_carga(id) on delete cascade,
  cod_area text, area text, funcao text, colaborador text, modalidade text, admissao date, demissao date, genero text, status text,
  projeto text, frente text, cargo_orc text);
create table if not exists "18 - rh".pes_bi_orcamento (carga_id bigint not null references "18 - rh".pes_bi_carga(id) on delete cascade,
  cod_area text, area text, funcao text, projeto text, mes date, headcount numeric);
create table if not exists "18 - rh".pes_bi_depara (carga_id bigint not null references "18 - rh".pes_bi_carga(id) on delete cascade,
  area text, funcao_folha text, cargo_orc text, observacao text);
create index if not exists pes_bi_contratado_c on "18 - rh".pes_bi_contratado (carga_id);
create index if not exists pes_bi_orcamento_c on "18 - rh".pes_bi_orcamento (carga_id);
create index if not exists pes_bi_depara_c on "18 - rh".pes_bi_depara (carga_id);
alter table "18 - rh".pes_bi_carga enable row level security;
alter table "18 - rh".pes_bi_contratado enable row level security;
alter table "18 - rh".pes_bi_orcamento enable row level security;
alter table "18 - rh".pes_bi_depara enable row level security;

-- ───────────── carga ─────────────
create or replace function public.app_pes_carga_iniciar(p_tipo text, p_nome text, p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_aviso text; v_ant timestamptz;
begin
  if not "18 - rh".pes_carga_pode(auth.uid()) then raise exception 'sem permissão para carregar arquivos de Pessoas'; end if;
  if p_tipo not in ('contratados','orcamento','depara') then raise exception 'tipo de arquivo inválido'; end if;
  select max(concluido_em) into v_ant from "18 - rh".pes_bi_carga where tipo = p_tipo and status = 'ok' and sha256 is not null and sha256 = p_sha256;
  if v_ant is not null then v_aviso := 'idêntico ao já enviado em ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'); end if;
  insert into "18 - rh".pes_bi_carga (tipo, nome_original, sha256, aviso) values (p_tipo, left(p_nome, 300), p_sha256, v_aviso) returning id into v_id;
  return jsonb_build_object('carga_id', v_id, 'aviso', v_aviso);
end $$;

-- p_tabela: contratado | orcamento | depara
create or replace function public.app_pes_carga_lote(p_carga bigint, p_tabela text, p_linhas jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare c "18 - rh".pes_bi_carga; n int;
begin
  if not "18 - rh".pes_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "18 - rh".pes_bi_carga where id = p_carga and status = 'pendente';
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'lote inválido'; end if;
  if not ((c.tipo = 'contratados' and p_tabela = 'contratado') or (c.tipo = 'orcamento' and p_tabela = 'orcamento') or (c.tipo = 'depara' and p_tabela = 'depara')) then
    raise exception 'tabela % não pertence a esse tipo de carga', p_tabela; end if;
  if p_tabela = 'contratado' then
    insert into "18 - rh".pes_bi_contratado select p_carga, x.cod_area, x.area, x.funcao, x.colaborador, x.modalidade, x.admissao, x.demissao, x.genero, x.status, x.projeto, x.frente, x.cargo_orc
      from jsonb_to_recordset(p_linhas) as x(cod_area text, area text, funcao text, colaborador text, modalidade text, admissao date, demissao date, genero text, status text, projeto text, frente text, cargo_orc text);
  elsif p_tabela = 'orcamento' then
    insert into "18 - rh".pes_bi_orcamento select p_carga, x.cod_area, x.area, x.funcao, x.projeto, x.mes, x.headcount
      from jsonb_to_recordset(p_linhas) as x(cod_area text, area text, funcao text, projeto text, mes date, headcount numeric);
  else
    insert into "18 - rh".pes_bi_depara select p_carga, x.area, x.funcao_folha, x.cargo_orc, x.observacao
      from jsonb_to_recordset(p_linhas) as x(area text, funcao_folha text, cargo_orc text, observacao text);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- troca de uma vez: o novo vale só se chegou inteiro; o anterior do mesmo tipo sai
create or replace function public.app_pes_carga_finalizar(p_carga bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c "18 - rh".pes_bi_carga; n int;
begin
  if not "18 - rh".pes_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "18 - rh".pes_bi_carga where id = p_carga and status = 'pendente' for update;
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if c.tipo = 'contratados' then select count(*) into n from "18 - rh".pes_bi_contratado where carga_id = p_carga;
  elsif c.tipo = 'orcamento' then select count(*) into n from "18 - rh".pes_bi_orcamento where carga_id = p_carga;
  else select count(*) into n from "18 - rh".pes_bi_depara where carga_id = p_carga; end if;
  if coalesce(n, 0) = 0 then
    update "18 - rh".pes_bi_carga set status = 'erro', erro = 'nenhuma linha válida no arquivo', concluido_em = now() where id = p_carga;
    raise exception 'nenhuma linha válida no arquivo — nada foi alterado';
  end if;
  update "18 - rh".pes_bi_carga set ativa = false where tipo = c.tipo and ativa;
  delete from "18 - rh".pes_bi_contratado where carga_id in (select id from "18 - rh".pes_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "18 - rh".pes_bi_orcamento where carga_id in (select id from "18 - rh".pes_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "18 - rh".pes_bi_depara where carga_id in (select id from "18 - rh".pes_bi_carga where tipo = c.tipo and id <> p_carga);
  update "18 - rh".pes_bi_carga set status = 'ok', ativa = true, linhas = n, concluido_em = now() where id = p_carga;
  return jsonb_build_object('carga_id', p_carga, 'tipo', c.tipo, 'linhas', n, 'aviso', c.aviso);
end $$;

create or replace function public.app_pes_carga_falha(p_carga bigint, p_erro text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not "18 - rh".pes_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  update "18 - rh".pes_bi_carga set status = 'erro', erro = left(p_erro, 500), concluido_em = now() where id = p_carga and status = 'pendente';
  delete from "18 - rh".pes_bi_contratado where carga_id = p_carga; delete from "18 - rh".pes_bi_orcamento where carga_id = p_carga;
  delete from "18 - rh".pes_bi_depara where carga_id = p_carga;
end $$;

create or replace function public.app_pes_cargas_listar(p_limite int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "18 - rh".pes_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object('pode_carregar', "18 - rh".pes_carga_pode(auth.uid()),
    'ativas', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'tipo', k.tipo, 'nome', k.nome_original, 'linhas', k.linhas, 'em', k.concluido_em) order by k.tipo)
        from "18 - rh".pes_bi_carga k where k.ativa), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(to_jsonb(h) order by h.enviado_em desc) from (
        select k.id, k.tipo, k.nome_original as nome, k.linhas, k.status, k.aviso, k.erro, k.enviado_em, (select nome from public.perfil p where p.id = k.enviado_por) as por
        from "18 - rh".pes_bi_carga k order by k.enviado_em desc limit greatest(p_limite, 1)) h), '[]'::jsonb));
end $$;

-- ───────────── BI: contratados já com o CARGO ORÇAMENTO final ─────────────
-- 1) de-para por ÁREA + FUNÇÃO (arquivo De_Para_Cargo_Area): onde houver par, vale o dele; senão o cargo da base;
-- 2) cargos da folha → nomes do Orçamento Aprovado (de-para confirmado em 17/11/2026);
-- 3) motoristas (18/11/2026): Recadastramento (04.002.001) → MOTORISTA I; demais áreas de campo → AJUDANTE DE SANEAMENTO (áreas 01.* e sem área ficam).
create or replace function "18 - rh".pes_cargo_final(p_cod text, p_cargo_dp text) returns text language sql immutable as $$
  with m as (select case p_cargo_dp
      when 'ENCANADOR' then 'ENCANADOR I' when 'PEDREIRO' then 'PEDREIRO I' when 'INSPETOR DE SANEAMENTO' then 'INSPETOR DE SANEAMENTO II'
      when 'ASSISTENTE SOCIAL' then 'ASSISTENTE SOCIAL - PL' when 'AGENTE DE ATENDIMENTO AO CLIENTE' then 'AJUDANTE GERAL'
      when 'GESTOR DE CONTRATO' then 'ENGENHEIRO SENIOR - GESTOR DE CONTRATO' when 'COORDENADOR DE PROJETOS' then 'ENGENHEIRO PLENO - COORDENADOR DE PROJETO'
      when 'COORDENADOR DE PLANEJAMENTO' then 'ENGENHEIRO PLENO - COORDENADOR DE PLANEJAMENTO' when 'SUPERVISOR DE PLANEJAMENTO' then 'SUPERVISOR DE PRODUCAO SENIOR'
      when 'GESTOR DE OBRAS' then 'ENGENHEIRO SENIOR - GESTOR DE OBRAS' when 'ENGENHEIRO DE PRODUÇÃO' then 'ENGENHEIRO DE PRODUÇÃO JUNIOR'
      when 'SUPERVISOR DE PRODUCAO' then 'SUPERVISOR DE PRODUCAO SENIOR' when 'COORDENADOR DE SGI' then 'ENGENHEIRO JUNIOR - COORDENADOR DE QSMSS'
      when 'TECNICO DE SEGURANÇA DO TRABALHO' then 'TECNICO DE SEGURANÇA DO TRABALHO I ou II' else p_cargo_dp end as c)
  select case when c in ('MOTORISTA', 'MOTORISTA CAMINHÃO', 'MOTORISTA RETROESCAVADADEIRA')
              then (case when p_cod is null then c when p_cod = '04.002.001' then 'MOTORISTA I' when p_cod like '01.%' then c else 'AJUDANTE DE SANEAMENTO' end)
              else c end from m
$$;

create or replace function public.app_pes_bi()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "18 - rh".pes_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'hoje', "18 - rh".pes_bi_hoje(),
    'contratados', coalesce((
      select jsonb_agg(jsonb_build_object('n', c.colaborador, 'ca', c.cod_area, 'a', c.area, 'f', c.funcao, 'g', c.genero, 's', c.status, 'p', c.projeto, 'mo', c.modalidade,
          'ad', c.admissao, 'de', c.demissao, 'e', upper(c.frente), 'cg', "18 - rh".pes_cargo_final(c.cod_area, coalesce(d.cargo_orc, c.cargo_orc))))
      from "18 - rh".pes_bi_contratado c join "18 - rh".pes_bi_carga k on k.id = c.carga_id and k.ativa and k.tipo = 'contratados'
      left join lateral (select dp.cargo_orc from "18 - rh".pes_bi_depara dp join "18 - rh".pes_bi_carga kd on kd.id = dp.carga_id and kd.ativa
                          where dp.area = c.area and dp.funcao_folha = c.funcao order by dp.cargo_orc limit 1) d on true
      where c.colaborador is not null), '[]'::jsonb),
    -- orçamento já por empresa: Contagem → Águas Integradas, Betim → Eficiência Hídrica, Ambos = posição comum ('COMUM', k=1)
    'orc', coalesce((
      select jsonb_agg(jsonb_build_object('c', t.cod_area, 'a', t.area, 'f', t.funcao, 'e', t.emp, 'k', (t.emp = 'COMUM')::int, 'm', t.mes, 'h', t.h))
      from (select o.cod_area, o.area, o.funcao, o.mes, sum(o.headcount) as h,
                   case when pj = 'Contagem' then 'ÁGUAS INTEGRADAS' when pj = 'Betim' then 'EFICIÊNCIA HÍDRICA' else 'COMUM' end as emp
            from "18 - rh".pes_bi_orcamento o join "18 - rh".pes_bi_carga k on k.id = o.carga_id and k.ativa and k.tipo = 'orcamento',
                 lateral (select case when o.funcao = 'ANALISTA DE RECURSOS HUMANOS' and o.projeto = 'Ambos' then 'Contagem' else o.projeto end as pj) q
            where o.area is not null and o.funcao is distinct from 'MENOR APRENDIZ' and o.headcount is not null
            group by o.cod_area, o.area, o.funcao, o.mes, pj) t), '[]'::jsonb),
    'cargas', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'nome', k.nome_original, 'linhas', k.linhas, 'em', k.concluido_em) order by k.tipo)
        from "18 - rh".pes_bi_carga k where k.ativa), '[]'::jsonb));
end $$;

-- ───────────── acesso ─────────────
create or replace function public.app_pes_bi_acesso()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ver', "18 - rh".pes_bi_pode(auth.uid()), 'carregar', "18 - rh".pes_carga_pode(auth.uid()),
    'admin', exists (select 1 from public.perfil p where p.id = auth.uid() and p.ativo and p.funcao = 'admin'))
$$;
create or replace function public.app_pes_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and ativo and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', coalesce(p.nome, p.email), 'email', p.email, 'funcao', p.funcao, 'cargo', c.nome,
      'ver', coalesce(p.pes_bi_acesso, false), 'carregar', coalesce(p.pes_carga_acesso, false), 'admin', p.funcao = 'admin') order by coalesce(p.nome, p.email))
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id where coalesce(p.ativo, true)), '[]'::jsonb);
end $$;
create or replace function public.app_pes_acesso_set(p_uuid uuid, p_ver boolean, p_carregar boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and ativo and funcao = 'admin') then raise exception 'sem permissão'; end if;
  update public.perfil set pes_bi_acesso = coalesce(p_ver, false), pes_carga_acesso = coalesce(p_carregar, false) where id = p_uuid;
end $$;

revoke all on function public.app_pes_carga_iniciar(text, text, text), public.app_pes_carga_lote(bigint, text, jsonb), public.app_pes_carga_finalizar(bigint),
  public.app_pes_carga_falha(bigint, text), public.app_pes_cargas_listar(int), public.app_pes_bi(), public.app_pes_bi_acesso(),
  public.app_pes_acesso_listar(), public.app_pes_acesso_set(uuid, boolean, boolean) from public, anon;
grant execute on function public.app_pes_carga_iniciar(text, text, text), public.app_pes_carga_lote(bigint, text, jsonb), public.app_pes_carga_finalizar(bigint),
  public.app_pes_carga_falha(bigint, text), public.app_pes_cargas_listar(int), public.app_pes_bi(), public.app_pes_bi_acesso(),
  public.app_pes_acesso_listar(), public.app_pes_acesso_set(uuid, boolean, boolean) to authenticated;
