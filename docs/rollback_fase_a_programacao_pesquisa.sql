-- ============================================================
-- PONTO DE RETORNO — Fase A "Programação de pesquisa de vazamento"
-- Baseline: 2026-09-10 16:13 UTC. pesquisa_trecho estava VAZIA.
-- Rodar tudo isto reverte 100% ao estado anterior — INCLUINDO apagar dados reais
-- de pesquisa/programação lançados depois (Fases B/C/D/E). Só use isto pra
-- descontinuar o módulo inteiro, não como "desfazer a última mudança".
--
-- ⚠️ Desatualizado a partir da Fase E (2026-09-11, segmentação de rede p/
-- Programação de Pesquisa): não dropa "rede_pp_segmento"/"rede_pp_segmento_fonte"
-- nem o trigger em "2 - infra_agua".rede, e as funções abaixo usam o schema
-- pré-Fase E (rede_id em vez de segmento_id). Pra reverter só a Fase E mantendo
-- os dados reais, use docs/rollback_fase_e_segmentacao_pp.sql — este arquivo aqui
-- fica só como registro de como zerar o módulo inteiro desde o início.
-- Aplicar via mcp supabase apply_migration (name: rollback_fase_a_pp) ou psql.
-- ============================================================

begin;

-- 1. trigger + funções de cruzamento
drop trigger if exists trg_pp_cruzar on "8 - coleta_campo".pesquisa_trecho;
drop function if exists "8 - coleta_campo".pp_cruzar_trecho();
drop function if exists "8 - coleta_campo".pp_recompute(bigint[]);

-- 2. RPCs
drop function if exists public.app_rede_bbox(double precision,double precision,double precision,double precision,text,boolean);
drop function if exists public.app_rede_bbox(double precision,double precision,double precision,double precision,text,boolean,date);
drop function if exists public.app_pp_rede_no_poligono(text,text);
drop function if exists public.app_pp_atribuir(bigint[],uuid,boolean);
drop function if exists public.app_pp_desatribuir(bigint[]);
drop function if exists public.app_pp_resumo();
drop function if exists public.app_pp_por_colaborador(uuid);
drop function if exists public.app_pp_colaboradores();
drop function if exists public.app_pp_minhas();
drop function if exists public.app_pp_mapa(uuid,text,date,date);
drop function if exists public.app_pp_recruzar(numeric,numeric);
drop function if exists public.app_pp_recruzar(numeric,numeric,numeric,numeric);

-- 3. view da vitrine
drop view if exists "0 - vitrine_gis".vw_gis_programacao_pesquisa;

-- 4. tabelas
drop table if exists "8 - coleta_campo".programacao_pesquisa;
drop table if exists "8 - coleta_campo".pp_config;

-- 5. dados simulados (pesquisa_trecho estava vazia no baseline)
delete from "8 - coleta_campo".pesquisa_trecho where dispositivo = 'SIM_FASE_A';
-- confirmação: deve voltar a 0
-- select count(*) from "8 - coleta_campo".pesquisa_trecho;

commit;

notify pgrst, 'reload schema';
