-- =====================================================================================
-- Orçamento por organograma ("fazedor de orçamento") — schema "19 - orcamento" (2026-11-23)
-- Base parcial do Orçamento Budget.xlsx: abas Mão de Obra, Locação e parte de Despesas.
-- Cada caixa do organograma é uma pessoa (ou vaga) = uma linha de Mão de Obra; veículos,
-- equipamentos, celular etc. se ligam à pessoa ou a uma equipe (grupo de pessoas).
-- App-only (sem USAGE para gis_*): acesso só por RPC SECURITY DEFINER, gate = admin ou
-- perfil.dev_acesso (bloco 🚧 Em desenvolvimento). Carga inicial (valores da planilha) fica FORA do repo (público): aplicada direto no banco.
-- =====================================================================================

create schema if not exists "19 - orcamento";
revoke all on schema "19 - orcamento" from public, anon, authenticated;

set local search_path to "19 - orcamento", public;

-- ---------- catálogos ----------
create table if not exists orc_premissa(
  chave text primary key,
  valor numeric,
  rotulo text not null,
  grupo text,
  ordem int default 0
);

create table if not exists orc_za(
  za text primary key,              -- ZA1004, ZA0200, ZA1500, ZA1600
  consorcio text,                   -- consórcio dono (null = a definir)
  rotulo text not null,
  ordem int default 0
);

create table if not exists orc_cargo(
  id serial primary key,
  funcao text not null unique,
  salario numeric not null default 0,
  regime text not null default 'MENSALISTA' check (regime in ('MENSALISTA','HORISTA')),
  adicional text not null default 'nenhum' check (adicional in ('nenhum','insalubridade_1','insalubridade_2','insalubridade_3','periculosidade')),
  hora_extra boolean not null default false,
  setor_padrao text check (setor_padrao in ('OBRAS','ENGENHARIA','ADMINISTRAÇÃO')),
  origem text not null default 'planilha' check (origem in ('planilha','manual')),
  ativo boolean not null default true,
  atualizado_em timestamptz default now()
);

create table if not exists orc_aprop(
  cod text primary key,             -- código SIENGE (nível 4), ex. 1.1.10.1
  nivel1 text, nivel2 text, nivel3 text, nivel4 text,
  categoria text,                   -- Despesas Gerais / Mão de Obra / Material ...
  ordem int default 0
);

create table if not exists orc_item(
  id serial primary key,
  categoria text not null check (categoria in ('veiculo','equipamento','ferramenta','ti','outro')),
  descricao text not null unique,
  cobranca text not null default 'mensal' check (cobranca in ('mensal','pontual')),  -- pontual = 1x no mês de início
  componentes jsonb not null default '{}'::jsonb,  -- locacao, motorista, plotagem, lavagem, rastreador, manutencao, combustivel, avarias
  valor numeric,                    -- custo unitário (mensal ou pontual); null = preço a definir
  aprop_contabil text,
  origem text not null default 'manual',
  ativo boolean not null default true,
  atualizado_em timestamptz default now()
);

-- ---------- organograma ----------
create table if not exists orc_quadro(
  id uuid primary key default gen_random_uuid(),
  titulo text not null default 'Organograma',
  ordem bigint not null default (extract(epoch from now())*1000)::bigint,
  desenho jsonb not null default '{"notes":[],"strokes":[]}'::jsonb,  -- textos livres e riscos do quadro
  criado_por uuid, criado_em timestamptz default now(),
  atualizado_por uuid, atualizado_em timestamptz default now()
);

create table if not exists orc_pessoa(
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references orc_quadro(id) on delete cascade,
  parent_id uuid references orc_pessoa(id) on delete set null,
  x int not null default 0, y int not null default 0, cor text,
  nome text not null default 'A definir',
  cargo_id int references orc_cargo(id) on delete set null,
  funcao text,                      -- nome do cargo (texto livre quando o cargo não existe na base)
  setor text check (setor in ('OBRAS','ENGENHARIA','ADMINISTRAÇÃO')),
  modalidade text not null default 'CLT' check (modalidade in ('CLT','PJ','ESTAGIO','APRENDIZ','TEMPORARIO')),
  regime text not null default 'MENSALISTA' check (regime in ('MENSALISTA','HORISTA')),
  salario numeric,                  -- salário/mês (CLT etc.)
  adicional text not null default 'nenhum' check (adicional in ('nenhum','insalubridade_1','insalubridade_2','insalubridade_3','periculosidade')),
  adicional_valor numeric,          -- sobrepõe o valor calculado do adicional (null = fórmula das premissas)
  hora_extra boolean not null default false,
  valor_pj numeric,                 -- PJ: valor mensal da NF (sem encargos/benefícios)
  zas text[] not null default '{}' check (zas <@ array['ZA1004','ZA0200','ZA1500','ZA1600']),
  aprop_cod text references orc_aprop(cod) on delete set null,
  mes_ini date, mes_fim date,       -- 1º dia do mês; null em mes_fim = até o fim do contrato
  obs text,
  atualizado_por uuid, atualizado_em timestamptz default now(),
  check (mes_fim is null or mes_ini is null or mes_fim >= mes_ini)
);
create index if not exists orc_pessoa_quadro on orc_pessoa(quadro_id);

create table if not exists orc_equipe(
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references orc_quadro(id) on delete cascade,
  nome text not null,
  cor text,
  zas text[] not null default '{}' check (zas <@ array['ZA1004','ZA0200','ZA1500','ZA1600']),
  aprop_cod text references orc_aprop(cod) on delete set null,
  mes_ini date, mes_fim date,
  atualizado_por uuid, atualizado_em timestamptz default now()
);
create index if not exists orc_equipe_quadro on orc_equipe(quadro_id);

create table if not exists orc_equipe_membro(
  equipe_id uuid not null references orc_equipe(id) on delete cascade,
  pessoa_id uuid not null references orc_pessoa(id) on delete cascade,
  primary key (equipe_id, pessoa_id)
);

create table if not exists orc_vinculo(
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references orc_quadro(id) on delete cascade,
  item_id int not null references orc_item(id),
  pessoa_id uuid references orc_pessoa(id) on delete cascade,
  equipe_id uuid references orc_equipe(id) on delete cascade,
  qtd numeric not null default 1 check (qtd > 0),
  valor numeric,                    -- sobrepõe o custo unitário do catálogo
  mes_ini date, mes_fim date,       -- null = herda da pessoa/equipe
  obs text,
  atualizado_por uuid, atualizado_em timestamptz default now(),
  check ((pessoa_id is null) <> (equipe_id is null))
);
create index if not exists orc_vinculo_quadro on orc_vinculo(quadro_id);

alter table orc_premissa enable row level security;
alter table orc_za enable row level security;
alter table orc_cargo enable row level security;
alter table orc_aprop enable row level security;
alter table orc_item enable row level security;
alter table orc_quadro enable row level security;
alter table orc_pessoa enable row level security;
alter table orc_equipe enable row level security;
alter table orc_equipe_membro enable row level security;
alter table orc_vinculo enable row level security;

insert into orc_za(za,consorcio,rotulo,ordem) values
  ('ZA1004','Águas Integradas','ZA1004 · Contagem',1),
  ('ZA0200','Eficiência Hídrica','ZA0200 · Betim',2),
  ('ZA1500',null,'ZA1500',3),
  ('ZA1600',null,'ZA1600',4)
on conflict (za) do nothing;

-- ---------- helpers (não expostos) ----------
create or replace function "19 - orcamento".orc_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfil where id = p_uid and coalesce(ativo,true)
                 and (funcao = 'admin' or coalesce(dev_acesso,false)));
$$;
create or replace function "19 - orcamento".orc_exige() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'nao autenticado'; end if;
  if not "19 - orcamento".orc_pode(v) then raise exception 'sem permissão para o Orçamento'; end if;
  return v;
end $$;
create or replace function "19 - orcamento".orc_mes(p text) returns date
language sql immutable as $$ select case when nullif(p,'') is null then null else date_trunc('month', (p||case when length(p)=7 then '-01' else '' end)::date)::date end $$;
revoke all on function "19 - orcamento".orc_pode(uuid), "19 - orcamento".orc_exige(), "19 - orcamento".orc_mes(text) from public, anon, authenticated;

-- ---------- leitura ----------
create or replace function public.app_orc_catalogos() returns jsonb
language plpgsql stable security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  return jsonb_build_object(
    'premissas', (select coalesce(jsonb_agg(to_jsonb(p) order by p.ordem),'[]') from orc_premissa p),
    'zas',       (select coalesce(jsonb_agg(to_jsonb(z) order by z.ordem),'[]') from orc_za z),
    'cargos',    (select coalesce(jsonb_agg(to_jsonb(c) order by c.funcao),'[]') from orc_cargo c where c.ativo),
    'aprop',     (select coalesce(jsonb_agg(to_jsonb(a) order by a.ordem),'[]') from orc_aprop a),
    'itens',     (select coalesce(jsonb_agg(to_jsonb(i) order by i.categoria, i.descricao),'[]') from orc_item i where i.ativo),
    'admin',     exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin'));
end $$;

create or replace function public.app_orc_quadros() returns jsonb
language plpgsql stable security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  return (select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'titulo',q.titulo,'ordem',q.ordem,'atualizado_em',q.atualizado_em,
            'pessoas',(select count(*) from orc_pessoa p where p.quadro_id=q.id)) order by q.ordem),'[]') from orc_quadro q);
end $$;

create or replace function public.app_orc_quadro(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  if not exists (select 1 from orc_quadro where id = p_id) then raise exception 'organograma não encontrado'; end if;
  return jsonb_build_object(
    'quadro',   (select to_jsonb(q) from orc_quadro q where q.id = p_id),
    'pessoas',  (select coalesce(jsonb_agg(to_jsonb(p) order by p.y, p.x),'[]') from orc_pessoa p where p.quadro_id = p_id),
    'equipes',  (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('membros',
                   (select coalesce(jsonb_agg(m.pessoa_id),'[]') from orc_equipe_membro m where m.equipe_id = e.id)) order by e.nome),'[]')
                 from orc_equipe e where e.quadro_id = p_id),
    'vinculos', (select coalesce(jsonb_agg(to_jsonb(v)),'[]') from orc_vinculo v where v.quadro_id = p_id));
end $$;

-- ---------- organograma ----------
create or replace function public.app_orc_quadro_salvar(p jsonb) returns uuid
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_uid uuid := "19 - orcamento".orc_exige(); v_id uuid := nullif(p->>'id','')::uuid;
begin
  if v_id is null or not exists (select 1 from orc_quadro where id = v_id) then
    insert into orc_quadro(id,titulo,ordem,desenho,criado_por,atualizado_por)
    values (coalesce(v_id,gen_random_uuid()), coalesce(nullif(trim(p->>'titulo'),''),'Organograma'),
            coalesce((p->>'ordem')::bigint,(extract(epoch from now())*1000)::bigint),
            coalesce(p->'desenho','{"notes":[],"strokes":[]}'::jsonb), v_uid, v_uid)
    returning id into v_id;
  else
    update orc_quadro set
      titulo  = case when p ? 'titulo' then coalesce(nullif(trim(p->>'titulo'),''),'Organograma') else titulo end,
      ordem   = case when p ? 'ordem' then (p->>'ordem')::bigint else ordem end,
      desenho = case when p ? 'desenho' then p->'desenho' else desenho end,
      atualizado_por = v_uid, atualizado_em = now()
    where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.app_orc_quadro_excluir(p_id uuid) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  delete from orc_quadro where id = p_id;
end $$;

-- Grava uma pessoa (cria se o id não existe). Só mexe nas chaves enviadas.
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

-- Posição/ligação em lote (arrastar, organizar, alinhar): [{id,x,y,parent_id?}]
create or replace function public.app_orc_pessoas_pos(p jsonb) returns int
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_uid uuid := "19 - orcamento".orc_exige(); n int;
begin
  update orc_pessoa t set
    x = round((e->>'x')::numeric)::int, y = round((e->>'y')::numeric)::int,
    parent_id = case when e ? 'parent_id' then nullif(e->>'parent_id','')::uuid else t.parent_id end,
    atualizado_por = v_uid, atualizado_em = now()
  from jsonb_array_elements(p) e where t.id = (e->>'id')::uuid;
  get diagnostics n = row_count;
  return n;
end $$;

-- Exclui a pessoa; os subordinados sobem para o superior dela.
create or replace function public.app_orc_pessoa_excluir(p_id uuid) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_pai uuid;
begin
  perform "19 - orcamento".orc_exige();
  select parent_id into v_pai from orc_pessoa where id = p_id;
  update orc_pessoa set parent_id = v_pai where parent_id = p_id;
  delete from orc_pessoa where id = p_id;
end $$;

-- ---------- equipes ----------
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

create or replace function public.app_orc_equipe_excluir(p_id uuid) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  delete from orc_equipe where id = p_id;
end $$;

-- ---------- itens ligados (pessoa ou equipe) ----------
create or replace function public.app_orc_vinculo_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_uid uuid := "19 - orcamento".orc_exige(); v_id uuid := coalesce(nullif(p->>'id','')::uuid, gen_random_uuid()); r orc_vinculo; v_q uuid;
begin
  if not exists (select 1 from orc_vinculo where id = v_id) then
    v_q := coalesce((select quadro_id from orc_pessoa where id = nullif(p->>'pessoa_id','')::uuid),
                    (select quadro_id from orc_equipe where id = nullif(p->>'equipe_id','')::uuid));
    if v_q is null then raise exception 'informe a pessoa ou a equipe'; end if;
    insert into orc_vinculo(id, quadro_id, item_id, pessoa_id, equipe_id, atualizado_por)
    values (v_id, v_q, (p->>'item_id')::int, nullif(p->>'pessoa_id','')::uuid, nullif(p->>'equipe_id','')::uuid, v_uid);
  end if;
  update orc_vinculo set
    item_id = case when p ? 'item_id' then (p->>'item_id')::int else item_id end,
    qtd = case when p ? 'qtd' then coalesce(nullif(p->>'qtd','')::numeric,1) else qtd end,
    valor = case when p ? 'valor' then nullif(p->>'valor','')::numeric else valor end,
    mes_ini = case when p ? 'mes_ini' then "19 - orcamento".orc_mes(p->>'mes_ini') else mes_ini end,
    mes_fim = case when p ? 'mes_fim' then "19 - orcamento".orc_mes(p->>'mes_fim') else mes_fim end,
    obs = case when p ? 'obs' then nullif(p->>'obs','') else obs end,
    atualizado_por = v_uid, atualizado_em = now()
  where id = v_id returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.app_orc_vinculo_excluir(p_id uuid) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  delete from orc_vinculo where id = p_id;
end $$;

-- ---------- catálogos editáveis ----------
-- Cargo novo (quando não existe na base) ou ajuste de salário/regra de um existente.
create or replace function public.app_orc_cargo_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_id int := nullif(p->>'id','')::int; r orc_cargo; v_f text := upper(trim(coalesce(p->>'funcao','')));
begin
  perform "19 - orcamento".orc_exige();
  if v_id is null then
    if v_f = '' then raise exception 'informe o nome do cargo'; end if;
    select id into v_id from orc_cargo where upper(funcao) = v_f;
    if v_id is null then insert into orc_cargo(funcao, origem) values (v_f, 'manual') returning id into v_id; end if;
  end if;
  update orc_cargo set
    funcao = case when v_f <> '' then v_f else funcao end,
    salario = case when p ? 'salario' then coalesce(nullif(p->>'salario','')::numeric,0) else salario end,
    regime = case when p ? 'regime' then coalesce(nullif(p->>'regime',''),'MENSALISTA') else regime end,
    adicional = case when p ? 'adicional' then coalesce(nullif(p->>'adicional',''),'nenhum') else adicional end,
    hora_extra = case when p ? 'hora_extra' then coalesce((p->>'hora_extra')::boolean,false) else hora_extra end,
    setor_padrao = case when p ? 'setor_padrao' then nullif(p->>'setor_padrao','') else setor_padrao end,
    ativo = case when p ? 'ativo' then coalesce((p->>'ativo')::boolean,true) else ativo end,
    atualizado_em = now()
  where id = v_id returning * into r;
  return to_jsonb(r);
end $$;

create or replace function public.app_orc_item_salvar(p jsonb) returns jsonb
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_id int := nullif(p->>'id','')::int; r orc_item;
begin
  perform "19 - orcamento".orc_exige();
  if v_id is null then
    if nullif(trim(p->>'descricao'),'') is null then raise exception 'informe a descrição do item'; end if;
    insert into orc_item(categoria, descricao, origem) values (coalesce(nullif(p->>'categoria',''),'outro'), trim(p->>'descricao'), 'manual') returning id into v_id;
  end if;
  update orc_item set
    categoria = case when p ? 'categoria' then coalesce(nullif(p->>'categoria',''),'outro') else categoria end,
    descricao = case when p ? 'descricao' and nullif(trim(p->>'descricao'),'') is not null then trim(p->>'descricao') else descricao end,
    cobranca = case when p ? 'cobranca' then coalesce(nullif(p->>'cobranca',''),'mensal') else cobranca end,
    componentes = case when p ? 'componentes' then coalesce(p->'componentes','{}'::jsonb) else componentes end,
    valor = case when p ? 'valor' then nullif(p->>'valor','')::numeric else valor end,
    aprop_contabil = case when p ? 'aprop_contabil' then nullif(p->>'aprop_contabil','') else aprop_contabil end,
    ativo = case when p ? 'ativo' then coalesce((p->>'ativo')::boolean,true) else ativo end,
    atualizado_em = now()
  where id = v_id returning * into r;
  return to_jsonb(r);
end $$;

-- Premissas (encargos, benefícios...) e ZAs: só admin.
create or replace function public.app_orc_premissa_set(p_chave text, p_valor numeric) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'só o admin altera premissas'; end if;
  update orc_premissa set valor = p_valor where chave = p_chave;
  if not found then raise exception 'premissa % não existe', p_chave; end if;
end $$;

create or replace function public.app_orc_za_set(p_za text, p_consorcio text, p_rotulo text) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'só o admin altera as ZAs'; end if;
  update orc_za set consorcio = nullif(trim(p_consorcio),''), rotulo = coalesce(nullif(trim(p_rotulo),''), rotulo) where za = p_za;
  if not found then raise exception 'ZA % não existe', p_za; end if;
end $$;

do $$ declare f text; begin
  foreach f in array array[
    'app_orc_catalogos()','app_orc_quadros()','app_orc_quadro(uuid)','app_orc_quadro_salvar(jsonb)','app_orc_quadro_excluir(uuid)',
    'app_orc_pessoa_salvar(jsonb)','app_orc_pessoas_pos(jsonb)','app_orc_pessoa_excluir(uuid)',
    'app_orc_equipe_salvar(jsonb)','app_orc_equipe_excluir(uuid)','app_orc_vinculo_salvar(jsonb)','app_orc_vinculo_excluir(uuid)',
    'app_orc_cargo_salvar(jsonb)','app_orc_item_salvar(jsonb)','app_orc_premissa_set(text,numeric)','app_orc_za_set(text,text,text)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
