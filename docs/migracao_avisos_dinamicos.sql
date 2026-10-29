-- Avisos dinâmicos (2026-10-28): o módulo deixa de ser feito só para o aviso do checklist da frota.
-- Antes: público só "todos"/"condutores_vinculados", lembrete só do tipo checklist_frota em 5 horários fixos
-- (5 jobs aviso-lembrete-1..5) e pop-up a cada abertura do app, sem saber quem viu.
-- Agora (MODULOS.md §19):
--   * filtros (jsonb): consórcios, funções, cargos, pessoas e condições ("tem_veiculo") — combinados com E;
--     dentro de cada filtro, qualquer um dos valores serve; vazio = todos.
--   * exibicao: sempre | diario | uma_vez | confirmar ("Li e entendi"), com registro de quem viu/confirmou.
--   * botão: tela/atalho do app (botao_link) ou link externo (botao_url).
--   * lembretes: horários livres + dias da semana + texto por horário + título do push + pendência
--     (nao_viu | nao_confirmou | nao_fez_checklist). Um único job a cada 15 min (aviso_lembretes_tick).
-- O aviso existente é migrado sem mudar o comportamento (publico/lembrete antigos → filtros/lembretes).
-- app_aviso_salvar muda de assinatura (§0.6: drop + create) e passa a receber um jsonb (campo novo = sem nova assinatura).

-- 1) colunas novas
alter table public.app_aviso
  add column if not exists filtros jsonb not null default '{}'::jsonb,
  add column if not exists exibicao text not null default 'sempre',
  add column if not exists botao_url text,
  add column if not exists lembrete_horarios time[],
  add column if not exists lembrete_dias int[] not null default '{1,2,3,4,5}',
  add column if not exists lembrete_titulo text,
  add column if not exists lembrete_pendencia text,
  add column if not exists atualizado_em timestamptz not null default now();
alter table public.app_aviso drop constraint if exists app_aviso_exibicao_check;
alter table public.app_aviso add constraint app_aviso_exibicao_check check (exibicao in ('sempre','diario','uma_vez','confirmar'));
alter table public.app_aviso drop constraint if exists app_aviso_pendencia_check;
alter table public.app_aviso add constraint app_aviso_pendencia_check
  check (lembrete_pendencia is null or lembrete_pendencia in ('nao_viu','nao_confirmou','nao_fez_checklist'));

-- 2) migra o modelo antigo (só se as colunas antigas ainda existem)
do $$ begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='app_aviso' and column_name='publico') then
    update public.app_aviso set filtros = case when publico='condutores_vinculados' then '{"condicoes":["tem_veiculo"]}'::jsonb else '{}'::jsonb end;
    update public.app_aviso set lembrete_horarios='{08:00,10:00,12:00,14:00,16:00}', lembrete_dias='{1,2,3,4,5}',
           lembrete_pendencia='nao_fez_checklist', lembrete_titulo=coalesce(lembrete_titulo,'Checklist diário do veículo')
     where lembrete='checklist_frota';
    alter table public.app_aviso drop column publico;
    alter table public.app_aviso drop column lembrete;
  end if;
end $$;

-- 3) quem viu/confirmou e envios de lembrete (RLS sem policy: só RPC)
create table if not exists public.app_aviso_visto (
  aviso_id bigint not null references public.app_aviso(id) on delete cascade,
  usuario uuid not null references public.perfil(id) on delete cascade,
  primeiro_em timestamptz not null default now(),
  ultimo_em timestamptz not null default now(),
  vezes int not null default 1,
  confirmado_em timestamptz,
  primary key (aviso_id, usuario)
);
alter table public.app_aviso_visto enable row level security;
revoke all on public.app_aviso_visto from anon, authenticated;

create table if not exists public.app_aviso_envio (
  aviso_id bigint not null references public.app_aviso(id) on delete cascade,
  dia date not null,
  horario time not null,
  enviados int not null default 0,
  criado_em timestamptz not null default now(),
  primary key (aviso_id, dia, horario)
);
alter table public.app_aviso_envio enable row level security;
revoke all on public.app_aviso_envio from anon, authenticated;

-- 4) regras internas
-- a pessoa está no público do aviso? (filtros combinados com E; vazio = todos os ativos)
create or replace function public.aviso_no_publico(p_filtros jsonb, p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from public.perfil p
    where p.id = p_uid and coalesce(p.ativo,true)
      and (coalesce(jsonb_array_length(p_filtros->'consorcios'),0)=0 or p.consorcio in (select jsonb_array_elements_text(p_filtros->'consorcios')))
      and (coalesce(jsonb_array_length(p_filtros->'funcoes'),0)=0 or p.funcao in (select jsonb_array_elements_text(p_filtros->'funcoes')))
      and (coalesce(jsonb_array_length(p_filtros->'cargos'),0)=0 or p.cargo_id::text in (select jsonb_array_elements_text(p_filtros->'cargos')))
      and (coalesce(jsonb_array_length(p_filtros->'pessoas'),0)=0 or p.id::text in (select jsonb_array_elements_text(p_filtros->'pessoas')))
      and (not (coalesce(p_filtros->'condicoes','[]'::jsonb) ? 'tem_veiculo') or public.aviso_tem_veiculo(p.id)));
$$;

-- a pessoa ainda está pendente para o lembrete? (null = todo o público)
create or replace function public.aviso_pendente(p_aviso_id bigint, p_pendencia text, p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select case p_pendencia
    when 'nao_viu' then not exists(select 1 from public.app_aviso_visto v where v.aviso_id=p_aviso_id and v.usuario=p_uid)
    when 'nao_confirmou' then not exists(select 1 from public.app_aviso_visto v where v.aviso_id=p_aviso_id and v.usuario=p_uid and v.confirmado_em is not null)
    when 'nao_fez_checklist' then exists(
      select 1 from "10 - Frotas".frota_veiculo_vinculo vv
      join "10 - Frotas".frota_veiculo v on v.id=vv.veiculo_id and v.ativo
      where vv.condutor_id=p_uid and vv.desvinculado_em is null
        and not exists(select 1 from "10 - Frotas".frota_checklist_situacao s
                       where s.veiculo_id=vv.veiculo_id and s.reportado_por=p_uid
                         and (s.criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date))
    else true end;
$$;

-- 5) usuário: avisos que deve ver agora + registrar que viu/confirmou
create or replace function public.app_avisos_ativos() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if v_id is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'titulo',a.titulo,'texto',a.texto,'imagem',a.imagem,
      'botao_texto',a.botao_texto,'botao_link',a.botao_link,'botao_url',a.botao_url,'exibicao',a.exibicao) order by a.id desc)
    from public.app_aviso a
    left join public.app_aviso_visto v on v.aviso_id=a.id and v.usuario=v_id
    where a.ativo and v_hoje between a.inicio and a.fim
      and public.aviso_no_publico(a.filtros, v_id)
      and case a.exibicao
            when 'uma_vez' then v.aviso_id is null
            when 'diario' then v.aviso_id is null or (v.ultimo_em at time zone 'America/Sao_Paulo')::date < v_hoje
            when 'confirmar' then v.confirmado_em is null
            else true end), '[]'::jsonb);
end; $$;

create or replace function public.app_aviso_marcar(p_id bigint, p_confirmar boolean default false) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_f jsonb;
begin
  if v_id is null then return; end if;
  select filtros into v_f from public.app_aviso where id=p_id;
  if v_f is null or not public.aviso_no_publico(v_f, v_id) then return; end if;   -- só conta quem é do público
  insert into public.app_aviso_visto(aviso_id,usuario,confirmado_em) values (p_id, v_id, case when p_confirmar then now() end)
  on conflict (aviso_id,usuario) do update set
    ultimo_em = now(),
    vezes = public.app_aviso_visto.vezes + case when p_confirmar then 0 else 1 end,
    confirmado_em = coalesce(public.app_aviso_visto.confirmado_em, case when p_confirmar then now() end);
end; $$;

-- 6) admin
create or replace function public.app_avisos_admin_listar() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('criado_por_nome',p.nome,
      'n_publico',(select count(*) from public.perfil pp where public.aviso_no_publico(a.filtros, pp.id)),
      'n_viram',(select count(*) from public.app_aviso_visto v where v.aviso_id=a.id),
      'n_confirmaram',(select count(*) from public.app_aviso_visto v where v.aviso_id=a.id and v.confirmado_em is not null),
      'ult_envio',(select jsonb_build_object('dia',e.dia,'horario',e.horario,'enviados',e.enviados) from public.app_aviso_envio e
                   where e.aviso_id=a.id order by e.dia desc, e.horario desc limit 1))
    order by a.id desc)
    from public.app_aviso a left join public.perfil p on p.id=a.criado_por), '[]'::jsonb);
end; $$;

create or replace function public.app_aviso_opcoes() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'cargos', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'nome',c.nome) order by c.nome) from "9 - suprimentos".sup_cargo c where c.ativo),'[]'::jsonb),
    'pessoas', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'nome',coalesce(p.nome,p.email),'consorcio',p.consorcio,'funcao',p.funcao)
                         order by coalesce(p.nome,p.email)) from public.perfil p where coalesce(p.ativo,true)),'[]'::jsonb));
end; $$;

create or replace function public.app_aviso_publico_previa(p_filtros jsonb) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  return (select jsonb_build_object('n', count(*), 'nomes', coalesce(to_jsonb((array_agg(coalesce(p.nome,p.email) order by coalesce(p.nome,p.email)))[1:6]),'[]'::jsonb))
          from public.perfil p where public.aviso_no_publico(coalesce(p_filtros,'{}'::jsonb), p.id));
end; $$;

create or replace function public.app_aviso_relatorio(p_id bigint) returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('nome',coalesce(p.nome,p.email),'consorcio',p.consorcio,
      'viu_em',v.primeiro_em,'ultimo_em',v.ultimo_em,'vezes',v.vezes,'confirmou_em',v.confirmado_em)
      order by (v.usuario is null), coalesce(p.nome,p.email))
    from public.app_aviso a cross join public.perfil p
    left join public.app_aviso_visto v on v.aviso_id=a.id and v.usuario=p.id
    where a.id=p_id and (public.aviso_no_publico(a.filtros, p.id) or v.usuario is not null)), '[]'::jsonb);
end; $$;

create or replace function public.app_aviso_ativar(p_id bigint, p_ativo boolean) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  update public.app_aviso set ativo=coalesce(p_ativo,false), atualizado_em=now() where id=p_id;
  if not found then raise exception 'aviso inexistente'; end if;
end; $$;

-- cria (p_id null) ou edita. p_dados: titulo, texto, imagem (path | '-' remove | null mantém), botao_texto, botao_link,
-- botao_url, filtros{}, exibicao, inicio, fim, ativo, lembretes[{horario,texto}], lembrete_dias[1..7], lembrete_titulo,
-- lembrete_pendencia
drop function if exists public.app_aviso_salvar(bigint,text,text,text,text,text,text,date,date,boolean,text,text[]);
create or replace function public.app_aviso_salvar(p_id bigint, p_dados jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d jsonb := coalesce(p_dados,'{}'::jsonb); v_id bigint;
  v_tit text := trim(coalesce(d->>'titulo',''));
  v_ini date := nullif(d->>'inicio','')::date;
  v_fim date := nullif(d->>'fim','')::date;
  v_img text := d->>'imagem';
  v_exib text := coalesce(nullif(d->>'exibicao',''),'sempre');
  v_url text := nullif(trim(coalesce(d->>'botao_url','')),'');
  v_link text := nullif(trim(coalesce(d->>'botao_link','')),'');
  v_pend text := nullif(d->>'lembrete_pendencia','');
  v_filtros jsonb := coalesce(d->'filtros','{}'::jsonb);
  v_hor time[]; v_txt text[]; v_dias int[];
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  if v_tit='' then raise exception 'informe o título'; end if;
  if v_fim is null then raise exception 'informe até quando o aviso vale'; end if;
  if v_ini is not null and v_fim < v_ini then raise exception 'a data final é antes da inicial'; end if;
  if v_exib not in ('sempre','diario','uma_vez','confirmar') then raise exception 'modo de exibição inválido'; end if;
  if v_url is not null and v_url !~* '^https?://' then raise exception 'o link externo precisa começar com http:// ou https://'; end if;
  if v_url is not null then v_link := null; end if;
  if jsonb_typeof(v_filtros) <> 'object' then raise exception 'filtros inválidos'; end if;
  select array_agg((x->>'horario')::time order by (x->>'horario')::time), array_agg(coalesce(trim(x->>'texto'),'') order by (x->>'horario')::time)
    into v_hor, v_txt
    from jsonb_array_elements(coalesce(d->'lembretes','[]'::jsonb)) x where nullif(x->>'horario','') is not null;
  select array_agg(distinct x::int order by x::int) into v_dias
    from jsonb_array_elements_text(coalesce(d->'lembrete_dias','[]'::jsonb)) x;
  if v_hor is not null then
    if (select count(*) from unnest(v_hor)) <> (select count(distinct h) from unnest(v_hor) h) then raise exception 'há horário repetido nos lembretes'; end if;
    if v_dias is null then raise exception 'escolha os dias dos lembretes'; end if;
    if exists(select 1 from unnest(v_dias) x where x not between 1 and 7) then raise exception 'dia da semana inválido'; end if;
    if v_pend is not null and v_pend not in ('nao_viu','nao_confirmou','nao_fez_checklist') then raise exception 'pendência inválida'; end if;
  else
    v_txt := null; v_pend := null;
  end if;
  if p_id is null then
    insert into public.app_aviso(titulo,texto,imagem,botao_texto,botao_link,botao_url,filtros,exibicao,inicio,fim,ativo,
      lembrete_horarios,lembrete_dias,lembrete_textos,lembrete_titulo,lembrete_pendencia,criado_por,atualizado_em)
    values (v_tit, nullif(d->>'texto',''), nullif(nullif(v_img,''),'-'), nullif(trim(coalesce(d->>'botao_texto','')),''), v_link, v_url,
      v_filtros, v_exib, coalesce(v_ini,(now() at time zone 'America/Sao_Paulo')::date), v_fim, coalesce((d->>'ativo')::boolean,true),
      v_hor, coalesce(v_dias,'{1,2,3,4,5}'), v_txt, nullif(trim(coalesce(d->>'lembrete_titulo','')),''), v_pend, auth.uid(), now())
    returning id into v_id;
  else
    update public.app_aviso set titulo=v_tit, texto=nullif(d->>'texto',''),
      imagem=case when v_img='-' then null else coalesce(nullif(v_img,''),imagem) end,
      botao_texto=nullif(trim(coalesce(d->>'botao_texto','')),''), botao_link=v_link, botao_url=v_url,
      filtros=v_filtros, exibicao=v_exib, inicio=coalesce(v_ini,inicio), fim=v_fim, ativo=coalesce((d->>'ativo')::boolean,ativo),
      lembrete_horarios=v_hor, lembrete_dias=coalesce(v_dias,'{1,2,3,4,5}'), lembrete_textos=v_txt,
      lembrete_titulo=nullif(trim(coalesce(d->>'lembrete_titulo','')),''), lembrete_pendencia=v_pend, atualizado_em=now()
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'aviso inexistente'; end if;
  end if;
  return jsonb_build_object('id',v_id);
end; $$;

-- 7) lembretes: um job a cada 15 min manda os horários que venceram nos últimos 30 min e ainda não foram enviados hoje.
-- Horário anterior à última edição do aviso não dispara (criar às 10h05 um lembrete das 10h não manda nada hoje).
create or replace function public.aviso_lembretes_tick() returns int language plpgsql security definer set search_path to 'public' as $$
declare a record; i int; h time; v_agora timestamp := now() at time zone 'America/Sao_Paulo'; v_hoje date := v_agora::date;
  v_dow int := extract(isodow from v_agora)::int; v_total int := 0; v_txt text; v_dest uuid[];
begin
  for a in select * from public.app_aviso
           where ativo and v_hoje between inicio and fim and coalesce(array_length(lembrete_horarios,1),0)>0 and v_dow = any(lembrete_dias) loop
    for i in 1..array_length(a.lembrete_horarios,1) loop
      h := a.lembrete_horarios[i];
      continue when (v_hoje + h) > v_agora or (v_hoje + h) <= v_agora - interval '30 minutes';
      continue when (v_hoje + h) < (a.atualizado_em at time zone 'America/Sao_Paulo') - interval '1 minute';
      continue when exists(select 1 from public.app_aviso_envio e where e.aviso_id=a.id and e.dia=v_hoje and e.horario=h);
      v_txt := coalesce(nullif(a.lembrete_textos[i],''), nullif(a.lembrete_textos[1],''), a.titulo);
      select coalesce(array_agg(p.id),'{}') into v_dest from public.perfil p
       where public.aviso_no_publico(a.filtros, p.id) and public.aviso_pendente(a.id, a.lembrete_pendencia, p.id);
      if cardinality(v_dest) > 0 then
        perform "9 - suprimentos".sup_notificar(v_dest, 'aviso', coalesce(nullif(a.lembrete_titulo,''), a.titulo), v_txt,
                                                coalesce(a.botao_link,'notificacoes'));
      end if;
      insert into public.app_aviso_envio(aviso_id,dia,horario,enviados) values (a.id, v_hoje, h, cardinality(v_dest)) on conflict do nothing;
      v_total := v_total + cardinality(v_dest);
    end loop;
  end loop;
  return v_total;
end; $$;

select cron.unschedule(jobname) from cron.job where jobname like 'aviso-lembrete-%' or jobname = 'aviso-lembretes';
drop function if exists public.aviso_lembretes_run(int);
select cron.schedule('aviso-lembretes', '*/15 * * * *', 'select public.aviso_lembretes_tick()');

-- 8) grants
revoke all on function public.aviso_no_publico(jsonb,uuid) from public, anon, authenticated;
revoke all on function public.aviso_pendente(bigint,text,uuid) from public, anon, authenticated;
revoke all on function public.aviso_lembretes_tick() from public, anon, authenticated;
revoke all on function public.aviso_eh_admin() from public, anon, authenticated;
revoke all on function public.aviso_tem_veiculo(uuid) from public, anon, authenticated;
revoke all on function public.app_avisos_ativos() from public, anon;
revoke all on function public.app_aviso_marcar(bigint,boolean) from public, anon;
revoke all on function public.app_avisos_admin_listar() from public, anon;
revoke all on function public.app_aviso_opcoes() from public, anon;
revoke all on function public.app_aviso_publico_previa(jsonb) from public, anon;
revoke all on function public.app_aviso_relatorio(bigint) from public, anon;
revoke all on function public.app_aviso_ativar(bigint,boolean) from public, anon;
revoke all on function public.app_aviso_salvar(bigint,jsonb) from public, anon;
grant execute on function public.app_avisos_ativos() to authenticated;
grant execute on function public.app_aviso_marcar(bigint,boolean) to authenticated;
grant execute on function public.app_avisos_admin_listar() to authenticated;
grant execute on function public.app_aviso_opcoes() to authenticated;
grant execute on function public.app_aviso_publico_previa(jsonb) to authenticated;
grant execute on function public.app_aviso_relatorio(bigint) to authenticated;
grant execute on function public.app_aviso_ativar(bigint,boolean) to authenticated;
grant execute on function public.app_aviso_salvar(bigint,jsonb) to authenticated;

notify pgrst, 'reload schema';
