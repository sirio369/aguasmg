-- Ponto crítico de cada VRP (par VRP × ponto crítico) — 2026-11-18
-- Fonte: modelo hidráulico ZA0200 (MH_ZA0200_Resumo_Atualizado.gpkg, camada pontos_criticos).
-- Só a localização do ponto crítico e o vínculo com a VRP (1 ponto crítico por VRP; VRPs em par
-- podem ter o mesmo ponto). Pressões/setpoints do modelo NÃO são carregados.
-- Aditiva: a ficha e o cabeçalho da OS passam a devolver o ponto crítico; o front antigo ignora.

create table if not exists "2 - infra_agua".vrp_ponto_critico (
  vrp_id        bigint primary key references "2 - infra_agua".vrps(id) on delete cascade,
  no_modelo     text,                                -- nó do ponto crítico no modelo (J-xxxx)
  geom          geometry(Point,31983) not null,
  fonte         text,
  atualizado_em timestamptz not null default now()
);
create index if not exists vrp_ponto_critico_geom_idx on "2 - infra_agua".vrp_ponto_critico using gist(geom);
alter table "2 - infra_agua".vrp_ponto_critico enable row level security;  -- acesso só pelas RPCs definer
comment on table "2 - infra_agua".vrp_ponto_critico is 'Ponto crítico de cada VRP (1:1 com vrps). Carga inicial: modelo hidráulico ZA0200, 2026-11-18.';

-- carga Betim (101 VRPs existentes do modelo; casa por cd_no_agua)
insert into "2 - infra_agua".vrp_ponto_critico(vrp_id,no_modelo,geom,fonte)
select v.id, g.pc, ST_SetSRID(ST_MakePoint(g.x,g.y),31983), 'MH_ZA0200_Resumo_Atualizado.gpkg (2026-11-18)'
from (values
  ('VRP0000559','J-7637',583780.04,7793958.09),
  ('VRP0001035','J-6087',586230.31,7794185.58),
  ('VRP0001182','J-6301',586825.59,7793899.20),
  ('VRP0001254','J-73',586964.74,7795079.82),
  ('VRP0001320','J-7623',587300.75,7790811.14),
  ('VRP0531075','J-6703',586175.99,7793226.53),
  ('VRP0546055','J-7893',579694.27,7797162.41),
  ('VRP0557191','J-7552',587366.43,7791214.16),
  ('VRP0557192','J-6008',587390.99,7791164.44),
  ('VRP0557193','J-6426',587679.58,7791003.25),
  ('VRP0557197','J-6050',587026.16,7792315.44),
  ('VRP0557271','J-1494',586153.92,7794167.27),
  ('VRP0557308','J-7350',586815.11,7791400.06),
  ('VRP0557343','J-2735',586577.70,7794983.55),
  ('VRP0571059','J-7630',586031.06,7791001.94),
  ('VRP0574563','J-7420',586502.68,7790761.95),
  ('VRP0575937','J-4715',586027.96,7793542.65),
  ('VRP0576050','J-7262',585689.10,7796112.78),
  ('VRP0595817','J-7436',579743.29,7793156.36),
  ('VRP0619822','J-7511',583338.24,7795220.53),
  ('VRP0622709','J-6742',584988.73,7793205.51),
  ('VRP0622710','J-6742',584988.73,7793205.51),
  ('VRP0659572','J-1253',585303.50,7794378.48),
  ('VRP0659641','J-4084',587046.01,7791152.70),
  ('VRP0659977','J-6432',582033.77,7792845.21),
  ('VRP0660113','J-7567',581727.42,7792409.42),
  ('VRP0664054','J-5704',583650.56,7795382.42),
  ('VRP0672644','J-904',581429.45,7795467.99),
  ('VRP0677312','J-1272',581178.20,7791674.77),
  ('VRP0677817','J-7339',585278.26,7793288.30),
  ('VRP0679730','J-1521',586871.41,7794206.15),
  ('VRP0679806','J-5756',585541.87,7793747.87),
  ('VRP0680058','J-20',580961.15,7791908.85),
  ('VRP0687309','J-7243',582949.10,7795838.86),
  ('VRP0698604','J-1588',586007.30,7794917.46),
  ('VRP0709045','J-7660',583705.93,7795342.43),
  ('VRP0710958','J-8066',586008.16,7794914.22),
  ('VRP0711697','J-2971',584854.66,7794804.01),
  ('VRP0729337','J-4171',580896.69,7794212.05),
  ('VRP0729857','J-7461',581362.53,7794033.50),
  ('VRP0730336','J-2611',581469.09,7794376.06),
  ('VRP0730339','J-5472',581429.90,7794386.88),
  ('VRP0750521','J-5637',586693.16,7791495.14),
  ('VRP0757015','J-5919',584215.48,7794656.76),
  ('VRP0807821','J-3413',586546.15,7791492.74),
  ('VRP0807822','J-7400',586189.03,7791499.21),
  ('VRP1120207','J-5658',585616.72,7793096.00),
  ('VRP1249682','J-3419',582061.90,7790858.97),
  ('VRP1249818','J-1321',581276.83,7790811.05),
  ('VRP1249902','J-42',581623.02,7791297.86),
  ('VRP1249915','J-42',581623.02,7791297.86),
  ('VRP1249981','J-4514',581772.64,7791071.05),
  ('VRP1249982','J-4532',581764.57,7791082.36),
  ('VRP1250061','J-5735',581777.82,7790883.74),
  ('VRP1250062','J-5735',581777.82,7790883.74),
  ('VRP1250178','J-1249',582060.06,7790842.78),
  ('VRP1400586','J-2873',586047.95,7793946.08),
  ('VRP1433832','J-7503',579845.30,7788570.19),
  ('VRP1433845','J-785',579106.15,7788772.60),
  ('VRP1434090','J-5478',579002.22,7789228.58),
  ('VRP1434091','J-7617',578890.27,7788911.70),
  ('VRP1435255','J-7682',580377.22,7790243.13),
  ('VRP1435256','J-7717',579706.49,7789723.41),
  ('VRP1435553','J-2507',578022.78,7789195.28),
  ('VRP1435554','J-4857',577991.89,7789441.87),
  ('VRP1435620','J-4760',578696.72,7789076.06),
  ('VRP1435621','J-3464',578474.11,7788914.50),
  ('VRP1435713','J-7649',579203.68,7788325.76),
  ('VRP1435714','J-3047',579318.89,7787774.93),
  ('VRP1441995','J-1405',580462.81,7793109.34),
  ('VRP1456982','J-6707',586189.41,7791502.45),
  ('VRP1456983','J-6707',586189.41,7791502.45),
  ('VRP1477147','J-4457',586641.07,7794939.95),
  ('VRP1504795','J-7087',580621.83,7791153.70),
  ('VRP1526918','J-3960',585553.03,7793190.33),
  ('VRP1526919','J-3960',585553.03,7793190.33),
  ('VRP1527217','J-4927',585415.95,7793268.43),
  ('VRP1527218','J-4927',585415.95,7793268.43),
  ('VRP1540126','J-26',582585.99,7790932.53),
  ('VRP1547538','J-7726',586327.05,7797242.64),
  ('VRP1549410','J-7285',580713.11,7793493.44),
  ('VRP1556344','J-4248',582190.66,7792937.93),
  ('VRP1564928','J-5392',584911.37,7796988.11),
  ('VRP1567834','J-7721',579599.56,7794157.08),
  ('VRP1571904','J-7408',586763.30,7790191.56),
  ('VRP1585194','J-7375',584835.78,7793494.07),
  ('VRP1609102','J-2373',586096.48,7793341.21),
  ('VRP1623648','J-2017',585023.17,7796931.05),
  ('VRP1626646','J-3330',579638.13,7790361.27),
  ('VRP1630452','J-7965',587000.13,7791139.53),
  ('VRP1630458','J-7965',587000.13,7791139.53),
  ('VRP1630541','J-7983',587202.38,7790703.50),
  ('VRP1630551','J-7983',587202.38,7790703.50),
  ('VRP1634678','J-6758',582592.97,7795678.18),
  ('VRP1645065','J-1949',580190.71,7797293.62),
  ('VRP1645100','J-7714',580887.79,7796668.34),
  ('VRP1645114','J-7714',580887.79,7796668.34),
  ('VRP1645899','J-1949',580190.71,7797293.62),
  ('VRR0000870','J-6059',586062.03,7794551.55),
  ('VRR0000892','J-6231',586860.05,7794204.20),
  ('VRR1520211','J-7673',586000.68,7794113.09)
) g(cd,pc,x,y)
join "2 - infra_agua".vrps v on v.cd_no_agua=g.cd
on conflict (vrp_id) do update set no_modelo=excluded.no_modelo, geom=excluded.geom, fonte=excluded.fonte, atualizado_em=now();

-- helper: ponto crítico da VRP em jsonb (lat/lon 4326 + distância à VRP em m)
create or replace function public.vrp_pc_json(p_vrp_id bigint)
returns jsonb language sql stable security definer set search_path to 'public','extensions' as $$
  select jsonb_build_object('no_modelo',pc.no_modelo,
    'lat',ST_Y(ST_Transform(pc.geom,4326)),'lon',ST_X(ST_Transform(pc.geom,4326)),
    'dist_m',round(ST_Distance(pc.geom, ST_Transform(v.geom,31983))::numeric))
  from "2 - infra_agua".vrp_ponto_critico pc join "2 - infra_agua".vrps v on v.id=pc.vrp_id
  where pc.vrp_id=p_vrp_id
$$;
revoke all on function public.vrp_pc_json(bigint) from public, anon, authenticated;

-- ficha: + ponto_critico
create or replace function public.app_vrp_ficha(p_vrp_id bigint)
 returns jsonb language plpgsql stable security definer set search_path to 'public','extensions'
as $function$
declare v_uid uuid := auth.uid(); v jsonb; v_dmc text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  v_dmc := public.vrp_dmc_de(p_vrp_id);
  select jsonb_build_object('cadastro', jsonb_build_object(
      'vrp_id',vr.id,'num_vrp',vr.num_vrp,'cd_no_agua',vr.cd_no_agua,'consorcio',vr.consorcio,'dmc',v_dmc,
      'diametro',vr.diametro,'atuacao',vr.atuacao,'pres_max',vr.pres_max,'pres_min',vr.pres_min,'pres_saida',vr.pres_saida,
      'cota',vr.cota,'cota_max',vr.cota_max,'cota_min',vr.cota_min,'responsavel',vr.responsavel,'observacao',vr.observacao,
      'lat',ST_Y(ST_Transform(vr.geom,4326)),'lon',ST_X(ST_Transform(vr.geom,4326))))
    into v from "2 - infra_agua".vrps vr where vr.id=p_vrp_id;
  if v is null then raise exception 'VRP inexistente'; end if;
  return v
    || jsonb_build_object('ponto_critico', public.vrp_pc_json(p_vrp_id))
    || jsonb_build_object('ultima', (select jsonb_build_object('modelo',modelo,'tem_controlador',tem_controlador,'controlador_modelo',controlador_modelo,
         'ponto_critico_ref',ponto_critico_ref,'press_mont_fin',press_mont_fin,'press_jus_fin',press_jus_fin,'press_pc_fin',press_pc_fin,'os_numero',os_numero,'executado_em',executado_em)
       from "8 - coleta_campo".vrp_os where vrp_id=p_vrp_id and status in ('concluida','concluida_pendencia') order by executado_em desc nulls last limit 1))
    || jsonb_build_object('historico', coalesce((select jsonb_agg(jsonb_build_object('os_id',o.id,'os_numero',o.os_numero,'os_sigos',o.os_sigos,
         'status',o.status,'origem',o.origem,'executado_em',o.executado_em,'programada_para',o.programada_para,'aberto_em',o.aberto_em,'executor',pr.nome)
         order by coalesce(o.executado_em,o.aberto_em) desc)
       from "8 - coleta_campo".vrp_os o left join public.perfil pr on pr.id=o.executado_por where o.vrp_id=p_vrp_id),'[]'::jsonb))
    || jsonb_build_object('visitas', coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'situacao',x.situacao,'visitado_em',x.visitado_em,
         'visitado_por',pr.nome,'respostas',x.respostas,'fotos',x.fotos) order by x.visitado_em desc)
       from "8 - coleta_campo".vrp_visita x left join public.perfil pr on pr.id=x.visitado_por where x.vrp_id=p_vrp_id),'[]'::jsonb))
    || jsonb_build_object('pendencias', coalesce((select jsonb_agg(jsonb_build_object('id',pe.id,'tipo',pe.tipo,'lado',pe.lado,'descricao',pe.descricao,'status',pe.status,'aberta_em',pe.aberta_em)
         order by pe.aberta_em desc)
       from "8 - coleta_campo".vrp_pendencia pe where pe.vrp_id=p_vrp_id and pe.status in ('aberta','em_andamento')),'[]'::jsonb))
    || jsonb_build_object('preventiva', (
         with cfg as (select coalesce(ov.intervalo_dias, c.intervalo_dias, 180) itv, coalesce(c.aviso_dias,30) av
             from "2 - infra_agua".vrps v
             left join "8 - coleta_campo".vrp_prev_vrp ov on ov.vrp_id=v.id and ov.ativo
             left join "8 - coleta_campo".vrp_prev_config c on c.consorcio=v.consorcio where v.id=p_vrp_id),
           ult as (select max(executado_em) u from "8 - coleta_campo".vrp_os where vrp_id=p_vrp_id and status in ('concluida','concluida_pendencia'))
         select jsonb_build_object('intervalo',(select itv from cfg),'ultima',(select u from ult),
           'proxima', case when (select u from ult) is null then null else ((select u from ult)::date + (select itv from cfg)) end)));
end $function$;

-- cabeçalho da OS: + ponto_critico (usado na etapa de Calibração)
create or replace function public.app_vrp_os_header(p_vrp_id bigint)
 returns jsonb language plpgsql stable security definer set search_path to 'public','extensions'
as $function$
declare v_uid uuid := auth.uid(); v jsonb; l record; v_pend int; v_orig text;
begin
  if v_uid is null then raise exception 'nao autenticado'; end if;
  select jsonb_build_object(
    'vrp_id', vr.id, 'num_vrp', vr.num_vrp, 'cd_no_agua', vr.cd_no_agua, 'consorcio', vr.consorcio,
    'dmc', public.vrp_dmc_de(vr.id),
    'diametro', vr.diametro, 'proj_mont', vr.pres_max, 'proj_jus', vr.pres_saida, 'proj_min', vr.pres_min,
    'atuacao', vr.atuacao, 'observacao', vr.observacao,
    'lat', ST_Y(ST_Transform(vr.geom,4326)), 'lon', ST_X(ST_Transform(vr.geom,4326))
  ) into v from "2 - infra_agua".vrps vr where vr.id=p_vrp_id;
  if v is null then raise exception 'VRP inexistente'; end if;
  select modelo, tem_controlador, controlador_modelo, ponto_critico_ref, press_mont_fin, press_jus_fin, press_pc_fin, os_numero, executado_em
    into l from "8 - coleta_campo".vrp_os where vrp_id=p_vrp_id and status in ('concluida','concluida_pendencia')
    order by executado_em desc nulls last limit 1;
  select origem into v_orig from "8 - coleta_campo".vrp_os where vrp_id=p_vrp_id and status='programada'
    order by programada_para nulls last, aberto_em limit 1;
  select count(*) into v_pend from "8 - coleta_campo".vrp_pendencia where vrp_id=p_vrp_id and status in ('aberta','em_andamento');
  return v || jsonb_build_object('modelo', l.modelo, 'tem_controlador', l.tem_controlador, 'controlador_modelo', l.controlador_modelo,
    'ponto_critico_ref', l.ponto_critico_ref, 'ult_mont', l.press_mont_fin, 'ult_jus', l.press_jus_fin, 'ult_pc', l.press_pc_fin,
    'ult_os', l.os_numero, 'ult_os_em', l.executado_em, 'pendencias_abertas', v_pend, 'origem', v_orig,
    'ponto_critico', public.vrp_pc_json(p_vrp_id));
end $function$;
