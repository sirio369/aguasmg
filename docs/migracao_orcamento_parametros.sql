-- Orçamento por organograma — parâmetros editáveis (⚙️), mensal/pontual por item ligado, sub-CC por item da equipe,
-- kits só de equipe com composição (23/11/2026). Sem valores: preços e premissas ficam só no banco (repo público).
set local search_path to "19 - orcamento", public;

-- item ligado: mensal/pontual próprio (null = o do catálogo) e sub-CC (nível 4 da aba Auxiliar)
alter table orc_vinculo add column if not exists cobranca text;
alter table orc_vinculo add column if not exists aprop_cod text references orc_aprop(cod) on delete set null;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orc_vinculo_cobranca_chk') then
    alter table orc_vinculo add constraint orc_vinculo_cobranca_chk check (cobranca is null or cobranca in ('mensal','pontual'));
  end if;
end $$;
-- equipe: centro de custo de 1º nível (nivel3 da aba Auxiliar, ex. "02.001.001 - VCA")
alter table orc_equipe add column if not exists aprop_grupo text;
-- catálogo: item só de equipe (kits) e composição do kit [{descricao, qtd, valor}] (valor do kit = soma)
alter table orc_item add column if not exists so_equipe boolean not null default false;
alter table orc_item add column if not exists composicao jsonb not null default '[]';
update orc_item set so_equipe = true where descricao ilike 'Kit pesquisa%' or descricao ilike 'Kit de ferramentas (bolsa%';

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
    cobranca = case when p ? 'cobranca' then nullif(p->>'cobranca','') else cobranca end,
    aprop_cod = case when p ? 'aprop_cod' then nullif(p->>'aprop_cod','') else aprop_cod end,
    obs = case when p ? 'obs' then nullif(p->>'obs','') else obs end,
    atualizado_por = v_uid, atualizado_em = now()
  where id = v_id returning * into r;
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
    aprop_grupo = case when p ? 'aprop_grupo' then nullif(p->>'aprop_grupo','') else aprop_grupo end,
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
    so_equipe = case when p ? 'so_equipe' then coalesce((p->>'so_equipe')::boolean,false) else so_equipe end,
    composicao = case when p ? 'composicao' then coalesce(p->'composicao','[]'::jsonb) else composicao end,
    ativo = case when p ? 'ativo' then coalesce((p->>'ativo')::boolean,true) else ativo end,
    atualizado_em = now()
  where id = v_id returning * into r;
  return to_jsonb(r);
end $$;

-- contrato de cada ZA (início, duração, meses de execução) — só admin
create or replace function public.app_orc_za_contrato_set(p_za text, p_inicio date, p_meses int, p_execucao int) returns void
language plpgsql security definer set search_path = "19 - orcamento", public as $$
begin
  perform "19 - orcamento".orc_exige();
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'só o admin altera o contrato das ZAs'; end if;
  if p_inicio is null or p_meses is null or p_execucao is null or p_meses < 1 or p_execucao < 0 or p_execucao > p_meses then raise exception 'datas/meses inválidos'; end if;
  update orc_za set inicio = date_trunc('month', p_inicio)::date, meses = p_meses, meses_execucao = p_execucao where za = p_za;
  if not found then raise exception 'ZA % não existe', p_za; end if;
end $$;

revoke all on function public.app_orc_vinculo_salvar(jsonb), public.app_orc_equipe_salvar(jsonb), public.app_orc_item_salvar(jsonb), public.app_orc_za_contrato_set(text,date,int,int) from public, anon;
grant execute on function public.app_orc_vinculo_salvar(jsonb), public.app_orc_equipe_salvar(jsonb), public.app_orc_item_salvar(jsonb), public.app_orc_za_contrato_set(text,date,int,int) to authenticated;

-- ⚙️ Parâmetros › Cargos: grava o cargo e leva a mudança para as pessoas (de todos os organogramas) ligadas a ele
-- que ainda usam o valor da base (campo igual ao antigo); quem foi ajustado à mão fica como está.
create or replace function public.app_orc_cargo_aplicar(p jsonb) returns jsonb
language plpgsql security definer set search_path = "19 - orcamento", public as $$
declare v_id int := nullif(p->>'id','')::int; o orc_cargo; r orc_cargo; n int;
begin
  perform "19 - orcamento".orc_exige();
  select * into o from orc_cargo where id = v_id for update;
  if not found then raise exception 'cargo não encontrado'; end if;
  update orc_cargo set
    salario = case when p ? 'salario' then coalesce(nullif(p->>'salario','')::numeric,0) else salario end,
    regime = case when p ? 'regime' then coalesce(nullif(p->>'regime',''),'MENSALISTA') else regime end,
    adicional = case when p ? 'adicional' then coalesce(nullif(p->>'adicional',''),'nenhum') else adicional end,
    hora_extra = case when p ? 'hora_extra' then coalesce((p->>'hora_extra')::boolean,false) else hora_extra end,
    setor_padrao = case when p ? 'setor_padrao' then nullif(p->>'setor_padrao','') else setor_padrao end,
    atualizado_em = now()
  where id = v_id returning * into r;
  update orc_pessoa ps set
    salario = case when ps.salario is not distinct from o.salario then r.salario else ps.salario end,
    regime = case when ps.regime = o.regime then r.regime else ps.regime end,
    adicional = case when ps.adicional = o.adicional then r.adicional else ps.adicional end,
    hora_extra = case when ps.hora_extra = o.hora_extra then r.hora_extra else ps.hora_extra end,
    atualizado_em = now()
  where ps.cargo_id = v_id
    and ((ps.salario is not distinct from o.salario and r.salario is distinct from o.salario)
      or (ps.regime = o.regime and r.regime <> o.regime)
      or (ps.adicional = o.adicional and r.adicional <> o.adicional)
      or (ps.hora_extra = o.hora_extra and r.hora_extra <> o.hora_extra));
  get diagnostics n = row_count;
  return jsonb_build_object('cargo', to_jsonb(r), 'pessoas', n,
    'proprias', (select count(*) from orc_pessoa where cargo_id = v_id and salario is distinct from r.salario));
end $$;
revoke all on function public.app_orc_cargo_aplicar(jsonb) from public, anon;
grant execute on function public.app_orc_cargo_aplicar(jsonb) to authenticated;
