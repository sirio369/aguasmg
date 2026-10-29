-- Histórico fechado por ZA (tela s-historico do cockpit de Perdas) — aplicada em 2026-10-29 (migração nrw_historico_za).
-- Fonte dos dados: planilha "dados volume.xlsx" enviada pelo usuário (= aba "Macro e Micro" da
-- "Dados Indices de Perdas.xlsx" da COPASA, dez/2023–fev/2025). App-only: acesso só via RPC.
create table if not exists "11 - perdas_nrw".historico_za (
  consorcio    text    not null check (consorcio in ('ZA0200','ZA1004')),
  competencia  int     not null check (competencia between 200001 and 209912),
  vd           numeric not null,           -- volume distribuído (macro)
  vc           numeric not null,           -- volume consumido (micro)
  fonte        text    not null default 'COPASA - planilha de fechamento',
  carregado_em timestamptz not null default now(),
  primary key (consorcio, competencia)
);
alter table "11 - perdas_nrw".historico_za enable row level security;
revoke all on "11 - perdas_nrw".historico_za from public, anon, authenticated;

insert into "11 - perdas_nrw".historico_za (consorcio, competencia, vd, vc) values
('ZA1004',202312,2196036,1107818),('ZA0200',202312,1422247,689076),
('ZA1004',202401,2081864,1084518),('ZA0200',202401,1469086,710555),
('ZA1004',202402,2186562,1048158),('ZA0200',202402,1495432,655728),
('ZA1004',202403,2159119,1053337),('ZA0200',202403,1412870,652265),
('ZA1004',202404,2263257,1182174),('ZA0200',202404,1512099,705687),
('ZA1004',202405,2220133,1144199),('ZA0200',202405,1445931,705695),
('ZA1004',202406,2117832,1157932),('ZA0200',202406,1484080,707294),
('ZA1004',202407,2098266,1204397),('ZA0200',202407,1445960,738827),
('ZA1004',202408,2108476,1177140),('ZA0200',202408,1524370,698999),
('ZA1004',202409,1793067,1184748),('ZA0200',202409,1668531,740935),
('ZA1004',202410,1721027,1262529),('ZA0200',202410,1619302,808503),
('ZA1004',202411,1701670,1132982),('ZA0200',202411,1577401,694884),
('ZA1004',202412,2180852,1175040),('ZA0200',202412,1526936,728653),
('ZA1004',202501,2305380,1103873),('ZA0200',202501,1535212,719077),
('ZA1004',202502,2322653,1090692),('ZA0200',202502,1626209,675104)
on conflict (consorcio, competencia) do nothing;

-- Série histórica por ZA: histórico fechado (historico_za) + meses do sistema (app_nrw_resultado:
-- macro GMOA − micro). O mês que existe no sistema prevalece sobre o histórico. "Ambos" (p_consorcio
-- null) soma as 2 ZAs e só usa mês histórico presente nas duas. Gate = o mesmo do resultado.
create or replace function public.app_nrw_historico(p_consorcio text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r jsonb;
begin
  r := public.app_nrw_resultado(p_consorcio, false);   -- valida acesso (admin|dev_acesso) e traz baselines + série do sistema
  return jsonb_build_object(
    'escopo', coalesce(p_consorcio,'all'),
    'baselines', r->'baselines',
    'serie', coalesce((
      select jsonb_agg(x order by (x->>'competencia')::int) from (
        select jsonb_build_object('competencia', comp, 'vd', round(vd), 'vc', round(vc), 'vp', round(vd-vc),
                 'ip_pct', round(100*(vd-vc)/nullif(vd,0),1), 'fonte', 'historico') x
        from (
          select h.competencia comp, sum(h.vd) vd, sum(h.vc) vc
          from "11 - perdas_nrw".historico_za h
          where (p_consorcio is null or h.consorcio = p_consorcio)
            and not exists (select 1 from "11 - perdas_nrw".macro_mensal m
                            where m.consorcio = h.consorcio and m.competencia = h.competencia)
          group by h.competencia
          having count(*) = case when p_consorcio is null then 2 else 1 end
        ) a
        union all
        select jsonb_build_object('competencia', (e->>'competencia')::int, 'vd', e->'vd', 'vc', e->'vc',
                 'vp', e->'vp', 'ip_pct', e->'ip_pct', 'fonte', 'sistema')
        from jsonb_array_elements(coalesce(r->'serie','[]'::jsonb)) e
      ) t
    ), '[]'::jsonb)
  );
end $function$;
revoke all on function public.app_nrw_historico(text) from public, anon;
grant execute on function public.app_nrw_historico(text) to authenticated;
