-- BI Suprimentos · acesso (PR-B, 2026-11-19). Depende de docs/migracao_sup_bi.sql.
-- app_sup_bi_acesso: o app pergunta ao abrir a Home se mostra o card do BI e o botão de cargas (não mexe no app_me).
-- app_sup_acesso_listar / _set: só admin (engrenagem "Acesso" do BI), liga/desliga "ver o BI" e "subir relatórios" por pessoa.
create or replace function public.app_sup_bi_acesso()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ver', "9 - suprimentos".sup_bi_pode(auth.uid()), 'carregar', "9 - suprimentos".sup_carga_pode(auth.uid()),
    'admin', exists (select 1 from public.perfil p where p.id = auth.uid() and p.ativo and p.funcao = 'admin'))
$$;

create or replace function public.app_sup_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and ativo and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', coalesce(p.nome, p.email), 'email', p.email, 'funcao', p.funcao,
      'cargo', c.nome, 'ver', coalesce(p.sup_bi_acesso, false), 'carregar', coalesce(p.sup_carga_acesso, false), 'admin', p.funcao = 'admin')
      order by coalesce(p.nome, p.email))
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id where coalesce(p.ativo, true)), '[]'::jsonb);
end $$;

create or replace function public.app_sup_acesso_set(p_uuid uuid, p_ver boolean, p_carregar boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and ativo and funcao = 'admin') then raise exception 'sem permissão'; end if;
  update public.perfil set sup_bi_acesso = coalesce(p_ver, false), sup_carga_acesso = coalesce(p_carregar, false) where id = p_uuid;
end $$;

revoke all on function public.app_sup_bi_acesso(), public.app_sup_acesso_listar(), public.app_sup_acesso_set(uuid, boolean, boolean) from public, anon;
grant execute on function public.app_sup_bi_acesso(), public.app_sup_acesso_listar(), public.app_sup_acesso_set(uuid, boolean, boolean) to authenticated;
