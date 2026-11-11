-- Projetos › Pré-obra (2026-11-11)
--   1) "Liberação prefeitura" e "Liberação Transcon" eram a mesma coisa → fica uma etapa só (chave 'alvara', que já
--      tem histórico); a 'lib_transcon' sai do modelo (nenhuma intervenção tinha dado nela).
--      O nome segue a região da intervenção: ZA1004/Contagem = "Liberação TransCon", ZA0200/Betim = "Liberação Transbetim".
--   2) "Não se aplica" (Obras) em cada item da pré-obra, menos a OS SIGOS: status 'nao_aplica' conta como feito,
--      some da fila e leva junto a aprovação da Qualidade (vistoria). Dá para desfazer (volta a pendente).
--   3) Só a OS SIGOS trava a Execução. Os demais documentos da pré-obra continuam abertos com Obras (fila e prazo),
--      mas não seguram a abertura da fase 4.

-- 1) modelo -----------------------------------------------------------------------------------------------------
delete from "13 - projetos_obra".etapa_modelo where chave = 'lib_transcon';
update "13 - projetos_obra".etapa_modelo set nome = 'Liberação TransCon / Transbetim' where chave = 'alvara';

-- nome exibido de uma etapa, conforme a região da intervenção
create or replace function "13 - projetos_obra".proj_etapa_nome(p_chave text, p_nome text, p_consorcio text, p_cidade text)
returns text language sql immutable set search_path to 'public' as $$
  select case when p_chave = 'alvara' then
    case when p_consorcio = 'ZA0200' or (p_consorcio is null and p_cidade ilike '%betim%') then 'Liberação Transbetim'
         when p_consorcio = 'ZA1004' or (p_consorcio is null and p_cidade ilike '%contagem%') then 'Liberação TransCon'
         else 'Liberação TransCon / Transbetim' end
  else p_nome end $$;
revoke all on function "13 - projetos_obra".proj_etapa_nome(text,text,text,text) from public, anon;

-- 2) status / evento novos --------------------------------------------------------------------------------------
alter table "13 - projetos_obra".intervencao_etapa drop constraint if exists intervencao_etapa_status_check;
alter table "13 - projetos_obra".intervencao_etapa add constraint intervencao_etapa_status_check
  check (status in ('pendente','enviado','correcao','aguardando','aprovado','reprovado','nao_aplica'));
alter table "13 - projetos_obra".intervencao_etapa_evento drop constraint if exists intervencao_etapa_evento_evento_check;
alter table "13 - projetos_obra".intervencao_etapa_evento add constraint intervencao_etapa_evento_evento_check
  check (evento in ('liberado','reaberto','enviado','aprovado','reprovado','removido','escopo','legado','fase','nao_aplica','aplica'));

-- 3) proj_calc: nome por região, 'nao_aplica' = feito (e desliga a aprovação do documento), fase 4 só pela OS SIGOS
create or replace function "13 - projetos_obra".proj_calc(p_kind text, p_gid bigint)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_tipo text; v_cons text; v_cid text; v_leg boolean; v_lib boolean; v_arv jsonb; v_pct numeric;
  v_f3 timestamptz; v_f4 timestamptz; v_f5 timestamptz;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_base jsonb; v_itens jsonb; v_falta jsonb; v_atores jsonb;
  f2 boolean; f3 boolean; f5 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean; v_concl boolean;
  v_status text; v_fase int; v_exec boolean; v_feitos int; v_total int; v_desl int; v_leg_pend jsonb;
begin
  select tipo, consorcio, cidade into v_tipo, v_cons, v_cid from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then return null; end if;
  select legado, locked, arv, exec_pct, fase3_em, fase4_em, fase5_em into v_leg, v_lib, v_arv, v_pct, v_f3, v_f4, v_f5
    from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  v_leg := coalesce(v_leg, false); v_lib := coalesce(v_lib, false);
  v_pct := coalesce(v_pct, "13 - projetos_obra".proj_arv_pct(v_arv));

  -- 1ª passada: modelo + estado; a aprovação acompanha o "No escopo?" do seu documento e some se ele "não se aplica"
  with b as (
    select m.chave, m.ordem, m.fase, m.ator, m.natureza,
           "13 - projetos_obra".proj_etapa_nome(m.chave, m.nome, v_cons, v_cid) nome,
           m.aprova, m.pede_folha, m.prazo_aten, m.prazo_atraso,
           coalesce(e.ativo, m.padrao_ativo) ativo_p, coalesce(e.status, 'pendente') status, e.status_em, e.valor, e.folha,
           e.justificativa, e.por_nome, e.comentario
    from "13 - projetos_obra".etapa_modelo m
    left join "13 - projetos_obra".intervencao_etapa e on e.kind = p_kind and e.gid = p_gid and e.chave = m.chave
    where m.tipo = v_tipo and m.natureza in ('doc','link','os','aprovacao')
  ), c as (
    select b.*, case when b.natureza = 'aprovacao' then coalesce((select d.ativo_p and d.status <> 'nao_aplica' from b d where d.chave = b.aprova), false)
                     else b.ativo_p end ativo
    from b
  ), d as (
    select c.*, case when c.natureza = 'aprovacao' then c.status = 'aprovado'
                     when c.status = 'nao_aplica' then true
                     else coalesce((select a.status = 'aprovado' from c a
                                    where a.natureza = 'aprovacao' and a.aprova = c.chave and a.ativo limit 1),
                                   c.status = 'enviado') end feito
    from c
  )
  select coalesce(jsonb_agg(jsonb_build_object('chave',chave,'ordem',ordem,'fase',fase,'ator',ator,'natureza',natureza,
           'nome',nome,'aprova',aprova,'pede_folha',pede_folha,'prazo_aten',prazo_aten,'prazo_atraso',prazo_atraso,
           'ativo',ativo,'status',status,'status_em',status_em,'valor',valor,'folha',folha,'justificativa',justificativa,
           'por_nome',por_nome,'comentario',comentario,'feito',feito) order by ordem), '[]'::jsonb)
    into v_base from d;

  -- f3 = só a OS SIGOS (2026-11-11): os demais itens da pré-obra não seguram a Execução
  select coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 2), true),
         coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 3 and x->>'natureza' = 'os'), true),
         coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 5), true),
         coalesce(jsonb_agg(x->>'nome' order by (x->>'ordem')::int) filter (
           where (x->>'ativo')::boolean and (x->>'fase')::int = 1 and x->>'natureza' = 'doc'
             and not (x->>'status' = 'enviado' and (not (x->>'pede_folha')::boolean or nullif(x->>'folha','') is not null))), '[]'::jsonb),
         count(*) filter (where not (x->>'ativo')::boolean and nullif(x->>'justificativa','') is not null)
    into f2, f3, f5, v_falta, v_desl
    from jsonb_array_elements(v_base) x;

  -- legado pula só os portões de antes da obra (2 e 3); o Encerramento abre em 100% para todas
  a2 := v_lib;
  a3 := v_lib and (v_leg or f2);
  a4 := a3 and (v_leg or f3);
  a5 := a4 and v_pct >= 100;
  v_concl := a4 and v_pct >= 100 and f5;
  v_exec := a4 and v_pct < 100;
  v_status := case when not v_lib then 'configuracao' when not a3 then 'aprovacao' when not a4 then 'preobra'
                   when v_pct < 100 then case when v_pct <= 0 then 'exec_nao_iniciada' else 'exec_andamento' end
                   when not v_concl then 'encerramento' else 'concluida' end;
  v_fase := case v_status when 'configuracao' then 1 when 'aprovacao' then 2 when 'preobra' then 3
                          when 'encerramento' then 5 when 'concluida' then 6 else 4 end;

  -- 2ª passada: etapa aberta? acionável? relógio. No legado, o que falta antes da obra (fases 1–3, pendente/aguardando)
  -- fica marcado como pendência do legado: aparece na intervenção, mas não entra nas filas nem no "com quem está".
  select coalesce(jsonb_agg(s3.x || jsonb_build_object('aberta', s3.ab, 'acionavel', s3.ac, 'pend_legado', s3.pl, 'desde', s3.ds,
           'dias', case when s3.ds is not null then v_hoje - (s3.ds at time zone 'America/Sao_Paulo')::date end,
           'faixa', case when s3.ds is null or s3.x->>'prazo_aten' is null then null
                         when v_hoje - (s3.ds at time zone 'America/Sao_Paulo')::date <= (s3.x->>'prazo_aten')::int then 'ok'
                         when v_hoje - (s3.ds at time zone 'America/Sao_Paulo')::date <= (s3.x->>'prazo_atraso')::int then 'aten'
                         else 'atraso' end)
           order by (s3.x->>'ordem')::int), '[]'::jsonb)
    into v_itens
    from (
      select s2.x, s2.ab, s2.pode and not s2.leg ac, s2.pode and s2.leg pl,
             case when not s2.pode or s2.leg then null
                  when s2.x->>'natureza' = 'aprovacao' or s2.x->>'status' = 'correcao' then (s2.x->>'status_em')::timestamptz
                  when (s2.x->>'fase')::int = 3 then v_f3
                  when (s2.x->>'fase')::int = 5 then v_f5 end ds
      from (
        select s1.x, s1.ab,
               (s1.x->>'ativo')::boolean and s1.ab and (
                 (s1.x->>'natureza' in ('doc','link','os') and s1.x->>'status' in ('pendente','correcao'))
                 or (s1.x->>'natureza' = 'aprovacao' and s1.x->>'status' = 'aguardando')) pode,
               v_leg and (s1.x->>'fase')::int <= 3 and s1.x->>'status' in ('pendente','aguardando') leg
        from (
          select x, case (x->>'fase')::int when 1 then (not v_lib) or x->>'status' = 'correcao' or v_leg
                                           when 2 then a2 when 3 then a3 when 4 then a4 when 5 then a5 else false end ab
          from jsonb_array_elements(v_base) x) s1) s2) s3;
  select coalesce(jsonb_object_agg(a, n), '{}'::jsonb) into v_leg_pend from (
    select x->>'ator' a, count(*) n from jsonb_array_elements(v_itens) x where (x->>'pend_legado')::boolean group by 1) z;

  -- com quem está (+ pior prazo por ator)
  select coalesce(jsonb_object_agg(w.ator, jsonb_build_object('n', w.n, 'dias', w.dias, 'faixa', w.faixa)), '{}'::jsonb)
    into v_atores
    from (
      select z.ator, count(*) n, max(z.dias) dias,
             case max(case z.faixa when 'atraso' then 3 when 'aten' then 2 when 'ok' then 1 else 0 end)
               when 3 then 'atraso' when 2 then 'aten' when 1 then 'ok' end faixa
      from (
        select x->>'ator' ator, (x->>'dias')::int dias, x->>'faixa' faixa
          from jsonb_array_elements(v_itens) x where (x->>'acionavel')::boolean
        union all select 'eng', null, null where not v_lib                                   -- configurar + Liberar
        union all select 'obra', case when v_f4 is not null and not v_leg then v_hoje - (v_f4 at time zone 'America/Sao_Paulo')::date end,
                         null where v_exec                                                   -- lançar avanço
      ) z group by z.ator) w;

  if v_fase = 4 then v_feitos := round(v_pct); v_total := 100;
  else
    select count(*) filter (where case when v_fase = 1 then x->>'status' = 'enviado' else (x->>'feito')::boolean end), count(*)
      into v_feitos, v_total
      from jsonb_array_elements(v_itens) x where (x->>'ativo')::boolean and (x->>'fase')::int = least(v_fase, 5);
  end if;

  return jsonb_build_object('kind', p_kind, 'gid', p_gid, 'tipo', v_tipo, 'legado', v_leg, 'liberado', v_lib,
    'status', v_status, 'fase', v_fase, 'exec_pct', v_pct, 'exec_pendente', v_exec,
    'em_correcao', exists (select 1 from jsonb_array_elements(v_itens) x where (x->>'ativo')::boolean and x->>'status' = 'correcao'),
    'aberta', jsonb_build_object('2', a2, '3', a3, '4', a4, '5', a5), 'concluida', v_concl,
    'f1_falta', v_falta, 'atores', v_atores, 'prog', jsonb_build_object('feitos', v_feitos, 'total', v_total),
    'desligados', v_desl, 'legado_pend', v_leg_pend, 'fase3_em', v_f3, 'fase4_em', v_f4, 'fase5_em', v_f5, 'itens', v_itens);
end $function$;

-- 4) "Não se aplica" (Obras) — itens doc/link da pré-obra; a OS SIGOS não tem ----------------------------------
create or replace function public.app_proj_etapa_nao_aplica(p_kind text, p_gid bigint, p_chave text, p_nao_aplica boolean)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_id uuid := auth.uid(); v_tipo text; m record; it jsonb; v_nome text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if p_nao_aplica is null then raise exception 'informe se a etapa se aplica'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then raise exception 'intervenção não encontrada'; end if;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = p_chave;
  if not found or m.fase <> 3 or m.natureza not in ('doc','link') then raise exception 'esta etapa não tem "Não se aplica"'; end if;
  if not "13 - projetos_obra".proj_ator_pode(v_id, m.ator) then raise exception 'sem permissão (responsáveis de obras)'; end if;
  select x into it from jsonb_array_elements("13 - projetos_obra".proj_calc(p_kind, p_gid)->'itens') x where x->>'chave' = p_chave;
  if not (it->>'ativo')::boolean then raise exception 'esta etapa está fora do escopo'; end if;
  if not (it->>'aberta')::boolean then raise exception 'a pré-obra ainda não foi liberada'; end if;
  if p_nao_aplica and it->>'status' not in ('pendente','correcao') then
    raise exception 'só dá para marcar "não se aplica" em item pendente'; end if;
  if not p_nao_aplica and it->>'status' <> 'nao_aplica' then raise exception 'esta etapa não está como "não se aplica"'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  insert into "13 - projetos_obra".intervencao_etapa (kind, gid, chave, status, status_em, por_uuid, por_nome)
  values (p_kind, p_gid, p_chave, case when p_nao_aplica then 'nao_aplica' else 'pendente' end, now(), v_id, v_nome)
  on conflict (kind, gid, chave) do update set status = excluded.status, status_em = now(), comentario = null,
    por_uuid = excluded.por_uuid, por_nome = excluded.por_nome, atualizado_em = now();
  insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, por_uuid, por_nome)
  values (p_kind, p_gid, p_chave, case when p_nao_aplica then 'nao_aplica' else 'aplica' end, v_id, v_nome);
  perform "13 - projetos_obra".proj_fase_sync(p_kind, p_gid);
  return "13 - projetos_obra".proj_calc(p_kind, p_gid) - 'itens';
end $function$;
revoke all on function public.app_proj_etapa_nao_aplica(text,bigint,text,boolean) from public, anon;
grant execute on function public.app_proj_etapa_nao_aplica(text,bigint,text,boolean) to authenticated;

-- 5) Resumo (app_proj_eventos): nome da etapa pela região -------------------------------------------------------
create or replace function public.app_proj_eventos(p_de date default null, p_ate date default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(z.j order by z.em desc, z.ord desc) from (
    select e.em, lpad(e.id::text, 12, '0') ord, jsonb_build_object('id',e.id,'kind',e.kind,'gid',e.gid,'iv',v.id,'projeto',v.projeto,
        'cidade',v.cidade,'consorcio',v.consorcio,'tipo',v.tipo,'chave',e.chave,
        'nome',"13 - projetos_obra".proj_etapa_nome(e.chave, m.nome, v.consorcio, v.cidade),'ator',m.ator,'natureza',m.natureza,
        'evento',e.evento,'valor',e.valor,'comentario',e.comentario,'por',e.por_nome,'em',e.em) j
      from (select * from "13 - projetos_obra".intervencao_etapa_evento x
             where x.evento <> 'legado'
               and (p_de is null or (x.em at time zone 'America/Sao_Paulo')::date >= p_de)
               and (p_ate is null or (x.em at time zone 'America/Sao_Paulo')::date <= p_ate)
             order by x.em desc limit 3000) e
      left join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
      left join "13 - projetos_obra".etapa_modelo m on m.tipo = v.tipo and m.chave = e.chave
    union all
    select q.em, q.ord, jsonb_build_object('id',q.ord,'kind',r.kind,'gid',r.gid,'iv',v.id,'projeto',v.projeto,'cidade',v.cidade,
        'consorcio',v.consorcio,'tipo',v.tipo,'chave','ensaio_reaterro',
        'nome','Ensaio de reaterro · ' || case when r.rotulo = '' then 'Vala da rede' else r.rotulo end,
        'ator',q.ator,'natureza','ensaio','evento',q.evento,'valor',q.valor,'comentario',q.comentario,'por',q.por,'em',q.em) j
      from (
        select ev.proj_reaterro_id rid, ev.em, 'ev' || lpad(ev.id::text, 10, '0') ord,
               case ev.evento when 'pedido' then 'ensaio_pedido' else 'reaterro_refeito' end evento, 'obra' ator, null::text valor,
               case when ev.evento = 'refeito' then 'refeito em ' || to_char(ev.data, 'DD/MM/YYYY') end comentario, ev.por_nome por
          from "8 - coleta_campo".pav_reaterro_evento ev
         where ev.proj_reaterro_id is not null and ev.evento in ('pedido','refeito')
        union all
        select en.proj_reaterro_id, en.created_at, 'en' || en.id::text, 'ensaio_' || en.resultado, 'qual', en.tentativa::text, en.obs,
               coalesce(en.usuario_nome, en.usuario_email)
          from "8 - coleta_campo".pav_reaterro_ensaio en
         where en.proj_reaterro_id is not null
      ) q
      join "13 - projetos_obra".proj_reaterro r on r.id = q.rid
      left join "13 - projetos_obra".vw_iv v on v.kind = r.kind and v.gid = r.gid
     where (p_de is null or (q.em at time zone 'America/Sao_Paulo')::date >= p_de)
       and (p_ate is null or (q.em at time zone 'America/Sao_Paulo')::date <= p_ate)
  ) z), '[]'::jsonb);
end $function$;

-- 6) intervenções que já tinham a OS SIGOS e estavam paradas só por documento da pré-obra: abre a Execução agora
do $$ declare r record; begin
  for r in select kind, gid from "13 - projetos_obra".intervencao_estado where locked and not coalesce(legado, false) and fase4_em is null loop
    perform "13 - projetos_obra".proj_fase_sync(r.kind, r.gid);
  end loop;
end $$;
