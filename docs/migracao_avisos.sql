-- Avisos (pop-ups) do AcquaHub — módulo só para admin. 2026-10-27.
-- Pop-up aparece toda vez que o usuário abre o app enquanto o aviso estiver no período.
-- Opcional: lembretes push do checklist diário da frota (5 horários), só p/ quem tem veículo vinculado e não fez o checklist do dia.
-- Idempotente. Não apaga dado.

create table if not exists public.app_aviso (
  id bigint generated always as identity primary key,
  titulo text not null,
  texto text,                    -- aceita **negrito** e quebra de linha
  imagem text,                   -- caminho no bucket fotos-campo (avisos/...) ou arquivo do site começando com ./ (ex.: ./avisos/x.webp) ou URL http
  botao_texto text,
  botao_link text,               -- ação do app (mesmos links das notificações, ex.: frota_checklist); null = só fechar
  publico text not null default 'todos' check (publico in ('todos','condutores_vinculados')),
  inicio date not null default current_date,
  fim date not null,
  ativo boolean not null default true,
  lembrete text check (lembrete is null or lembrete in ('checklist_frota')),
  lembrete_textos text[],        -- 1 texto por horário (5)
  criado_por uuid references public.perfil(id),
  criado_em timestamptz not null default now()
);
alter table public.app_aviso enable row level security;   -- acesso só via RPC
revoke all on public.app_aviso from anon, authenticated;

create or replace function public.aviso_eh_admin() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select funcao='admin' from public.perfil where id=auth.uid()), false);
$$;

-- tem veículo vinculado agora (condutor ativo)
create or replace function public.aviso_tem_veiculo(p_uid uuid) returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from "10 - Frotas".frota_veiculo_vinculo vv join "10 - Frotas".frota_veiculo v on v.id=vv.veiculo_id and v.ativo
                where vv.condutor_id=p_uid and vv.desvinculado_em is null);
$$;

-- avisos que o usuário logado deve ver agora (pop-up ao abrir o app)
create or replace function public.app_avisos_ativos() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if v_id is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'titulo',a.titulo,'texto',a.texto,'imagem',a.imagem,
      'botao_texto',a.botao_texto,'botao_link',a.botao_link) order by a.id desc)
    from public.app_aviso a
    where a.ativo and v_hoje between a.inicio and a.fim
      and (a.publico='todos' or (a.publico='condutores_vinculados' and public.aviso_tem_veiculo(v_id)))), '[]'::jsonb);
end; $$;

-- admin: lista todos
create or replace function public.app_avisos_admin_listar() returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('criado_por_nome',p.nome) order by a.id desc)
    from public.app_aviso a left join public.perfil p on p.id=a.criado_por), '[]'::jsonb);
end; $$;

-- admin: cria (p_id null) ou edita
create or replace function public.app_aviso_salvar(p_id bigint, p_titulo text, p_texto text, p_imagem text, p_botao_texto text, p_botao_link text,
  p_publico text, p_inicio date, p_fim date, p_ativo boolean, p_lembrete text, p_lembrete_textos text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  if not public.aviso_eh_admin() then raise exception 'sem permissão'; end if;
  if coalesce(trim(p_titulo),'')='' then raise exception 'informe o título'; end if;
  if p_fim is null then raise exception 'informe até quando o aviso vale'; end if;
  if p_inicio is not null and p_fim < p_inicio then raise exception 'a data final é antes da inicial'; end if;
  if p_id is null then
    insert into public.app_aviso(titulo,texto,imagem,botao_texto,botao_link,publico,inicio,fim,ativo,lembrete,lembrete_textos,criado_por)
    values (trim(p_titulo),p_texto,nullif(nullif(p_imagem,''),'-'),nullif(trim(coalesce(p_botao_texto,'')),''),nullif(p_botao_link,''),coalesce(p_publico,'todos'),
      coalesce(p_inicio,(now() at time zone 'America/Sao_Paulo')::date),p_fim,coalesce(p_ativo,true),nullif(p_lembrete,''),p_lembrete_textos,auth.uid())
    returning id into v_id;
  else
    -- p_imagem: path novo | '-' = remover | null/'' = manter a atual
    update public.app_aviso set titulo=trim(p_titulo), texto=p_texto,
      imagem=case when p_imagem='-' then null else coalesce(nullif(p_imagem,''),imagem) end,
      botao_texto=nullif(trim(coalesce(p_botao_texto,'')),''), botao_link=nullif(p_botao_link,''), publico=coalesce(p_publico,publico),
      inicio=coalesce(p_inicio,inicio), fim=p_fim, ativo=coalesce(p_ativo,ativo), lembrete=nullif(p_lembrete,''), lembrete_textos=p_lembrete_textos
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'aviso inexistente'; end if;
  end if;
  return jsonb_build_object('id',v_id);
end; $$;

-- lembretes: roda em cada horário (slot 1..5); usa o texto do slot
-- Só o aviso de lembrete mais recente vigente: 2 avisos de checklist no ar não podem mandar 2 pushes por horário.
create or replace function public.aviso_lembretes_run(p_slot int) returns int language plpgsql security definer set search_path to 'public' as $$
declare a record; v_uid uuid; v_n int := 0; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; v_txt text;
begin
  for a in select * from public.app_aviso where ativo and lembrete='checklist_frota' and v_hoje between inicio and fim order by id desc limit 1 loop
    v_txt := coalesce(a.lembrete_textos[p_slot], 'Já fez o checklist do seu carro hoje?');
    for v_uid in
      select distinct vv.condutor_id
      from "10 - Frotas".frota_veiculo_vinculo vv
      join "10 - Frotas".frota_veiculo v on v.id=vv.veiculo_id and v.ativo
      join public.perfil pe on pe.id=vv.condutor_id and coalesce(pe.ativo,true)
      where vv.desvinculado_em is null
        and not exists (select 1 from "10 - Frotas".frota_checklist_situacao s
                        where s.veiculo_id=vv.veiculo_id and s.reportado_por=vv.condutor_id
                          and (s.criado_em at time zone 'America/Sao_Paulo')::date = v_hoje)
    loop
      perform "9 - suprimentos".sup_notificar(array[v_uid], 'frota', 'Checklist diário do veículo', v_txt, 'frota_checklist');
      v_n := v_n + 1;
    end loop;
  end loop;
  return v_n;
end; $$;

revoke all on function public.app_avisos_ativos() from public, anon;
revoke all on function public.app_avisos_admin_listar() from public, anon;
revoke all on function public.app_aviso_salvar(bigint,text,text,text,text,text,text,date,date,boolean,text,text[]) from public, anon;
revoke all on function public.aviso_lembretes_run(int) from public, anon, authenticated;
-- helpers internos: só são chamados de dentro das RPCs definer (o Supabase dá execute a anon/authenticated por padrão)
revoke all on function public.aviso_eh_admin() from public, anon, authenticated;
revoke all on function public.aviso_tem_veiculo(uuid) from public, anon, authenticated;
grant execute on function public.app_avisos_ativos() to authenticated;
grant execute on function public.app_avisos_admin_listar() to authenticated;
grant execute on function public.app_aviso_salvar(bigint,text,text,text,text,text,text,date,date,boolean,text,text[]) to authenticated;

-- 5 horários (Brasília = UTC-3): 08h, 10h, 12h, 14h, 16h — segunda a sexta
select cron.unschedule(jobname) from cron.job where jobname like 'aviso-lembrete-%';
select cron.schedule('aviso-lembrete-1', '0 11 * * 1-5', 'select public.aviso_lembretes_run(1)');
select cron.schedule('aviso-lembrete-2', '0 13 * * 1-5', 'select public.aviso_lembretes_run(2)');
select cron.schedule('aviso-lembrete-3', '0 15 * * 1-5', 'select public.aviso_lembretes_run(3)');
select cron.schedule('aviso-lembrete-4', '0 17 * * 1-5', 'select public.aviso_lembretes_run(4)');
select cron.schedule('aviso-lembrete-5', '0 19 * * 1-5', 'select public.aviso_lembretes_run(5)');

-- 1º aviso: checklist diário (até sexta 30/10/2026). Pop-up p/ todos; lembretes (aviso_lembretes_run) só p/ quem tem carro vinculado.
insert into public.app_aviso(titulo,texto,imagem,botao_texto,botao_link,publico,inicio,fim,ativo,lembrete,lembrete_textos,criado_por)
select 'Checklist diário do veículo',
  E'Até **sexta-feira (30/10)**, quem usa carro da frota precisa fazer o checklist **todos os dias** pelo AcquaHub.\nLeva menos de 2 minutos: confira pneus, faróis, óleo, extintor e fotografe o veículo.',
  './avisos/checklist-frota-2026-10.webp', 'Fazer meu checklist agora', 'frota_checklist', 'todos',
  (now() at time zone 'America/Sao_Paulo')::date, '2026-10-30', true, 'checklist_frota',
  array['🚗 Bom dia! Já fez o checklist do seu carro hoje?',
        '⏰ Lembrete: o checklist diário do veículo ainda não foi feito.',
        '✅ Leva menos de 2 minutos: abra o AcquaHub e faça o checklist do carro.',
        '⚠️ Seu checklist de hoje continua pendente. Prazo para regularizar: sexta (30/10).',
        '🔔 Último lembrete do dia: faça o checklist do seu veículo antes de encerrar.'],
  (select id from public.perfil where lower(email)='geovana.mendonca@aguasmg.com.br')
where not exists (select 1 from public.app_aviso where titulo='Checklist diário do veículo' and fim='2026-10-30');

notify pgrst, 'reload schema';
