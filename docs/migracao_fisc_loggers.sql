-- Consolidador: loggers separados por tipo (temporário/fixo) e etapa (instalação/remoção),
-- acumulado de logger desde a 1ª instalação e saldo de temporários "em campo".
-- APLICADO em produção em 2026-11-13 (via MCP). Backups: "12 - retaguarda"._bkp_funcdef_20261113 (defs antigas
-- de fisc_execucoes/fisc_ordem/fisc_linhas) e "12 - retaguarda"._bkp_fisc_dia_20261113.

-- 1) fisc_execucoes: e_log passa a gerar 4 atividades (patch textual sobre a definição vigente)
do $mig$
declare d text; d0 text;
begin
  d0 := pg_get_functiondef('public.fisc_execucoes'::regproc);
  d := replace(d0,
    $a$select l.data_instalacao::date, l.consorcio, 'Loggers de pressão', 'app:logger:inst:' || l.id, 'AcquaHub',
           'Instalação de logger',$a$,
    $a$select l.data_instalacao::date, l.consorcio,
           case when l.logger_temporario then 'Logger temporário — instalação' else 'Logger fixo — instalação' end,
           'app:logger:inst:' || l.id, 'AcquaHub',
           case when l.logger_temporario then 'Instalação de logger temporário' else 'Instalação de logger fixo' end,$a$);
  if d = d0 then raise exception 'trecho instalação não encontrado'; end if;
  d0 := d;
  d := replace(d0,
    $a$select l.data_remocao::date, l.consorcio, 'Loggers de pressão', 'app:logger:rem:' || l.id, 'AcquaHub',
           'Remoção de logger',$a$,
    $a$select l.data_remocao::date, l.consorcio,
           case when l.logger_temporario then 'Logger temporário — remoção' else 'Logger fixo — remoção' end,
           'app:logger:rem:' || l.id, 'AcquaHub',
           case when l.logger_temporario then 'Remoção de logger temporário' else 'Remoção de logger fixo' end,$a$);
  if d = d0 then raise exception 'trecho remoção não encontrado'; end if;
  execute d;
end $mig$;

-- 2) ordem das linhas
create or replace function public.fisc_ordem(p_atividade text) returns integer language sql immutable as $f$
  select case p_atividade
    when 'Pesquisa de vazamento' then 10 when 'Correção de vazamento' then 12
    when 'Logger temporário — instalação' then 20 when 'Logger temporário — remoção' then 21
    when 'Logger fixo — instalação' then 22 when 'Logger fixo — remoção' then 23
    when 'Loggers de pressão' then 20 when 'Mapeamento de pressão' then 25
    else public.rdo_familia_ordem(p_atividade) end;
$f$;

-- 3) fisc_linhas: acumulado de logger desde a 1ª instalação + saldo "em campo" dos temporários
CREATE OR REPLACE FUNCTION public.fisc_linhas(p_de date, p_ate date, p_za text)
 RETURNS TABLE(dia date, za text, chave text, atividade text, ordem integer, medidas jsonb, execs jsonb, n integer, hash text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_ini constant date := date '2026-09-01';   -- início do Consolidador
  v_log date;                                 -- loggers: acumulado desde a 1ª instalação (13/11/2026)
begin
  select least(v_ini, min(l.data_instalacao)::date) into v_log from "8 - coleta_campo".instalacao_logger_calibracao l;
  return query
  with e as (
    select x.* from public.fisc_execucoes(coalesce(v_log, v_ini), p_ate) x
     where x.za = p_za and (x.dia >= v_ini or x.atividade like 'Logger %')
  ),
  m as (select e.dia, e.atividade, e.unidade, sum(e.qtd) q, count(*) c from e group by 1, 2, 3),
  ma as (select m.*, sum(m.q) over (partition by m.atividade, m.unidade order by m.dia) acum from m),
  -- saldo de loggers temporários em campo ao fim do dia (instalados − removidos, desde a 1ª instalação)
  sd as (
    select e.dia, sum(case when e.atividade = 'Logger temporário — instalação' then e.qtd else -e.qtd end) delta
      from e where e.atividade in ('Logger temporário — instalação', 'Logger temporário — remoção') group by 1
  ),
  sda as (select sd.dia, sum(sd.delta) over (order by sd.dia) saldo from sd),
  med as (
    select ma.dia, ma.atividade,
           jsonb_agg(jsonb_build_object('un', ma.unidade, 'dia', ma.q, 'acum', ma.acum) order by ma.c desc, ma.unidade)
             || case when ma.atividade like 'Logger temporário%'
                     then jsonb_build_array(jsonb_build_object('un', 'em campo', 'dia', max(s.saldo), 'acum', max(s.saldo), 'saldo', true))
                     else '[]'::jsonb end j
      from ma left join sda s on s.dia = ma.dia
     where ma.dia between greatest(p_de, v_ini) and p_ate group by 1, 2
  ),
  ex as (
    select e.dia, e.atividade, min(e.ordem) ord, count(*)::int n,
           jsonb_agg(jsonb_build_object('id', e.exec_id, 'origem', e.origem, 'servico', e.servico, 'desc', e.descricao, 'local', e.local,
                                        'equipe', e.equipe, 'hora', e.hora, 'qtd', e.qtd, 'un', e.unidade, 'os_app', e.os_app, 'os_sigos', e.os_sigos,
                                        'sigos', e.sigos_sit, 'fotos', to_jsonb(e.fotos), 'geo', e.geo, 'extra', e.extra)
                     order by e.servico, e.hora nulls last, e.exec_id) j,
           md5(string_agg(e.exec_id || '|' || coalesce(e.descricao, '') || '|' || e.qtd || '|' || coalesce(e.sigos_sit, ''), '§' order by e.exec_id)) h
      from e where e.dia between greatest(p_de, v_ini) and p_ate group by 1, 2
  )
  select ex.dia, p_za, 'atv:' || ex.atividade, ex.atividade, ex.ord, med.j, ex.j, ex.n, ex.h
    from ex join med on med.dia = ex.dia and med.atividade = ex.atividade;
end $function$;

-- 4) validações já feitas: chave antiga → chaves novas do mesmo dia (mesmo autor/horário), depois apaga a antiga
insert into "12 - retaguarda".fisc_linha_val(dia, za, chave, status, hash, obs, por, por_nome, em)
select o.dia, o.za, l.chave, o.status, l.hash, o.obs, o.por, o.por_nome, o.em
  from "12 - retaguarda".fisc_linha_val o cross join lateral public.fisc_linhas(o.dia, o.dia, o.za) l
 where o.chave = 'atv:Loggers de pressão' and l.atividade like 'Logger %'
on conflict do nothing;
delete from "12 - retaguarda".fisc_linha_val where chave = 'atv:Loggers de pressão';

-- 5) snapshots dos dias fechados com logger regerados (mesma montagem de app_fisc_dia_validar), só onde o hash bate
with y as (select f.dia, f.za, public.fisc_dia_dados(f.dia, f.za) d from "12 - retaguarda".fisc_dia f
            where f.snapshot::text ilike '%logger%' and f.hash = public.fisc_dia_hash(public.fisc_dia_dados(f.dia, f.za)))
update "12 - retaguarda".fisc_dia f set
  snapshot = jsonb_build_object('dia', y.dia, 'za', y.za,
    'linhas', coalesce((select jsonb_agg(e - 'val' - 'hash') from jsonb_array_elements(y.d->'linhas') e where e->'val'->>'status' = 'validada'), '[]'::jsonb),
    'projetos', coalesce((select jsonb_agg(e - 'val' - 'hash') from jsonb_array_elements(y.d->'projetos') e where e->'val'->>'status' = 'validada'), '[]'::jsonb))
from y where f.dia = y.dia and f.za = y.za;
