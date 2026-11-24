-- Orçamento: 🔐 por organograma tira até os administradores (24/11/2026, sw v450)
-- Antes: admin sempre entrava e sempre mudava o acesso. Agora só o(s) DONO(s) do módulo (tabela orc_dono) e quem
-- criou o organograma sempre entram e mudam a lista; os demais administradores entram só se marcados.
-- Lista vazia continua = aberto a todos com acesso ao módulo. Sem DROP de dados. Idempotente.
-- O dono é cadastrado à parte (insert em "19 - orcamento".orc_dono), fora do repositório.

create table if not exists "19 - orcamento".orc_dono (
  perfil_id uuid primary key references public.perfil(id) on delete cascade,
  criado_em timestamptz not null default now()
);
alter table "19 - orcamento".orc_dono enable row level security;  -- só via funções security definer

create or replace function "19 - orcamento".orc_eh_dono(p_uid uuid)
returns boolean language sql stable security definer set search_path to '19 - orcamento', 'public' as $$
  select exists (select 1 from orc_dono where perfil_id = p_uid);
$$;
revoke all on function "19 - orcamento".orc_eh_dono(uuid) from public, anon;

create or replace function "19 - orcamento".orc_quadro_pode(p_quadro uuid, p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path to '19 - orcamento', 'public' as $$
  select p_uid is null                                   -- SQL direto / serviço
      or "19 - orcamento".orc_eh_dono(p_uid)
      or exists (select 1 from orc_quadro q where q.id = p_quadro and q.criado_por = p_uid)
      or not exists (select 1 from orc_quadro_acesso a where a.quadro_id = p_quadro)
      or exists (select 1 from orc_quadro_acesso a where a.quadro_id = p_quadro and a.perfil_id = p_uid);
$$;

create or replace function "19 - orcamento".orc_quadro_config(p_quadro uuid, p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path to '19 - orcamento', 'public' as $$
  select "19 - orcamento".orc_eh_dono(p_uid)
      or exists (select 1 from orc_quadro q where q.id = p_quadro and q.criado_por = p_uid);
$$;

-- candidatos: flag 'dono' (sempre entra) no lugar de 'admin'
create or replace function public.app_orc_quadro_acesso(p_quadro uuid)
returns jsonb language plpgsql stable security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_quadro_pode(p_quadro, v_uid) then raise exception 'sem acesso a este organograma'; end if;
  return jsonb_build_object(
    'pode_config', "19 - orcamento".orc_quadro_config(p_quadro, v_uid),
    'criado_por', (select criado_por from orc_quadro where id = p_quadro),
    'lista', (select coalesce(jsonb_agg(perfil_id),'[]') from orc_quadro_acesso where quadro_id = p_quadro),
    'candidatos', (select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'nome',coalesce(nullif(f.nome,''),f.email),'email',f.email,
                     'admin', f.funcao = 'admin', 'dono', "19 - orcamento".orc_eh_dono(f.id)) order by coalesce(nullif(f.nome,''),f.email)),'[]')
                   from public.perfil f where coalesce(f.ativo,true) and (f.funcao = 'admin' or coalesce(f.dev_acesso,false))));
end $$;

create or replace function public.app_orc_quadro_acesso_set(p_quadro uuid, p_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_quadro_config(p_quadro, v_uid) then raise exception 'só o dono do módulo ou quem criou o organograma muda o acesso'; end if;
  delete from orc_quadro_acesso where quadro_id = p_quadro and not (perfil_id = any(coalesce(p_ids,'{}')));
  insert into orc_quadro_acesso(quadro_id, perfil_id, concedido_por)
    select p_quadro, x, v_uid from unnest(coalesce(p_ids,'{}')) x
    where exists (select 1 from public.perfil f where f.id = x)
  on conflict do nothing;
  return (select coalesce(jsonb_agg(perfil_id),'[]') from orc_quadro_acesso where quadro_id = p_quadro);
end $$;
