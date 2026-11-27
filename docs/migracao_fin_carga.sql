-- Gestão Financeira (Custos), etapa 1: CARGA dos 6 arquivos do Custos 3.0 (2026-11-27). Telas do BI vêm depois.
-- O app lê o .xlsx no aparelho e manda as linhas com as colunas que o Power Query do Custos 3.0 usa, sem transformar.
-- Cada arquivo novo substitui o anterior do mesmo tipo, só quando chega inteiro e com linhas e somas iguais às do arquivo.
-- Dados financeiros: nenhuma função devolve as linhas; só admin ou perfil.fin_carga_acesso (ninguém por padrão) carrega e vê o resumo.
-- Pode rodar mais de uma vez.
create schema if not exists "20 - financeiro";
alter table public.perfil add column if not exists fin_carga_acesso boolean not null default false;

create or replace function "20 - financeiro".fin_carga_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo and (p.funcao = 'admin' or p.fin_carga_acesso))
$$;

create table if not exists "20 - financeiro".fin_carga (
  id bigserial primary key,
  tipo text not null check (tipo in ('extrato','parcelas','plano','orcamento','orcamento_det','apropriacoes')),
  nome_original text, sha256 text, linhas int, resumo jsonb,
  status text not null default 'pendente' check (status in ('pendente','ok','erro')),
  ativa boolean not null default false, aviso text, erro text,
  enviado_por uuid default auth.uid(), enviado_em timestamptz not null default now(), concluido_em timestamptz
);
create table if not exists "20 - financeiro".fin_linha (
  carga_id bigint not null references "20 - financeiro".fin_carga(id) on delete cascade, n int not null, dados jsonb not null,
  primary key (carga_id, n)
);
alter table "20 - financeiro".fin_carga enable row level security;
alter table "20 - financeiro".fin_linha enable row level security;

create or replace function public.app_fin_acesso()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('carregar', coalesce("20 - financeiro".fin_carga_pode(auth.uid()), false))
$$;

create or replace function public.app_fin_carga_iniciar(p_tipo text, p_nome text, p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_aviso text; v_ant timestamptz;
begin
  if not "20 - financeiro".fin_carga_pode(auth.uid()) then raise exception 'sem permissão para carregar arquivos de Custos'; end if;
  if p_tipo is null or p_tipo not in ('extrato','parcelas','plano','orcamento','orcamento_det','apropriacoes') then raise exception 'tipo de arquivo inválido'; end if;
  select max(concluido_em) into v_ant from "20 - financeiro".fin_carga where tipo = p_tipo and status = 'ok' and sha256 = p_sha256;
  if v_ant is not null then v_aviso := 'idêntico ao já enviado em ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'); end if;
  insert into "20 - financeiro".fin_carga (tipo, nome_original, sha256, aviso) values (p_tipo, left(p_nome, 300), p_sha256, v_aviso) returning id into v_id;
  return jsonb_build_object('carga_id', v_id, 'aviso', v_aviso);
end $$;

create or replace function public.app_fin_carga_lote(p_carga bigint, p_inicio int, p_linhas jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  if not "20 - financeiro".fin_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  perform 1 from "20 - financeiro".fin_carga where id = p_carga and status = 'pendente';
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 2000 then raise exception 'lote inválido'; end if;
  insert into "20 - financeiro".fin_linha (carga_id, n, dados)
  select p_carga, p_inicio + x.o::int, x.v from jsonb_array_elements(p_linhas) with ordinality as x(v, o);
  get diagnostics n = row_count;
  return n;
end $$;

-- p_conferencia = o que o aparelho leu no arquivo: {"linhas": n, "totais": {"Coluna": soma}}
create or replace function public.app_fin_carga_finalizar(p_carga bigint, p_conferencia jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  c "20 - financeiro".fin_carga; n int; r record; v_soma numeric; v_totais jsonb := '{}'::jsonb; v_data text; v_de text; v_ate text;
  v_cons jsonb; v_res jsonb;
begin
  if not "20 - financeiro".fin_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "20 - financeiro".fin_carga where id = p_carga and status = 'pendente' for update;
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  select count(*) into n from "20 - financeiro".fin_linha where carga_id = p_carga;
  if n = 0 then raise exception 'nenhuma linha válida no arquivo — nada foi alterado'; end if;
  if n is distinct from (p_conferencia->>'linhas')::int then
    raise exception 'chegaram % linhas e o arquivo tem % — nada foi alterado', n, p_conferencia->>'linhas'; end if;
  for r in select key, value from jsonb_each_text(coalesce(p_conferencia->'totais', '{}'::jsonb)) loop
    select coalesce(sum((dados->>r.key)::numeric), 0) into v_soma from "20 - financeiro".fin_linha where carga_id = p_carga;
    if abs(v_soma - r.value::numeric) > 0.05 then
      raise exception 'a soma de "%" no banco (%) difere da do arquivo (%) — nada foi alterado', r.key, round(v_soma, 2), round(r.value::numeric, 2); end if;
    v_totais := v_totais || jsonb_build_object(r.key, round(v_soma, 2));
  end loop;
  v_data := case c.tipo when 'extrato' then 'Data' when 'parcelas' then 'Data vencimento' when 'orcamento' then 'Mês Calendário' when 'orcamento_det' then 'Mês Calendário' end;
  if v_data is not null then
    select min(dados->>v_data), max(dados->>v_data) into v_de, v_ate from "20 - financeiro".fin_linha where carga_id = p_carga;
  end if;
  if c.tipo in ('orcamento', 'orcamento_det') then
    select jsonb_object_agg(k, v) into v_cons from (
      select coalesce(dados->>'Consórcio', '(sem consórcio)') k, round(sum(coalesce((dados->>'Soma de Valor')::numeric, (dados->>'Valor')::numeric, 0)), 2) v
        from "20 - financeiro".fin_linha where carga_id = p_carga group by 1) z;
  end if;
  v_res := jsonb_strip_nulls(jsonb_build_object('totais', v_totais, 'de', v_de, 'ate', v_ate, 'por_consorcio', v_cons));
  update "20 - financeiro".fin_carga set ativa = false where tipo = c.tipo and ativa;
  delete from "20 - financeiro".fin_linha where carga_id in (select id from "20 - financeiro".fin_carga where tipo = c.tipo and id <> p_carga);
  update "20 - financeiro".fin_carga set status = 'ok', ativa = true, linhas = n, resumo = v_res, concluido_em = now() where id = p_carga;
  return jsonb_build_object('carga_id', p_carga, 'tipo', c.tipo, 'linhas', n, 'resumo', v_res, 'aviso', c.aviso);
end $$;

create or replace function public.app_fin_carga_falha(p_carga bigint, p_erro text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not "20 - financeiro".fin_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  update "20 - financeiro".fin_carga set status = 'erro', erro = left(p_erro, 500), concluido_em = now() where id = p_carga and status = 'pendente';
  if not found then return; end if;
  delete from "20 - financeiro".fin_linha where carga_id = p_carga;
end $$;

create or replace function public.app_fin_cargas_listar(p_limite int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "20 - financeiro".fin_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'ativas', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'nome', k.nome_original, 'linhas', k.linhas, 'resumo', k.resumo, 'em', k.concluido_em) order by k.tipo)
        from "20 - financeiro".fin_carga k where k.ativa), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(to_jsonb(h) order by h.enviado_em desc) from (
        select k.id, k.tipo, k.nome_original as nome, k.linhas, k.resumo, k.status, k.aviso, k.erro, k.enviado_em, (select nome from public.perfil p where p.id = k.enviado_por) as por
        from "20 - financeiro".fin_carga k order by k.enviado_em desc limit greatest(p_limite, 1)) h), '[]'::jsonb));
end $$;

revoke all on function public.app_fin_acesso() from public, anon;
revoke all on function public.app_fin_carga_iniciar(text, text, text) from public, anon;
revoke all on function public.app_fin_carga_lote(bigint, int, jsonb) from public, anon;
revoke all on function public.app_fin_carga_finalizar(bigint, jsonb) from public, anon;
revoke all on function public.app_fin_carga_falha(bigint, text) from public, anon;
revoke all on function public.app_fin_cargas_listar(int) from public, anon;
grant execute on function public.app_fin_acesso() to authenticated;
grant execute on function public.app_fin_carga_iniciar(text, text, text) to authenticated;
grant execute on function public.app_fin_carga_lote(bigint, int, jsonb) to authenticated;
grant execute on function public.app_fin_carga_finalizar(bigint, jsonb) to authenticated;
grant execute on function public.app_fin_carga_falha(bigint, text) to authenticated;
grant execute on function public.app_fin_cargas_listar(int) to authenticated;
