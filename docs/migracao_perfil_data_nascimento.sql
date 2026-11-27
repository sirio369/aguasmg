-- Data de nascimento no cadastro de usuários (2026-11-25)
-- JÁ APLICADO em produção (projeto lwttadkctfznidzvmury). Arquivo de registro/reaplicação; idempotente.
-- Origem do dado: relatório de empregados do e-Social, conferido por CPF. Os valores NÃO ficam no repositório (dado pessoal, repo público).
-- Acesso: public.perfil tem RLS 'perfil_select_own' (cada usuário só lê a própria linha). Nenhuma tela usa o campo ainda.
-- A coluna não é atualizada automaticamente: novos cadastros ficam em branco até a próxima conferência.

alter table public.perfil add column if not exists data_nascimento date;
