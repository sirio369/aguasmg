-- Consolidador: detalhe do "mudou" (2026-11-16)
-- Antes a validação da linha guardava só o hash (execuções: id|descrição|qtd|situação SIGOS; obra: %|ids dos avanços|concluída),
-- então a tela sabia QUE a linha mudou, mas não O QUE. Agora a validação grava também um resumo enxuto da linha
-- (fisc_linha_val.antes) e fisc_dia_dados devolve esse resumo em val.antes só nas linhas que mudaram — o front compara
-- com o que está no banco hoje (novas / saíram / alteradas, campo a campo).
-- O passado é preenchido pelo snapshot do dia validado ("12 - retaguarda".fisc_dia): o dia só fecha com todas as linhas
-- validadas e em dia, então o snapshot é exatamente o que foi validado. Não muda hash, snapshot nem o que a fiscalização vê.

alter table "12 - retaguarda".fisc_linha_val add column if not exists antes jsonb;
comment on column "12 - retaguarda".fisc_linha_val.antes is
  'Resumo da linha no momento da validação (fisc_val_resumo) — base do detalhe "o que mudou" no Consolidador';

-- resumo enxuto de uma linha do dia (atividade: execuções; obra: %, concluída e avanços) — só o que entra no hash + rótulos
create or replace function public.fisc_val_resumo(x jsonb)
returns jsonb language sql immutable set search_path to 'public' as $$
  select case when x ? 'execs' then
    jsonb_build_object('execs', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', e->>'id', 'servico', e->>'servico', 'desc', e->>'desc', 'qtd', e->'qtd', 'un', e->>'un',
        'sigos', e->>'sigos', 'os_sigos', e->>'os_sigos', 'os_app', e->>'os_app', 'hora', e->>'hora', 'local', e->>'local'))
        order by e->>'id') from jsonb_array_elements(x->'execs') e), '[]'::jsonb))
  else
    jsonb_build_object('pct', x->'pct', 'concluida', x->'concluida',
      'avancos', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', a->'id', 'item', a->'item', 'valor', a->'valor', 'un', a->>'un', 'hora', a->>'hora', 'por', a->>'por'))
        order by (a->>'id')) from jsonb_array_elements(coalesce(x->'avancos', '[]'::jsonb)) a), '[]'::jsonb))
  end
$$;
revoke all on function public.fisc_val_resumo(jsonb) from public, anon;

-- dados do dia: val.antes só quando a linha mudou depois de validada (o resto do JSON fica igual)
create or replace function public.fisc_dia_dados(p_dia date, p_za text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_l jsonb; v_p jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('chave', l.chave, 'atividade', l.atividade, 'ordem', l.ordem, 'medidas', l.medidas,
           'execs', l.execs, 'n', l.n, 'hash', l.hash,
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from l.hash)
                    || case when v.hash is distinct from l.hash then jsonb_build_object('antes', v.antes) else '{}'::jsonb end end)
           order by l.ordem, l.atividade), '[]'::jsonb)
    into v_l
    from public.fisc_linhas(p_dia, p_dia, p_za) l
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = l.chave;
  select coalesce(jsonb_agg(jsonb_build_object('chave', p.chave, 'kind', p.kind, 'gid', p.gid, 'codigo', p.codigo, 'tipo', p.tipo, 'local', p.local,
           'inicio', p.inicio, 'pct', p.pct, 'pct_ant', p.pct_ant, 'concluida', p.concluida, 'avancos', p.avancos, 'fotos', to_jsonb(p.fotos), 'geo', p.geo, 'hash', p.hash,
           'ext', public.fisc_proj_ext(p.kind, p.gid, p_dia),
           'val', case when v.chave is null then null else jsonb_build_object('status', v.status, 'por', v.por_nome, 'em', v.em, 'obs', v.obs, 'ok', v.hash is not distinct from p.hash)
                    || case when v.hash is distinct from p.hash then jsonb_build_object('antes', v.antes) else '{}'::jsonb end end)
           order by p.codigo), '[]'::jsonb)
    into v_p
    from public.fisc_projetos(p_dia, p_dia, p_za) p
    left join "12 - retaguarda".fisc_linha_val v on v.dia = p_dia and v.za = p_za and v.chave = p.chave;
  return jsonb_build_object('dia', p_dia, 'za', p_za, 'linhas', v_l, 'projetos', v_p);
end $function$;

-- validar uma linha: grava também o resumo
create or replace function public.app_fisc_linha_validar(p_dia date, p_za text, p_chave text, p_status text, p_obs text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d jsonb; x jsonb; v_nome text;
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "12 - retaguarda".fisc_dia where dia = p_dia and za = p_za) then raise exception 'dia já validado — reabra antes'; end if;
  if p_status is null then
    delete from "12 - retaguarda".fisc_linha_val where dia = p_dia and za = p_za and chave = p_chave;
    return jsonb_build_object('ok', true);
  end if;
  if p_status <> 'validada' then raise exception 'status inválido'; end if;
  d := public.fisc_dia_dados(p_dia, p_za);
  select y into x from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) y where y->>'chave' = p_chave;
  if x is null or x->>'hash' is null then raise exception 'linha não encontrada neste dia'; end if;
  if x ? 'kind' and public.fisc_sem_avanco(x) then raise exception 'obra sem avanço neste dia — não precisa de validação'; end if;
  select nome into v_nome from public.perfil where id = auth.uid();
  insert into "12 - retaguarda".fisc_linha_val(dia, za, chave, status, hash, obs, por, por_nome, em, antes)
  values (p_dia, p_za, p_chave, p_status, x->>'hash', nullif(btrim(p_obs), ''), auth.uid(), v_nome, now(), public.fisc_val_resumo(x))
  on conflict (dia, za, chave) do update set status = excluded.status, hash = excluded.hash, obs = excluded.obs,
    por = excluded.por, por_nome = excluded.por_nome, em = excluded.em, antes = excluded.antes;
  return jsonb_build_object('ok', true);
end $function$;

-- validar todas: idem
create or replace function public.app_fisc_linhas_validar_todas(p_dia date, p_za text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d jsonb; v_nome text; n int;
begin
  if not public.fisc_pode_validar(auth.uid()) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "12 - retaguarda".fisc_dia where dia = p_dia and za = p_za) then raise exception 'dia já validado — reabra antes'; end if;
  d := public.fisc_dia_dados(p_dia, p_za);
  select nome into v_nome from public.perfil where id = auth.uid();
  with x as (select y->>'chave' chave, y->>'hash' hash, y->'val' val, public.fisc_sem_avanco(y) sa, public.fisc_val_resumo(y) antes
               from jsonb_array_elements(coalesce(d->'linhas', '[]') || coalesce(d->'projetos', '[]')) y)
  insert into "12 - retaguarda".fisc_linha_val(dia, za, chave, status, hash, por, por_nome, em, antes)
  select p_dia, p_za, x.chave, 'validada', x.hash, auth.uid(), v_nome, now(), x.antes from x
   where (x.val is null or jsonb_typeof(x.val) = 'null' or (x.val->>'ok')::boolean is not true) and not x.sa
  on conflict (dia, za, chave) do update set status = 'validada',
    hash = excluded.hash, por = excluded.por, por_nome = excluded.por_nome, em = excluded.em, antes = excluded.antes;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'n', n);
end $function$;

-- passado: resumo tirado do snapshot do dia validado (linhas + obras)
update "12 - retaguarda".fisc_linha_val v
   set antes = public.fisc_val_resumo(s.x)
  from (select f.dia, f.za, x
          from "12 - retaguarda".fisc_dia f,
               jsonb_array_elements(coalesce(f.snapshot->'linhas', '[]') || coalesce(f.snapshot->'projetos', '[]')) x) s
 where v.antes is null and v.dia = s.dia and v.za = s.za and v.chave = s.x->>'chave';
