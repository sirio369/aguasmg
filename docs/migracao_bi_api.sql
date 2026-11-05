-- Leitura dos BIs pela API HTTPS do Supabase (2026-11-05)
-- Motivo: o serviço do Power BI não confia na CA própria do Supabase no Postgres (5432) e exigiria gateway.
-- A API (https://<ref>.supabase.co/rest/v1) tem certificado público → atualização agendada no serviço sem gateway.
--
-- Como funciona
--   GET /rest/v1/rpc/bi_dados?p_view=bi_sst_dds&p_chave=<chave>   (header/param apikey = chave anon, pública)
--   - cada BI tem UMA chave (public.bi_api_chave), guardada só como hash sha256;
--   - a chave só lê views de um schema e prefixo (ex.: "16 - qsms" + bi_sst_), nada mais;
--   - no Power BI a chave fica na credencial "Chave da API Web" (ApiKeyName = p_chave), nunca no código.
--
-- Criar/girar a chave (SQL Editor, como postgres — mostra a chave UMA vez; a anterior deixa de valer):
--   select public.bi_chave_criar('qsms', '16 - qsms', 'bi_sst_');
-- Revogar: update public.bi_api_chave set ativo = false where nome = 'qsms';
-- BI novo = outra chave com o schema/prefixo das views dele.

create table if not exists public.bi_api_chave (
  nome        text primary key,
  schema_nome text not null,
  prefixo     text not null check (prefixo ~ '^bi_[a-z0-9_]+$'),
  chave_hash  bytea not null unique,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);
alter table public.bi_api_chave enable row level security;          -- sem policy: ninguém lê pela API
revoke all on public.bi_api_chave from public, anon, authenticated;

-- leitura (anon chama; a chave é que autoriza). STABLE porque o GET do PostgREST roda em transação read-only.
create or replace function public.bi_dados(p_view text, p_chave text)
returns json
language plpgsql stable security definer
set search_path = ''
as $$
declare
  c   public.bi_api_chave;
  res json;
begin
  select * into c from public.bi_api_chave k
   where k.ativo and k.chave_hash = sha256(convert_to(coalesce(p_chave, ''), 'UTF8'));
  if not found then
    raise exception 'chave inválida' using errcode = '28000';
  end if;
  if p_view is null or left(p_view, length(c.prefixo)) <> c.prefixo
     or not exists (select 1 from information_schema.views v
                     where v.table_schema = c.schema_nome and v.table_name = p_view) then
    raise exception 'view não permitida' using errcode = '42501';
  end if;
  execute format('select coalesce(json_agg(t), ''[]''::json) from %I.%I t', c.schema_nome, p_view) into res;
  return res;
end $$;
revoke all on function public.bi_dados(text, text) from public, authenticated;
grant execute on function public.bi_dados(text, text) to anon;

-- criar/girar chave: só o dono (SQL Editor). Devolve a chave em texto uma única vez.
create or replace function public.bi_chave_criar(p_nome text, p_schema text, p_prefixo text)
returns text
language plpgsql volatile security definer
set search_path = ''
as $$
declare k text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not exists (select 1 from pg_namespace where nspname = p_schema) then
    raise exception 'schema % não existe', p_schema;
  end if;
  insert into public.bi_api_chave (nome, schema_nome, prefixo, chave_hash)
  values (p_nome, p_schema, p_prefixo, sha256(convert_to(k, 'UTF8')))
  on conflict (nome) do update
     set schema_nome = excluded.schema_nome, prefixo = excluded.prefixo,
         chave_hash = excluded.chave_hash, ativo = true, criado_em = now();
  return k;
end $$;
revoke all on function public.bi_chave_criar(text, text, text) from public, anon, authenticated;
