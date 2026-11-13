-- Consolidador — VRP em duas atividades (2026-11-13, pedido do usuário: "quero que seja padrão")
--   'Vistoria primária de VRP' = visita primária do app (app:vrp_visita:*)            → fisc_ordem 30
--   'Manutenção de VRP'        = OS de manutenção (app:vrp_os:* e OS SIGOS de VRP)      → fisc_ordem 31
-- Só fisc_execucoes muda (RDO/Vitrine não usam). A chave da linha muda ('atv:VRP' → as duas novas), então:
--   * linha 'atv:VRP' validada e em dia → as duas linhas novas nascem validadas (mesmo autor/data);
--   * dia validado que estava em dia → snapshot e hash refeitos (mesmo autor/data) — continua validado;
--   * o que já estava "mudou"/pendente continua assim.
-- Backups: "12 - retaguarda"._bkp_fisc_linha_val_vrp_20261113, _bkp_fisc_dia_vrp_20261113.

create table if not exists "12 - retaguarda"._bkp_fisc_linha_val_vrp_20261113 as select * from "12 - retaguarda".fisc_linha_val where chave = 'atv:VRP';
create table if not exists "12 - retaguarda"._bkp_fisc_dia_vrp_20261113 as select * from "12 - retaguarda".fisc_dia;

-- Tudo num bloco, dia a dia (fisc_dia_dados ~3 s/dia: calcula cada dia uma vez antes e uma depois da troca).
-- Testado com rollback em 13/11 (3 dias de amostra: em dia antes = em dia depois, linhas migradas, snapshot com a atividade nova).
create or replace function public.fisc_ordem(p_atividade text)
 returns integer language sql immutable as $function$
  select case p_atividade
    when 'Pesquisa de vazamento' then 10 when 'Correção de vazamento' then 12
    when 'Logger temporário — instalação' then 20 when 'Logger temporário — remoção' then 21
    when 'Logger fixo — instalação' then 22 when 'Logger fixo — remoção' then 23
    when 'Loggers de pressão' then 20 when 'Mapeamento de pressão' then 25
    when 'Vistoria primária de VRP' then 30 when 'Manutenção de VRP' then 31
    else public.rdo_familia_ordem(p_atividade) end;
$function$;

do $mig$
declare d text; a text; b text; k record; dd jsonb;
begin
  -- estado ANTES da troca: dias validados em dia (que têm VRP) e linhas 'atv:VRP' validadas em dia
  create temp table _dia_ok (dia date, za text) on commit drop;
  for k in select dia, za, hash from "12 - retaguarda".fisc_dia where snapshot::text like '%"atividade": "VRP"%' loop
    if k.hash = public.fisc_dia_hash(public.fisc_dia_dados(k.dia, k.za)) then insert into _dia_ok values (k.dia, k.za); end if;
  end loop;
  create temp table _vrp_ok on commit drop as select * from "12 - retaguarda".fisc_linha_val where false;
  for k in select * from "12 - retaguarda".fisc_linha_val where chave = 'atv:VRP' and status = 'validada' loop
    if k.hash = (select l.hash from public.fisc_linhas(k.dia, k.dia, k.za) l where l.chave = 'atv:VRP') then
      insert into _vrp_ok select * from "12 - retaguarda".fisc_linha_val where dia = k.dia and za = k.za and chave = 'atv:VRP'; end if;
  end loop;

  -- fisc_execucoes: VRP → visita primária do app × OS de manutenção (app ou SIGOS)
  d := pg_get_functiondef('public.fisc_execucoes(date,date)'::regprocedure);
  if position('Vistoria primária de VRP' in d) = 0 then
    a := $x$  select t.d, t.z, t.atv, public.fisc_ordem(t.atv), t.eid,$x$;
    b := $x$  select t.d, t.z, x.a, public.fisc_ordem(x.a), t.eid,$x$;
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'trecho 1 não achado'; end if;
    d := replace(d, a, b);
    a := $x$    from todas t(d, z, atv, eid, ori, srv, dsc, loc, eq, hr, q, un, osa, oss, sst, ft, g, ex)$x$;
    b := a || $x$
    -- VRP em duas atividades (2026-11-13): visita primária do app × OS de manutenção (app ou SIGOS)
    cross join lateral (select case when t.atv = 'VRP' then case when t.eid like 'app:vrp_visita:%' then 'Vistoria primária de VRP'
                                                               else 'Manutenção de VRP' end else t.atv end a) x$x$;
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'trecho 2 não achado'; end if;
    execute replace(d, a, b);
  end if;

  -- linhas: as validações de 'atv:VRP' em dia passam para as chaves novas (mesmo autor/data/obs)
  for k in select * from _vrp_ok loop
    insert into "12 - retaguarda".fisc_linha_val(dia, za, chave, status, hash, obs, por, por_nome, em)
    select k.dia, k.za, l.chave, 'validada', l.hash, k.obs, k.por, k.por_nome, k.em
      from public.fisc_linhas(k.dia, k.dia, k.za) l where l.chave in ('atv:Vistoria primária de VRP', 'atv:Manutenção de VRP')
    on conflict (dia, za, chave) do update set status = 'validada', hash = excluded.hash, obs = excluded.obs,
      por = excluded.por, por_nome = excluded.por_nome, em = excluded.em;
  end loop;
  delete from "12 - retaguarda".fisc_linha_val where chave = 'atv:VRP';

  -- dias validados que estavam em dia: snapshot e hash refeitos (mesma regra do app_fisc_dia_validar), autor/data mantidos
  for k in select * from _dia_ok loop
    dd := public.fisc_dia_dados(k.dia, k.za);
    update "12 - retaguarda".fisc_dia f set hash = public.fisc_dia_hash(dd),
      snapshot = jsonb_build_object('dia', f.dia, 'za', f.za,
        'linhas', coalesce((select jsonb_agg(x - 'val' - 'hash') from jsonb_array_elements(dd->'linhas') x where x->'val'->>'status' = 'validada'), '[]'::jsonb),
        'projetos', coalesce((select jsonb_agg(x - 'val' - 'hash') from jsonb_array_elements(dd->'projetos') x where x->'val'->>'status' = 'validada' or public.fisc_sem_avanco(x)), '[]'::jsonb))
     where f.dia = k.dia and f.za = k.za;
  end loop;
end $mig$;
