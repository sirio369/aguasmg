-- ============================================================================
-- Programação do recadastramento comercial (Auxiliar de Programação › Serviços comerciais)
-- Tela `recad_prog` do index.html — docs/MODULOS.md §21.2 (2026-11-09)
--
-- Recadastramento = serviço SIGOS 1990100 "PDC REVISAO CADASTRO CONTRATADA".
-- Fontes (só leitura): "3 - comercial".ligacoes (todas as matrículas = o "todo"),
-- "17 - sigos".os_aberta (carteira da última Relação de Serviços) e
-- "17 - sigos".os_encerrada (Encerradas acumuladas).
--
-- Duas RPCs, ambas no gate do SIGOS (public.sigos_pode_ver = admin ou aux_acesso):
--   app_recad_dados()                → pontos de todas as ligações + OS de recadastramento por matrícula
--   app_recad_export(p_matriculas)   → endereço/bairro/roteiro para o export (até 50 mil por chamada)
-- A classificação (status atual, recadastrada, visitas, %) é feita no app sobre esses dados.
-- ============================================================================

create or replace function public.app_recad_dados()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', '17 - sigos'
as $function$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;

  with ab as (
    select a.matricula, a.numero, a.consorcio, a.status, a.equipe, a.responsavel, a.abertura, a.limite,
           a.enc_realizado, coalesce(a.visitas, 0) as visitas, a.classificacao
      from os_aberta a
     where a.cod_servico = '1990100' and a.matricula > 0
  ),
  en as (
    select e.matricula, e.numero, e.consorcio, e.status, e.equipe, e.responsavel, e.data_geracao, e.execucao,
           coalesce(e.visitas, 0) as visitas, e.ocorrencia
      from os_encerrada e
     where e.cod_servico = '1990100' and e.matricula > 0
  ),
  os as (
    select m.matricula,
           jsonb_build_object(
             'a', coalesce((select jsonb_agg(jsonb_build_object(
                     'n', a.numero, 'st', a.status, 'eq', a.equipe, 'resp', a.responsavel,
                     'ab', a.abertura, 'lim', a.limite, 'encr', a.enc_realizado, 'vis', a.visitas, 'cls', a.classificacao)
                     order by a.abertura desc) from ab a where a.matricula = m.matricula), '[]'::jsonb),
             'e', coalesce((select jsonb_agg(jsonb_build_object(
                     'n', e.numero, 'st', e.status, 'eq', e.equipe, 'resp', e.responsavel,
                     'ab', e.data_geracao, 'ex', e.execucao, 'vis', e.visitas, 'oc', e.ocorrencia)
                     order by e.execucao desc nulls last) from en e where e.matricula = m.matricula), '[]'::jsonb)
           ) as d
      from (select matricula from ab union select matricula from en) m
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'carteiras', (select jsonb_object_agg(consorcio, d) from (
                    select a.consorcio, max(f.enviado_em) d from os_aberta a join arquivo f on f.id = a.arquivo_id group by 1) c),
    'encerradas_ate', (select jsonb_object_agg(consorcio, d) from (
                    select consorcio, max(execucao) d from os_encerrada group by 1) c),
    'encerradas_desde', (select jsonb_object_agg(consorcio, d) from (
                    select consorcio, min(execucao) d from os_encerrada where cod_servico = '1990100' group by 1) c),
    'os', (select coalesce(jsonb_object_agg(matricula::text, d), '{}'::jsonb) from os),
    -- [matrícula, lat, lon, ZA (1 = ZA1004 · 0 = ZA0200), situação da ligação R/I/F/P]
    'pts', (select coalesce(jsonb_agg(jsonb_build_array(
                     l.matricula,
                     round(ST_Y(l.g)::numeric, 5), round(ST_X(l.g)::numeric, 5),
                     case l.consorcio when 'ZA1004' then 1 else 0 end,
                     l.situacao)), '[]'::jsonb)
              from (select matricula, consorcio, situacao, ST_Transform(geom, 4326) g
                      from "3 - comercial".ligacoes where geom is not null) l)
  ) into r;
  return r;
end $function$;

create or replace function public.app_recad_export(p_matriculas bigint[])
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  if coalesce(array_length(p_matriculas, 1), 0) > 50000 then raise exception 'no máximo 50 mil matrículas por chamada'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'mat', v.matricula, 'end', v.endereco, 'bai', v.bairro,
             'setor', v.setor_efetivo, 'rota', v.rota, 'rot', v.roteiro_leitura,
             'sit', v.situacao, 'cat', v.categoria))
      from "0 - vitrine_gis".vw_gis_cadastro_comercial v
     where v.matricula = any(p_matriculas)), '[]'::jsonb);
end $function$;

revoke all on function public.app_recad_dados() from public, anon;
revoke all on function public.app_recad_export(bigint[]) from public, anon;
grant execute on function public.app_recad_dados() to authenticated;
grant execute on function public.app_recad_export(bigint[]) to authenticated;
