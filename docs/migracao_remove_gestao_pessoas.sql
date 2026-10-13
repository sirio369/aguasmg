-- ⚠️ OPCIONAL E DESTRUTIVO — limpeza do banco da antiga Gestão de Pessoas (removida do app em 2026-10).
-- Apaga DEFINITIVAMENTE o schema "14 - pessoas" (candidatos com CPF/endereço/salário, admissões, checklists,
-- histórico de desligamentos, área_aprovador, premissas de benefícios) e todas as RPCs app_pessoas_*.
-- NÃO há rollback. Antes de rodar: exporte as tabelas do schema "14 - pessoas" (backup) e confirme com a gestão.
-- O app novo (Meus colaboradores) NÃO depende de nada daqui. public.perfil.pessoas_admin é mantida (app_me ainda a lê).
-- Arquivos anexados das cartas (bucket fotos-campo, pasta pessoas/) NÃO são apagados por este script.

do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_pessoas\_%' loop
    execute 'drop function ' || r.sig || ' cascade';
  end loop;
end $$;

drop schema if exists "14 - pessoas" cascade;

notify pgrst, 'reload schema';
