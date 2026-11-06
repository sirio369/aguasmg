-- =====================================================================================================
-- SIGOS — tela "OS não executadas" (Auxiliar de Programação) · localização das OS abertas
-- Depende de docs/migracao_sigos_carga.sql (schema "17 - sigos").  MODULOS §21.1
--
-- Localização de cada OS aberta (o relatório Relação NÃO traz coordenada), em ordem de prioridade:
--   1. cadastro  — ponto da matrícula em "3 - comercial".ligacoes
--   2. manual    — ponto fixado à mão pelo programador na tela (vale p/ o endereço em todas as cargas)
--   3. osm       — geocodificação do endereço no OpenStreetMap (Nominatim) pela Edge Function
--                  `sigos-geocode`; só o endereço sai do banco (sem nome/matrícula). Cache por endereço.
--   sem ponto    — vai p/ a "Fila sem localização" da tela.
-- O cache `geo_endereco` é por ENDEREÇO normalizado (tipo|rua|nº|bairro|cidade, sem complemento/CEP),
-- então uma nova carga da Relação reaproveita tudo o que já foi localizado.
-- pg_safeupdate: todo UPDATE/DELETE aqui tem WHERE (as RPCs rodam via PostgREST).
-- =====================================================================================================

-- ---------- endereço SIGOS → partes / chave ----------
-- Formato: "R. SAO GERALDO,62 (CAA) - SAO GOTARDO , CONTAGEM- MG, 32110-390"
-- plpgsql (plano em cache): como função SQL com SET search_path não é "inlinada" e é replanejada a
-- cada chamada (~3 ms/linha → 10 s na carteira toda).
create or replace function "17 - sigos".end_partes(p text)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare m text[];
begin
  m := pg_catalog.regexp_match(pg_catalog.upper(coalesce(p, '')),
     '^\s*([A-Z]+)\.?\s+(.+?)\s*,\s*(\d*)[^-]*-\s*(.+?)\s*,\s*([^,]+?)\s*-\s*MG\s*,?\s*([0-9-]*)');
  if m is null then return null; end if;
  return pg_catalog.jsonb_build_object(
    'tipo', m[1], 'rua', pg_catalog.btrim(m[2]), 'num', nullif(nullif(m[3], ''), '0'),
    'bairro', pg_catalog.btrim(m[4]), 'cidade', pg_catalog.btrim(m[5]), 'cep', m[6]);
end $$;

create or replace function "17 - sigos".end_chave(p text)
returns text language plpgsql immutable set search_path = '' as $$
declare m text[];
begin
  m := pg_catalog.regexp_match(pg_catalog.upper(coalesce(p, '')),
     '^\s*([A-Z]+)\.?\s+(.+?)\s*,\s*(\d*)[^-]*-\s*(.+?)\s*,\s*([^,]+?)\s*-\s*MG');
  if m is null then
    return nullif(pg_catalog.upper(pg_catalog.btrim(pg_catalog.regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'))), '');
  end if;
  return pg_catalog.concat_ws('|', m[1], pg_catalog.btrim(m[2]), coalesce(nullif(m[3], '0'), ''),
                              pg_catalog.btrim(m[4]), pg_catalog.btrim(m[5]));
end $$;

-- ---------- cache de localização por endereço ----------
create table if not exists "17 - sigos".geo_endereco (
  chave          text primary key,
  consorcio      text,
  endereco       text,                       -- um exemplo do texto original (p/ conferência)
  geom           geometry(Point, 31983),
  fonte          text not null check (fonte in ('osm', 'manual', 'nao_achou')),
  precisao       text check (precisao in ('numero', 'rua', 'manual')),
  detalhe        text,                       -- display_name do OSM / observação
  tentativas     int not null default 0,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);
alter table "17 - sigos".geo_endereco enable row level security;
create index if not exists geo_endereco_geom_idx on "17 - sigos".geo_endereco using gist (geom);

-- ---------- gate: quem usa a tela (Auxiliar de Programação) ----------
create or replace function public.sigos_pode_ver(p_uid uuid)
returns boolean language sql stable security definer set search_path = 'public' as $$
  select p_uid is not null and exists(select 1 from public.perfil
    where id = p_uid and coalesce(ativo, true) and (funcao = 'admin' or coalesce(aux_acesso, false)));
$$;

-- ---------- carteira aberta p/ a tela ----------
-- Devolve tudo de uma vez (≈3,3 mil OS); filtros, polígono e CSV são feitos no app.
create or replace function public.app_sigos_abertas()
returns jsonb language plpgsql stable security definer set search_path = 'public', '17 - sigos' as $$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;

  with o as (
    select a.*, f.enviado_em as carteira_de, "17 - sigos".end_chave(a.endereco) as chave,
           ((now() at time zone 'America/Sao_Paulo')::date - a.abertura::date) as idade
    from os_aberta a join arquivo f on f.id = a.arquivo_id
  ),
  nmat as (select matricula, count(*) n from os_aberta where matricula > 0 group by 1 having count(*) > 1),
  x as (
    select o.*, lg.geom as g_cad, lg.setor, lg.rota, lg.bairro_cad,
           ge.geom as g_end, ge.fonte as f_end, ge.precisao as p_end,
           nm.n as n_mat,
           (select jsonb_build_object('os', e.numero, 'srv', e.desc_servico, 'em', e.execucao)
              from os_encerrada e
             where o.matricula > 0 and e.matricula = o.matricula and e.execucao >= o.abertura
             order by e.execucao desc limit 1) as enc_depois
    from o
    left join lateral (
      select l.geom, l.setor, l.rota,
             (select b.nome from "1 - suporte_geografico".bairros b
               where b.cd_localidade = l.cd_localidade || lpad(l.cd_bairro::text, 6, '0') limit 1) as bairro_cad
        from "3 - comercial".ligacoes l
       where o.matricula > 0 and l.matricula = o.matricula and l.geom is not null
       limit 1) lg on true
    left join geo_endereco ge on ge.chave = o.chave and ge.geom is not null
    left join nmat nm on nm.matricula = o.matricula
  ),
  y as (
    select x.*, coalesce(g_cad, g_end) as g,
           case when g_cad is not null then 'cadastro' when g_end is not null then f_end end as gf,
           case when g_cad is not null then 'numero' else p_end end as gp
    from x
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'carteiras', (select jsonb_object_agg(consorcio, carteira_de) from (select distinct consorcio, carteira_de from o) c),
    'itens', coalesce(jsonb_agg(jsonb_build_object(
      'n', numero, 'za', consorcio, 'cod', cod_servico, 'srv', desc_servico, 'cls', classificacao,
      'st', status, 'eq', equipe, 'resp', responsavel, 'ta', tipo_atendimento,
      'mat', matricula, 'end', endereco,
      'bai', coalesce(bairro_cad, "17 - sigos".end_partes(endereco)->>'bairro'),
      'setor', setor, 'rota', rota,
      'ab', abertura, 'lim', limite, 'encp', enc_previsto, 'encr', enc_realizado,
      'vis', coalesce(visitas, 0), 'rk', ranqueamento, 'orig', desc_os_origem,
      'idade', idade,
      'lat', round(ST_Y(ST_Transform(g, 4326))::numeric, 6),
      'lon', round(ST_X(ST_Transform(g, 4326))::numeric, 6),
      'gf', gf, 'gp', gp, 'chave', chave,
      'nmat', coalesce(n_mat, 1),
      'exec_sigos', (status ilike 'EXECUTADA%' or enc_realizado is not null),
      'enc_depois', enc_depois
    ) order by idade desc nulls last), '[]'::jsonb)
  ) into r
  from y;
  return r;
end $$;

-- ---------- geocodificação: fila de endereços pendentes ----------
-- Endereços de OS abertas sem ponto no cadastro e ainda sem cache (ou "não achou" há mais de 7 dias,
-- até 3 tentativas). Devolve as partes já separadas p/ a Edge Function montar a busca.
create or replace function public.app_sigos_geo_pendentes(p_limite int default 20)
returns jsonb language plpgsql stable security definer set search_path = 'public', '17 - sigos' as $$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  with p as (
    select distinct on (ch) ch as chave, a.consorcio, a.endereco
    from (select a.*, "17 - sigos".end_chave(a.endereco) ch from os_aberta a) a
    where ch is not null
      and not exists (select 1 from "3 - comercial".ligacoes l
                       where a.matricula > 0 and l.matricula = a.matricula and l.geom is not null)
      and not exists (select 1 from geo_endereco g where g.chave = a.ch
                       and (g.fonte <> 'nao_achou' or g.tentativas >= 3 or g.atualizado_em > now() - interval '7 days'))
    order by ch
  )
  select jsonb_build_object(
    'total', (select count(*) from p),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('chave', chave, 'za', consorcio, 'endereco', endereco,
                                                           'partes', "17 - sigos".end_partes(endereco)))
                         from (select * from p limit greatest(1, least(coalesce(p_limite, 20), 60))) q), '[]'::jsonb))
  into r;
  return r;
end $$;

-- ---------- geocodificação: grava resultados da Edge Function ----------
-- p_itens: [{chave, za, endereco, lat, lon, precisao:'numero'|'rua', detalhe} | {chave, za, endereco, nao_achou:true}]
-- Nunca sobrescreve ponto 'manual'.
create or replace function public.app_sigos_geo_gravar(p_itens jsonb)
returns int language plpgsql volatile security definer set search_path = 'public', '17 - sigos' as $$
declare i jsonb; n int := 0; v_g geometry;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  for i in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    continue when coalesce(i->>'chave', '') = '';
    v_g := null;
    if not coalesce((i->>'nao_achou')::boolean, false) and i ? 'lat' and i ? 'lon' then
      v_g := ST_Transform(ST_SetSRID(ST_MakePoint((i->>'lon')::float8, (i->>'lat')::float8), 4326), 31983);
    end if;
    insert into geo_endereco as g (chave, consorcio, endereco, geom, fonte, precisao, detalhe, tentativas, atualizado_em, atualizado_por)
    values (i->>'chave', i->>'za', left(i->>'endereco', 300), v_g,
            case when v_g is null then 'nao_achou' else 'osm' end,
            case when v_g is null then null when i->>'precisao' = 'numero' then 'numero' else 'rua' end,
            left(i->>'detalhe', 300), 1, now(), auth.uid())
    on conflict (chave) do update set
      geom = excluded.geom, fonte = excluded.fonte, precisao = excluded.precisao, detalhe = excluded.detalhe,
      consorcio = excluded.consorcio, endereco = excluded.endereco,
      tentativas = g.tentativas + 1, atualizado_em = now(), atualizado_por = auth.uid()
    where g.fonte <> 'manual';
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- ponto manual (programador clica no mapa) ----------
-- p_lat/p_lon nulos = remove o ponto manual (o endereço volta p/ a fila de geocodificação).
create or replace function public.app_sigos_geo_manual(p_chave text, p_lat float8, p_lon float8,
                                                       p_za text default null, p_endereco text default null)
returns void language plpgsql volatile security definer set search_path = 'public', '17 - sigos' as $$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  if coalesce(p_chave, '') = '' then raise exception 'endereço inválido'; end if;
  if p_lat is null or p_lon is null then
    delete from geo_endereco where chave = p_chave and fonte = 'manual';
    return;
  end if;
  if p_lat not between -21 and -18 or p_lon not between -46 and -42 then raise exception 'ponto fora da região'; end if;
  insert into geo_endereco as g (chave, consorcio, endereco, geom, fonte, precisao, detalhe, tentativas, atualizado_em, atualizado_por)
  values (p_chave, p_za, left(p_endereco, 300),
          ST_Transform(ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326), 31983), 'manual', 'manual', null, 0, now(), auth.uid())
  on conflict (chave) do update set geom = excluded.geom, fonte = 'manual', precisao = 'manual', detalhe = null,
    consorcio = coalesce(excluded.consorcio, g.consorcio), endereco = coalesce(excluded.endereco, g.endereco),
    atualizado_em = now(), atualizado_por = auth.uid()
  where true;
end $$;

revoke all on function public.app_sigos_abertas() from public, anon;
revoke all on function public.app_sigos_geo_pendentes(int) from public, anon;
revoke all on function public.app_sigos_geo_gravar(jsonb) from public, anon;
revoke all on function public.app_sigos_geo_manual(text, float8, float8, text, text) from public, anon;
revoke all on function public.sigos_pode_ver(uuid) from public, anon;
grant execute on function public.app_sigos_abertas() to authenticated;
grant execute on function public.app_sigos_geo_pendentes(int) to authenticated;
grant execute on function public.app_sigos_geo_gravar(jsonb) to authenticated;
grant execute on function public.app_sigos_geo_manual(text, float8, float8, text, text) to authenticated;
grant execute on function public.sigos_pode_ver(uuid) to authenticated;

-- QGIS/BI: localização efetiva das OS abertas (mesma prioridade da tela)
create or replace view "17 - sigos".vw_os_aberta_local as
select v.*, coalesce(lg.geom, ge.geom) as geom,
       case when lg.geom is not null then 'cadastro' else ge.fonte end as geo_fonte,
       case when lg.geom is not null then 'numero' else ge.precisao end as geo_precisao
from "17 - sigos".vw_os_aberta v
left join lateral (select l.geom from "3 - comercial".ligacoes l
                    where v.matricula > 0 and l.matricula = v.matricula and l.geom is not null limit 1) lg on true
left join "17 - sigos".geo_endereco ge on ge.chave = "17 - sigos".end_chave(v.endereco) and ge.geom is not null;
grant select on "17 - sigos".vw_os_aberta_local to bi_sigos_leitura;
