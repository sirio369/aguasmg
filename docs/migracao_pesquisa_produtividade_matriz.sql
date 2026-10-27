-- Acompanhamento da pesquisa — produtividade por colaborador + matriz tipo × local. 2026-10-27.
-- app_pp_acompanhamento (mesma assinatura → mantém grants):
--  * kpis: + 'fraudes' e 'ocorr_km' = (vazamentos + fraudes) / km de rede pesquisada (substitui o vaz/km na tela).
--  * resumo: universo = quem teve execução de rede, trecho andado OU ocorrência no período/consórcio (antes: só quem
--    tinha rede programada/executada em qualquer data — quem só andou/reportou sumia e quem só foi programado aparecia
--    zerado); + 'fraudes' e 'ocorr_km'; respeita p_colaborador.
--  * matriz: [{tipo, local, n, com_os}] = ocorrências por tipo × local (bloco "Ocorrências por tipo e local").
--  * 'ocorrencias' (nome × tipo) fica só p/ a sw v277 em produção (quadros que saem nesta versão) — pode ser removida
--    depois do deploy da v278. 'vaz_km' segue por compatibilidade.
-- Regra (MODULOS §2.3): vazamento = tipo que não começa com 'Fraude'; fraude = começa com 'Fraude'.

create or replace function public.app_pp_acompanhamento(p_consorcio text DEFAULT NULL::text, p_colaborador uuid DEFAULT NULL::uuid,
  p_data_ini date DEFAULT NULL::date, p_data_fim date DEFAULT NULL::date)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_fun text; v_nome text; v_email text;
begin
  v_fun := coalesce("9 - suprimentos".sup_funcao(auth.uid()),'');
  if v_fun not in ('aprovador','admin') then raise exception 'sem permissao'; end if;
  if p_colaborador is not null then select nome, email into v_nome, v_email from public.perfil where id=p_colaborador; end if;

  return jsonb_build_object(
    'kpis', (
      with rede_exec as (
        select coalesce(sum(coalesce(e.comprimento_m, st_length(e.geom))),0) m
        from "8 - coleta_campo".pp_execucao e
        left join "2 - infra_agua".rede r on r.id = e.rede_id
        where (p_colaborador is null or e.colaborador_uuid = p_colaborador)
          and (p_consorcio is null or r.consorcio = p_consorcio)
          and (p_data_ini is null or e.executado_em::date >= p_data_ini)
          and (p_data_fim is null or e.executado_em::date <= p_data_fim)),
      andado as (
        select coalesce(sum(t.comprimento_m),0) m, coalesce(sum(t.duracao_s),0) s
        from "8 - coleta_campo".pesquisa_trecho t
        where (p_colaborador is null or t.usuario in (v_nome, v_email))
          and (p_consorcio is null or t.consorcio = p_consorcio)
          and (p_data_ini is null or t.inicio_ts::date >= p_data_ini)
          and (p_data_fim is null or t.inicio_ts::date <= p_data_fim)),
      oc as (
        select count(*) filter (where coalesce(o.tipo,'') not ilike 'fraude%') vaz,
               count(*) filter (where o.tipo ilike 'fraude%') fra
        from "8 - coleta_campo".ocorrencia o
        where (p_colaborador is null or o.usuario in (v_nome, v_email))
          and (p_consorcio is null or o.consorcio = p_consorcio)
          and (p_data_ini is null or o.data_hora::date >= p_data_ini)
          and (p_data_fim is null or o.data_hora::date <= p_data_fim))
      select jsonb_build_object(
        'km_rede_pesquisado', round((rede_exec.m/1000.0)::numeric,2),
        'km_andado', round((andado.m/1000.0)::numeric,2),
        'vazamentos', oc.vaz,
        'fraudes', oc.fra,
        'vaz_km', case when rede_exec.m>0 then round((oc.vaz/(rede_exec.m/1000.0))::numeric,2) else 0 end,
        'ocorr_km', case when rede_exec.m>0 then round(((oc.vaz+oc.fra)/(rede_exec.m/1000.0))::numeric,2) else 0 end,
        'velocidade_kmh', case when andado.s>0 then round(((andado.m/1000.0)/(andado.s/3600.0))::numeric,2) else 0 end)
      from rede_exec, andado, oc),
    'progresso_passadas', (
      with cnt as (select segmento_id, count(*) np from "8 - coleta_campo".pp_execucao where segmento_id is not null group by segmento_id),
      segb as (
        select least(coalesce(c.np,0),5) as bucket, coalesce(s.comprimento_m, st_length(s.geom)) as len
        from "8 - coleta_campo".rede_pp_segmento s
        join "2 - infra_agua".rede r on r.id = s.rede_id
        left join cnt c on c.segmento_id = s.id
        where r.situacao='O' and (p_consorcio is null or r.consorcio = p_consorcio)),
      agg as (select bucket, count(*) n, round((sum(len)/1000.0)::numeric,2) km from segb group by bucket)
      select coalesce(jsonb_agg(jsonb_build_object('passada', g.b, 'n_segmentos', coalesce(a.n,0), 'km', coalesce(a.km,0)) order by g.b),'[]'::jsonb)
      from generate_series(0,5) g(b) left join agg a on a.bucket = g.b),
    -- produtividade por colaborador: quem teve atividade (rede executada, trecho andado ou ocorrência) no filtro
    'resumo', (
      with univ as (
        select e.colaborador_uuid u from "8 - coleta_campo".pp_execucao e left join "2 - infra_agua".rede r on r.id=e.rede_id
        where e.colaborador_uuid is not null and (p_consorcio is null or r.consorcio = p_consorcio)
          and (p_data_ini is null or e.executado_em::date >= p_data_ini) and (p_data_fim is null or e.executado_em::date <= p_data_fim)
        union
        select pe.id from public.perfil pe where exists (select 1 from "8 - coleta_campo".pesquisa_trecho t
          where t.usuario in (pe.nome, pe.email) and (p_consorcio is null or t.consorcio = p_consorcio)
            and (p_data_ini is null or t.inicio_ts::date >= p_data_ini) and (p_data_fim is null or t.inicio_ts::date <= p_data_fim))
        union
        select pe.id from public.perfil pe where exists (select 1 from "8 - coleta_campo".ocorrencia o
          where o.usuario in (pe.nome, pe.email) and (p_consorcio is null or o.consorcio = p_consorcio)
            and (p_data_ini is null or o.data_hora::date >= p_data_ini) and (p_data_fim is null or o.data_hora::date <= p_data_fim)))
      select coalesce(jsonb_agg(jsonb_build_object(
        'nome', pe.nome,
        'km_rede_pesquisado', ke.km,
        'km_andado', round((an.m/1000.0)::numeric,2),
        'vazamentos', oc.vaz,
        'fraudes', oc.fra,
        'vaz_km', case when ke.km>0 then round((oc.vaz/ke.km)::numeric,2) else 0 end,
        'ocorr_km', case when ke.km>0 then round(((oc.vaz+oc.fra)/ke.km)::numeric,2) else 0 end,
        'velocidade_kmh', case when an.s>0 then round(((an.m/1000.0)/(an.s/3600.0))::numeric,2) else 0 end) order by pe.nome), '[]'::jsonb)
      from univ join public.perfil pe on pe.id = univ.u
      cross join lateral (
        select round((coalesce(sum(coalesce(e.comprimento_m,st_length(e.geom))),0)/1000.0)::numeric,2) km
        from "8 - coleta_campo".pp_execucao e left join "2 - infra_agua".rede r on r.id=e.rede_id
        where e.colaborador_uuid=univ.u and (p_consorcio is null or r.consorcio=p_consorcio)
          and (p_data_ini is null or e.executado_em::date>=p_data_ini) and (p_data_fim is null or e.executado_em::date<=p_data_fim)) ke
      cross join lateral (
        select count(*) filter (where coalesce(o.tipo,'') not ilike 'fraude%') vaz, count(*) filter (where o.tipo ilike 'fraude%') fra
        from "8 - coleta_campo".ocorrencia o
        where o.usuario in (pe.nome, pe.email) and (p_consorcio is null or o.consorcio=p_consorcio)
          and (p_data_ini is null or o.data_hora::date>=p_data_ini) and (p_data_fim is null or o.data_hora::date<=p_data_fim)) oc
      cross join lateral (
        select coalesce(sum(t.comprimento_m),0) m, coalesce(sum(t.duracao_s),0) s from "8 - coleta_campo".pesquisa_trecho t
        where t.usuario in (pe.nome, pe.email) and (p_consorcio is null or t.consorcio=p_consorcio)
          and (p_data_ini is null or t.inicio_ts::date>=p_data_ini) and (p_data_fim is null or t.inicio_ts::date<=p_data_fim)) an
      where p_colaborador is null or univ.u = p_colaborador),
    -- matriz tipo × local (bloco "Ocorrências por tipo e local")
    'matriz', (
      select coalesce(jsonb_agg(jsonb_build_object('tipo', x.tipo, 'local', x.local, 'n', x.n, 'com_os', x.com_os) order by x.tipo, x.local), '[]'::jsonb)
      from (
        select coalesce(o.tipo,'—') tipo, coalesce(o.local_ref,'—') local, count(*) n, count(o.os_numero) com_os
        from "8 - coleta_campo".ocorrencia o
        where (p_colaborador is null or o.usuario in (v_nome, v_email))
          and (p_consorcio is null or o.consorcio = p_consorcio)
          and (p_data_ini is null or o.data_hora::date >= p_data_ini)
          and (p_data_fim is null or o.data_hora::date <= p_data_fim)
        group by 1, 2) x),
    -- LEGADO (sw v277): quadros por colaborador × tipo que saíram na v278 — remover após o deploy
    'ocorrencias', (
      select coalesce(jsonb_agg(jsonb_build_object('nome', x.nome, 'tipo', x.tipo, 'n', x.n, 'com_os', x.com_os) order by x.nome, x.tipo), '[]'::jsonb)
      from (
        select coalesce(pu.nome, o.usuario, '—') nome, coalesce(o.tipo,'—') tipo, count(*) n, count(o.os_numero) com_os
        from "8 - coleta_campo".ocorrencia o
        left join lateral (select p.nome from public.perfil p where o.usuario in (p.nome, p.email) limit 1) pu on true
        where (p_colaborador is null or o.usuario in (v_nome, v_email))
          and (p_consorcio is null or o.consorcio = p_consorcio)
          and (p_data_ini is null or o.data_hora::date >= p_data_ini)
          and (p_data_fim is null or o.data_hora::date <= p_data_fim)
        group by 1, 2) x)
  );
end; $function$;
