-- Relatório do Consolidador (Excel) — classificação das execuções por gestor e agrupamento (2026-11-13)
-- Só leitura: devolve, para as OS SIGOS pedidas, o código do serviço e o gestor/agrupamento/família da
-- tabela "17 - sigos".codigo_servico (PDF Gestão_OS_Codigos v3.6, a mesma das OS Pendentes) + o mapa
-- família → gestor/agrupamento (moda) para o que não tem OS SIGOS (loggers, visitas de VRP do app, obras).
-- Código "Compartilhado" (pavimento, manobra) → gestor da OS de origem quando o SIGOS a informa.
-- Nada muda em fisc_execucoes / hash / snapshots. Gate = o mesmo do Consolidador (sigos_pode_ver).

create or replace function public.app_fisc_rel_classes(p_os text[])
returns jsonb
language plpgsql stable security definer
set search_path to 'public', '17 - sigos'
as $$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  with b as (
    select distinct public.sigos_os_base(x) base from unnest(coalesce(p_os, '{}')) x where public.sigos_os_base(x) is not null
  ),
  o as (   -- encerrada primeiro (é a execução), aberta como reserva
    select distinct on (b.base) b.base, s.cod_servico, s.cod_os_origem
      from b
      join lateral (
        select e.cod_servico, e.cod_os_origem, 1 pri, e.execucao em from os_encerrada e where public.sigos_os_base(e.numero) = b.base
        union all
        select a.cod_servico, a.cod_os_origem, 2, a.abertura from os_aberta a where public.sigos_os_base(a.numero) = b.base
      ) s on true
     order by b.base, s.pri, s.em desc nulls last
  ),
  c as (
    select o.base, o.cod_servico cod, ci.gestor, ci.grupo, ci.familia,
           case when ci.gestor = 'Compartilhado' then (select g.gestor from public.sigos_cod_info(o.cod_os_origem) g
                                                       where g.gestor not in ('Compartilhado', '—')) end g_orig
      from o left join lateral (select * from public.sigos_cod_info(o.cod_servico)) ci on true
  ),
  f as (
    select familia,
           mode() within group (order by gestor) filter (where gestor not in ('—', 'Compartilhado')) gestor,
           mode() within group (order by grupo) filter (where grupo not in ('Não usar', 'Suporte')) grupo,
           mode() within group (order by grupo) filter (where grupo <> 'Não usar') grupo2,
           mode() within group (order by gestor) gestor2
      from codigo_servico group by familia
  )
  select jsonb_build_object(
    'os', coalesce((select jsonb_object_agg(c.base, jsonb_build_object('cod', c.cod, 'gestor', coalesce(c.g_orig, c.gestor), 'grupo', c.grupo, 'familia', c.familia)) from c), '{}'::jsonb),
    'familias', coalesce((select jsonb_object_agg(f.familia, jsonb_build_object('gestor', coalesce(f.gestor, f.gestor2), 'grupo', coalesce(f.grupo, f.grupo2))) from f), '{}'::jsonb)
  ) into r;
  return r;
end $$;

revoke all on function public.app_fisc_rel_classes(text[]) from public, anon;
grant execute on function public.app_fisc_rel_classes(text[]) to authenticated;
