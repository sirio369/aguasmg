-- Frota: remove os 2 lembretes diários antigos (pedido do usuário, 2026-10-28). JÁ APLICADA em produção
-- (migração `remove_lembretes_frota_diarios`).
--  - frota-checklist-lembrete-diario       07h30 todo dia: "Checklist diário — Já fez seu checklist diário hoje?"
--                                          (quem tem carro vinculado + CNH ativa e ainda não fez o checklist do dia)
--  - frota-organizar-veiculo-lembrete-diario 16h50 todo dia: "Organize seu veículo — Lembre-se de organizar seu veículo
--                                          para o próximo dia de trabalho" (todo condutor com carro vinculado)
-- Lembrete de checklist que sobra: o do módulo Avisos (aviso_lembretes_run, MODULOS.md §19), só enquanto houver aviso
-- com lembrete='checklist_frota' vigente.

select cron.unschedule(jobname) from cron.job
 where jobname in ('frota-checklist-lembrete-diario','frota-organizar-veiculo-lembrete-diario');
drop function if exists public.frota_checklist_lembrete_diario();
drop function if exists public.frota_organizar_veiculo_lembrete_diario();

-- ===== ROLLBACK (recria exatamente o que existia) =====
-- create or replace function public.frota_checklist_lembrete_diario() returns void language plpgsql security definer set search_path to 'public' as $$
-- declare v_uid uuid;
-- begin
--   for v_uid in
--     select distinct vv.condutor_id
--     from "10 - Frotas".frota_veiculo_vinculo vv
--     join "10 - Frotas".frota_veiculo v on v.id=vv.veiculo_id and v.ativo
--     join "10 - Frotas".frota_condutor c on c.id=vv.condutor_id and c.status='ativo'
--     where vv.desvinculado_em is null
--       and not exists (
--         select 1 from "10 - Frotas".frota_checklist_situacao s
--         where s.veiculo_id=vv.veiculo_id and s.reportado_por=vv.condutor_id
--           and (s.criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
--       )
--   loop
--     perform "9 - suprimentos".sup_notificar(array[v_uid], 'frota',
--       'Checklist diário', 'Já fez seu checklist diário hoje?', 'frota_checklist');
--   end loop;
-- end; $$;
-- create or replace function public.frota_organizar_veiculo_lembrete_diario() returns void language plpgsql security definer set search_path to 'public' as $$
-- declare v_uid uuid;
-- begin
--   for v_uid in
--     select distinct vv.condutor_id
--     from "10 - Frotas".frota_veiculo_vinculo vv
--     join "10 - Frotas".frota_veiculo v on v.id=vv.veiculo_id and v.ativo
--     join "10 - Frotas".frota_condutor c on c.id=vv.condutor_id and c.status='ativo'
--     where vv.desvinculado_em is null
--   loop
--     perform "9 - suprimentos".sup_notificar(array[v_uid], 'frota',
--       'Organize seu veículo', 'Lembre-se de organizar seu veículo para o próximo dia de trabalho', 'frota_checklist');
--   end loop;
-- end; $$;
-- revoke all on function public.frota_checklist_lembrete_diario() from public, anon, authenticated;
-- revoke all on function public.frota_organizar_veiculo_lembrete_diario() from public, anon, authenticated;
-- select cron.schedule('frota-checklist-lembrete-diario', '30 10 * * *', 'select public.frota_checklist_lembrete_diario();');
-- select cron.schedule('frota-organizar-veiculo-lembrete-diario', '50 19 * * *', 'select public.frota_organizar_veiculo_lembrete_diario();');
