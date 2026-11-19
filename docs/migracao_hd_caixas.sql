-- Logística reversa de HD — caixas de hidrômetros recebidas da COPASA (Auxiliar › Serviços comerciais)
-- Fluxo: cadastrada (disponível para retirada) → vinculada a um responsável (em execução) → devolvida (gestor desvincula).
-- Acesso: admin ou aux_acesso (public.sigos_pode_ver) em todos os passos.

create table if not exists "12 - retaguarda".hd_caixa (
  id            bigserial primary key,
  consorcio     text not null check (consorcio in ('ZA1004','ZA0200')),
  numero        text not null,
  hd_inicial    text not null,
  hd_final      text not null,
  obs           text,
  status        text not null default 'disponivel' check (status in ('disponivel','em_execucao','devolvida')),
  responsavel   uuid references public.perfil(id),
  vinculado_em  timestamptz,
  vinculado_por uuid references public.perfil(id),
  devolvido_em  timestamptz,
  devolvido_por uuid references public.perfil(id),
  devolucao_obs text,
  criado_em     timestamptz not null default now(),
  criado_por    uuid references public.perfil(id),
  unique (consorcio, numero)
);
create index if not exists hd_caixa_resp_idx on "12 - retaguarda".hd_caixa(responsavel);

create table if not exists "12 - retaguarda".hd_caixa_evento (
  id          bigserial primary key,
  caixa_id    bigint not null references "12 - retaguarda".hd_caixa(id) on delete cascade,
  acao        text not null check (acao in ('cadastro','vinculo','devolucao','edicao')),
  responsavel uuid references public.perfil(id),
  por         uuid references public.perfil(id),
  em          timestamptz not null default now(),
  obs         text
);
create index if not exists hd_caixa_evento_cx_idx on "12 - retaguarda".hd_caixa_evento(caixa_id);

alter table "12 - retaguarda".hd_caixa enable row level security;
alter table "12 - retaguarda".hd_caixa_evento enable row level security;
revoke all on "12 - retaguarda".hd_caixa, "12 - retaguarda".hd_caixa_evento from anon, authenticated;

-- Lista de caixas (todas; filtros rodam no app)
create or replace function public.app_hdcx_listar()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'cons', c.consorcio, 'num', c.numero, 'ini', c.hd_inicial, 'fim', c.hd_final, 'obs', c.obs,
      'st', c.status, 'resp', c.responsavel, 'resp_nome', pr.nome,
      'vinc_em', c.vinculado_em, 'vinc_por', pv.nome,
      'dev_em', c.devolvido_em, 'dev_por', pd.nome, 'dev_obs', c.devolucao_obs,
      'cad_em', c.criado_em, 'cad_por', pc.nome) order by c.consorcio, c.numero)
    from "12 - retaguarda".hd_caixa c
    left join public.perfil pr on pr.id = c.responsavel
    left join public.perfil pv on pv.id = c.vinculado_por
    left join public.perfil pd on pd.id = c.devolvido_por
    left join public.perfil pc on pc.id = c.criado_por), '[]'::jsonb);
end $$;

-- Pessoas que podem receber caixa (perfis ativos)
create or replace function public.app_hdcx_pessoas()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'cons', consorcio, 'cargo', cargo) order by nome)
    from public.perfil where coalesce(ativo, true) and nome is not null), '[]'::jsonb);
end $$;

-- Cadastro em lote: p_itens = [{num, ini, fim, obs}]; números já existentes no consórcio são devolvidos em "dup"
create or replace function public.app_hdcx_cadastrar(p_consorcio text, p_itens jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_ins int := 0; v_dup text[] := '{}'; r jsonb; v_id bigint;
begin
  if not public.sigos_pode_ver(v_uid) then raise exception 'sem permissão'; end if;
  if p_consorcio not in ('ZA1004','ZA0200') then raise exception 'consórcio inválido'; end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then raise exception 'nenhuma caixa informada'; end if;
  if jsonb_array_length(p_itens) > 5000 then raise exception 'no máximo 5.000 caixas por vez'; end if;
  for r in select * from jsonb_array_elements(p_itens) loop
    if coalesce(btrim(r->>'num'),'') = '' or coalesce(btrim(r->>'ini'),'') = '' or coalesce(btrim(r->>'fim'),'') = '' then
      raise exception 'caixa sem número, HD inicial ou HD final'; end if;
    insert into "12 - retaguarda".hd_caixa(consorcio, numero, hd_inicial, hd_final, obs, criado_por)
    values (p_consorcio, btrim(r->>'num'), upper(btrim(r->>'ini')), upper(btrim(r->>'fim')), nullif(btrim(r->>'obs'),''), v_uid)
    on conflict (consorcio, numero) do nothing returning id into v_id;
    if v_id is null then v_dup := v_dup || btrim(r->>'num');
    else v_ins := v_ins + 1;
      insert into "12 - retaguarda".hd_caixa_evento(caixa_id, acao, por) values (v_id, 'cadastro', v_uid);
    end if;
    v_id := null;
  end loop;
  return jsonb_build_object('ins', v_ins, 'dup', to_jsonb(v_dup));
end $$;

-- Vincular caixas disponíveis a um responsável (retirada) → em execução
create or replace function public.app_hdcx_vincular(p_ids bigint[], p_responsavel uuid)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); n int;
begin
  if not public.sigos_pode_ver(v_uid) then raise exception 'sem permissão'; end if;
  if not exists(select 1 from public.perfil where id = p_responsavel and coalesce(ativo, true)) then raise exception 'responsável inválido'; end if;
  if exists(select 1 from "12 - retaguarda".hd_caixa where id = any(p_ids) and status <> 'disponivel') then
    raise exception 'só caixas disponíveis podem ser vinculadas'; end if;
  with u as (
    update "12 - retaguarda".hd_caixa set status = 'em_execucao', responsavel = p_responsavel, vinculado_em = now(), vinculado_por = v_uid
     where id = any(p_ids) and status = 'disponivel' returning id)
  insert into "12 - retaguarda".hd_caixa_evento(caixa_id, acao, responsavel, por) select id, 'vinculo', p_responsavel, v_uid from u;
  get diagnostics n = row_count;
  return n;
end $$;

-- Devolução (gestor desvincula a caixa do responsável) → devolvida
create or replace function public.app_hdcx_devolver(p_ids bigint[], p_obs text default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); n int;
begin
  if not public.sigos_pode_ver(v_uid) then raise exception 'sem permissão'; end if;
  if exists(select 1 from "12 - retaguarda".hd_caixa where id = any(p_ids) and status <> 'em_execucao') then
    raise exception 'só caixas em execução podem ser devolvidas'; end if;
  with u as (
    update "12 - retaguarda".hd_caixa set status = 'devolvida', devolvido_em = now(), devolvido_por = v_uid, devolucao_obs = nullif(btrim(p_obs),'')
     where id = any(p_ids) and status = 'em_execucao' returning id, responsavel)
  insert into "12 - retaguarda".hd_caixa_evento(caixa_id, acao, responsavel, por, obs) select id, 'devolucao', responsavel, v_uid, nullif(btrim(p_obs),'') from u;
  get diagnostics n = row_count;
  return n;
end $$;

-- Corrigir / excluir caixa cadastrada errada (só enquanto disponível)
create or replace function public.app_hdcx_editar(p_id bigint, p_num text, p_ini text, p_fim text, p_obs text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  if coalesce(btrim(p_num),'') = '' or coalesce(btrim(p_ini),'') = '' or coalesce(btrim(p_fim),'') = '' then raise exception 'preencha número, HD inicial e HD final'; end if;
  update "12 - retaguarda".hd_caixa set numero = btrim(p_num), hd_inicial = upper(btrim(p_ini)), hd_final = upper(btrim(p_fim)), obs = nullif(btrim(p_obs),'')
   where id = p_id and status = 'disponivel';
  if not found then raise exception 'só caixas disponíveis podem ser corrigidas'; end if;
  insert into "12 - retaguarda".hd_caixa_evento(caixa_id, acao, por) values (p_id, 'edicao', auth.uid());
end $$;

create or replace function public.app_hdcx_excluir(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  delete from "12 - retaguarda".hd_caixa where id = p_id and status = 'disponivel';
  if not found then raise exception 'só caixas disponíveis podem ser excluídas'; end if;
end $$;

revoke all on function public.app_hdcx_listar(), public.app_hdcx_pessoas(), public.app_hdcx_cadastrar(text, jsonb),
  public.app_hdcx_vincular(bigint[], uuid), public.app_hdcx_devolver(bigint[], text),
  public.app_hdcx_editar(bigint, text, text, text, text), public.app_hdcx_excluir(bigint) from public, anon;
grant execute on function public.app_hdcx_listar(), public.app_hdcx_pessoas(), public.app_hdcx_cadastrar(text, jsonb),
  public.app_hdcx_vincular(bigint[], uuid), public.app_hdcx_devolver(bigint[], text),
  public.app_hdcx_editar(bigint, text, text, text, text), public.app_hdcx_excluir(bigint) to authenticated;
