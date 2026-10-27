-- Vitrine (TV): atividades de campo com fotos + indicadores, ao vivo. 2026-10-26.
-- Acesso restrito a Geovana e Sander (checado aqui no banco E no botão do app).
-- Idempotente. Só leitura (função SECURITY DEFINER que lê as tabelas de campo).
create or replace function public.app_vitrine_dados(p_desde date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_email text; v_desde date;
begin
  select lower(email) into v_email from public.perfil where id = auth.uid();
  if v_email is null or v_email not in ('geovana.mendonca@aguasmg.com.br','sander.sirio@aguasmg.com.br') then
    raise exception 'sem permissão';
  end if;
  -- padrão: desde a última sexta-feira (ou hoje, se hoje for sexta)
  v_desde := coalesce(p_desde, (now() at time zone 'America/Sao_Paulo')::date
             - ((extract(isodow from (now() at time zone 'America/Sao_Paulo')::date)::int + 2) % 7));
  return jsonb_build_object(
   'desde', v_desde,
   'gerado', to_char(now() at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
   'ev', coalesce((select jsonb_agg(to_jsonb(ev) order by ev.quando) from (
     select 'Instalação de logger' tipo, l.data_instalacao quando, l.consorcio, coalesce(pu.nome, l.usuario_instalacao) quem,
       concat_ws(' · ','Logger '||l.numero_logger,'HD '||l.numero_hd, l.zone) descr,
       coalesce(l.gps_lat_inst::float8, st_y(st_transform(l.geom,4326))) lat, coalesce(l.gps_lon_inst::float8, st_x(st_transform(l.geom,4326))) lon,
       array_remove(array[l.foto_fachada,l.foto_cavalete_instalacao],null) fotos
     from "8 - coleta_campo".instalacao_logger_calibracao l left join public.perfil pu on lower(pu.email)=lower(l.usuario_instalacao)
     where l.data_instalacao >= v_desde
     union all
     select 'Remoção de logger', l.data_remocao, l.consorcio, coalesce(pu.nome, l.usuario_remocao), concat_ws(' · ','Logger '||l.numero_logger,'HD '||l.numero_hd, l.zone),
       coalesce(l.gps_lat_rem::float8, st_y(st_transform(l.geom,4326))), coalesce(l.gps_lon_rem::float8, st_x(st_transform(l.geom,4326))), array_remove(array[l.foto_cavalete_remocao],null)
     from "8 - coleta_campo".instalacao_logger_calibracao l left join public.perfil pu on lower(pu.email)=lower(l.usuario_remocao)
     where l.data_remocao >= v_desde
     union all
     select 'VRP — '||coalesce(o.origem,'OS'), o.executado_em at time zone 'America/Sao_Paulo', o.consorcio, p.nome,
       concat_ws(' · ', o.num_vrp, 'DMC '||o.dmc, o.status, case when o.press_jus_fin is not null then 'jusante final '||o.press_jus_fin||' mca' end),
       coalesce(o.gps_lat, st_y(st_transform(o.geom,4326))), coalesce(o.gps_lon, st_x(st_transform(o.geom,4326))),
       (select array_agg(v) from (select value v from jsonb_each_text(case when jsonb_typeof(o.fotos)='object' then o.fotos else '{}'::jsonb end) where value like '%/%' limit 4) z)
     from "8 - coleta_campo".vrp_os o left join public.perfil p on p.id=o.executado_por
     where o.executado_em >= (v_desde::timestamp at time zone 'America/Sao_Paulo') and o.status <> 'programada'
     union all
     select 'Ocorrência — '||o.tipo, o.data_hora, o.consorcio, coalesce(p.nome,o.usuario), concat_ws(' · ', o.local_ref, o.observacao), o.lat, o.lon, array_remove(array[o.foto],null)
     from "8 - coleta_campo".ocorrencia o left join public.perfil p on o.usuario in (p.nome,p.email) where o.data_hora >= v_desde
     union all
     select 'Recomposição de pavimento', r.created_at at time zone 'America/Sao_Paulo', r.consorcio, r.usuario_nome,
       concat_ws(' · ', r.servico_origem, r.tipo_pavimento, r.dimensao, 'OS '||r.os_sigos), r.lat::float8, r.lon::float8, array_remove(array[r.foto1,r.foto2],null)
     from "8 - coleta_campo".pav_recomposicao r where r.created_at >= (v_desde::timestamp at time zone 'America/Sao_Paulo')
     union all
     select 'Mapeamento de pressão', m.data_hora, m.consorcio, coalesce(p.nome,m.usuario), concat_ws(' · ', m.pressao_mca||' mca', 'HD '||m.numero_hd),
       m.gps_lat::float8, m.gps_lon::float8, array_remove(array[m.foto],null)
     from "8 - coleta_campo".mapeamento_pressao m left join public.perfil p on m.usuario in (p.nome,p.email) where m.data_hora >= v_desde
     union all
     select 'Obra — '||coalesce(i.atividade,i.tipo), i.ts at time zone 'America/Sao_Paulo', i.consorcio, i.autor_nome,
       concat_ws(' · ', i.iv_cod, i.iv_local, i.sub, case when i.valor is not null then i.valor||' '||coalesce(i.unidade,'') end, i.obs), null::float8, null::float8, i.fotos
     from "13 - projetos_obra".intervencao_avanco i where i.ts >= (v_desde::timestamp at time zone 'America/Sao_Paulo')
     union all
     select 'Solicitação de serviço — '||coalesce(a.tipo_label,a.tipo_codigo), a.data_hora at time zone 'America/Sao_Paulo', a.consorcio, p.nome,
       concat_ws(' · ','Matrícula '||a.matricula, a.observacao), a.lat, a.lon, array_remove(array[a.foto_hd],null)
     from "12 - retaguarda".abertura_servico a left join public.perfil p on p.id=a.usuario where a.data_hora >= (v_desde::timestamp at time zone 'America/Sao_Paulo')
   ) ev), '[]'::jsonb),
   'ind', jsonb_build_object(
     'loggers_em_campo', (select count(*) from "8 - coleta_campo".instalacao_logger_calibracao where data_instalacao is not null and data_remocao is null and coalesce(ativo,true)),
     'loggers_inst_mes', (select count(*) from "8 - coleta_campo".instalacao_logger_calibracao where data_instalacao >= date_trunc('month', now() at time zone 'America/Sao_Paulo')),
     'vrp_os_mes', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from "8 - coleta_campo".vrp_os
                     where coalesce(executado_em,aberto_em) >= date_trunc('month', now()) group by 1) x), '{}'::jsonb),
     'vrp_pend_abertas', (select count(*) from "8 - coleta_campo".vrp_pendencia where status='aberta'),
     'pav_mes', (select count(*) from "8 - coleta_campo".pav_recomposicao where created_at >= date_trunc('month', now())),
     'abertura_mes', (select count(*) from "12 - retaguarda".abertura_servico where data_hora >= date_trunc('month', now())),
     'abertura_sem_os', (select count(*) from "12 - retaguarda".abertura_servico where os_numero is null),
     'ocorr_sem_os', (select count(*) from "8 - coleta_campo".ocorrencia where os_numero is null),
     'ocorr_mes', (select count(*) from "8 - coleta_campo".ocorrencia where data_hora >= date_trunc('month', now() at time zone 'America/Sao_Paulo')),
     'pesq_km_andado', (select round(coalesce(sum(comprimento_m),0)/1000.0,1) from "8 - coleta_campo".pesquisa_trecho where inicio_ts >= date_trunc('month', now() at time zone 'America/Sao_Paulo')),
     'pesq_trechos', (select count(*) from "8 - coleta_campo".pesquisa_trecho where inicio_ts >= date_trunc('month', now() at time zone 'America/Sao_Paulo')),
     'pesq_km_rede', (select round((coalesce(sum(coalesce(comprimento_m, st_length(geom))),0)/1000.0)::numeric,1) from "8 - coleta_campo".pp_execucao where executado_em >= date_trunc('month', now())),
     'frota', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from "10 - Frotas".frota_veiculo where coalesce(ativo,true) group by 1) x), '{}'::jsonb),
     'veic_vinculados', (select count(*) from "10 - Frotas".frota_veiculo_vinculo where desvinculado_em is null),
     'checklists_hoje', (select count(*) from "10 - Frotas".frota_checklist_situacao where (criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date),
     'manut', coalesce((select jsonb_object_agg(status,n) from (select status,count(*) n from "10 - Frotas".frota_manutencao where status in ('pendente','aprovado','agendado') group by 1) x), '{}'::jsonb),
     'pessoas', coalesce((select jsonb_object_agg(coalesce(consorcio,'-'), n) from (select consorcio, count(*) n from public.perfil where coalesce(ativo,true) group by 1) x), '{}'::jsonb),
     'obra_avancos', (select count(*) from "13 - projetos_obra".intervencao_avanco where ts >= date_trunc('month', now())),
     'obra_pessoas', (select count(distinct autor) from "13 - projetos_obra".intervencao_avanco where ts >= date_trunc('month', now()))
   ));
end; $$;
revoke all on function public.app_vitrine_dados(date) from public, anon;
grant execute on function public.app_vitrine_dados(date) to authenticated;
notify pgrst, 'reload schema';
