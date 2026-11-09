-- ============================================================================
-- Priorização de troca de HD × SIGOS (2026-11-09) — docs/MODULOS.md §11 (Priorização de HD › Vínculo SIGOS)
--
-- Cruza cada matrícula da priorização com as OS de troca de hidrômetro dos relatórios SIGOS
-- ("17 - sigos".os_aberta = carteira da última Relação; os_encerrada = Encerradas acumuladas).
--
-- OS de troca = código de serviço da tabela de calibres ("11 - perdas_nrw".hd_calibre.codigo_servico,
-- sem os espaços: '117 79 00' → '1177900') OU descrição 'SUBST.HIDROMETRO%' (pega também o
-- 1178000 "embaçado CAP Y", que é manutenção mas também tira o HD velho).
--
-- Situação SIGOS da matrícula (coluna `sit`), nesta ordem:
--   'trocado'  — OS executada: Encerrada EXECUTADA, carteira EXECUTADA(E), ou Encerrada com motivo
--                S89 "hidrômetro já substituído" (decisão do usuário em 09/11/2026);
--   status da OS mais recente da carteira: 'NP','PR','RE','PE','AV','BL','N' (outro código → 'OUT');
--   'nao_exec' — só Encerradas sem execução (motivo em `oc`);
--   'sem'      — nenhuma OS de troca (a matrícula não aparece em hd_sigos_situacao).
-- `oculto` = trocado DEPOIS da carga do cadastro de HD daquela matrícula (hd_cadastro.importado_em):
-- o cadastro ainda mostra o HD velho, então a matrícula sai da lista por padrão. Quando uma carga
-- nova do cadastro trouxer o HD novo, `oculto` volta a false e o próprio motor decide.
--
-- RPCs de leitura (mesmos nomes; só ganharam parâmetros opcionais no fim — o front antigo continua
-- funcionando e já passa a esconder os trocados):
--   p_sigos text[]              — filtra pelas situações acima ('sem' incluso)
--   p_sigos_col text            — responsável (ou 'Equipe <eq>') da OS atual; '__sem' = OS sem equipe
--   p_mostrar_trocados boolean  — default false: esconde os `oculto`
-- Novo: app_nrw_hd_sigos_diverg(p_consorcio) — OS de troca em carteira que não batem com a lista.
-- ============================================================================

-- ---------- helper interno: situação SIGOS por matrícula (só as que têm OS de troca) ----------
create or replace function public.hd_sigos_situacao()
returns table(matricula bigint, sit text, oculto boolean, trocado_em timestamp, os text, st text, cod text, srv text,
              eq text, resp text, ab timestamp, lim timestamp, oc text, vis integer, n_os integer, hist jsonb)
language plpgsql
stable security definer
set search_path to 'public', '17 - sigos'
as $function$
begin
  -- plpgsql de propósito: não é "inlinada" no plano de quem chama → roda 1 vez (≈20 ms) em vez de por linha
  return query
  with cods as (
    select replace(codigo_servico, ' ', '') c from "11 - perdas_nrw".hd_calibre where codigo_servico is not null
  ),
  u as (
    select a.matricula, 'a'::text fonte, a.numero, a.status, a.cod_servico, a.desc_servico, a.equipe, a.responsavel,
           a.abertura ab, a.limite lim, a.enc_realizado ex, coalesce(a.visitas, 0) vis, null::text oc,
           (a.status ~ '\(E\)\s*$') exe
      from os_aberta a
     where a.matricula > 0 and (a.cod_servico in (select c from cods) or a.desc_servico ilike 'SUBST.HIDROMETRO%')
    union all
    select e.matricula, 'e', e.numero, e.status, e.cod_servico, e.desc_servico, e.equipe, e.responsavel,
           e.data_geracao, null, e.execucao, coalesce(e.visitas, 0), e.ocorrencia,
           (e.status = 'EXECUTADA' or coalesce(e.ocorrencia, '') ilike 'S89%')
      from os_encerrada e
     where e.matricula > 0 and (e.cod_servico in (select c from cods) or e.desc_servico ilike 'SUBST.HIDROMETRO%')
  ),
  agg as (
    select u.matricula, sum(u.vis)::int vis, count(*)::int n_os,
           jsonb_agg(jsonb_build_object('n', u.numero, 'st', u.status, 'cod', u.cod_servico, 'srv', u.desc_servico,
                     'eq', u.equipe, 'resp', u.responsavel, 'ab', u.ab, 'lim', u.lim, 'ex', u.ex, 'vis', u.vis,
                     'oc', u.oc, 'carteira', u.fonte = 'a')
                     order by coalesce(u.ex, u.ab) desc nulls last) hist
      from u group by u.matricula
  ),
  cur as (
    select distinct on (u.matricula) u.*
      from u
     order by u.matricula, u.exe desc, (u.fonte = 'a') desc, coalesce(u.ex, u.ab) desc nulls last
  )
  select c.matricula::bigint,
         case when c.exe then 'trocado'
              when c.fonte = 'a' then coalesce((select k from unnest(array['NP','PR','RE','PE','AV','BL','N']) k
                                                 where k = substring(c.status from '\(([A-Z]+)\)\s*$')), 'OUT')
              else 'nao_exec' end,
         (c.exe and (h.importado_em is null or coalesce(c.ex, c.ab) > h.importado_em)),
         case when c.exe then coalesce(c.ex, c.ab) end,
         c.numero, c.status, c.cod_servico, c.desc_servico, c.equipe, c.responsavel, c.ab, c.lim, c.oc,
         g.vis::int, g.n_os::int, g.hist
    from cur c
    join agg g on g.matricula = c.matricula
    left join "11 - perdas_nrw".hd_cadastro h on h.matricula = c.matricula;
end $function$;
revoke all on function public.hd_sigos_situacao() from public, anon, authenticated;

-- colaborador da OS atual (mesma regra do front da Programação do recadastramento)
create or replace function public.hd_sigos_col(p_resp text, p_eq text)
returns text language sql immutable as $$
  select case when p_resp is not null then p_resp when p_eq is not null then 'Equipe ' || p_eq else '__sem' end
$$;

-- ---------- app_nrw_hd_resumo ----------
drop function if exists public.app_nrw_hd_resumo(text, text, text, text, text, text, text, text, text, integer[], integer, integer, boolean);
create function public.app_nrw_hd_resumo(
  p_consorcio text DEFAULT NULL, p_situacao text DEFAULT 'ativa', p_interno text DEFAULT NULL, p_categoria text DEFAULT NULL,
  p_motivo text DEFAULT NULL, p_cap text DEFAULT NULL, p_adequacao text DEFAULT NULL, p_codigo text DEFAULT NULL,
  p_poligono text DEFAULT NULL, p_idades integer[] DEFAULT NULL, p_idade_min integer DEFAULT NULL, p_idade_max integer DEFAULT NULL,
  p_incluir_sem_troca boolean DEFAULT false,
  p_sigos text[] DEFAULT NULL, p_sigos_col text DEFAULT NULL, p_mostrar_trocados boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_poly geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return (
    with sg as materialized (select * from public.hd_sigos_situacao()),
    b0 as (   -- todos os filtros menos idade e SIGOS
      select p.*, case when p.idade_medidor is null then -1 when p.idade_medidor>=30 then 30 else p.idade_medidor end faixa_idade,
             coalesce(s.sit,'sem') sit, coalesce(s.oculto,false) oculto, public.hd_sigos_col(s.resp, s.eq) col, s.matricula is not null tem_os
      from "11 - perdas_nrw".hd_priorizacao p
      left join sg s on s.matricula = p.matricula
      where (p_consorcio is null or p.consorcio=p_consorcio)
        and (p_incluir_sem_troca or coalesce(p.troca_efetiva,false))
        and (p_situacao='todas' or (p_situacao='ativa' and p.situacao_lig='R') or (p_situacao='inativa' and coalesce(p.situacao_lig,'X') in ('I','F','P')))
        and (p_interno is null or p.interno_externo=p_interno)
        and (p_categoria is null or p.categoria=p_categoria)
        and (p_motivo is null or p_motivo = any(p.motivos))
        and (p_cap is null or p.cap=p_cap)
        and (p_adequacao is null or p.adequacao=p_adequacao)
        and (p_codigo is null or p.codigo_servico=p_codigo)
        and (v_poly is null or exists(select 1 from "3 - comercial".ligacoes l where l.matricula=p.matricula and l.geom is not null and st_contains(v_poly, l.geom)))
    ),
    b as (select * from b0 where (p_mostrar_trocados or not oculto) and (p_sigos is null or sit = any(p_sigos)) and (p_sigos_col is null or (tem_os and col=p_sigos_col))),
    f0 as (select * from b0 where (p_idades is null or faixa_idade = any(p_idades)) and (p_idade_min is null or idade_medidor >= p_idade_min) and (p_idade_max is null or idade_medidor <= p_idade_max)),
    f as (select * from b where (p_idades is null or faixa_idade = any(p_idades)) and (p_idade_min is null or idade_medidor >= p_idade_min) and (p_idade_max is null or idade_medidor <= p_idade_max))
    select jsonb_build_object(
      'n_total', (select count(*) from f),
      'n_remanejamento', (select count(*) from f where remanejamento_sugerido),
      'ips_medio', (select round(avg(ips),1) from f),
      'idade_media', (select round(avg(idade_medidor),1) from f),
      'por_categoria', (select coalesce(jsonb_object_agg(categoria,n),'{}') from (select categoria,count(*) n from f group by categoria) t),
      'por_adequacao', (select coalesce(jsonb_object_agg(adequacao,n),'{}') from (select adequacao,count(*) n from f group by adequacao) t),
      'por_codigo', (select coalesce(jsonb_object_agg(coalesce(codigo_servico,'(fora do contrato)'),n),'{}') from (select codigo_servico,count(*) n from f group by codigo_servico) t),
      'por_motivo', (select coalesce(jsonb_object_agg(mot,n),'{}') from (select unnest(motivos) mot,count(*) n from f group by 1 order by 2 desc) t),
      'por_idade', (select coalesce(jsonb_object_agg(faixa_idade,n),'{}') from (select faixa_idade,count(*) n from b group by faixa_idade) t),
      -- SIGOS: contagens sem o próprio filtro de situação/colaborador e COM os trocados (mostra quantos estão ocultos)
      'por_sigos', (select coalesce(jsonb_object_agg(sit,n),'{}') from (select sit,count(*) n from f0 where (p_sigos_col is null or (tem_os and col=p_sigos_col)) group by sit) t),
      'n_trocados_ocultos', (select count(*) from f0 where oculto),
      'sigos_por_categoria', (select coalesce(jsonb_object_agg(categoria, o),'{}') from (
          select categoria, jsonb_build_object('total',count(*),'trocado',count(*) filter (where sit='trocado'),
                 'carteira',count(*) filter (where sit not in ('trocado','nao_exec','sem')),'nao_exec',count(*) filter (where sit='nao_exec'),
                 'sem',count(*) filter (where sit='sem')) o
          from f0 group by categoria) t),
      'por_sigos_col', (select coalesce(jsonb_object_agg(col,n),'{}') from (select col,count(*) n from f0 where tem_os and (p_sigos is null or sit = any(p_sigos)) group by col) t)
    )
  );
end $function$;

-- ---------- app_nrw_hd_mapa ----------
drop function if exists public.app_nrw_hd_mapa(text, text, text, text, text, integer, text, text, text, integer[], integer, integer, boolean);
create function public.app_nrw_hd_mapa(
  p_consorcio text DEFAULT NULL, p_categoria text DEFAULT NULL, p_situacao text DEFAULT 'ativa', p_interno text DEFAULT NULL,
  p_cap text DEFAULT NULL, p_limit integer DEFAULT 8000, p_adequacao text DEFAULT NULL, p_codigo text DEFAULT NULL,
  p_poligono text DEFAULT NULL, p_idades integer[] DEFAULT NULL, p_idade_min integer DEFAULT NULL, p_idade_max integer DEFAULT NULL,
  p_incluir_sem_troca boolean DEFAULT false,
  p_sigos text[] DEFAULT NULL, p_sigos_col text DEFAULT NULL, p_mostrar_trocados boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_poly geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return coalesce((select jsonb_agg(row_to_json(r)) from (
    select p.matricula, p.cap, p.cal_recomendado, p.codigo_servico, p.ips, p.categoria, p.remanejamento_sugerido, p.idade_medidor,
      coalesce(s.sit,'sem') sit, s.os sig_os,
      round(st_y(st_transform(l.geom,4326))::numeric,6) lat, round(st_x(st_transform(l.geom,4326))::numeric,6) lon
    from "11 - perdas_nrw".hd_priorizacao p
    join "3 - comercial".ligacoes l on l.matricula=p.matricula and l.geom is not null
    left join public.hd_sigos_situacao() s on s.matricula=p.matricula
    where (p_consorcio is null or p.consorcio=p_consorcio)
      and (p_incluir_sem_troca or coalesce(p.troca_efetiva,false))
      and (p_categoria is null or p.categoria=p_categoria)
      and (p_situacao='todas' or (p_situacao='ativa' and p.situacao_lig='R') or (p_situacao='inativa' and coalesce(p.situacao_lig,'X') in ('I','F','P')))
      and (p_interno is null or p.interno_externo=p_interno)
      and (p_cap is null or p.cap=p_cap)
      and (p_adequacao is null or p.adequacao=p_adequacao)
      and (p_codigo is null or p.codigo_servico=p_codigo)
      and (p_idades is null or (case when p.idade_medidor is null then -1 when p.idade_medidor>=30 then 30 else p.idade_medidor end) = any(p_idades))
      and (p_idade_min is null or p.idade_medidor >= p_idade_min)
      and (p_idade_max is null or p.idade_medidor <= p_idade_max)
      and (v_poly is null or st_contains(v_poly, l.geom))
      and (p_mostrar_trocados or not coalesce(s.oculto,false))
      and (p_sigos is null or coalesce(s.sit,'sem') = any(p_sigos))
      and (p_sigos_col is null or (s.matricula is not null and public.hd_sigos_col(s.resp, s.eq)=p_sigos_col))
    order by p.ips desc nulls last
    limit greatest(1,least(p_limit,20000))) r),'[]');
end $function$;

-- ---------- app_nrw_hd_ranking ----------
drop function if exists public.app_nrw_hd_ranking(text, text, text, text, text, text, text, integer, integer, text, text, text, boolean, boolean, integer[], integer, integer);
create function public.app_nrw_hd_ranking(
  p_consorcio text DEFAULT NULL, p_categoria text DEFAULT NULL, p_motivo text DEFAULT NULL, p_cap text DEFAULT NULL,
  p_situacao text DEFAULT 'ativa', p_interno text DEFAULT NULL, p_busca text DEFAULT NULL, p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0, p_adequacao text DEFAULT NULL, p_codigo text DEFAULT NULL, p_poligono text DEFAULT NULL,
  p_incluir_endereco boolean DEFAULT false, p_incluir_sem_troca boolean DEFAULT false, p_idades integer[] DEFAULT NULL,
  p_idade_min integer DEFAULT NULL, p_idade_max integer DEFAULT NULL,
  p_sigos text[] DEFAULT NULL, p_sigos_col text DEFAULT NULL, p_mostrar_trocados boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_poly geometry;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  if p_poligono is not null then v_poly := st_transform(st_setsrid(st_geomfromgeojson(p_poligono),4326),31983); end if;
  return (
    with sg as (select * from public.hd_sigos_situacao()),
    f as (
      select p.*, lg.situacao_desde, h.num_hidr, ad.bairro, ad.endereco,
             coalesce(s.sit,'sem') sit, coalesce(s.oculto,false) sig_oculto, s.os sig_os, s.st sig_st, s.cod sig_cod, s.srv sig_srv,
             s.eq sig_eq, s.resp sig_resp, s.ab sig_ab, s.lim sig_lim, s.oc sig_oc, s.vis sig_vis, s.n_os sig_n, s.trocado_em sig_trocado_em
      from "11 - perdas_nrw".hd_priorizacao p
      left join "3 - comercial".ligacoes lg on lg.matricula=p.matricula
      left join "11 - perdas_nrw".hd_cadastro h on h.matricula=p.matricula
      left join sg s on s.matricula=p.matricula
      left join lateral (
        select c.bairro, c.endereco
        from "0 - vitrine_gis".vw_gis_cadastro_comercial c
        where p_incluir_endereco and c.matricula=p.matricula and c.consorcio=p.consorcio
        limit 1
      ) ad on true
      where (p_consorcio is null or p.consorcio=p_consorcio)
        and (p_incluir_sem_troca or coalesce(p.troca_efetiva,false))
        and (p_categoria is null or p.categoria=p_categoria)
        and (p_motivo is null or p_motivo = any(p.motivos))
        and (p_cap is null or p.cap=p_cap)
        and (p_adequacao is null or p.adequacao=p_adequacao)
        and (p_codigo is null or p.codigo_servico=p_codigo)
        and (p_situacao='todas' or (p_situacao='ativa' and p.situacao_lig='R') or (p_situacao='inativa' and coalesce(p.situacao_lig,'X') in ('I','F','P')))
        and (p_interno is null or p.interno_externo=p_interno)
        and (p_busca is null or p_busca='' or p.matricula::text like p_busca||'%')
        and (p_idades is null or (case when p.idade_medidor is null then -1 when p.idade_medidor>=30 then 30 else p.idade_medidor end) = any(p_idades))
        and (p_idade_min is null or p.idade_medidor >= p_idade_min)
        and (p_idade_max is null or p.idade_medidor <= p_idade_max)
        and (v_poly is null or exists(select 1 from "3 - comercial".ligacoes l where l.matricula=p.matricula and l.geom is not null and st_contains(v_poly, l.geom)))
        and (p_mostrar_trocados or not coalesce(s.oculto,false))
        and (p_sigos is null or coalesce(s.sit,'sem') = any(p_sigos))
        and (p_sigos_col is null or (s.matricula is not null and public.hd_sigos_col(s.resp, s.eq)=p_sigos_col))
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'rows', coalesce((select jsonb_agg(row_to_json(r)) from (
        select matricula, num_hidr, cap, q3, cal_recomendado, q3_recomendado, codigo_recomendado, desc_recomendado,
          codigo_servico, in_contrato, idade_medidor, round(media,1) media, media_m3h, round(media_4m,1) media_4m, p90, faixa_predominante, tendencia,
          adequacao, troca_efetiva, round(volume_periodo,0) volume_periodo, ips, categoria, interno_externo, situacao_lig, situacao_desde, remanejamento_sugerido, justificativa,
          bairro, endereco,
          sit, sig_oculto, sig_os, sig_st, sig_cod, sig_srv, sig_eq, sig_resp, sig_ab, sig_lim, sig_oc, sig_vis, sig_n, sig_trocado_em
        from f order by ips desc nulls last, matricula
        limit greatest(1,least(p_limit,2000)) offset greatest(0,p_offset)) r),'[]')
    )
  );
end $function$;

-- ---------- app_nrw_hd_detalhe: + histórico de OS SIGOS ----------
create or replace function public.app_nrw_hd_detalhe(p_matricula bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v jsonb;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  select to_jsonb(p) || jsonb_build_object('situacao_desde', (select l2.situacao_desde from "3 - comercial".ligacoes l2 where l2.matricula=p_matricula limit 1), 'num_hidr', h.num_hidr, 'ano_cod', h.ano_cod,
     'calibre', to_jsonb(c), 'calibre_rec', to_jsonb(cr),
     'serie', coalesce((select jsonb_agg(jsonb_build_object('competencia',mi.competencia,'vol',mi.qt_volume_) order by mi.competencia)
        from "5 - info_copasa".micromedicao_historico mi where mi.nu_matricu=p_matricula),'[]'),
     'sigos', (select jsonb_build_object('sit', s.sit, 'oculto', s.oculto, 'trocado_em', s.trocado_em, 'vis', s.vis, 'n_os', s.n_os, 'hist', s.hist)
                 from public.hd_sigos_situacao() s where s.matricula=p_matricula),
     'cadastro_hd_em', h.importado_em)
  into v
  from "11 - perdas_nrw".hd_priorizacao p
  left join "11 - perdas_nrw".hd_cadastro h on h.matricula=p.matricula
  left join "11 - perdas_nrw".hd_calibre c on c.cap=p.cap
  left join "11 - perdas_nrw".hd_calibre cr on cr.cap=p.cal_recomendado
  where p.matricula=p_matricula;
  if v is null then raise exception 'matrícula não encontrada'; end if;
  return v;
end $function$;

-- ---------- novo: divergências (OS de troca em carteira que não batem com a lista) ----------
create or replace function public.app_nrw_hd_sigos_diverg(p_consorcio text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', '17 - sigos'
AS $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(dev_acesso,false))) then raise exception 'sem permissão'; end if;
  return (
    with cods as (select replace(codigo_servico,' ','') c, cap from "11 - perdas_nrw".hd_calibre where codigo_servico is not null),
    a as (
      select a.numero, a.consorcio, a.matricula, a.status, a.cod_servico, a.desc_servico, a.equipe, a.responsavel, a.abertura, a.limite, a.endereco,
             p.matricula is not null na_lista, coalesce(p.troca_efetiva,false) troca_efetiva, p.categoria, p.cap, p.cal_recomendado,
             replace(p.codigo_recomendado,' ','') cod_rec, (a.cod_servico in (select c from cods)) cod_contrato
        from os_aberta a
        left join "11 - perdas_nrw".hd_priorizacao p on p.matricula = a.matricula
       where a.matricula > 0
         and (a.cod_servico in (select c from cods) or a.desc_servico ilike 'SUBST.HIDROMETRO%')
         and a.status !~ '\(E\)\s*$'
         and (p_consorcio is null or a.consorcio = p_consorcio)
    ),
    d as (
      select a.*, case when not na_lista then 'fora_cadastro'
                       when not troca_efetiva then 'sem_troca_recomendada'
                       when cod_contrato and cod_rec is not null and cod_servico <> cod_rec then 'calibre_diferente' end tipo
        from a
    )
    select jsonb_build_object(
      'por_tipo', (select coalesce(jsonb_object_agg(tipo, n),'{}') from (select tipo, count(*) n from d where tipo is not null group by 1) t),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('tipo', tipo, 'os', numero, 'za', consorcio, 'mat', matricula, 'st', status,
                 'cod', cod_servico, 'srv', desc_servico, 'eq', equipe, 'resp', responsavel, 'ab', abertura, 'lim', limite, 'end', endereco,
                 'categoria', categoria, 'cap', cap, 'cal_rec', cal_recomendado, 'cod_rec', cod_rec) order by tipo, abertura)
               from d where tipo is not null), '[]')
    )
  );
end $function$;

revoke all on function public.app_nrw_hd_resumo(text,text,text,text,text,text,text,text,text,integer[],integer,integer,boolean,text[],text,boolean) from public, anon;
revoke all on function public.app_nrw_hd_mapa(text,text,text,text,text,integer,text,text,text,integer[],integer,integer,boolean,text[],text,boolean) from public, anon;
revoke all on function public.app_nrw_hd_ranking(text,text,text,text,text,text,text,integer,integer,text,text,text,boolean,boolean,integer[],integer,integer,text[],text,boolean) from public, anon;
revoke all on function public.app_nrw_hd_detalhe(bigint) from public, anon;
revoke all on function public.app_nrw_hd_sigos_diverg(text) from public, anon;
grant execute on function public.app_nrw_hd_resumo(text,text,text,text,text,text,text,text,text,integer[],integer,integer,boolean,text[],text,boolean) to authenticated;
grant execute on function public.app_nrw_hd_mapa(text,text,text,text,text,integer,text,text,text,integer[],integer,integer,boolean,text[],text,boolean) to authenticated;
grant execute on function public.app_nrw_hd_ranking(text,text,text,text,text,text,text,integer,integer,text,text,text,boolean,boolean,integer[],integer,integer,text[],text,boolean) to authenticated;
grant execute on function public.app_nrw_hd_detalhe(bigint) to authenticated;
grant execute on function public.app_nrw_hd_sigos_diverg(text) to authenticated;
