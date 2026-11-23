-- Orçamento por organograma — contrato por ZA e fases Execução/Manutenção (23/11/2026)
-- ZA1004/ZA0200: jul/2026 → jun/2031; ZA1500/ZA1600: jan/2027 → dez/2031 (60 meses cada).
-- Fases contadas a partir do início de cada ZA: Execução = 18 primeiros meses, Manutenção = 42 restantes.
-- Pessoa/equipe: fase 'execucao' | 'manutencao' | 'todo'; mes_ini/mes_fim (opcionais) recortam dentro da fase.
-- Mês com mais de uma ZA ativa: custo dividido igual só entre as ZAs ativas naquele mês.
set local search_path to "19 - orcamento", public;

alter table orc_za add column if not exists inicio date;
alter table orc_za add column if not exists meses int not null default 60;
alter table orc_za add column if not exists meses_execucao int not null default 18;
update orc_za set inicio = date '2026-07-01' where za in ('ZA1004','ZA0200') and inicio is null;
update orc_za set inicio = date '2027-01-01' where za in ('ZA1500','ZA1600') and inicio is null;

alter table orc_pessoa add column if not exists fase text not null default 'todo';
alter table orc_equipe add column if not exists fase text not null default 'todo';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orc_pessoa_fase_chk') then
    alter table orc_pessoa add constraint orc_pessoa_fase_chk check (fase in ('execucao','manutencao','todo'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orc_equipe_fase_chk') then
    alter table orc_equipe add constraint orc_equipe_fase_chk check (fase in ('execucao','manutencao','todo'));
  end if;
end $$;

create or replace function public.app_orc_pessoa_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_uid uuid := "19 - orcamento".orc_exige(); v_id uuid := coalesce(nullif(p->>'id','')::uuid, gen_random_uuid()); r orc_pessoa;
begin
  if not exists (select 1 from orc_pessoa where id = v_id) then
    if nullif(p->>'quadro_id','') is null then raise exception 'quadro_id obrigatório'; end if;
    insert into orc_pessoa(id, quadro_id, atualizado_por) values (v_id, (p->>'quadro_id')::uuid, v_uid);
  end if;
  update orc_pessoa set
    parent_id = case when p ? 'parent_id' then nullif(p->>'parent_id','')::uuid else parent_id end,
    x = case when p ? 'x' then round((p->>'x')::numeric)::int else x end,
    y = case when p ? 'y' then round((p->>'y')::numeric)::int else y end,
    cor = case when p ? 'cor' then p->>'cor' else cor end,
    nome = case when p ? 'nome' then coalesce(nullif(trim(p->>'nome'),''),'A definir') else nome end,
    cargo_id = case when p ? 'cargo_id' then nullif(p->>'cargo_id','')::int else cargo_id end,
    funcao = case when p ? 'funcao' then nullif(trim(p->>'funcao'),'') else funcao end,
    setor = case when p ? 'setor' then nullif(p->>'setor','') else setor end,
    modalidade = case when p ? 'modalidade' then coalesce(nullif(p->>'modalidade',''),'CLT') else modalidade end,
    regime = case when p ? 'regime' then coalesce(nullif(p->>'regime',''),'MENSALISTA') else regime end,
    salario = case when p ? 'salario' then nullif(p->>'salario','')::numeric else salario end,
    adicional = case when p ? 'adicional' then coalesce(nullif(p->>'adicional',''),'nenhum') else adicional end,
    adicional_valor = case when p ? 'adicional_valor' then nullif(p->>'adicional_valor','')::numeric else adicional_valor end,
    hora_extra = case when p ? 'hora_extra' then coalesce((p->>'hora_extra')::boolean,false) else hora_extra end,
    valor_pj = case when p ? 'valor_pj' then nullif(p->>'valor_pj','')::numeric else valor_pj end,
    fase = case when p ? 'fase' then coalesce(nullif(p->>'fase',''),'todo') else fase end,
    recebe_epi = case when p ? 'recebe_epi' then coalesce((p->>'recebe_epi')::boolean,true) else recebe_epi end,
    zas = case when p ? 'zas' then coalesce((select array_agg(distinct z) from jsonb_array_elements_text(p->'zas') z),'{}') else zas end,
    aprop_cod = case when p ? 'aprop_cod' then nullif(p->>'aprop_cod','') else aprop_cod end,
    mes_ini = case when p ? 'mes_ini' then "19 - orcamento".orc_mes(p->>'mes_ini') else mes_ini end,
    mes_fim = case when p ? 'mes_fim' then "19 - orcamento".orc_mes(p->>'mes_fim') else mes_fim end,
    obs = case when p ? 'obs' then nullif(p->>'obs','') else obs end,
    atualizado_por = v_uid, atualizado_em = now()
  where id = v_id returning * into r;
  if r.parent_id = r.id then raise exception 'a pessoa não pode ser superior de si mesma'; end if;
  return to_jsonb(r);
end $$;

create or replace function public.app_orc_equipe_salvar(p jsonb) returns uuid
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_uid uuid := "19 - orcamento".orc_exige(); v_id uuid := coalesce(nullif(p->>'id','')::uuid, gen_random_uuid());
begin
  if not exists (select 1 from orc_equipe where id = v_id) then
    if nullif(p->>'quadro_id','') is null then raise exception 'quadro_id obrigatório'; end if;
    insert into orc_equipe(id, quadro_id, nome, atualizado_por) values (v_id, (p->>'quadro_id')::uuid, coalesce(nullif(trim(p->>'nome'),''),'Equipe'), v_uid);
  end if;
  update orc_equipe set
    nome = case when p ? 'nome' then coalesce(nullif(trim(p->>'nome'),''),'Equipe') else nome end,
    cor = case when p ? 'cor' then p->>'cor' else cor end,
    zas = case when p ? 'zas' then coalesce((select array_agg(distinct z) from jsonb_array_elements_text(p->'zas') z),'{}') else zas end,
    aprop_cod = case when p ? 'aprop_cod' then nullif(p->>'aprop_cod','') else aprop_cod end,
    fase = case when p ? 'fase' then coalesce(nullif(p->>'fase',''),'todo') else fase end,
    mes_ini = case when p ? 'mes_ini' then "19 - orcamento".orc_mes(p->>'mes_ini') else mes_ini end,
    mes_fim = case when p ? 'mes_fim' then "19 - orcamento".orc_mes(p->>'mes_fim') else mes_fim end,
    atualizado_por = v_uid, atualizado_em = now()
  where id = v_id;
  if p ? 'membros' then
    delete from orc_equipe_membro where equipe_id = v_id;
    insert into orc_equipe_membro(equipe_id, pessoa_id)
      select distinct v_id, m::uuid from jsonb_array_elements_text(p->'membros') m
      join orc_pessoa ps on ps.id = m::uuid and ps.quadro_id = (select quadro_id from orc_equipe where id = v_id);
  end if;
  return v_id;
end $$;

revoke all on function public.app_orc_pessoa_salvar(jsonb), public.app_orc_equipe_salvar(jsonb) from public, anon;
grant execute on function public.app_orc_pessoa_salvar(jsonb), public.app_orc_equipe_salvar(jsonb) to authenticated;
