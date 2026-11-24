-- Orçamento: acesso por organograma (engrenagem 🔐 em cada organograma) — 24/11/2026, sw v448
-- Regra: entra no organograma quem já tem acesso ao módulo (admin ou dev_acesso) E
--   (é admin) ou (criou o organograma) ou (a lista do organograma está vazia) ou (está na lista).
-- Lista vazia = aberto a todos do módulo (comportamento de antes). Só admin ou o criador mexem na lista.
-- Leitura (lista/abrir) checada nas RPCs; escrita checada por trigger nas tabelas filhas.
-- Sem DROP de dados. Idempotente.

create table if not exists "19 - orcamento".orc_quadro_acesso (
  quadro_id     uuid not null references "19 - orcamento".orc_quadro(id) on delete cascade,
  perfil_id     uuid not null references public.perfil(id) on delete cascade,
  concedido_por uuid,
  criado_em     timestamptz not null default now(),
  primary key (quadro_id, perfil_id)
);
alter table "19 - orcamento".orc_quadro_acesso enable row level security;  -- só via funções security definer

create or replace function "19 - orcamento".orc_eh_admin(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil where id = p_uid and coalesce(ativo,true) and funcao = 'admin');
$$;

create or replace function "19 - orcamento".orc_quadro_pode(p_quadro uuid, p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path to '19 - orcamento', 'public' as $$
  select p_uid is null                                   -- SQL direto / serviço
      or "19 - orcamento".orc_eh_admin(p_uid)
      or exists (select 1 from orc_quadro q where q.id = p_quadro and q.criado_por = p_uid)
      or not exists (select 1 from orc_quadro_acesso a where a.quadro_id = p_quadro)
      or exists (select 1 from orc_quadro_acesso a where a.quadro_id = p_quadro and a.perfil_id = p_uid);
$$;

create or replace function "19 - orcamento".orc_quadro_config(p_quadro uuid, p_uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path to '19 - orcamento', 'public' as $$
  select "19 - orcamento".orc_eh_admin(p_uid)
      or exists (select 1 from orc_quadro q where q.id = p_quadro and q.criado_por = p_uid);
$$;

-- escrita: pessoas, equipes, membros e vínculos só de organograma liberado
create or replace function "19 - orcamento".orc_trg_acesso()
returns trigger language plpgsql security definer set search_path to '19 - orcamento', 'public' as $$
declare v_q uuid;
begin
  if TG_TABLE_NAME = 'orc_equipe_membro' then
    select e.quadro_id into v_q from orc_equipe e where e.id = case when TG_OP = 'DELETE' then old.equipe_id else new.equipe_id end;
  elsif TG_OP = 'DELETE' then v_q := old.quadro_id;
  else v_q := new.quadro_id;
  end if;
  if v_q is not null and not "19 - orcamento".orc_quadro_pode(v_q) then
    raise exception 'sem acesso a este organograma';
  end if;
  return case when TG_OP = 'DELETE' then old else new end;
end $$;

drop trigger if exists trg_acesso on "19 - orcamento".orc_pessoa;
create trigger trg_acesso before insert or update or delete on "19 - orcamento".orc_pessoa for each row execute function "19 - orcamento".orc_trg_acesso();
drop trigger if exists trg_acesso on "19 - orcamento".orc_equipe;
create trigger trg_acesso before insert or update or delete on "19 - orcamento".orc_equipe for each row execute function "19 - orcamento".orc_trg_acesso();
drop trigger if exists trg_acesso on "19 - orcamento".orc_equipe_membro;
create trigger trg_acesso before insert or update or delete on "19 - orcamento".orc_equipe_membro for each row execute function "19 - orcamento".orc_trg_acesso();
drop trigger if exists trg_acesso on "19 - orcamento".orc_vinculo;
create trigger trg_acesso before insert or update or delete on "19 - orcamento".orc_vinculo for each row execute function "19 - orcamento".orc_trg_acesso();

-- lista de organogramas: só os liberados (+ flags para a engrenagem)
create or replace function public.app_orc_quadros()
returns jsonb language plpgsql stable security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'titulo',q.titulo,'ordem',q.ordem,'atualizado_em',q.atualizado_em,
            'pessoas',(select count(*) from orc_pessoa p where p.quadro_id=q.id),
            'restrito',exists(select 1 from orc_quadro_acesso a where a.quadro_id=q.id),
            'pode_config',"19 - orcamento".orc_quadro_config(q.id, v_uid)) order by q.ordem),'[]')
          from orc_quadro q where "19 - orcamento".orc_quadro_pode(q.id, v_uid));
end $$;

create or replace function public.app_orc_quadro(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not exists (select 1 from orc_quadro where id = p_id) then raise exception 'organograma não encontrado'; end if;
  if not "19 - orcamento".orc_quadro_pode(p_id, v_uid) then raise exception 'sem acesso a este organograma'; end if;
  return jsonb_build_object(
    'quadro',   (select to_jsonb(q) || jsonb_build_object('restrito', exists(select 1 from orc_quadro_acesso a where a.quadro_id=q.id),
                   'pode_config', "19 - orcamento".orc_quadro_config(q.id, v_uid)) from orc_quadro q where q.id = p_id),
    'pessoas',  (select coalesce(jsonb_agg(to_jsonb(p) order by p.y, p.x),'[]') from orc_pessoa p where p.quadro_id = p_id),
    'equipes',  (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('membros',
                   (select coalesce(jsonb_agg(m.pessoa_id),'[]') from orc_equipe_membro m where m.equipe_id = e.id)) order by e.nome),'[]')
                 from orc_equipe e where e.quadro_id = p_id),
    'vinculos', (select coalesce(jsonb_agg(to_jsonb(v)),'[]') from orc_vinculo v where v.quadro_id = p_id));
end $$;

create or replace function public.app_orc_quadro_salvar(p jsonb)
returns uuid language plpgsql security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige(); v_id uuid := nullif(p->>'id','')::uuid;
begin
  if v_id is null or not exists (select 1 from orc_quadro where id = v_id) then
    insert into orc_quadro(id,titulo,ordem,desenho,criado_por,atualizado_por)
    values (coalesce(v_id,gen_random_uuid()), coalesce(nullif(trim(p->>'titulo'),''),'Organograma'),
            coalesce((p->>'ordem')::bigint,(extract(epoch from now())*1000)::bigint),
            coalesce(p->'desenho','{"notes":[],"strokes":[]}'::jsonb), v_uid, v_uid)
    returning id into v_id;
  else
    if not "19 - orcamento".orc_quadro_pode(v_id, v_uid) then raise exception 'sem acesso a este organograma'; end if;
    update orc_quadro set
      titulo  = case when p ? 'titulo' then coalesce(nullif(trim(p->>'titulo'),''),'Organograma') else titulo end,
      ordem   = case when p ? 'ordem' then (p->>'ordem')::bigint else ordem end,
      desenho = case when p ? 'desenho' then p->'desenho' else desenho end,
      atualizado_por = v_uid, atualizado_em = now()
    where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.app_orc_quadro_excluir(p_id uuid)
returns void language plpgsql security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_quadro_pode(p_id, v_uid) then raise exception 'sem acesso a este organograma'; end if;
  delete from orc_quadro where id = p_id;
end $$;

-- engrenagem: quem pode entrar
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
                     'admin', f.funcao = 'admin') order by coalesce(nullif(f.nome,''),f.email)),'[]')
                   from public.perfil f where coalesce(f.ativo,true) and (f.funcao = 'admin' or coalesce(f.dev_acesso,false))));
end $$;

create or replace function public.app_orc_quadro_acesso_set(p_quadro uuid, p_ids uuid[])
returns jsonb language plpgsql security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_quadro_config(p_quadro, v_uid) then raise exception 'só o administrador ou quem criou o organograma muda o acesso'; end if;
  delete from orc_quadro_acesso where quadro_id = p_quadro and not (perfil_id = any(coalesce(p_ids,'{}')));
  insert into orc_quadro_acesso(quadro_id, perfil_id, concedido_por)
    select p_quadro, x, v_uid from unnest(coalesce(p_ids,'{}')) x
    where exists (select 1 from public.perfil f where f.id = x)
  on conflict do nothing;
  return (select coalesce(jsonb_agg(perfil_id),'[]') from orc_quadro_acesso where quadro_id = p_quadro);
end $$;

revoke all on function public.app_orc_quadro_acesso(uuid) from public, anon;
revoke all on function public.app_orc_quadro_acesso_set(uuid, uuid[]) from public, anon;
grant execute on function public.app_orc_quadro_acesso(uuid) to authenticated;
grant execute on function public.app_orc_quadro_acesso_set(uuid, uuid[]) to authenticated;
