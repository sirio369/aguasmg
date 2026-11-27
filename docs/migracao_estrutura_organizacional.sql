-- Estrutura Organizacional (organograma montado a partir do cadastro de colaboradores) — 2026-11-26
-- Fonte: public.perfil. Quem responde a quem = Aprovador 1. Entram os ativos; terceiro e a conta de teste ficam fora.
-- A função devolve SÓ nome, cargo, área, consórcio e o superior (nada de CPF, e-mail, telefone, datas ou salário).
-- EM DESENVOLVIMENTO: por enquanto só admin e quem tem perfil.dev_acesso. Para liberar a todo colaborador, trocar a
-- condição de "estrutura_pode" por:  p.ativo   (e tirar o cadeado do card no front).
-- Idempotente.

create or replace function public.estrutura_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo and (p.funcao = 'admin' or coalesce(p.dev_acesso, false)))
$$;
revoke all on function public.estrutura_pode(uuid) from public, anon, authenticated;

create or replace function public.app_estrutura() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.estrutura_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return (
    with v as (
      select p.id, p.nome, p.cargo, c.nome as cargo_nome, p.area, p.consorcio, p.aprovador_uuid
        from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id
       where p.ativo and upper(coalesce(p.modalidade, '')) <> 'TERCEIRO' and lower(coalesce(p.email, '')) <> 'usertest@acquahub.com.br'
    )
    select jsonb_build_object('eu', auth.uid(), 'pessoas', coalesce(jsonb_agg(jsonb_build_object(
             'id', v.id, 'nome', coalesce(v.nome, '(sem nome)'), 'cargo', coalesce(v.cargo_nome, v.cargo), 'area', v.area, 'consorcio', v.consorcio,
             'sup', case when v.aprovador_uuid is distinct from v.id and exists (select 1 from v s where s.id = v.aprovador_uuid) then v.aprovador_uuid end)
           order by v.nome), '[]'::jsonb))
      from v);
end $$;
revoke all on function public.app_estrutura() from public, anon;
grant execute on function public.app_estrutura() to authenticated;
