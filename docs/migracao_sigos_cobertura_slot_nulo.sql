-- Cobertura SIGOS com carga em 2 campos (2026-11-16) — JÁ APLICADO em produção em 16/11/2026.
-- Bug: desde a carga em 2 campos (PR #332, migracao_sigos_carga_2campos.sql) o arquivo chega com slot_za = NULL
-- (a ZA sai de cada linha). A vw_carga_cobertura filtrava slot_za = za, então ignorava todas as cargas novas e a
-- cobertura ficou travada na última carga do app antigo (11/11/2026). Efeito: Consolidador/RDO/Vitrine/Vínculo
-- mostravam "⏳ O SIGOS chegou só até 11/11" e bloqueavam a validação do dia, mesmo com Encerradas até 15/11.
-- Correção: arquivo sem ZA (cobre as duas) conta para as duas ZAs.
-- Cuidado: CREATE OR REPLACE VIEW sem WITH (...) zera as reloptions — manter security_invoker = true.

create or replace view "17 - sigos".vw_carga_cobertura with (security_invoker = true) as
select z.za,
       (select max(f.enviado_em) from "17 - sigos".arquivo f
         where f.slot_tipo = 'relacao' and (f.slot_za = z.za or f.slot_za is null) and f.status = 'ok') as relacao_em,
       (select max(f.periodo_fim) from "17 - sigos".arquivo f
         where f.slot_tipo = 'encerradas' and (f.slot_za = z.za or f.slot_za is null) and f.status = 'ok') as encerradas_ate,
       (select min(e.execucao)::date from "17 - sigos".os_encerrada e where e.consorcio = z.za) as encerradas_desde
from (values ('ZA0200'), ('ZA1004')) z(za);
