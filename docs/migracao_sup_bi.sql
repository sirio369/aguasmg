-- BI de Suprimentos dentro do AcquaHub + carga direta dos relatórios do SIENGE (2026-11-19)
-- Substitui o Power BI "Suprimentos" (PBIP). A regra é a mesma do Power Query/DAX do BI, portada para SQL:
--   Painel de Compras (estágio do funil, aging, leads, valor estimado), Mapa de Cotações (cotações × itens × fornecedores)
--   e Cotações e Pedidos Vinculados (data da cotação de cada pedido).
-- Fluxo da carga (o app lê o .xlsx no aparelho; o banco recebe linhas já normalizadas, em lotes):
--   app_sup_carga_iniciar → app_sup_carga_lote (N vezes) → app_sup_carga_finalizar   (ou app_sup_carga_falha)
-- Regra de substituição (decidida pela usuária): o relatório novo SUBSTITUI o anterior.
--   • Painel de Compras ........ substitui tudo (1 arquivo com as duas obras);
--   • Mapa de Cotações ......... substitui por obra (1 arquivo por obra: 430 ou 440);
--   • Vinculados ............... substitui tudo.
-- Nada é apagado até o arquivo novo chegar inteiro (finalizar troca de uma vez, numa transação).
-- Só as obras 430 (ZA1004 · Águas Integradas) e 440 (ZA0200 · Eficiência Hídrica) entram.

-- ───────────── acesso ─────────────
alter table public.perfil add column if not exists sup_bi_acesso boolean not null default false;     -- vê o BI de Suprimentos
alter table public.perfil add column if not exists sup_carga_acesso boolean not null default false;  -- sobe os relatórios

create or replace function "9 - suprimentos".sup_bi_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo
    and (p.funcao = 'admin' or p.sup_bi_acesso or p.sup_carga_acesso))
$$;
create or replace function "9 - suprimentos".sup_carga_pode(p_uid uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_uid and p.ativo
    and (p.funcao = 'admin' or p.sup_carga_acesso))
$$;

-- "hoje" do BI (BRT). app.sup_hoje existe só para teste/conferência de números de uma data passada.
create or replace function "9 - suprimentos".sup_bi_hoje() returns date language sql stable as $$
  select coalesce(nullif(current_setting('app.sup_hoje', true), '')::date, (now() at time zone 'America/Sao_Paulo')::date)
$$;

-- fnNorm do BI: tira o código do insumo ("2900 - CIMENTO" → "CIMENTO"), troca | e _ por espaço, colapsa espaços, caixa alta.
create or replace function "9 - suprimentos".sup_norm(s text) returns text language sql immutable as $$
  select upper(regexp_replace(btrim(replace(replace(
    case when t ~ '^[0-9]+[[:space:]]*-' then regexp_replace(t, '^[0-9]+[[:space:]]*-[[:space:]]*', '') else t end,
    '|', ' '), '_', ' ')), '[ ]+', ' ', 'g'))
  from (select ltrim(regexp_replace(coalesce(s, ''), E'[\\t\\n\\r\\u00a0]', ' ', 'g')) as t) x
$$;

-- ───────────── tabelas (app-only: RLS sem policy) ─────────────
create table if not exists "9 - suprimentos".sup_carga (
  id           bigserial primary key,
  tipo         text not null check (tipo in ('painel','mapa','vinculados')),
  nome_original text,
  sha256       text,
  obras        int[],
  linhas       int,
  fora_escopo  int,
  status       text not null default 'pendente' check (status in ('pendente','ok','erro')),
  ativa        boolean not null default false,
  aviso        text,
  erro         text,
  enviado_por  uuid default auth.uid(),
  enviado_em   timestamptz not null default now(),
  concluido_em timestamptz
);
create table if not exists "9 - suprimentos".sup_painel_linha (
  carga_id bigint not null references "9 - suprimentos".sup_carga(id) on delete cascade,
  sc int not null, obra int not null, cod_insumo int, item text, grupo text, qtd_solicitada numeric, unidade text,
  data_solicitacao date, solicitante text, sit_solicitacao text, data_necessidade date, data_aut_solicitacao date,
  sit_aut_item text, pedido text, data_pedido date, sit_pedido text, comprador text, fornecedor text, previsao_entrega date,
  data_aut_pedido date, sit_aut_pedido text, qtd_entregue numeric, saldo numeric, data_nf date, nf text, valor_nf numeric,
  sit_pagamento text, data_entrega_obra date
);
create index if not exists sup_painel_linha_carga on "9 - suprimentos".sup_painel_linha (carga_id);
create table if not exists "9 - suprimentos".sup_mapa_linha (
  carga_id bigint not null references "9 - suprimentos".sup_carga(id) on delete cascade,
  cotacao int, comprador text, obra int not null, insumo text, qtd numeric, unidade text, fornecedor text,
  preco_unit numeric, preco_total numeric, seq bigint not null
);
create index if not exists sup_mapa_linha_carga on "9 - suprimentos".sup_mapa_linha (carga_id);
create table if not exists "9 - suprimentos".sup_cotped_linha (
  carga_id bigint not null references "9 - suprimentos".sup_carga(id) on delete cascade,
  idx int not null, cotacao int, data_cotacao date, pedido text not null, obra int
);
create index if not exists sup_cotped_linha_carga on "9 - suprimentos".sup_cotped_linha (carga_id);
alter table "9 - suprimentos".sup_carga enable row level security;
alter table "9 - suprimentos".sup_painel_linha enable row level security;
alter table "9 - suprimentos".sup_mapa_linha enable row level security;
alter table "9 - suprimentos".sup_cotped_linha enable row level security;

-- ───────────── carga ─────────────
create or replace function public.app_sup_carga_iniciar(p_tipo text, p_nome text, p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_aviso text; v_ant timestamptz;
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão para carregar relatórios de Suprimentos'; end if;
  if p_tipo not in ('painel','mapa','vinculados') then raise exception 'tipo de relatório inválido'; end if;
  select max(concluido_em) into v_ant from "9 - suprimentos".sup_carga where tipo = p_tipo and status = 'ok' and sha256 is not null and sha256 = p_sha256;
  if v_ant is not null then v_aviso := 'idêntico ao já enviado em ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'); end if;
  insert into "9 - suprimentos".sup_carga (tipo, nome_original, sha256, aviso) values (p_tipo, left(p_nome, 300), p_sha256, v_aviso) returning id into v_id;
  return jsonb_build_object('carga_id', v_id, 'aviso', v_aviso);
end $$;

create or replace function public.app_sup_carga_lote(p_carga bigint, p_linhas jsonb)
returns int language plpgsql security definer set search_path to 'public' as $$
declare c "9 - suprimentos".sup_carga; n int;
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "9 - suprimentos".sup_carga where id = p_carga and status = 'pendente';
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if jsonb_typeof(p_linhas) <> 'array' then raise exception 'lote inválido'; end if;
  if c.tipo = 'painel' then
    insert into "9 - suprimentos".sup_painel_linha
    select p_carga, x.sc, x.obra, x.cod_insumo, x.item, x.grupo, x.qtd_solicitada, x.unidade, x.data_solicitacao, x.solicitante, x.sit_solicitacao,
           x.data_necessidade, x.data_aut_solicitacao, x.sit_aut_item, x.pedido, x.data_pedido, x.sit_pedido, x.comprador, x.fornecedor,
           x.previsao_entrega, x.data_aut_pedido, x.sit_aut_pedido, x.qtd_entregue, x.saldo, x.data_nf, x.nf, x.valor_nf, x.sit_pagamento, x.data_entrega_obra
    from jsonb_to_recordset(p_linhas) as x(sc int, obra int, cod_insumo int, item text, grupo text, qtd_solicitada numeric, unidade text,
      data_solicitacao date, solicitante text, sit_solicitacao text, data_necessidade date, data_aut_solicitacao date, sit_aut_item text,
      pedido text, data_pedido date, sit_pedido text, comprador text, fornecedor text, previsao_entrega date, data_aut_pedido date,
      sit_aut_pedido text, qtd_entregue numeric, saldo numeric, data_nf date, nf text, valor_nf numeric, sit_pagamento text, data_entrega_obra date)
    where x.obra in (430, 440);
  elsif c.tipo = 'mapa' then
    insert into "9 - suprimentos".sup_mapa_linha
    select p_carga, x.cotacao, x.comprador, x.obra, x.insumo, x.qtd, x.unidade, x.fornecedor, x.preco_unit, x.preco_total, x.seq
    from jsonb_to_recordset(p_linhas) as x(cotacao int, comprador text, obra int, insumo text, qtd numeric, unidade text, fornecedor text,
      preco_unit numeric, preco_total numeric, seq bigint)
    where x.obra in (430, 440);
  else
    insert into "9 - suprimentos".sup_cotped_linha
    select p_carga, x.idx, x.cotacao, x.data_cotacao, x.pedido, x.obra
    from jsonb_to_recordset(p_linhas) as x(idx int, cotacao int, data_cotacao date, pedido text, obra int)
    where x.obra in (430, 440);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- troca o conjunto ativo de uma vez: o arquivo novo só vale (e o antigo só sai) se chegou inteiro e dentro do escopo
create or replace function public.app_sup_carga_finalizar(p_carga bigint, p_lidas int default null, p_fora int default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c "9 - suprimentos".sup_carga; n int; v_obras int[]; v_aviso text;
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "9 - suprimentos".sup_carga where id = p_carga and status = 'pendente' for update;
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if c.tipo = 'painel' then
    select count(*), array_agg(distinct obra order by obra) into n, v_obras from "9 - suprimentos".sup_painel_linha where carga_id = p_carga;
  elsif c.tipo = 'mapa' then
    select count(*), array_agg(distinct obra order by obra) into n, v_obras from "9 - suprimentos".sup_mapa_linha where carga_id = p_carga;
  else
    select count(*), array_agg(distinct obra order by obra) into n, v_obras from "9 - suprimentos".sup_cotped_linha where carga_id = p_carga;
  end if;
  if coalesce(n, 0) = 0 then
    update "9 - suprimentos".sup_carga set status = 'erro', erro = 'nenhuma linha das obras 430/440 no arquivo', concluido_em = now() where id = p_carga;
    raise exception 'nenhuma linha das obras 430/440 no arquivo — nada foi alterado';
  end if;
  if c.tipo = 'painel' then
    update "9 - suprimentos".sup_carga set ativa = false where tipo = 'painel' and ativa;
    delete from "9 - suprimentos".sup_painel_linha where carga_id in (select id from "9 - suprimentos".sup_carga where tipo = 'painel' and id <> p_carga);
  elsif c.tipo = 'mapa' then
    -- substitui só as obras que vieram neste arquivo
    delete from "9 - suprimentos".sup_mapa_linha where carga_id <> p_carga and obra = any (v_obras)
      and carga_id in (select id from "9 - suprimentos".sup_carga where tipo = 'mapa');
    update "9 - suprimentos".sup_carga k set ativa = false where k.tipo = 'mapa' and k.ativa and k.id <> p_carga
      and not exists (select 1 from "9 - suprimentos".sup_mapa_linha l where l.carga_id = k.id);
  else
    update "9 - suprimentos".sup_carga set ativa = false where tipo = 'vinculados' and ativa;
    delete from "9 - suprimentos".sup_cotped_linha where carga_id in (select id from "9 - suprimentos".sup_carga where tipo = 'vinculados' and id <> p_carga);
  end if;
  v_aviso := c.aviso;
  if coalesce(p_fora, 0) > 0 then v_aviso := concat_ws(' · ', v_aviso, p_fora || ' linha(s) de outras obras ignoradas'); end if;
  update "9 - suprimentos".sup_carga set status = 'ok', ativa = true, obras = v_obras, linhas = n, fora_escopo = p_fora, aviso = v_aviso, concluido_em = now() where id = p_carga;
  return jsonb_build_object('carga_id', p_carga, 'tipo', c.tipo, 'linhas', n, 'obras', v_obras, 'aviso', v_aviso);
end $$;

create or replace function public.app_sup_carga_falha(p_carga bigint, p_erro text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  update "9 - suprimentos".sup_carga set status = 'erro', erro = left(p_erro, 500), concluido_em = now() where id = p_carga and status = 'pendente';
  delete from "9 - suprimentos".sup_painel_linha where carga_id = p_carga;
  delete from "9 - suprimentos".sup_mapa_linha where carga_id = p_carga;
  delete from "9 - suprimentos".sup_cotped_linha where carga_id = p_carga;
end $$;

create or replace function public.app_sup_cargas_listar(p_limite int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "9 - suprimentos".sup_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'pode_carregar', "9 - suprimentos".sup_carga_pode(auth.uid()),
    'ativas', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'tipo', k.tipo, 'nome', k.nome_original, 'obras', k.obras, 'linhas', k.linhas,
        'em', k.concluido_em) order by k.tipo, k.obras) from "9 - suprimentos".sup_carga k where k.ativa), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(to_jsonb(h) order by h.enviado_em desc) from (
        select k.id, k.tipo, k.nome_original as nome, k.obras, k.linhas, k.status, k.aviso, k.erro, k.enviado_em,
               (select nome from public.perfil p where p.id = k.enviado_por) as por
        from "9 - suprimentos".sup_carga k order by k.enviado_em desc limit greatest(p_limite, 1)) h), '[]'::jsonb));
end $$;

-- ───────────── BI: mesmas colunas/regras das tabelas do modelo do Power BI ─────────────
-- Itens cotados (CotacoesItens): 1 linha por cotação × insumo × obra, só com preço total diferente de zero.
create or replace view "9 - suprimentos".sup_bi_cotacoes_itens as
with m as (
  select l.* from "9 - suprimentos".sup_mapa_linha l
  join "9 - suprimentos".sup_carga k on k.id = l.carga_id and k.ativa
  where l.preco_total is not null and l.preco_total <> 0
), g as (
  select cotacao, insumo, obra, min(seq) as seq, count(*) as n_forn,
         round(min(preco_total), 2) as menor, round(avg(preco_total), 2) as medio
  from m group by cotacao, insumo, obra
), p as (
  select distinct on (cotacao, insumo, obra) cotacao, insumo, obra, qtd, unidade, comprador
  from m order by cotacao, insumo, obra, seq
)
select g.cotacao as "Cotação",
       case g.obra when 430 then 'ZA1004 · Águas Integradas' when 440 then 'ZA0200 · Eficiência Hídrica' else 'Obra ' || g.obra end as "Obra",
       g.insumo as "Insumo", p.qtd as "Qtd", p.unidade as "Unidade", g.n_forn as "Nº de Fornecedores", g.menor as "Menor Proposta",
       case when g.n_forn >= 2 then g.medio end as "Preço Médio (2+ forn.)",
       case when g.n_forn >= 2 and g.menor <= 10000000 then greatest(0, g.medio - g.menor) else 0 end as "Valor Evitado",
       p.comprador as "Comprador",
       case when g.n_forn >= 6 then '6+' else g.n_forn::text end as "Faixa de Concorrência",
       g.obra::text || '|' || "9 - suprimentos".sup_norm(g.insumo) as "Chave", g.seq as "Seq"
from g join p using (cotacao, insumo, obra);

-- Preço de referência por obra+insumo: menor proposta ÷ qtd da cotação MAIS RECENTE (desempate: menor Seq).
create or replace view "9 - suprimentos".sup_bi_preco_ref as
select distinct on ("Chave") "Chave" as chave, "Menor Proposta" / "Qtd" as preco_unit
from "9 - suprimentos".sup_bi_cotacoes_itens
where "Qtd" is not null and "Qtd" > 0 and "Menor Proposta" is not null and "Menor Proposta" > 0 and "Cotação" is not null
order by "Chave", "Cotação" desc, "Seq" asc;

-- Linhas de itens da solicitação (Solicitacoes): estágio, aging, leads, fila do comprador, estimativa.
create or replace view "9 - suprimentos".sup_bi_solicitacoes as
with h as (select "9 - suprimentos".sup_bi_hoje() as hoje),
b as (
  select l.*,
         case when l.sit_aut_item = 'Reprovado' then 'reprovado'
              when l.sit_aut_item is distinct from 'Autorizado' then 'aguardando_autorizacao_item'
              when l.sit_solicitacao = 'Totalmente atendida' and l.pedido is null then 'atendida_contrato'
              when l.pedido is null then 'pronto_para_comprar'
              when l.sit_aut_pedido is distinct from 'Autorizado' then 'aguardando_autorizacao_pedido'
              when l.data_entrega_obra is null then 'aguardando_entrega'
              when coalesce(l.saldo, 0) > 0.0001 then 'entregue_parcial'
              when l.sit_pagamento = 'Totalmente pago' then 'pago'
              when l.nf is not null then 'faturado'
              else 'entregue_total' end as estagio_id,
         "9 - suprimentos".sup_norm(l.item) as item_norm
  from "9 - suprimentos".sup_painel_linha l
  join "9 - suprimentos".sup_carga k on k.id = l.carga_id and k.ativa
  where l.sit_solicitacao is distinct from 'Cancelada' and l.sit_aut_item is distinct from 'Reprovado' and l.sit_pedido is distinct from 'Cancelado'
),
cp as (
  select distinct on (pedido) pedido, data_cotacao
  from "9 - suprimentos".sup_cotped_linha c join "9 - suprimentos".sup_carga k on k.id = c.carga_id and k.ativa
  order by pedido, idx desc
),
ch as (
  select distinct l.obra::text || '|' || "9 - suprimentos".sup_norm(l.insumo) as chave
  from "9 - suprimentos".sup_mapa_linha l join "9 - suprimentos".sup_carga k on k.id = l.carga_id and k.ativa
),
x as (
  select b.*, h.hoje,
         case when b.grupo ~* 'SERVI|LOCA|CONSULTORIA|ASSESS' then 'Serviço / Contrato'
              when b.grupo ~* 'VERBAS|TAXAS|IMPOSTOS' then 'Taxas / Impostos'
              else 'Aquisição / Material' end as tipo_contratacao,
         b.obra::text || '|' || b.item_norm as chave_cotacao,
         case when b.data_solicitacao is null then null else h.hoje - b.data_solicitacao end as dias_aberto
  from b cross join h
),
y as (
  select x.*,
         (x.estagio_id in ('aguardando_autorizacao_item','pronto_para_comprar','aguardando_autorizacao_pedido','aguardando_entrega','entregue_parcial')) as aberto,
         (x.chave_cotacao in (select chave from ch)) as tem_cot,
         cp.data_cotacao as data_cotacao_pedido,
         pr.preco_unit as preco_ref
  from x left join cp on cp.pedido = x.pedido
         left join "9 - suprimentos".sup_bi_preco_ref pr on pr.chave = x.chave_cotacao
),
z as (
  select y.*,
         case when y.aberto and y.dias_aberto is not null then
              (case when y.dias_aberto <= 7 then 'OK' when y.dias_aberto <= 15 then 'Atenção' when y.dias_aberto <= 30 then 'Prioritário' else 'Crítico' end) end as urgencia,
         case when y.pedido is null and y.estagio_id <> 'atendida_contrato' and y.preco_ref is not null
                   and y.preco_ref * coalesce(y.qtd_solicitada, 0) <= 10000000 then round(y.preco_ref * coalesce(y.qtd_solicitada, 0), 2) end as valor_estimado,
         (y.tipo_contratacao = 'Aquisição / Material' and y.pedido is null and y.estagio_id not in ('reprovado','atendida_contrato')) as escopo_est
  from y
)
select z.sc::text as "Nº da SC", z.sc as "Nº da Solicitação",
       case z.obra when 430 then 'ZA1004 · Águas Integradas' when 440 then 'ZA0200 · Eficiência Hídrica' else 'Obra ' || z.obra end as "Obra",
       case z.obra when 430 then 'ZA1004' when 440 then 'ZA0200' else z.obra::text end as "Obra Sigla",
       z.item as "Item", z.grupo as "Grupo de Insumo", z.qtd_solicitada as "Qtd Solicitada", z.solicitante as "Solicitante",
       z.sit_aut_item as "Situação Autorização do Item", z.pedido as "Nº do Pedido", z.comprador as "Comprador", z.fornecedor as "Fornecedor",
       z.sit_aut_pedido as "Situação Autorização do Pedido", z.nf as "Nº da Nota Fiscal", z.valor_nf as "Valor da Nota",
       z.sit_pagamento as "Situação do Pagamento", z.data_solicitacao as "Data da Solicitação", z.previsao_entrega as "Previsão de Entrega",
       z.data_entrega_obra as "Data Entrega na Obra",
       case z.estagio_id when 'aguardando_autorizacao_item' then '1. Aguardando autorização do item' when 'pronto_para_comprar' then '2. Pronto para comprar'
         when 'aguardando_autorizacao_pedido' then '3. Aguardando autorização do pedido' when 'aguardando_entrega' then '4. Aguardando entrega'
         when 'entregue_parcial' then '5. Entregue parcialmente' when 'entregue_total' then '6. Entregue (sem nota fiscal)' when 'faturado' then '7. Faturado'
         when 'pago' then '8. Pago' when 'atendida_contrato' then '9. Atendida por contrato (sem pedido)' else '9. Reprovado' end as "Estágio",
       case when z.aberto then 'Sim' else 'Não' end as "Backlog Aberto", z.dias_aberto as "Dias em Aberto", z.urgencia as "Urgência",
       case z.urgencia when 'OK' then '0–7 dias' when 'Atenção' then '8–15 dias' when 'Prioritário' then '16–30 dias' when 'Crítico' then '> 30 dias' end as "Faixa de Aging",
       case z.urgencia when 'OK' then 1 when 'Atenção' then 2 when 'Prioritário' then 3 when 'Crítico' then 4 end as "Faixa de Aging Ordem",
       case when z.data_solicitacao is null or z.data_aut_solicitacao is null then null else z.data_aut_solicitacao - z.data_solicitacao end as "Lead Solicitação → Autorização",
       case when z.data_pedido is null or z.data_aut_pedido is null then null else z.data_aut_pedido - z.data_pedido end as "Lead Pedido → Autorização",
       case when z.data_pedido is null or z.data_entrega_obra is null then null else z.data_entrega_obra - z.data_pedido end as "Lead Pedido → Entrega",
       case when z.tem_cot then 'Sim' else 'Não' end as "Tem Cotação",
       case when z.estagio_id = 'pronto_para_comprar' then (case when z.tem_cot then 'Cotado, aguardando aprovação' else 'Pronto para cotar' end)
            when z.estagio_id = 'aguardando_autorizacao_pedido' then 'Aguardando autorização do pedido'
            when z.estagio_id = 'aguardando_entrega' then 'Aguardando entrega' end as "Fila do Comprador",
       case when z.estagio_id = 'pronto_para_comprar' then (case when z.tem_cot then 2 else 1 end)
            when z.estagio_id = 'aguardando_autorizacao_pedido' then 3 when z.estagio_id = 'aguardando_entrega' then 4 end as "Fila do Comprador Ordem",
       case when z.previsao_entrega is null then null else z.hoje - z.previsao_entrega end as "Dias de Atraso da Previsão",
       case when z.data_cotacao_pedido is null or z.data_pedido is null then null else z.data_pedido - z.data_cotacao_pedido end as "Lead Cotação → Pedido",
       z.valor_estimado as "Valor Estimado (sem pedido)",
       case when z.escopo_est then 'Sim' else 'Não' end as "Escopo da Estimativa",
       case when not z.escopo_est then null when z.valor_estimado is null then (case when z.preco_ref is not null then 'Estimativa a revisar' else 'Sem cotação equivalente' end)
            else 'Com preço de referência' end as "Situação da Estimativa",
       case when z.nf is not null and z.valor_nf is not null then z.nf || '|' || coalesce(z.fornecedor, '') end as "Chave NF",
       case when z.valor_estimado is null then null else z.valor_estimado / (case when z.qtd_solicitada is null or z.qtd_solicitada = 0 then 1 else z.qtd_solicitada end) end as "Preço Unit. Estimado (exibição)"
from z;

-- Tela do BI: devolve as linhas (mesmo contrato de colunas do modelo do Power BI) para o app calcular as medidas.
create or replace function public.app_sup_bi()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "9 - suprimentos".sup_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'hoje', "9 - suprimentos".sup_bi_hoje(),
    'sol', coalesce((select jsonb_agg(to_jsonb(s) order by s."Nº da Solicitação") from "9 - suprimentos".sup_bi_solicitacoes s), '[]'::jsonb),
    'cot', coalesce((select jsonb_agg(to_jsonb(c) order by c."Seq") from "9 - suprimentos".sup_bi_cotacoes_itens c), '[]'::jsonb),
    'cargas', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'nome', k.nome_original, 'obras', k.obras, 'linhas', k.linhas, 'em', k.concluido_em)
        order by k.tipo, k.obras) from "9 - suprimentos".sup_carga k where k.ativa), '[]'::jsonb));
end $$;

revoke all on function public.app_sup_carga_iniciar(text, text, text), public.app_sup_carga_lote(bigint, jsonb),
  public.app_sup_carga_finalizar(bigint, int, int), public.app_sup_carga_falha(bigint, text),
  public.app_sup_cargas_listar(int), public.app_sup_bi() from public, anon;
grant execute on function public.app_sup_carga_iniciar(text, text, text), public.app_sup_carga_lote(bigint, jsonb),
  public.app_sup_carga_finalizar(bigint, int, int), public.app_sup_carga_falha(bigint, text),
  public.app_sup_cargas_listar(int), public.app_sup_bi() to authenticated;
