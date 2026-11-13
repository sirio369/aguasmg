-- Consolidador — quem pode VALIDAR (engrenagem ⚙️ dentro da própria tela, só admin) (2026-11-13)
-- Antes: só funcao='admin'. Agora: admin OU perfil.fisc_validar (marcado na engrenagem).
-- Para validar a pessoa também precisa abrir o Consolidador (aux_acesso) — a lista só mostra quem abre.
-- Retrocompatível: o front já obedece ao 'pode_validar' devolvido por app_fisc_mes/app_fisc_dia.

alter table public.perfil add column if not exists fisc_validar boolean not null default false;

create or replace function public.fisc_pode_validar(p_uid uuid)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select p_uid is not null and exists(select 1 from public.perfil
    where id = p_uid and coalesce(ativo, true)
      and (funcao = 'admin' or (fisc_validar and coalesce(aux_acesso, false))));
$$;
revoke all on function public.fisc_pode_validar(uuid) from public, anon;

-- lista: quem abre o Consolidador (admin | aux_acesso) + quem está marcado (mesmo que tenha perdido o acesso)
create or replace function public.app_fisc_validador_listar()
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'nome', coalesce(nome, email), 'email', email, 'cargo', cargo, 'funcao', funcao, 'ativo', coalesce(ativo, true),
      'admin', funcao = 'admin', 'aux', coalesce(aux_acesso, false), 'validar', funcao = 'admin' or fisc_validar)
      order by (funcao = 'admin') desc, fisc_validar desc, coalesce(nome, email))
    from public.perfil where funcao = 'admin' or coalesce(aux_acesso, false) or fisc_validar), '[]'::jsonb);
end $$;

create or replace function public.app_fisc_validador_set(p_uuid uuid, p_validar boolean)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare v_f text;
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  select funcao into v_f from public.perfil where id = p_uuid;
  if v_f is null then raise exception 'usuário inexistente'; end if;
  if v_f = 'admin' then raise exception 'admin sempre valida'; end if;
  update public.perfil set fisc_validar = coalesce(p_validar, false) where id = p_uuid;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.app_fisc_validador_listar() from public, anon;
revoke all on function public.app_fisc_validador_set(uuid, boolean) from public, anon;
grant execute on function public.app_fisc_validador_listar() to authenticated;
grant execute on function public.app_fisc_validador_set(uuid, boolean) to authenticated;
