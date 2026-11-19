-- BI de Frota dentro do AcquaHub (Gestão de Frotas) + cargas dos arquivos de apoio (2026-11-19)
-- Substitui o Power BI "Frota". Fontes:
--   • Veículos e máquinas ......... direto do cadastro do app ("10 - Frotas".frota_veiculo + vínculo do condutor) — sem carga;
--   • Orçado ...................... carga de Orcamento_Equipamentos.xlsx (abas Orcamento + Areas; gerado do REV21, aba Locação);
--   • De-para ..................... carga de De_Para_Equipamentos.xlsx (abas DePara + Itens): descrição → item do orçamento → grupo;
--   • Equipamentos leves .......... carga de Controle_Equipamentos_Leves.xlsx;
--   • Combustível ................. carga de Abastecimentos_Base.xlsx (gerado dos relatórios do cartão Ticket Log).
-- Regra (decidida pela usuária no BI de Suprimentos): cada arquivo novo SUBSTITUI o anterior do mesmo tipo.
-- Fluxo: app_frota_carga_iniciar → app_frota_carga_lote (por aba/tabela) → app_frota_carga_finalizar | app_frota_carga_falha.

alter table public.perfil add column if not exists frota_bi_acesso boolean not null default false;     -- vê a Gestão de Frotas
alter table public.perfil add column if not exists frota_carga_acesso boolean not null default false;  -- sobe os arquivos

create or replace function "10 - Frotas".frota_bi_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo and (p.funcao = 'admin' or coalesce(p.aux_acesso, false) or p.frota_bi_acesso or p.frota_carga_acesso))
$$;
create or replace function "10 - Frotas".frota_carga_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo and (p.funcao = 'admin' or p.frota_carga_acesso))
$$;
create or replace function "10 - Frotas".frota_bi_hoje() returns date language sql stable as $$
  select coalesce(nullif(current_setting('app.frota_hoje', true), '')::date, (now() at time zone 'America/Sao_Paulo')::date)
$$;
-- fnChave do BI: caixa alta, espaços colapsados
create or replace function "10 - Frotas".frota_chave(s text) returns text language sql immutable as $$
  select nullif(upper(regexp_replace(btrim(coalesce(s, '')), '[[:space:]]+', ' ', 'g')), '')
$$;
-- fnCC do BI: "04.002.009.002" ou "0402009002" → "4.2.9.2" (igual ao código do orçamento)
create or replace function "10 - Frotas".frota_cc(s text) returns text language plpgsql immutable as $$
declare t text := btrim(coalesce(s, '')); d text; r text;
begin
  if t = '' then return null; end if;
  if position('.' in t) > 0 then
    select string_agg((p::bigint)::text, '.' order by o) into r from unnest(string_to_array(t, '.')) with ordinality as x(p, o) where p ~ '^[0-9]+$';
    return coalesce(r, t);
  end if;
  d := lpad(t, 10, '0');
  if d !~ '^[0-9]{10}$' then return t; end if;
  return (substr(d, 1, 1)::int)::text || '.' || (substr(d, 2, 3)::int)::text || '.' || (substr(d, 5, 3)::int)::text || '.' || (substr(d, 8, 3)::int)::text;
end $$;
create or replace function "10 - Frotas".frota_consorcio(s text) returns text language sql immutable as $$
  select case when btrim(coalesce(s, '')) = '' then null
              when upper(s) ~ '(AGUAS|ÁGUAS)' or upper(btrim(s)) in ('CAI', 'ZA1004') then 'Águas Integradas'
              when upper(s) ~ 'EFICI' or upper(btrim(s)) in ('CEH', 'ZA0200') then 'Eficiência Hídrica'
              else btrim(s) end
$$;

-- ───────────── tabelas (app-only) ─────────────
create table if not exists "10 - Frotas".frota_bi_carga (
  id bigserial primary key,
  tipo text not null check (tipo in ('orcamento','depara','leves','abastecimento')),
  nome_original text, sha256 text, linhas int,
  status text not null default 'pendente' check (status in ('pendente','ok','erro')),
  ativa boolean not null default false, aviso text, erro text,
  enviado_por uuid default auth.uid(), enviado_em timestamptz not null default now(), concluido_em timestamptz
);
create table if not exists "10 - Frotas".frota_bi_orcamento (carga_id bigint not null references "10 - Frotas".frota_bi_carga(id) on delete cascade,
  consorcio text, cod_cc text, item text, mes date, qtd numeric);
create table if not exists "10 - Frotas".frota_bi_area (carga_id bigint not null references "10 - Frotas".frota_bi_carga(id) on delete cascade, cod_cc text, area text);
create table if not exists "10 - Frotas".frota_bi_depara (carga_id bigint not null references "10 - Frotas".frota_bi_carga(id) on delete cascade,
  fonte text, descricao text, item text, situacao text, observacao text);
create table if not exists "10 - Frotas".frota_bi_item_orc (carga_id bigint not null references "10 - Frotas".frota_bi_carga(id) on delete cascade, item text, grupo text);
create table if not exists "10 - Frotas".frota_bi_leve (carga_id bigint not null references "10 - Frotas".frota_bi_carga(id) on delete cascade,
  empresa text, fornecedor text, contrato text, descricao text, complemento text, cod text, dt_aporte date, dt_devolucao date, status text);
create table if not exists "10 - Frotas".frota_bi_abast (carga_id bigint not null references "10 - Frotas".frota_bi_carga(id) on delete cascade,
  data date, mes date, placa text, motorista text, consorcio text, combustivel text, litros numeric, preco_litro numeric, valor_total numeric, posto text, alerta text);
create index if not exists frota_bi_orcamento_c on "10 - Frotas".frota_bi_orcamento (carga_id);
create index if not exists frota_bi_abast_c on "10 - Frotas".frota_bi_abast (carga_id);
alter table "10 - Frotas".frota_bi_carga enable row level security;
alter table "10 - Frotas".frota_bi_orcamento enable row level security;
alter table "10 - Frotas".frota_bi_area enable row level security;
alter table "10 - Frotas".frota_bi_depara enable row level security;
alter table "10 - Frotas".frota_bi_item_orc enable row level security;
alter table "10 - Frotas".frota_bi_leve enable row level security;
alter table "10 - Frotas".frota_bi_abast enable row level security;

-- ───────────── carga ─────────────
create or replace function public.app_frota_carga_iniciar(p_tipo text, p_nome text, p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_aviso text; v_ant timestamptz;
begin
  if not "10 - Frotas".frota_carga_pode(auth.uid()) then raise exception 'sem permissão para carregar arquivos da Frota'; end if;
  if p_tipo not in ('orcamento','depara','leves','abastecimento') then raise exception 'tipo de arquivo inválido'; end if;
  select max(concluido_em) into v_ant from "10 - Frotas".frota_bi_carga where tipo = p_tipo and status = 'ok' and sha256 is not null and sha256 = p_sha256;
  if v_ant is not null then v_aviso := 'idêntico ao já enviado em ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'); end if;
  insert into "10 - Frotas".frota_bi_carga (tipo, nome_original, sha256, aviso) values (p_tipo, left(p_nome, 300), p_sha256, v_aviso) returning id into v_id;
  return jsonb_build_object('carga_id', v_id, 'aviso', v_aviso);
end $$;

-- p_tabela: orcamento | area | depara | item_orc | leve | abast  (o arquivo de orçamento e o de de-para têm 2 abas cada)
create or replace function public.app_frota_carga_lote(p_carga bigint, p_tabela text, p_linhas jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare c "10 - Frotas".frota_bi_carga; n int;
begin
  if not "10 - Frotas".frota_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "10 - Frotas".frota_bi_carga where id = p_carga and status = 'pendente';
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'lote inválido'; end if;
  if not ((c.tipo = 'orcamento' and p_tabela in ('orcamento','area')) or (c.tipo = 'depara' and p_tabela in ('depara','item_orc'))
          or (c.tipo = 'leves' and p_tabela = 'leve') or (c.tipo = 'abastecimento' and p_tabela = 'abast')) then
    raise exception 'tabela % não pertence a esse tipo de carga', p_tabela; end if;
  if p_tabela = 'orcamento' then
    insert into "10 - Frotas".frota_bi_orcamento select p_carga, x.consorcio, x.cod_cc, x.item, x.mes, x.qtd
      from jsonb_to_recordset(p_linhas) as x(consorcio text, cod_cc text, item text, mes date, qtd numeric);
  elsif p_tabela = 'area' then
    insert into "10 - Frotas".frota_bi_area select p_carga, x.cod_cc, x.area from jsonb_to_recordset(p_linhas) as x(cod_cc text, area text);
  elsif p_tabela = 'depara' then
    insert into "10 - Frotas".frota_bi_depara select p_carga, x.fonte, x.descricao, x.item, x.situacao, x.observacao
      from jsonb_to_recordset(p_linhas) as x(fonte text, descricao text, item text, situacao text, observacao text);
  elsif p_tabela = 'item_orc' then
    insert into "10 - Frotas".frota_bi_item_orc select p_carga, x.item, x.grupo from jsonb_to_recordset(p_linhas) as x(item text, grupo text);
  elsif p_tabela = 'leve' then
    insert into "10 - Frotas".frota_bi_leve select p_carga, x.empresa, x.fornecedor, x.contrato, x.descricao, x.complemento, x.cod, x.dt_aporte, x.dt_devolucao, x.status
      from jsonb_to_recordset(p_linhas) as x(empresa text, fornecedor text, contrato text, descricao text, complemento text, cod text, dt_aporte date, dt_devolucao date, status text);
  else
    insert into "10 - Frotas".frota_bi_abast select p_carga, x.data, x.mes, x.placa, x.motorista, x.consorcio, x.combustivel, x.litros, x.preco_litro, x.valor_total, x.posto, x.alerta
      from jsonb_to_recordset(p_linhas) as x(data date, mes date, placa text, motorista text, consorcio text, combustivel text, litros numeric, preco_litro numeric, valor_total numeric, posto text, alerta text);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- troca de uma vez: o novo vale só se chegou inteiro; o anterior do mesmo tipo sai
create or replace function public.app_frota_carga_finalizar(p_carga bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c "10 - Frotas".frota_bi_carga; n int; v_aviso text;
begin
  if not "10 - Frotas".frota_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "10 - Frotas".frota_bi_carga where id = p_carga and status = 'pendente' for update;
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if c.tipo = 'orcamento' then select count(*) into n from "10 - Frotas".frota_bi_orcamento where carga_id = p_carga;
  elsif c.tipo = 'depara' then select count(*) into n from "10 - Frotas".frota_bi_depara where carga_id = p_carga;
  elsif c.tipo = 'leves' then select count(*) into n from "10 - Frotas".frota_bi_leve where carga_id = p_carga;
  else select count(*) into n from "10 - Frotas".frota_bi_abast where carga_id = p_carga; end if;
  if coalesce(n, 0) = 0 then
    update "10 - Frotas".frota_bi_carga set status = 'erro', erro = 'nenhuma linha válida no arquivo', concluido_em = now() where id = p_carga;
    raise exception 'nenhuma linha válida no arquivo — nada foi alterado';
  end if;
  update "10 - Frotas".frota_bi_carga set ativa = false where tipo = c.tipo and ativa;
  delete from "10 - Frotas".frota_bi_orcamento where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "10 - Frotas".frota_bi_area where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "10 - Frotas".frota_bi_depara where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "10 - Frotas".frota_bi_item_orc where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "10 - Frotas".frota_bi_leve where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = c.tipo and id <> p_carga);
  delete from "10 - Frotas".frota_bi_abast where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = c.tipo and id <> p_carga);
  v_aviso := c.aviso;
  update "10 - Frotas".frota_bi_carga set status = 'ok', ativa = true, linhas = n, aviso = v_aviso, concluido_em = now() where id = p_carga;
  return jsonb_build_object('carga_id', p_carga, 'tipo', c.tipo, 'linhas', n, 'aviso', v_aviso);
end $$;

create or replace function public.app_frota_carga_falha(p_carga bigint, p_erro text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not "10 - Frotas".frota_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  update "10 - Frotas".frota_bi_carga set status = 'erro', erro = left(p_erro, 500), concluido_em = now() where id = p_carga and status = 'pendente';
  if not found then return; end if;  -- carga já concluída/sem pendência: não apaga linhas ativas
  delete from "10 - Frotas".frota_bi_orcamento where carga_id = p_carga; delete from "10 - Frotas".frota_bi_area where carga_id = p_carga;
  delete from "10 - Frotas".frota_bi_depara where carga_id = p_carga; delete from "10 - Frotas".frota_bi_item_orc where carga_id = p_carga;
  delete from "10 - Frotas".frota_bi_leve where carga_id = p_carga; delete from "10 - Frotas".frota_bi_abast where carga_id = p_carga;
end $$;

create or replace function public.app_frota_cargas_listar(p_limite int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "10 - Frotas".frota_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object('pode_carregar', "10 - Frotas".frota_carga_pode(auth.uid()),
    'ativas', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'tipo', k.tipo, 'nome', k.nome_original, 'linhas', k.linhas, 'em', k.concluido_em) order by k.tipo)
        from "10 - Frotas".frota_bi_carga k where k.ativa), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(to_jsonb(h) order by h.enviado_em desc) from (
        select k.id, k.tipo, k.nome_original as nome, k.linhas, k.status, k.aviso, k.erro, k.enviado_em, (select nome from public.perfil p where p.id = k.enviado_por) as por
        from "10 - Frotas".frota_bi_carga k order by k.enviado_em desc limit greatest(p_limite, 1)) h), '[]'::jsonb));
end $$;

-- ───────────── BI: itens (veículos e máquinas do app + equipamentos leves da carga) ─────────────
-- Mesma regra do modelo do Power BI: situação hoje, pendências, item do orçamento pelo de-para.
create or replace view "10 - Frotas".frota_bi_itens as
with h as (select "10 - Frotas".frota_bi_hoje() as hoje),
dp as (select distinct on (d.fonte, "10 - Frotas".frota_chave(d.descricao)) d.fonte, "10 - Frotas".frota_chave(d.descricao) as dchave, "10 - Frotas".frota_chave(d.item) as item, d.situacao
        from "10 - Frotas".frota_bi_depara d join "10 - Frotas".frota_bi_carga k on k.id = d.carga_id and k.ativa order by d.fonte, "10 - Frotas".frota_chave(d.descricao)),
ccs as (select distinct o.cod_cc from "10 - Frotas".frota_bi_orcamento o join "10 - Frotas".frota_bi_carga k on k.id = o.carga_id and k.ativa),
vei as (
  select 'Veículos e máquinas'::text as fonte, v.placa as id, v.modelo as descricao, "10 - Frotas".frota_chave(v.modelo) as chave,
         "10 - Frotas".frota_consorcio(v.consorcio) as consorcio, nullif(btrim(v.fornecedor), '') as locador,
         (select nullif(btrim(p.area), '') from "10 - Frotas".frota_veiculo_vinculo vv join public.perfil p on p.id = vv.condutor_id
            where vv.veiculo_id = v.id and vv.desvinculado_em is null order by vv.vinculado_em desc limit 1) as setor,
         (select nullif(btrim(p.nome), '') from "10 - Frotas".frota_veiculo_vinculo vv join public.perfil p on p.id = vv.condutor_id
            where vv.veiculo_id = v.id and vv.desvinculado_em is null order by vv.vinculado_em desc limit 1) as colaborador,
         "10 - Frotas".frota_cc(v.centro_custo) as cod_cc, v.data_inicio::date as ini, coalesce(v.data_fim_real, v.data_fim_prevista)::date as fim, null::text as alerta
  from "10 - Frotas".frota_veiculo v
),
lev as (
  select 'Equipamentos leves'::text, nullif(btrim(l.cod), ''), nullif(btrim(l.descricao), ''), "10 - Frotas".frota_chave(l.descricao),
         "10 - Frotas".frota_consorcio(l.empresa), nullif(btrim(l.fornecedor), ''), null::text, null::text, null::text, l.dt_aporte, l.dt_devolucao,
         case when "10 - Frotas".frota_chave(l.status) = 'ATIVO' and l.dt_devolucao is not null and l.dt_devolucao <= (select hoje from h) then 'STATUS ATIVO, mas a devolução já passou'
              when "10 - Frotas".frota_chave(l.status) = 'INATIVO' and l.dt_devolucao is null then 'STATUS INATIVO, mas sem devolução' end
  from "10 - Frotas".frota_bi_leve l join "10 - Frotas".frota_bi_carga k on k.id = l.carga_id and k.ativa
  where nullif(btrim(l.descricao), '') is not null or nullif(btrim(l.cod), '') is not null
),
t0 as (select * from vei union all select * from lev),
rep as (select fonte, id from t0 where id is not null and id <> '-' group by fonte, id having count(*) > 1),
x as (
  select t0.*, d.item as item_dp, d.situacao as sit_dp
  from t0 left join dp d on d.fonte = t0.fonte and d.dchave = t0.chave
)
select x.fonte as "Fonte", x.id as "ID", x.descricao as "Descrição", x.consorcio as "Consórcio", x.locador as "Locador", x.setor as "Setor", x.colaborador as "Colaborador",
       coalesce(x.cod_cc, 'SEM CC') as "Cód CC", coalesce(x.item_dp, '(sem de-para)') as "Item do orçamento",
       x.ini as "Data Mobilização", x.fim as "Data Desmobilização",
       case when x.ini is null then 'Sem data de mobilização' when x.ini > h.hoje then 'Programado' when x.fim is not null and x.fim <= h.hoje then 'Desmobilizado' else 'Ativo' end as "Situação Hoje",
       case when x.ini is null then 4 when x.ini > h.hoje then 2 when x.fim is not null and x.fim <= h.hoje then 3 else 1 end as "Situação Ordem",
       nullif(concat_ws('; ',
         case when x.item_dp is null then 'descrição sem de-para' end,
         case when x.sit_dp = 'A confirmar' then 'de-para a confirmar' end,
         case when x.ini is null then 'sem data de mobilização' end,
         case when x.ini is not null and x.fim is not null and x.fim < x.ini then 'desmobilização antes da mobilização' end,
         case when x.consorcio is null then 'sem consórcio' end,
         case when x.locador is null then 'sem locador/fornecedor' end,
         case when x.fonte = 'Veículos e máquinas' and x.cod_cc is null then 'sem centro de custo' end,
         case when x.cod_cc is not null and x.cod_cc not in (select cod_cc from ccs) then 'centro de custo sem orçamento' end,
         case when x.id is not null and exists (select 1 from rep r where r.fonte = x.fonte and r.id = x.id) then 'código/placa repetido' end,
         x.alerta), '') as "Pendências"
from x cross join h;

create or replace function public.app_frota_bi()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "10 - Frotas".frota_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'hoje', "10 - Frotas".frota_bi_hoje(),
    'itens', coalesce((select jsonb_agg(to_jsonb(i)) from "10 - Frotas".frota_bi_itens i), '[]'::jsonb),
    'orc', coalesce((select jsonb_agg(jsonb_build_object('Consórcio', o.consorcio, 'Cód CC', o.cod_cc, 'Item do orçamento', "10 - Frotas".frota_chave(o.item), 'Mês', o.mes, 'Qtd', o.qtd))
        from "10 - Frotas".frota_bi_orcamento o join "10 - Frotas".frota_bi_carga k on k.id = o.carga_id and k.ativa), '[]'::jsonb),
    'areas', coalesce((select jsonb_agg(jsonb_build_object('Cód CC', a.cod_cc, 'Área', a.area)) from "10 - Frotas".frota_bi_area a join "10 - Frotas".frota_bi_carga k on k.id = a.carga_id and k.ativa), '[]'::jsonb),
    'depara', coalesce((select jsonb_agg(jsonb_build_object('Fonte', d.fonte, 'Descrição na planilha', "10 - Frotas".frota_chave(d.descricao), 'Item do orçamento', coalesce("10 - Frotas".frota_chave(d.item), '(sem item no orçamento)'),
        'Situação do de-para', d.situacao, 'Observação', d.observacao)) from "10 - Frotas".frota_bi_depara d join "10 - Frotas".frota_bi_carga k on k.id = d.carga_id and k.ativa), '[]'::jsonb),
    'grupos', coalesce((select jsonb_agg(jsonb_build_object('Item do orçamento', "10 - Frotas".frota_chave(g.item), 'Grupo', g.grupo)) from "10 - Frotas".frota_bi_item_orc g join "10 - Frotas".frota_bi_carga k on k.id = g.carga_id and k.ativa), '[]'::jsonb),
    'abast', coalesce((select jsonb_agg(jsonb_build_object('Data', a.data, 'Mês', a.mes, 'Placa', a.placa, 'Motorista', a.motorista, 'Consórcio', a.consorcio, 'Combustível', a.combustivel,
        'Litros', a.litros, 'R$/Litro', a.preco_litro, 'Valor Total', a.valor_total, 'Posto', a.posto, 'Alerta', a.alerta) order by a.data desc)
        from "10 - Frotas".frota_bi_abast a join "10 - Frotas".frota_bi_carga k on k.id = a.carga_id and k.ativa), '[]'::jsonb),
    'cargas', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'nome', k.nome_original, 'linhas', k.linhas, 'em', k.concluido_em) order by k.tipo)
        from "10 - Frotas".frota_bi_carga k where k.ativa), '[]'::jsonb));
end $$;

-- ───────────── acesso ─────────────
create or replace function public.app_frota_bi_acesso()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ver', "10 - Frotas".frota_bi_pode(auth.uid()), 'carregar', "10 - Frotas".frota_carga_pode(auth.uid()),
    'admin', exists (select 1 from public.perfil p where p.id = auth.uid() and p.ativo and p.funcao = 'admin'))
$$;
create or replace function public.app_frota_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and ativo and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', coalesce(p.nome, p.email), 'email', p.email, 'funcao', p.funcao, 'cargo', c.nome,
      'ver', coalesce(p.frota_bi_acesso, false), 'carregar', coalesce(p.frota_carga_acesso, false), 'admin', p.funcao = 'admin') order by coalesce(p.nome, p.email))
    from public.perfil p left join "9 - suprimentos".sup_cargo c on c.id = p.cargo_id where coalesce(p.ativo, true)), '[]'::jsonb);
end $$;
create or replace function public.app_frota_acesso_set(p_uuid uuid, p_ver boolean, p_carregar boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and ativo and funcao = 'admin') then raise exception 'sem permissão'; end if;
  update public.perfil set frota_bi_acesso = coalesce(p_ver, false), frota_carga_acesso = coalesce(p_carregar, false) where id = p_uuid;
end $$;

revoke all on function public.app_frota_carga_iniciar(text, text, text), public.app_frota_carga_lote(bigint, text, jsonb), public.app_frota_carga_finalizar(bigint),
  public.app_frota_carga_falha(bigint, text), public.app_frota_cargas_listar(int), public.app_frota_bi(), public.app_frota_bi_acesso(),
  public.app_frota_acesso_listar(), public.app_frota_acesso_set(uuid, boolean, boolean) from public, anon;
grant execute on function public.app_frota_carga_iniciar(text, text, text), public.app_frota_carga_lote(bigint, text, jsonb), public.app_frota_carga_finalizar(bigint),
  public.app_frota_carga_falha(bigint, text), public.app_frota_cargas_listar(int), public.app_frota_bi(), public.app_frota_bi_acesso(),
  public.app_frota_acesso_listar(), public.app_frota_acesso_set(uuid, boolean, boolean) to authenticated;
