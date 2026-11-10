-- Vitrine unificada (2026-11-10): um feed só de serviços executados — OS do SIGOS + lançamentos do AcquaHub —
-- sem separar por origem. Cada item tem família de serviço (mesma taxonomia do SIGOS/RDO: sigos_servico_grupo /
-- rdo_familia_ordem), serviço legível, ZA, dia/hora, quem (equipe SIGOS ou colaborador do app), local e fotos.
-- Deduplicação: quando um lançamento do app tem a OS SIGOS do mesmo serviço (logger: OS de instalação/remoção;
-- VRP: os_sigos) e essa OS está executada, fica um item só — o do app (tem foto, pessoa e GPS) com a OS ao lado.
-- Substitui, no front, app_vitrine_dados + app_vitrine_sigos (as duas seguem no banco p/ app em cache ≤ v345).
-- Gate igual às outras RPCs da Vitrine: admin ou dev_acesso.

create or replace function public.app_vitrine_feed(p_desde date default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $function$
declare v_id uuid := auth.uid(); v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
        v_desde date; v_mes date; v_ini date; v_it date;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id = v_id and (funcao = 'admin' or coalesce(dev_acesso, false))) then
    raise exception 'sem permissão'; end if;
  v_desde := coalesce(p_desde, v_hoje - ((extract(isodow from v_hoje)::int + 2) % 7));   -- última sexta
  v_mes   := date_trunc('month', v_hoje)::date;
  v_ini   := least(v_desde, v_mes, v_hoje - 29);   -- janela das contagens (período, mês, 30 dias)
  v_it    := least(v_desde, v_hoje - 6);           -- janela dos itens (mapa, dia a dia, fotos)
  return (
  with
  app as (
    -- Loggers
    select l.consorcio za, 'Loggers de pressão'::text f, 'Instalação de logger'::text s, l.data_instalacao ts,
           coalesce(pu.nome, l.usuario_instalacao) quem, concat_ws(' · ', 'Logger ' || l.numero_logger, 'HD ' || l.numero_hd, l.zone) d,
           coalesce(l.gps_lat_inst::float8, st_y(st_transform(l.geom, 4326))) lat, coalesce(l.gps_lon_inst::float8, st_x(st_transform(l.geom, 4326))) lon,
           array_remove(array[l.foto_fachada, l.foto_cavalete_instalacao], null) fotos, nullif(btrim(l.os_copasa_instalacao), '') os
      from "8 - coleta_campo".instalacao_logger_calibracao l left join public.perfil pu on lower(pu.email) = lower(l.usuario_instalacao)
     where l.data_instalacao::date between v_ini and v_hoje
    union all
    select l.consorcio, 'Loggers de pressão', 'Remoção de logger', l.data_remocao,
           coalesce(pu.nome, l.usuario_remocao), concat_ws(' · ', 'Logger ' || l.numero_logger, 'HD ' || l.numero_hd, l.zone),
           coalesce(l.gps_lat_rem::float8, st_y(st_transform(l.geom, 4326))), coalesce(l.gps_lon_rem::float8, st_x(st_transform(l.geom, 4326))),
           array_remove(array[l.foto_cavalete_remocao], null), nullif(btrim(l.os_copasa_remocao), '')
      from "8 - coleta_campo".instalacao_logger_calibracao l left join public.perfil pu on lower(pu.email) = lower(l.usuario_remocao)
     where l.data_remocao::date between v_ini and v_hoje
    union all
    -- Mapeamento de pressão
    select m.consorcio, 'Loggers de pressão', 'Mapeamento de pressão', m.data_hora, coalesce(p.nome, m.usuario),
           concat_ws(' · ', m.pressao_mca || ' mca', 'HD ' || m.numero_hd), m.gps_lat::float8, m.gps_lon::float8, array_remove(array[m.foto], null), null
      from "8 - coleta_campo".mapeamento_pressao m left join public.perfil p on m.usuario in (p.nome, p.email)
     where m.data_hora::date between v_ini and v_hoje
    union all
    -- VRP (OS de manutenção concluídas)
    select o.consorcio, 'VRP', 'Manutenção de VRP' || case o.status when 'concluida_pendencia' then ' (com pendência)' when 'improdutiva' then ' (improdutiva)' else '' end,
           o.executado_em at time zone 'America/Sao_Paulo', p.nome,
           concat_ws(' · ', o.num_vrp, 'DMC ' || o.dmc, case when o.press_jus_fin is not null then 'jusante final ' || o.press_jus_fin || ' mca' end),
           coalesce(o.gps_lat, st_y(st_transform(o.geom, 4326))), coalesce(o.gps_lon, st_x(st_transform(o.geom, 4326))),
           (select array_agg(v) from (select value v from jsonb_each_text(case when jsonb_typeof(o.fotos) = 'object' then o.fotos else '{}'::jsonb end)
                                       where value like '%/%' limit 4) z),
           nullif(btrim(o.os_sigos), '')
      from "8 - coleta_campo".vrp_os o left join public.perfil p on p.id = o.executado_por
     where o.status in ('concluida', 'concluida_pendencia', 'improdutiva')
       and (o.executado_em at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje
    union all
    -- Pesquisa de vazamento: ocorrências registradas (vazamento / fraude)
    select o.consorcio, case when o.tipo ilike 'Fraude%' then 'Fiscalização de irregularidade' else 'Pesquisa de vazamento' end,
           o.tipo, o.data_hora, coalesce(p.nome, o.usuario), concat_ws(' · ', o.local_ref, o.observacao), o.lat, o.lon, array_remove(array[o.foto], null), null
      from "8 - coleta_campo".ocorrencia o left join public.perfil p on o.usuario in (p.nome, p.email)
     where o.data_hora::date between v_ini and v_hoje
    union all
    -- Pavimento a recompor (1 por ponto levantado)
    select min(r.consorcio), 'Recomposição de pavimento', 'Pavimento a recompor (levantamento)', min(r.created_at at time zone 'America/Sao_Paulo'),
           min(r.usuario_nome), concat_ws(' · ', min(r.servico_origem), string_agg(r.tipo_pavimento, ', ' order by r.tipo_pavimento), 'OS ' || min(r.os_sigos)),
           avg(r.lat::float8), avg(r.lon::float8),
           (array_remove(array_agg(r.foto1) || array_agg(r.foto2), null))[1:4], null
      from "8 - coleta_campo".pav_recomposicao r
     where (r.created_at at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje
     group by r.grupo
    union all
    -- Obras: avanço lançado no dia por intervenção
    select min(case a.consorcio when 'Águas Integradas' then 'ZA1004' when 'Eficiência Hídrica' then 'ZA0200' else a.consorcio end),
           'Obras (projetos)', 'Avanço de obra — ' || coalesce(min(v.tipo_origem), min(a.tipo), 'intervenção'),
           max(a.ts at time zone 'America/Sao_Paulo'), string_agg(distinct a.autor_nome, ', '),
           concat_ws(' · ', min(a.iv_cod), coalesce(min(a.iv_local), min(v.projeto)), string_agg(distinct coalesce(a.atividade, a.sub), ', ')),
           null::float8, null::float8,
           (array_remove(string_to_array(string_agg(array_to_string(a.fotos, '|'), '|'), '|'), ''))[1:4],
           null
      from "13 - projetos_obra".intervencao_avanco a
      left join "13 - projetos_obra".vw_iv v on v.kind = a.kind and v.gid = a.gid
     where (a.ts at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje
     group by (a.ts at time zone 'America/Sao_Paulo')::date, a.kind, a.gid
    union all
    -- Atendimento comercial: solicitações de serviço do campo
    select a.consorcio, 'Atendimento comercial', 'Solicitação de serviço — ' || coalesce(a.tipo_label, a.tipo_codigo),
           a.data_hora at time zone 'America/Sao_Paulo', p.nome, 'Matrícula ' || a.matricula, a.lat, a.lon, array_remove(array[a.foto_hd], null), null
      from "12 - retaguarda".abertura_servico a left join public.perfil p on p.id = a.usuario
     where (a.data_hora at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje
  ),
  sg as (   -- OS executadas e encerradas sem execução (mesma base do RDO)
    select s.base, s.numero, s.consorcio za, public.sigos_servico_grupo(s.desc_servico) f, public.sigos_servico_nome(s.desc_servico) s,
           s.data_execucao ts, s.situacao sit
      from "17 - sigos".vw_os_situacao s
     where s.situacao in ('executada', 'encerrada_sem_execucao') and s.data_execucao::date between v_ini and v_hoje
  ),
  dup as (   -- OS executadas que o app já mostra (fica o item do app, com a OS ao lado)
    select distinct sg.base from app join sg on sg.sit = 'executada' and sg.base = public.sigos_os_base(app.os)
     where app.os is not null
  ),
  u as (
    select app.za, app.f, app.s, app.ts, app.quem, app.d, app.lat, app.lon, coalesce(app.fotos, '{}') fotos,
           case when exists (select 1 from sg where sg.sit = 'executada' and sg.base = public.sigos_os_base(app.os)) then app.os end os
      from app
    union all
    select sg.za, sg.f, sg.s, sg.ts,
           coalesce(nullif(btrim(e.equipe), ''), nullif(btrim(e.responsavel), ''), nullif(btrim(a.equipe), '')),
           coalesce(e.endereco, a.endereco),
           round(coalesce(e.lat_foto, e.lat_imovel)::numeric, 6)::float8, round(coalesce(e.lon_foto, e.lon_imovel)::numeric, 6)::float8,
           '{}'::text[], sg.numero
      from sg
      left join "17 - sigos".os_encerrada e on e.numero = sg.numero
      left join "17 - sigos".os_aberta a on a.numero = sg.numero and e.numero is null
     where sg.sit = 'executada' and sg.base not in (select base from dup)
  ),
  ux as (select u.*, u.ts::date dia from u where u.za in ('ZA1004', 'ZA0200') and u.ts is not null),
  cart as (   -- serviços em aberto aguardando execução (tira o que já aparece nas Encerradas)
    select a.consorcio za, public.sigos_servico_grupo(a.desc_servico) f, count(*) n,
           count(*) filter (where a.limite < now() at time zone 'America/Sao_Paulo') vencidas,
           round(avg(v_hoje - a.abertura::date)) idade
      from "17 - sigos".os_aberta a
     where a.status not ilike 'EXECUTADA%'
       and not exists (select 1 from "17 - sigos".os_encerrada e where public.sigos_os_base(e.numero) = public.sigos_os_base(a.numero))
     group by 1, 2
  ),
  quem_mes as (
    select za, quem, count(*) n from ux where dia >= v_mes and quem is not null group by 1, 2 order by 3 desc limit 16
  )
  select jsonb_build_object(
    'desde', v_desde, 'mes', v_mes, 'hoje', v_hoje, 'itens_desde', v_it,
    'gerado', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    'cobertura', (select jsonb_object_agg(c.za, jsonb_build_object('relacao_em', c.relacao_em, 'encerradas_ate', c.encerradas_ate)) from "17 - sigos".vw_carga_cobertura c),
    -- contagem por dia × ZA × família (executado); nex = OS encerradas sem execução
    'agg', coalesce((select jsonb_agg(jsonb_build_object('dia', dia, 'za', za, 'f', f, 'n', n) order by dia)
                       from (select dia, za, f, count(*) n from ux group by 1, 2, 3) q), '[]'::jsonb),
    'nex', coalesce((select jsonb_agg(jsonb_build_object('dia', d, 'za', za, 'f', f, 'n', n))
                       from (select ts::date d, za, f, count(*) n from sg where sit <> 'executada' group by 1, 2, 3) q), '[]'::jsonb),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'f', f, 's', s, 'dia', dia, 'h', to_char(ts, 'HH24:MI'), 'quem', quem, 'd', d,
                                                            'lat', lat, 'lon', lon, 'fotos', to_jsonb(fotos[1:4]), 'os', os) order by ts)
                         from ux where dia >= v_it), '[]'::jsonb),
    'quem_mes', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'nome', quem, 'n', n) order by n desc) from quem_mes), '[]'::jsonb),
    'carteira', coalesce((select jsonb_agg(jsonb_build_object('za', za, 'f', f, 'n', n, 'venc', vencidas, 'idade', idade)) from cart), '[]'::jsonb),
    'ind', jsonb_build_object(
      'loggers_em_campo', (select count(*) from "8 - coleta_campo".instalacao_logger_calibracao where data_instalacao is not null and data_remocao is null and coalesce(ativo, true)),
      'vrp_pend_abertas', (select count(*) from "8 - coleta_campo".vrp_pendencia where status = 'aberta'),
      'abertura_sem_os', (select count(*) from "12 - retaguarda".abertura_servico where os_numero is null),
      'ocorr_sem_os', (select count(*) from "8 - coleta_campo".ocorrencia where os_numero is null),
      'pesq_km_andado', (select round(coalesce(sum(comprimento_m), 0) / 1000.0, 1) from "8 - coleta_campo".pesquisa_trecho where inicio_ts >= v_mes),
      'pesq_km_rede', (select round((coalesce(sum(coalesce(comprimento_m, st_length(geom))), 0) / 1000.0)::numeric, 1) from "8 - coleta_campo".pp_execucao
                        where executado_em >= v_mes),
      'frota', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from "10 - Frotas".frota_veiculo where coalesce(ativo, true) group by 1) x), '{}'::jsonb),
      'manut', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from "10 - Frotas".frota_manutencao where status in ('pendente', 'aprovado', 'agendado') group by 1) x), '{}'::jsonb)
    )
  ));
end $function$;

revoke all on function public.app_vitrine_feed(date) from public, anon;
grant execute on function public.app_vitrine_feed(date) to authenticated;
