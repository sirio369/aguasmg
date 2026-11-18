-- Projetos › pipeline sem portões de fase (2026-11-18)
-- Pedido do usuário: tirar as travas que impedem o avanço do pipeline do início ao fim.
--   • Toda fase fica ABERTA desde o início: Qualidade aprova sem esperar o Liberar, Obras anexa a pré-obra e o
--     Encerramento, e lança avanço na Execução sem esperar aprovação da Qualidade, OS SIGOS ou execução 100%.
--     (c->'aberta' e item->'aberta' = true em todas as fases 2–5; é o que as RPCs de escrita conferem.)
--   • Continuam: os papéis (Engenharia / Qualidade / 3 cargos de Obras), o Liberar exigindo os anexos da fase 1
--     (ele só manda o pacote para a Qualidade), a trava do ensaio de reaterro → recomposição, e "Concluída" só com
--     tudo feito.
--   • O status/fase da intervenção, as filas e os avisos de "fase aberta" seguem a ordem do pipeline (onde ela está),
--     agora em c->'chegou'. Item de fase ainda não alcançada só entra na fila se estiver aguardando aprovação ou em
--     correção (alguém precisa agir nele) — as pendências comuns não lotam as filas antes da hora.
-- Só banco; o front já lê as flags do servidor. Sem mudança de assinatura.

create or replace function "13 - projetos_obra".proj_calc(p_kind text, p_gid bigint)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tipo text; v_cons text; v_cid text; v_leg boolean; v_lib boolean; v_arv jsonb; v_pct numeric;
  v_f3 timestamptz; v_f4 timestamptz; v_f5 timestamptz;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_base jsonb; v_itens jsonb; v_falta jsonb; v_atores jsonb;
  f2 boolean; f3 boolean; f5 boolean; r2 boolean; r3 boolean; r4 boolean; r5 boolean; v_concl boolean;
  v_status text; v_fase int; v_exec boolean; v_feitos int; v_total int; v_desl int; v_leg_pend jsonb;
begin
  select tipo, consorcio, cidade into v_tipo, v_cons, v_cid from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then return null; end if;
  select legado, locked, arv, exec_pct, fase3_em, fase4_em, fase5_em into v_leg, v_lib, v_arv, v_pct, v_f3, v_f4, v_f5
    from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  v_leg := coalesce(v_leg, false); v_lib := coalesce(v_lib, false);
  v_pct := coalesce(v_pct, "13 - projetos_obra".proj_arv_pct(v_arv));

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

  select coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 2), true),
         coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 3 and x->>'natureza' = 'os'), true),
         coalesce(bool_and((x->>'feito')::boolean) filter (where (x->>'ativo')::boolean and (x->>'fase')::int = 5), true),
         coalesce(jsonb_agg(x->>'nome' order by (x->>'ordem')::int) filter (
           where (x->>'ativo')::boolean and (x->>'fase')::int = 1 and x->>'natureza' = 'doc'
             and not (x->>'status' = 'enviado' and (not (x->>'pede_folha')::boolean or nullif(x->>'folha','') is not null))), '[]'::jsonb),
         count(*) filter (where not (x->>'ativo')::boolean and nullif(x->>'justificativa','') is not null)
    into f2, f3, f5, v_falta, v_desl
    from jsonb_array_elements(v_base) x;

  -- r* = fase ALCANÇADA na ordem do pipeline (status, filas, avisos). Abertura para trabalhar = sempre (sem portões).
  r2 := v_lib;
  r3 := v_lib and (v_leg or f2);
  r4 := r3 and (v_leg or f3);
  r5 := r4 and v_pct >= 100;
  v_concl := r4 and v_pct >= 100 and f5;
  v_exec := r4 and v_pct < 100;
  v_status := case when not v_lib then 'configuracao' when not r3 then 'aprovacao' when not r4 then 'preobra'
                   when v_pct < 100 then case when v_pct <= 0 then 'exec_nao_iniciada' else 'exec_andamento' end
                   when not v_concl then 'encerramento' else 'concluida' end;
  v_fase := case v_status when 'configuracao' then 1 when 'aprovacao' then 2 when 'preobra' then 3
                          when 'encerramento' then 5 when 'concluida' then 6 else 4 end;

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
               (s1.x->>'ativo')::boolean and s1.ab
               and (s1.ch or s1.x->>'status' in ('aguardando','correcao'))   -- fase não alcançada: só o que espera alguém
               and (
                 (s1.x->>'natureza' in ('doc','link','os') and s1.x->>'status' in ('pendente','correcao'))
                 or (s1.x->>'natureza' = 'aprovacao' and s1.x->>'status' = 'aguardando')) pode,
               v_leg and (s1.x->>'fase')::int <= 3 and s1.x->>'status' in ('pendente','aguardando') leg
        from (
          select x,
                 case (x->>'fase')::int when 1 then (not v_lib) or x->>'status' = 'correcao' or v_leg else true end ab,
                 case (x->>'fase')::int when 1 then true when 2 then r2 when 3 then r3 when 4 then r4 when 5 then r5 else false end ch
          from jsonb_array_elements(v_base) x) s1) s2) s3;
  select coalesce(jsonb_object_agg(a, n), '{}'::jsonb) into v_leg_pend from (
    select x->>'ator' a, count(*) n from jsonb_array_elements(v_itens) x where (x->>'pend_legado')::boolean group by 1) z;

  select coalesce(jsonb_object_agg(w.ator, jsonb_build_object('n', w.n, 'dias', w.dias, 'faixa', w.faixa)), '{}'::jsonb)
    into v_atores
    from (
      select z.ator, count(*) n, max(z.dias) dias,
             case max(case z.faixa when 'atraso' then 3 when 'aten' then 2 when 'ok' then 1 else 0 end)
               when 3 then 'atraso' when 2 then 'aten' when 1 then 'ok' end faixa
      from (
        select x->>'ator' ator, (x->>'dias')::int dias, x->>'faixa' faixa
          from jsonb_array_elements(v_itens) x where (x->>'acionavel')::boolean
        union all select 'eng', null, null where not v_lib
        union all select 'obra', case when v_f4 is not null and not v_leg then v_hoje - (v_f4 at time zone 'America/Sao_Paulo')::date end,
                         null where v_exec
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
    'aberta', jsonb_build_object('2', true, '3', true, '4', true, '5', true),
    'chegou', jsonb_build_object('2', r2, '3', r3, '4', r4, '5', r5), 'concluida', v_concl,
    'f1_falta', v_falta, 'atores', v_atores, 'prog', jsonb_build_object('feitos', v_feitos, 'total', v_total),
    'desligados', v_desl, 'legado_pend', v_leg_pend, 'fase3_em', v_f3, 'fase4_em', v_f4, 'fase5_em', v_f5, 'itens', v_itens);
end $function$;

-- carimbo/aviso de "fase aberta" passa a seguir a fase ALCANÇADA (c->'chegou'), não a abertura (que agora é sempre)
create or replace function "13 - projetos_obra".proj_fase_sync(p_kind text, p_gid bigint)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_lib boolean; v_leg boolean; e3 timestamptz; e4 timestamptz; e5 timestamptz; e6 timestamptz; c jsonb; v_nome text;
begin
  select locked, legado, fase3_em, fase4_em, fase5_em, concluida_em into v_lib, v_leg, e3, e4, e5, e6
    from "13 - projetos_obra".intervencao_estado where kind = p_kind and gid = p_gid;
  if not found or v_leg or not v_lib then return; end if;
  c := "13 - projetos_obra".proj_calc(p_kind, p_gid);
  if c is null then return; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = auth.uid();
  if (c->'chegou'->>'3')::boolean and e3 is null then
    update "13 - projetos_obra".intervencao_estado set fase3_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '3', auth.uid(), v_nome);
  end if;
  if (c->'chegou'->>'4')::boolean and e4 is null then
    update "13 - projetos_obra".intervencao_estado set fase4_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '4', auth.uid(), v_nome);
  end if;
  if (c->'chegou'->>'5')::boolean and e5 is null then
    update "13 - projetos_obra".intervencao_estado set fase5_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '5', auth.uid(), v_nome);
  end if;
  if (c->>'concluida')::boolean and e6 is null then
    update "13 - projetos_obra".intervencao_estado set concluida_em = now() where kind = p_kind and gid = p_gid;
    insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, evento, valor, por_uuid, por_nome) values (p_kind, p_gid, 'fase', '6', auth.uid(), v_nome);
  end if;
end $function$;
