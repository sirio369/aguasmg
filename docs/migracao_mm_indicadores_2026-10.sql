-- Indicadores de micromedição por ZA e mês (relatório de linha de base, item 7.2 / Anexo E) — 2026-10-26.
-- Já aplicado em produção (migrations mm_indicadores_mensal + mm_stats_rebuild_chama_indicadores).
-- Critério do mm_mensal: total = lido + estimado + factível; faturada = volume>0 ou factível>0. 202505 fica fora.
create table if not exists "11 - perdas_nrw".mm_indicadores (
  consorcio text not null, competencia int not null,
  n_ligacoes int not null, n_ativas int not null, n_faturadas int not null,
  n_ativas_estimadas int not null, n_ativas_zero int not null, n_nao_ativas int not null,
  n_nao_ativas_vol int not null, n_nao_ativas_fac int not null,
  volume_total bigint not null, volume_medido bigint not null, volume_estimado bigint not null, volume_factivel bigint not null,
  n_economias_ativas bigint not null default 0, volume_nao_ativas bigint not null default 0,
  atualizado_em timestamptz not null default now(),
  primary key (consorcio, competencia)
);
alter table "11 - perdas_nrw".mm_indicadores enable row level security;

create or replace function public.app_nrw_mm_indicadores_rebuild(p_consorcio text default null)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  delete from "11 - perdas_nrw".mm_indicadores where (p_consorcio is null or consorcio=p_consorcio);
  insert into "11 - perdas_nrw".mm_indicadores
    (consorcio, competencia, n_ligacoes, n_ativas, n_faturadas, n_ativas_estimadas, n_ativas_zero,
     n_nao_ativas, n_nao_ativas_vol, n_nao_ativas_fac, volume_total, volume_medido, volume_estimado, volume_factivel,
     n_economias_ativas, volume_nao_ativas)
  select za, competencia,
    count(*),
    count(*) filter (where cd_situaca='R'),
    count(*) filter (where qt_volume_>0 or qt_vol_fac>0),
    count(*) filter (where cd_situaca='R' and qt_vol_est>0),
    count(*) filter (where cd_situaca='R' and qt_volume_=0),
    count(*) filter (where cd_situaca<>'R'),
    count(*) filter (where cd_situaca<>'R' and qt_volume_>0),
    count(*) filter (where cd_situaca<>'R' and qt_vol_fac>0),
    coalesce(sum(qt_volume_),0) + coalesce(sum(qt_vol_fac),0),
    coalesce(sum(qt_volume_) filter (where qt_vol_est=0),0),
    coalesce(sum(qt_volume_) filter (where qt_vol_est>0),0),
    coalesce(sum(qt_vol_fac),0),
    coalesce(sum(qt_economi) filter (where cd_situaca='R'),0),
    coalesce(sum(qt_volume_ + qt_vol_fac) filter (where cd_situaca<>'R'),0)
  from "5 - info_copasa".micromedicao_historico
  where competencia<>202505 and (p_consorcio is null or za=p_consorcio)
  group by za, competencia;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.app_nrw_mm_indicadores_rebuild(text) from public, anon, authenticated;

create or replace function public.app_nrw_mm_indicadores(p_consorcio text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'serie', coalesce((select jsonb_agg(to_jsonb(m) - 'atualizado_em' order by m.consorcio, m.competencia)
                       from "11 - perdas_nrw".mm_indicadores m where p_consorcio is null or m.consorcio=p_consorcio), '[]'::jsonb),
    'janela', coalesce((select jsonb_object_agg(l.consorcio, jsonb_build_object(
                'de', (l.premissas->>'janela_de')::int, 'ate', (l.premissas->>'janela_ate')::int,
                'excluir', coalesce(l.premissas->'excluir','[]'::jsonb)))
              from "11 - perdas_nrw".linha_base l
              where l.indicador='VP_BL' and l.premissas->>'fonte'='previa' and (p_consorcio is null or l.consorcio=p_consorcio)), '{}'::jsonb));
end $$;
revoke all on function public.app_nrw_mm_indicadores(text) from public, anon;
grant execute on function public.app_nrw_mm_indicadores(text) to authenticated;

-- app_nrw_mm_stats_rebuild passou a chamar, logo após refazer mm_mensal:
--   perform public.app_nrw_mm_indicadores_rebuild(p_consorcio);
select public.app_nrw_mm_indicadores_rebuild(null);
