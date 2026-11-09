-- =====================================================================================
-- Ajustes de 09/11/2026 (depois do RDO diário — docs/migracao_rdo_diario.sql):
--  1) public.rdo_periodo(de, ate) — linhas do RDO JÁ REVISADAS (fechado = snapshot; senão rascunho
--     com a revisão aplicada), sem as ocultas, por dia × ZA. Base da Vitrine.
--  2) app_vitrine_rdo(desde) — a Vitrine (TV) passa a mostrar o RDO de cada dia (gate = Vitrine:
--     admin ou dev_acesso).
--  3) Correção de OS pelo painel "Vínculo das OS": app_sigos_os_corrigir grava o número novo no
--     campo de origem (pavimento, projetos, VRP, pesquisa, APR, loggers…) e guarda o histórico em
--     "17 - sigos".os_correcao.
-- =====================================================================================

-- 1) Linhas revisadas de um período --------------------------------------------------------------
create or replace function public.rdo_periodo(p_de date, p_ate date)
returns table(dia date, za text, fechado boolean, linhas jsonb)
language sql stable security definer set search_path to 'public' as $$
  with ev as (select * from public.rdo_eventos(p_de, p_ate)),
  lin as (
    select e.dia, e.za, coalesce(i.tipo, e.tipo) tipo, e.fonte, e.ordem, coalesce(i.descricao, e.descricao) descr,
           coalesce(i.oculto, false) oculto
      from ev e
      left join "12 - retaguarda".rdo_item i on i.dia = e.dia and i.za = e.za and i.chave = e.chave
    union all
    select i.dia, i.za, i.tipo, 'Manual', 90, i.descricao, i.oculto
      from "12 - retaguarda".rdo_item i where i.chave is null and i.dia between p_de and p_ate
  ),
  aberto as (
    select l.dia, l.za, jsonb_agg(jsonb_build_object('tipo', l.tipo, 'fonte', l.fonte, 'desc', l.descr)
             order by case l.tipo when 'Execução' then 1 when 'Em andamento' then 2 when 'Ocorrência' then 3 when 'Pendência' then 4 else 5 end,
                      l.ordem, l.descr) linhas
      from lin l where not l.oculto group by l.dia, l.za
  )
  select a.dia, a.za, false, a.linhas from aberto a
   where not exists (select 1 from "12 - retaguarda".rdo_dia f where f.dia = a.dia and f.za = a.za)
  union all
  select f.dia, f.za, true,
         coalesce((select jsonb_agg(jsonb_build_object('tipo', x->>'tipo', 'fonte', x->>'fonte', 'desc', x->>'desc') order by o)
                     from jsonb_array_elements(f.snapshot) with ordinality s(x, o)
                    where not coalesce((x->>'oculto')::boolean, false)), '[]'::jsonb)
    from "12 - retaguarda".rdo_dia f where f.dia between p_de and p_ate;
$$;
revoke all on function public.rdo_periodo(date, date) from public, anon, authenticated;

-- 2) Vitrine -----------------------------------------------------------------------------------------
-- mesmo período padrão do app_vitrine_dados: desde a última sexta-feira (ou hoje, se for sexta)
create or replace function public.app_vitrine_rdo(p_desde date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_desde date;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists (select 1 from public.perfil where id = v_id and (funcao = 'admin' or coalesce(dev_acesso, false))) then
    raise exception 'sem permissão'; end if;
  v_desde := coalesce(p_desde, v_hoje - ((extract(isodow from v_hoje)::int + 2) % 7));
  return jsonb_build_object('desde', v_desde,
    'dias', coalesce((select jsonb_agg(jsonb_build_object('dia', r.dia, 'za', r.za, 'fechado', r.fechado, 'linhas', r.linhas) order by r.dia, r.za)
                        from public.rdo_periodo(v_desde, v_hoje) r where jsonb_array_length(r.linhas) > 0), '[]'::jsonb));
end $$;
revoke all on function public.app_vitrine_rdo(date) from public, anon;
grant execute on function public.app_vitrine_rdo(date) to authenticated;

-- 3) Correção de OS -----------------------------------------------------------------------------------
create table if not exists "17 - sigos".os_correcao (
  id bigint generated always as identity primary key,
  modulo text not null, campo text not null, ref text not null,
  os_antes text, os_depois text not null, motivo text,
  linhas int not null,
  por_uuid uuid, por_nome text, em timestamptz not null default now()
);
alter table "17 - sigos".os_correcao enable row level security;
create index if not exists os_correcao_ref_idx on "17 - sigos".os_correcao (modulo, ref);

-- p_mod/p_campo/p_ref = exatamente o que app_sigos_vinculos devolve (mod, campo, ref); p_os_antes = o texto
-- que está gravado hoje (trava contra corrigir algo que outra pessoa já mudou). Grava só os dígitos.
create or replace function public.app_sigos_os_corrigir(p_mod text, p_campo text, p_ref text, p_os_antes text, p_os_nova text, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_nome text; v_nova text := regexp_replace(coalesce(p_os_nova, ''), '\D', '', 'g');
        v_antes text := btrim(coalesce(p_os_antes, '')); n int := 0; v_col text;
begin
  if not public.sigos_pode_ver(v_uid) then raise exception 'sem permissão'; end if;
  if public.sigos_os_base(v_nova) is null then raise exception 'número fora do padrão SIGOS (14 dígitos, ex.: 00127516560801)'; end if;
  if public.sigos_os_base(v_nova) = public.sigos_os_base(v_antes) and v_nova = v_antes then raise exception 'é o mesmo número'; end if;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_uid;

  if p_mod = 'pavimento' and p_campo = 'OS de origem' then
    -- a OS de origem é do ponto (grupo): corrige todos os tipos do mesmo grupo que têm o número antigo
    update "8 - coleta_campo".pav_recomposicao r set os_sigos = v_nova
     where r.grupo = (select x.grupo from "8 - coleta_campo".pav_recomposicao x where x.id::text = p_ref)
       and btrim(r.os_sigos) = v_antes;
  elsif p_mod = 'pavimento' and p_campo = 'OS da recomposição' then
    -- execução que veio da OS antiga pelo SIGOS sai; o gatilho pav_os_sigos remarca se a OS nova já estiver executada
    update "8 - coleta_campo".pav_recomposicao r
       set os_recomposicao = v_nova,
           execucao_data  = case when r.execucao_fonte = 'sigos' then null else r.execucao_data end,
           execucao_em    = case when r.execucao_fonte = 'sigos' then null else r.execucao_em end,
           execucao_por   = case when r.execucao_fonte = 'sigos' then null else r.execucao_por end
     where r.id::text = p_ref and btrim(r.os_recomposicao) = v_antes;
  elsif p_mod = 'projetos' then
    update "13 - projetos_obra".intervencao_etapa e set valor = v_nova, atualizado_em = now()
     where e.kind = split_part(p_ref, ':', 1) and e.gid::text = split_part(p_ref, ':', 2)
       and e.chave = 'os_sigos' and btrim(e.valor) = v_antes;
  elsif p_mod = 'vrp' then
    update "8 - coleta_campo".vrp_os o set os_sigos = v_nova where o.id::text = p_ref and btrim(o.os_sigos) = v_antes;
  elsif p_mod = 'pesquisa' then
    update "8 - coleta_campo".ocorrencia c set os_numero = v_nova where c.id::text = p_ref and btrim(c.os_numero) = v_antes;
  elsif p_mod = 'abertura de serviço' then
    update "12 - retaguarda".abertura_servico s set os_numero = v_nova where s.id::text = p_ref and btrim(s.os_numero) = v_antes;
  elsif p_mod = 'relatório diário pesquisa' then
    update "12 - retaguarda".pesquisa_dia_os d set os_sigos = v_nova
     where d.colaborador_uuid::text = split_part(p_ref, ':', 1) and d.dia::text = split_part(p_ref, ':', 2) and btrim(d.os_sigos) = v_antes;
  elsif p_mod = 'apr' then
    update "16 - qsms".qsms_atividade a set os_sigos = v_nova where a.id::text = p_ref and btrim(a.os_sigos) = v_antes;
  elsif p_mod = 'inspeção sst' then
    update "16 - qsms".sst_inspecao i set os = v_nova where i.id::text = p_ref and btrim(i.os) = v_antes;
  elsif p_mod = 'suprimentos' then
    update "9 - suprimentos".sup_movimento m set os = v_nova where m.id::text = p_ref and btrim(m.os) = v_antes;
  elsif p_mod = 'loggers' then
    v_col := case p_campo when 'OS SIGOS' then 'os_sigos' when 'OS COPASA instalação' then 'os_copasa_instalacao'
                          when 'OS COPASA remoção' then 'os_copasa_remocao' when 'OS COPASA social' then 'os_copasa_social' end;
    if v_col is null then raise exception 'campo desconhecido: %', p_campo; end if;
    execute format('update "8 - coleta_campo".instalacao_logger_calibracao set %1$I = $1 where id::text = $2 and btrim(%1$I) = $3', v_col)
      using v_nova, p_ref, v_antes;
  else
    raise exception 'módulo desconhecido: %', p_mod;
  end if;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'registro não encontrado ou a OS já foi alterada — recarregue a lista'; end if;

  insert into "17 - sigos".os_correcao (modulo, campo, ref, os_antes, os_depois, motivo, linhas, por_uuid, por_nome)
  values (p_mod, p_campo, p_ref, v_antes, v_nova, nullif(btrim(p_motivo), ''), n, v_uid, v_nome);
  return jsonb_build_object('ok', true, 'linhas', n, 'os', v_nova);
end $$;
revoke all on function public.app_sigos_os_corrigir(text, text, text, text, text, text) from public, anon;
grant execute on function public.app_sigos_os_corrigir(text, text, text, text, text, text) to authenticated;

-- histórico de correções (para o painel mostrar "corrigida de X por Fulano")
create or replace function public.app_sigos_os_correcoes()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('mod', c.modulo, 'campo', c.campo, 'ref', c.ref, 'antes', c.os_antes,
                     'depois', c.os_depois, 'motivo', c.motivo, 'por', c.por_nome, 'em', c.em) order by c.em desc)
                     from "17 - sigos".os_correcao c), '[]'::jsonb);
end $$;
revoke all on function public.app_sigos_os_correcoes() from public, anon;
grant execute on function public.app_sigos_os_correcoes() to authenticated;
