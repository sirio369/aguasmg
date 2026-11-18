-- Indicadores SST — BI QSMS dentro do AcquaHub (2026-11-18)
-- Devolve as linhas das mesmas views bi_sst_* que o Power BI lê (contrato de colunas igual),
-- para a tela "BI QSMS" (sst_bi) calcular as medidas no aparelho com a mesma regra do DAX.
-- Só leitura, função nova: nada do app atual muda.
--
-- Filtro de período = relação com o Calendário no BI:
--   Acidentes, Acidentes Vínculo, Inspeções, DDS e CIPA Reuniões pela Data;
--   Treinamentos vêm todos (o app filtra pela Data de Realização só nas medidas que o BI filtra;
--   as de situação — válidos/vencidos/a vencer/sem data/programados — ignoram o período, como no BI);
--   Saúde e CIPA Membros não têm data no BI (situação de hoje).
-- p_de/p_ate nulos = sem filtro de período (igual ao BI sem segmentação).

create or replace function public.app_sst_bi(p_de date default null, p_ate date default null, p_consorcio text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_c text := nullif(btrim(p_consorcio),''); r jsonb;
begin
  perform "16 - qsms".sst_gestao_check();
  select jsonb_build_object(
    'hoje', "16 - qsms".sst_hoje(),
    'areas', coalesce((select jsonb_agg(x."Área" order by x."Área") from "16 - qsms".bi_sst_area x), '[]'::jsonb),
    'acidentes', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_acidentes x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'vinculo', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_acidentes_vinculo x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'inspecoes', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_inspecoes x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'dds', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_dds x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'cipa_reunioes', coalesce((select jsonb_agg(to_jsonb(x) order by x."Data" desc) from "16 - qsms".bi_sst_cipa_reunioes x
        where (p_de is null or x."Data" >= p_de) and (p_ate is null or x."Data" <= p_ate) and (v_c is null or x."Consórcio" = v_c)), '[]'::jsonb),
    'treinamentos', coalesce((select jsonb_agg(to_jsonb(x) order by x."Colaborador", x."Treinamento") from "16 - qsms".bi_sst_treinamentos x
        where v_c is null or x."Consórcio" = v_c), '[]'::jsonb),
    'saude', coalesce((select jsonb_agg(to_jsonb(x) order by x."Colaborador") from "16 - qsms".bi_sst_saude x
        where v_c is null or x."Consórcio" = v_c), '[]'::jsonb),
    'cipa_membros', coalesce((select jsonb_agg(to_jsonb(x) order by x."Membro") from "16 - qsms".bi_sst_cipa_membros x
        where v_c is null or x."Consórcio" = v_c), '[]'::jsonb),
    -- "Sem dados" do cartão do BI = tabela inteira vazia (ISEMPTY(ALL(...))), independente de filtro
    'vazias', jsonb_build_object(
        'acidentes', not exists (select 1 from "16 - qsms".bi_sst_acidentes),
        'vinculo', not exists (select 1 from "16 - qsms".bi_sst_acidentes_vinculo),
        'inspecoes', not exists (select 1 from "16 - qsms".bi_sst_inspecoes),
        'dds', not exists (select 1 from "16 - qsms".bi_sst_dds),
        'treinamentos', not exists (select 1 from "16 - qsms".bi_sst_treinamentos),
        'saude', not exists (select 1 from "16 - qsms".bi_sst_saude),
        'cipa_membros', not exists (select 1 from "16 - qsms".bi_sst_cipa_membros),
        'cipa_reunioes', not exists (select 1 from "16 - qsms".bi_sst_cipa_reunioes))
  ) into r;
  return r;
end $$;
revoke all on function public.app_sst_bi(date, date, text) from public, anon;
grant execute on function public.app_sst_bi(date, date, text) to authenticated;
