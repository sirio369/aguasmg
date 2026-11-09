-- =====================================================================
-- Isolamento de trecho por válvulas (2026-11-09)
-- "Vazamento no trecho X → quais válvulas fechar para parar a água ali"
--
-- Grafo próprio de isolamento, derivado da rede + nós (não altera a rede):
--   "2 - infra_agua".isolamento_valvula  — cada válvula de manobra e como ela
--       foi encaixada no grafo (modo no / ponte / corte / fora)
--   "2 - infra_agua".isolamento_aresta   — arestas do grafo (trecho inteiro,
--       pedaço de trecho cortado por válvula, ou "ponte" = vão de válvula)
--   "2 - infra_agua".isolamento_recalcular() — refaz as duas tabelas.
--       RODAR DE NOVO a cada carga de rede/nós (scripts de atualização do cadastro).
--   public.app_isolamento_trecho(...)    — RPC do app (Cadastro técnico).
--
-- Válvulas consideradas: REG, ALM, RGF, VBO, RGA, RGD (decisão do usuário).
-- Fora: VRP (não é manobra), DSC (descarga), trechos com situacao 'D' (desativados).
-- Trechos 'C' (em construção/recém-implantados) ENTRAM: se a rede nova já estiver
-- ligada e ficasse de fora, a água continuaria chegando ao vazamento.
-- Válvula com estado F entra na lista com o aviso "confirmar em campo".
--
-- Encaixe de válvula que não é nó de nenhum trecho (RGF/VBO/RGA/RGD quase todas):
--   ponte : está no vão entre 2 nós da rede (≤3 m) que não são ligados entre si
--           e um deles é ponta (grau 1) → arestas n1–válvula–n2 (a válvula é a
--           única ligação entre os dois lados). ~1.000 casos.
--   corte : está sobre um trecho (≤3 m) → o trecho vira pedaços a–válvula–b.
--   fora  : nada a ≤3 m → ignorada (aparece só no relatório).
-- Válvula que já é nó (REG/ALM com trecho): modo no; se for ponta (grau 1) com
-- outra ponta não ligada a ≤3 m, ganha também a ponte até ela.
-- =====================================================================

create table if not exists "2 - infra_agua".isolamento_valvula (
  cd_no_agua text primary key,
  consorcio  text not null,
  tipo       text not null,          -- prefixo REG/ALM/RGF/VBO/RGA/RGD
  estado     text,                   -- A / F (cadastro)
  diametro   integer,
  modo       text not null,          -- no | ponte | corte | fora
  no_1       text,                   -- ponte: nós ligados pela válvula
  no_2       text,
  nu_trecho  bigint,                 -- corte: trecho cortado
  frac       double precision,       -- corte: posição no trecho (0..1, sentido da geometria)
  dist_m     double precision,       -- distância da válvula até o grafo
  geom       geometry(Point,31983)
);
create table if not exists "2 - infra_agua".isolamento_aresta (
  id        bigserial primary key,
  consorcio text not null,
  nu_trecho bigint,                  -- null = ponte de válvula
  a         text not null,
  b         text not null,
  f0        double precision,        -- trecho: fração inicial/final na geometria
  f1        double precision
);
create index if not exists isolamento_aresta_a_idx on "2 - infra_agua".isolamento_aresta (consorcio, a);
create index if not exists isolamento_aresta_b_idx on "2 - infra_agua".isolamento_aresta (consorcio, b);
create index if not exists isolamento_aresta_trecho_idx on "2 - infra_agua".isolamento_aresta (nu_trecho);
alter table "2 - infra_agua".isolamento_valvula enable row level security;
alter table "2 - infra_agua".isolamento_aresta  enable row level security;
grant select on "2 - infra_agua".isolamento_valvula, "2 - infra_agua".isolamento_aresta to gis_visualizacao;
comment on table "2 - infra_agua".isolamento_valvula is 'Válvulas de manobra encaixadas no grafo de isolamento (modo no/ponte/corte/fora). Saída de isolamento_recalcular() — não editar à mão.';
comment on table "2 - infra_agua".isolamento_aresta  is 'Arestas do grafo de isolamento (trecho, pedaço de trecho cortado por válvula, ou ponte de válvula). Saída de isolamento_recalcular() — não editar à mão.';

create or replace function "2 - infra_agua".isolamento_recalcular()
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare r jsonb;
begin
  truncate "2 - infra_agua".isolamento_aresta restart identity;
  truncate "2 - infra_agua".isolamento_valvula;

  -- rede ativa (fora só desativada) com a linha simples e qual nó está no início da geometria
  create temp table _iso_rede on commit drop as
  select r.consorcio, r.nu_trecho, r.no_agua_ini, r.no_agua_fim,
         st_geometryn(st_linemerge(r.geom),1) g,
         case when ni.geom is not null and nf.geom is not null
                   and st_distance(st_startpoint(st_geometryn(st_linemerge(r.geom),1)), nf.geom)
                     < st_distance(st_startpoint(st_geometryn(st_linemerge(r.geom),1)), ni.geom)
              then true else false end inv            -- geometria desenhada de fim→ini
  from "2 - infra_agua".rede r
  left join "2 - infra_agua".nos_agua ni on ni.cd_no_agua=r.no_agua_ini
  left join "2 - infra_agua".nos_agua nf on nf.cd_no_agua=r.no_agua_fim
  where coalesce(r.situacao,'O')<>'D' and r.no_agua_ini is not null and r.no_agua_fim is not null;
  create index on _iso_rede using gist (g);

  -- nós do grafo com grau
  create temp table _iso_no on commit drop as
  select x.consorcio, x.no, count(*) grau, n.geom
  from (select consorcio, no_agua_ini no from _iso_rede union all select consorcio, no_agua_fim from _iso_rede) x
  join "2 - infra_agua".nos_agua n on n.cd_no_agua=x.no
  group by x.consorcio, x.no, n.geom;
  create index on _iso_no using gist (geom);
  create index on _iso_no (no);

  -- pares de nós ligados diretamente por trecho (p/ saber se 2 nós próximos já estão ligados)
  create temp table _iso_adj on commit drop as
  select no_agua_ini a, no_agua_fim b from _iso_rede union select no_agua_fim, no_agua_ini from _iso_rede;
  create index on _iso_adj (a,b);

  -- válvulas candidatas
  create temp table _iso_v on commit drop as
  select n.cd_no_agua, n.consorcio, left(n.cd_no_agua,3) tipo, n.estado, n.diametro, n.geom,
         g.grau
  from "2 - infra_agua".nos_agua n
  left join _iso_no g on g.no=n.cd_no_agua
  where left(n.cd_no_agua,3) in ('REG','ALM','RGF','VBO','RGA','RGD') and n.geom is not null;

  -- 1) ponte: 2 nós do grafo a ≤3 m, não ligados entre si, ao menos um de grau 1
  --    (para válvula que já é nó: n1 = ela mesma)
  insert into "2 - infra_agua".isolamento_valvula (cd_no_agua,consorcio,tipo,estado,diametro,modo,no_1,no_2,dist_m,geom)
  select v.cd_no_agua, v.consorcio, v.tipo, v.estado, v.diametro, 'ponte', p.n1, p.n2, p.d1, v.geom
  from _iso_v v
  cross join lateral (
    select a.no n1, b.no n2, st_distance(a.geom,v.geom) d1
    from _iso_no a join _iso_no b on b.consorcio=a.consorcio and b.no<>a.no
    where a.consorcio=v.consorcio
      and st_dwithin(a.geom,v.geom,3) and st_dwithin(b.geom,v.geom,3)
      and (v.grau is null or a.no=v.cd_no_agua)                  -- válvula-nó: a ponte parte dela
      and (a.grau=1 or b.grau=1)
      and not exists (select 1 from _iso_adj j where j.a=a.no and j.b=b.no)
      and b.no<>v.cd_no_agua
    order by st_distance(a.geom,v.geom)+st_distance(b.geom,v.geom) limit 1) p
  where v.grau is null or v.grau=1;

  -- 2) válvula que já é nó (e não virou ponte)
  insert into "2 - infra_agua".isolamento_valvula (cd_no_agua,consorcio,tipo,estado,diametro,modo,dist_m,geom)
  select v.cd_no_agua, v.consorcio, v.tipo, v.estado, v.diametro, 'no', 0, v.geom
  from _iso_v v where v.grau is not null
    and not exists (select 1 from "2 - infra_agua".isolamento_valvula i where i.cd_no_agua=v.cd_no_agua);

  -- 3) corte: sobre um trecho a ≤3 m
  insert into "2 - infra_agua".isolamento_valvula (cd_no_agua,consorcio,tipo,estado,diametro,modo,nu_trecho,frac,dist_m,geom)
  select v.cd_no_agua, v.consorcio, v.tipo, v.estado, v.diametro, 'corte', t.nu_trecho,
         st_linelocatepoint(t.g, v.geom), st_distance(t.g, v.geom), v.geom
  from _iso_v v
  cross join lateral (select r.nu_trecho, r.g from _iso_rede r where r.consorcio=v.consorcio
                      order by r.g <-> v.geom limit 1) t
  where v.grau is null
    and not exists (select 1 from "2 - infra_agua".isolamento_valvula i where i.cd_no_agua=v.cd_no_agua)
    and st_dwithin(t.g, v.geom, 3);

  -- 4) fora (registro)
  insert into "2 - infra_agua".isolamento_valvula (cd_no_agua,consorcio,tipo,estado,diametro,modo,geom)
  select v.cd_no_agua, v.consorcio, v.tipo, v.estado, v.diametro, 'fora', v.geom
  from _iso_v v where not exists (select 1 from "2 - infra_agua".isolamento_valvula i where i.cd_no_agua=v.cd_no_agua);

  -- arestas: trechos sem corte = inteiros
  insert into "2 - infra_agua".isolamento_aresta (consorcio,nu_trecho,a,b,f0,f1)
  select r.consorcio, r.nu_trecho,
         case when r.inv then r.no_agua_fim else r.no_agua_ini end,
         case when r.inv then r.no_agua_ini else r.no_agua_fim end, 0, 1
  from _iso_rede r
  where not exists (select 1 from "2 - infra_agua".isolamento_valvula i where i.modo='corte' and i.nu_trecho=r.nu_trecho);

  -- trechos com corte: início → v1 → v2 → … → fim, no sentido da geometria
  insert into "2 - infra_agua".isolamento_aresta (consorcio,nu_trecho,a,b,f0,f1)
  select s.consorcio, s.nu_trecho, s.no, s.prox_no, s.f, s.prox_f
  from (
    select q.*, lead(q.no) over w prox_no, lead(q.f) over w prox_f
    from (
      select r.consorcio, r.nu_trecho, case when r.inv then r.no_agua_fim else r.no_agua_ini end no, 0::float8 f, 0 ord from _iso_rede r
        where exists (select 1 from "2 - infra_agua".isolamento_valvula i where i.modo='corte' and i.nu_trecho=r.nu_trecho)
      union all
      select i.consorcio, i.nu_trecho, i.cd_no_agua, i.frac, 1 from "2 - infra_agua".isolamento_valvula i where i.modo='corte'
      union all
      select r.consorcio, r.nu_trecho, case when r.inv then r.no_agua_ini else r.no_agua_fim end, 1::float8, 2 from _iso_rede r
        where exists (select 1 from "2 - infra_agua".isolamento_valvula i where i.modo='corte' and i.nu_trecho=r.nu_trecho)
    ) q
    window w as (partition by q.nu_trecho order by q.f, q.ord)
  ) s where s.prox_no is not null;

  -- pontes de válvula
  insert into "2 - infra_agua".isolamento_aresta (consorcio,nu_trecho,a,b)
  select consorcio, null::bigint, no_1, cd_no_agua from "2 - infra_agua".isolamento_valvula where modo='ponte' and no_1<>cd_no_agua
  union all
  select consorcio, null, cd_no_agua, no_2 from "2 - infra_agua".isolamento_valvula where modo='ponte';

  select jsonb_build_object(
    'valvulas', (select jsonb_object_agg(modo, n) from (select modo, count(*) n from "2 - infra_agua".isolamento_valvula group by 1) x),
    'arestas',  (select count(*) from "2 - infra_agua".isolamento_aresta)) into r;
  return r;
end $$;
revoke all on function "2 - infra_agua".isolamento_recalcular() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- RPC do app: isolamento de um trecho
--   p_nu_trecho  trecho com vazamento
--   p_lat/p_lon  ponto do vazamento (opcional): se o trecho tem válvula no meio,
--                escolhe o pedaço onde está o ponto
--   p_falhas     válvulas que "não operam" → viram tubo e o isolamento expande
-- Retorna {trecho, consorcio, valvulas:[…], falhas, pontas_soltas:[…], valvulas_fora:[…],
--          area:FeatureCollection, metros, n_trechos}
-- ---------------------------------------------------------------------
create or replace function public.app_isolamento_trecho(
  p_nu_trecho bigint, p_lat double precision default null, p_lon double precision default null,
  p_falhas text[] default '{}')
returns jsonb language plpgsql stable security definer set search_path to 'public','extensions' as $$
declare v_cons text; v_frac double precision; v_seeds text[]; v_res jsonb;
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  select consorcio into v_cons from "2 - infra_agua".isolamento_aresta where nu_trecho=p_nu_trecho limit 1;
  if v_cons is null then raise exception 'Trecho % fora do grafo de isolamento (desativado ou sem nós).', p_nu_trecho; end if;
  p_falhas := coalesce(p_falhas,'{}');

  -- ponto do vazamento → fração no trecho (só importa se o trecho foi cortado por válvula)
  if p_lat is not null and p_lon is not null then
    select st_linelocatepoint(st_geometryn(st_linemerge(r.geom),1), st_transform(st_setsrid(st_makepoint(p_lon,p_lat),4326),31983))
      into v_frac from "2 - infra_agua".rede r where r.nu_trecho=p_nu_trecho;
  end if;

  select array_agg(distinct x) into v_seeds from (
    select unnest(array[e.a,e.b]) x from "2 - infra_agua".isolamento_aresta e
    where e.nu_trecho=p_nu_trecho
      and (v_frac is null or (v_frac>=e.f0 and v_frac<=e.f1))) s;

  with recursive
  bar as (select cd_no_agua from "2 - infra_agua".isolamento_valvula
          where consorcio=v_cons and modo<>'fora' and not (cd_no_agua = any(p_falhas))),
  walk(no) as (
    select unnest(v_seeds)
    union
    select case when e.a=w.no then e.b else e.a end
    from walk w join "2 - infra_agua".isolamento_aresta e
      on e.consorcio=v_cons and (e.a=w.no or e.b=w.no)
    where not exists (select 1 from bar where bar.cd_no_agua=w.no)
  ),
  -- arestas alagadas: tocam um nó alcançado que não é barreira (+ o próprio pedaço do vazamento)
  livre as (select w.no from walk w where not exists (select 1 from bar where bar.cd_no_agua=w.no)),
  ar as (
    select e.id, e.nu_trecho, e.f0, e.f1 from "2 - infra_agua".isolamento_aresta e join livre l on l.no=e.a
      where e.consorcio=v_cons and e.nu_trecho is not null
    union
    select e.id, e.nu_trecho, e.f0, e.f1 from "2 - infra_agua".isolamento_aresta e join livre l on l.no=e.b
      where e.consorcio=v_cons and e.nu_trecho is not null
    union
    select e.id, e.nu_trecho, e.f0, e.f1 from "2 - infra_agua".isolamento_aresta e
      where e.nu_trecho=p_nu_trecho and (v_frac is null or (v_frac>=e.f0 and v_frac<=e.f1))
  ),
  geo as (
    select a.nu_trecho, st_linesubstring(st_geometryn(st_linemerge(r.geom),1), a.f0, a.f1) g, r.diametro
    from ar a join "2 - infra_agua".rede r on r.nu_trecho=a.nu_trecho
  ),
  -- alerta: ponta solta da área (grau 1) encostada (≤1 m) num trecho de fora → possível entrada de água sem válvula
  ponta as (
    select l.no, n.geom from livre l
    join "2 - infra_agua".nos_agua n on n.cd_no_agua=l.no
    where (select count(*) from "2 - infra_agua".isolamento_aresta e where e.consorcio=v_cons and (e.a=l.no or e.b=l.no))=1
      and exists (select 1 from "2 - infra_agua".rede r where r.consorcio=v_cons and coalesce(r.situacao,'O')<>'D'
                  and st_dwithin(r.geom,n.geom,1) and r.nu_trecho not in (select nu_trecho from ar))
  ),
  -- alerta: válvula sem rede a ≤3 m (modo fora) perto (≤10 m) da área
  fora as (
    select i.cd_no_agua, i.tipo, i.estado, i.geom from "2 - infra_agua".isolamento_valvula i
    where i.consorcio=v_cons and i.modo='fora' and exists (select 1 from geo where st_dwithin(geo.g, i.geom, 10))
  ),
  vv as (
    select i.*, st_distance(i.geom, (select st_geometryn(st_linemerge(geom),1) from "2 - infra_agua".rede where nu_trecho=p_nu_trecho)) dist
    from "2 - infra_agua".isolamento_valvula i join walk w on w.no=i.cd_no_agua
    where i.consorcio=v_cons and i.modo<>'fora' and not (i.cd_no_agua = any(p_falhas))
  )
  select jsonb_build_object(
    'trecho', p_nu_trecho, 'consorcio', v_cons,
    'valvulas', coalesce((select jsonb_agg(jsonb_build_object(
        'codigo', vv.cd_no_agua, 'tipo', vv.tipo, 'estado', vv.estado, 'diametro', vv.diametro,
        'dist_m', round(vv.dist::numeric), 'encaixe', vv.modo,
        'lat', st_y(st_transform(vv.geom,4326)), 'lon', st_x(st_transform(vv.geom,4326)))
        order by (vv.estado='F'), vv.dist) from vv), '[]'::jsonb),
    'falhas', to_jsonb(p_falhas),
    'pontas_soltas', coalesce((select jsonb_agg(jsonb_build_object('no', no,
        'lat', st_y(st_transform(geom,4326)), 'lon', st_x(st_transform(geom,4326)))) from ponta), '[]'::jsonb),
    'valvulas_fora', coalesce((select jsonb_agg(jsonb_build_object('codigo', cd_no_agua, 'tipo', tipo, 'estado', estado,
        'lat', st_y(st_transform(geom,4326)), 'lon', st_x(st_transform(geom,4326)))) from fora), '[]'::jsonb),
    'metros', (select round(sum(st_length(g))::numeric) from geo),
    'n_trechos', (select count(distinct nu_trecho) from geo),
    'area', jsonb_build_object('type','FeatureCollection','features', coalesce((select jsonb_agg(jsonb_build_object(
        'type','Feature','geometry', st_asgeojson(st_transform(g,4326),6)::jsonb,
        'properties', jsonb_build_object('trecho', nu_trecho, 'diametro', diametro))) from geo), '[]'::jsonb))
  ) into v_res;
  return v_res;
end $$;
revoke all on function public.app_isolamento_trecho(bigint,double precision,double precision,text[]) from public, anon;
grant execute on function public.app_isolamento_trecho(bigint,double precision,double precision,text[]) to authenticated;

select "2 - infra_agua".isolamento_recalcular();
