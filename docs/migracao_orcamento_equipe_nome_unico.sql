-- Orçamento: nome de equipe único em TODOS os organogramas (24/11/2026, sw v452) — aplicado como orc_27_equipe_nome_unico.
-- Compara sem maiúsculas e com espaços normalizados ("Equipe VCA" = " equipe  vca "). Sem DROP de dados. Idempotente.
-- Motivo: o Excel relaciona Mão de Obra × Locação × Despesas pela coluna Equipe; nome repetido mistura equipes no filtro.

create or replace function "19 - orcamento".orc_nome_norm(t text)
returns text language sql immutable set search_path to 'pg_catalog' as $$ select lower(regexp_replace(btrim(coalesce(t,'')), '\s+', ' ', 'g')) $$;

create unique index if not exists orc_equipe_nome_unico on "19 - orcamento".orc_equipe ("19 - orcamento".orc_nome_norm(nome));

-- app_orc_equipe_salvar: quando recebe 'nome' (ou cria), normaliza os espaços, recusa vazio e recusa nome já usado por outra
-- equipe em qualquer organograma: 'já existe uma equipe chamada "X" (organograma Y) — use outro nome'.
-- Chamadas só com 'membros' (colar/duplicar) não mexem no nome. Corpo completo no banco (pg_get_functiondef).

-- nomes de todas as equipes p/ a tela avisar antes de salvar; título do organograma só se o usuário entra nele (🔐)
create or replace function public.app_orc_equipe_nomes()
returns jsonb language plpgsql stable security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome,
            'quadro', case when "19 - orcamento".orc_quadro_pode(q.id, v_uid) then q.titulo end)), '[]')
          from orc_equipe e join orc_quadro q on q.id = e.quadro_id);
end $$;
revoke all on function public.app_orc_equipe_nomes() from public, anon;
grant execute on function public.app_orc_equipe_nomes() to authenticated;
