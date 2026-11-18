-- BI de Estoque dentro do AcquaHub + carga direta do relatório "Posições de Estoque Atual" do SIENGE (2026-11-19)
-- Substitui o Power BI "Estoque". Depende de docs/migracao_sup_bi.sql (usa o mesmo log de cargas, as mesmas permissões e a mesma tela de cargas).
-- Regra (a mesma do BI): 1 arquivo = 1 obra numa data ("posição"). Mesma obra + mesmo dia: vale a exportação mais recente.
-- Datas diferentes ficam como histórico; os números principais usam a posição MAIS RECENTE de cada obra.
-- Só obras 430 (ZA1004 · Águas Integradas) e 440 (ZA0200 · Eficiência Hídrica).

-- o log de cargas passa a aceitar o tipo 'estoque'
alter table "9 - suprimentos".sup_carga drop constraint if exists sup_carga_tipo_check;
alter table "9 - suprimentos".sup_carga add constraint sup_carga_tipo_check check (tipo in ('painel','mapa','vinculados','estoque'));

create table if not exists "9 - suprimentos".sup_estoque_posicao (
  carga_id      bigint primary key references "9 - suprimentos".sup_carga(id) on delete cascade,
  obra          int not null,
  empresa       text,
  obra_sienge   text,
  data_posicao  date not null,
  exportado_em  timestamp not null,          -- horário do rodapé do relatório (BRT, sem fuso)
  total_obra    numeric
);
create table if not exists "9 - suprimentos".sup_estoque_item (
  carga_id bigint not null references "9 - suprimentos".sup_carga(id) on delete cascade,
  seq int not null, insumo text, codigo text, descricao text, grupo text, familia text, unidade text,
  quantidade numeric, custo_medio numeric, custo_total numeric, estoque_minimo numeric, qtd_reservada numeric
);
create index if not exists sup_estoque_item_carga on "9 - suprimentos".sup_estoque_item (carga_id);
alter table "9 - suprimentos".sup_estoque_posicao enable row level security;
alter table "9 - suprimentos".sup_estoque_item enable row level security;

-- iniciar: agora também aceita o tipo 'estoque'
create or replace function public.app_sup_carga_iniciar(p_tipo text, p_nome text, p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_aviso text; v_ant timestamptz;
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão para carregar relatórios de Suprimentos'; end if;
  if p_tipo not in ('painel','mapa','vinculados','estoque') then raise exception 'tipo de relatório inválido'; end if;
  select max(concluido_em) into v_ant from "9 - suprimentos".sup_carga where tipo = p_tipo and status = 'ok' and sha256 is not null and sha256 = p_sha256;
  if v_ant is not null then v_aviso := 'idêntico ao já enviado em ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'); end if;
  insert into "9 - suprimentos".sup_carga (tipo, nome_original, sha256, aviso) values (p_tipo, left(p_nome, 300), p_sha256, v_aviso) returning id into v_id;
  return jsonb_build_object('carga_id', v_id, 'aviso', v_aviso);
end $$;

-- cabeçalho da posição (chamado antes dos lotes de itens)
create or replace function public.app_sup_estoque_posicao(p_carga bigint, p_obra int, p_empresa text, p_obra_sienge text, p_exportado_em timestamp, p_total_obra numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c "9 - suprimentos".sup_carga;
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "9 - suprimentos".sup_carga where id = p_carga and status = 'pendente' and tipo = 'estoque';
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if p_obra not in (430, 440) then raise exception 'obra % fora do escopo (só 430 e 440)', p_obra; end if;
  if p_exportado_em is null then raise exception 'não achei a data/hora do rodapé do relatório'; end if;
  insert into "9 - suprimentos".sup_estoque_posicao (carga_id, obra, empresa, obra_sienge, data_posicao, exportado_em, total_obra)
  values (p_carga, p_obra, left(p_empresa, 200), left(p_obra_sienge, 200), p_exportado_em::date, p_exportado_em, p_total_obra)
  on conflict (carga_id) do update set obra = excluded.obra, empresa = excluded.empresa, obra_sienge = excluded.obra_sienge,
    data_posicao = excluded.data_posicao, exportado_em = excluded.exportado_em, total_obra = excluded.total_obra;
end $$;

-- lote: agora também aceita itens de estoque (as outras 3 cargas ficam como estão)
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
  elsif c.tipo = 'estoque' then
    insert into "9 - suprimentos".sup_estoque_item
    select p_carga, x.seq, x.insumo, x.codigo, x.descricao, x.grupo, x.familia, x.unidade, x.quantidade, x.custo_medio, x.custo_total, x.estoque_minimo, x.qtd_reservada
    from jsonb_to_recordset(p_linhas) as x(seq int, insumo text, codigo text, descricao text, grupo text, familia text, unidade text,
      quantidade numeric, custo_medio numeric, custo_total numeric, estoque_minimo numeric, qtd_reservada numeric);
  else
    insert into "9 - suprimentos".sup_cotped_linha
    select p_carga, x.idx, x.cotacao, x.data_cotacao, x.pedido, x.obra
    from jsonb_to_recordset(p_linhas) as x(idx int, cotacao int, data_cotacao date, pedido text, obra int)
    where x.obra in (430, 440);
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.app_sup_carga_finalizar(p_carga bigint, p_lidas int default null, p_fora int default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c "9 - suprimentos".sup_carga; n int; v_obras int[]; v_aviso text; p "9 - suprimentos".sup_estoque_posicao;
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into c from "9 - suprimentos".sup_carga where id = p_carga and status = 'pendente' for update;
  if not found then raise exception 'carga não encontrada ou já encerrada'; end if;
  if c.tipo = 'painel' then
    select count(*), array_agg(distinct obra order by obra) into n, v_obras from "9 - suprimentos".sup_painel_linha where carga_id = p_carga;
  elsif c.tipo = 'mapa' then
    select count(*), array_agg(distinct obra order by obra) into n, v_obras from "9 - suprimentos".sup_mapa_linha where carga_id = p_carga;
  elsif c.tipo = 'estoque' then
    select * into p from "9 - suprimentos".sup_estoque_posicao where carga_id = p_carga;
    if not found then raise exception 'posição de estoque sem cabeçalho (obra/data) — nada foi alterado'; end if;
    select count(*) into n from "9 - suprimentos".sup_estoque_item where carga_id = p_carga;
    v_obras := array[p.obra];
  else
    select count(*), array_agg(distinct obra order by obra) into n, v_obras from "9 - suprimentos".sup_cotped_linha where carga_id = p_carga;
  end if;
  if coalesce(n, 0) = 0 then
    update "9 - suprimentos".sup_carga set status = 'erro', erro = 'nenhuma linha válida no arquivo', concluido_em = now() where id = p_carga;
    raise exception 'nenhuma linha válida no arquivo — nada foi alterado';
  end if;
  if c.tipo = 'painel' then
    update "9 - suprimentos".sup_carga set ativa = false where tipo = 'painel' and ativa;
    delete from "9 - suprimentos".sup_painel_linha where carga_id in (select id from "9 - suprimentos".sup_carga where tipo = 'painel' and id <> p_carga);
  elsif c.tipo = 'mapa' then
    delete from "9 - suprimentos".sup_mapa_linha where carga_id <> p_carga and obra = any (v_obras)
      and carga_id in (select id from "9 - suprimentos".sup_carga where tipo = 'mapa');
    update "9 - suprimentos".sup_carga k set ativa = false where k.tipo = 'mapa' and k.ativa and k.id <> p_carga
      and not exists (select 1 from "9 - suprimentos".sup_mapa_linha l where l.carga_id = k.id);
  elsif c.tipo = 'estoque' then
    -- mesma obra no mesmo dia: a exportação nova substitui a anterior (como no BI, vale a mais recente); outros dias ficam de histórico
    delete from "9 - suprimentos".sup_estoque_item where carga_id in
      (select o.carga_id from "9 - suprimentos".sup_estoque_posicao o where o.obra = p.obra and o.data_posicao = p.data_posicao and o.carga_id <> p_carga);
    delete from "9 - suprimentos".sup_estoque_posicao where obra = p.obra and data_posicao = p.data_posicao and carga_id <> p_carga;
    update "9 - suprimentos".sup_carga k set ativa = false where k.tipo = 'estoque' and k.ativa and k.id <> p_carga
      and not exists (select 1 from "9 - suprimentos".sup_estoque_posicao o where o.carga_id = k.id);
  else
    update "9 - suprimentos".sup_carga set ativa = false where tipo = 'vinculados' and ativa;
    delete from "9 - suprimentos".sup_cotped_linha where carga_id in (select id from "9 - suprimentos".sup_carga where tipo = 'vinculados' and id <> p_carga);
  end if;
  v_aviso := c.aviso;
  if coalesce(p_fora, 0) > 0 then v_aviso := concat_ws(' · ', v_aviso, p_fora || ' linha(s) de outras obras ignoradas'); end if;
  if c.tipo = 'estoque' and p.total_obra is not null then
    declare v_soma numeric; begin
      select sum(coalesce(custo_total, 0)) into v_soma from "9 - suprimentos".sup_estoque_item where carga_id = p_carga;
      if abs(v_soma - p.total_obra) > 0.05 * n then
        v_aviso := concat_ws(' · ', v_aviso, 'soma dos itens (' || to_char(v_soma, 'FM999G999G990D00') || ') difere do "Total da obra" do relatório (' || to_char(p.total_obra, 'FM999G999G990D00') || ')');
      end if; end;
  end if;
  update "9 - suprimentos".sup_carga set status = 'ok', ativa = true, obras = v_obras, linhas = n, fora_escopo = p_fora, aviso = v_aviso, concluido_em = now() where id = p_carga;
  return jsonb_build_object('carga_id', p_carga, 'tipo', c.tipo, 'linhas', n, 'obras', v_obras, 'aviso', v_aviso,
    'data_posicao', case when c.tipo = 'estoque' then p.data_posicao end);
end $$;

create or replace function public.app_sup_carga_falha(p_carga bigint, p_erro text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not "9 - suprimentos".sup_carga_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  update "9 - suprimentos".sup_carga set status = 'erro', erro = left(p_erro, 500), concluido_em = now() where id = p_carga and status = 'pendente';
  delete from "9 - suprimentos".sup_painel_linha where carga_id = p_carga;
  delete from "9 - suprimentos".sup_mapa_linha where carga_id = p_carga;
  delete from "9 - suprimentos".sup_cotped_linha where carga_id = p_carga;
  delete from "9 - suprimentos".sup_estoque_item where carga_id = p_carga;
  delete from "9 - suprimentos".sup_estoque_posicao where carga_id = p_carga;
end $$;

-- ───────────── BI: mesmas colunas/regras do modelo do Power BI "Estoque" ─────────────
-- Itens por posição, com Classe ABC (curva por obra: A até 80% do valor acumulado ANTES do item, B até 95%, C o resto),
-- participação na obra e pendências do relatório de origem (nada é corrigido: só sinalizado).
create or replace view "9 - suprimentos".sup_bi_estoque as
with p as (
  select o.*, case o.obra when 430 then 'Águas Integradas' when 440 then 'Eficiência Hídrica' end as consorcio,
         max(o.data_posicao) over (partition by o.obra) as ultima
  from "9 - suprimentos".sup_estoque_posicao o join "9 - suprimentos".sup_carga k on k.id = o.carga_id and k.ativa
), i as (
  select it.*, p.obra, p.empresa, p.obra_sienge, p.consorcio, p.data_posicao, p.exportado_em,
         (p.data_posicao = p.ultima) as mais_recente,
         sum(coalesce(it.custo_total, 0)) over (partition by it.carga_id) as tot,
         coalesce(sum(coalesce(it.custo_total, 0)) over (partition by it.carga_id order by it.custo_total desc nulls last, it.codigo asc, it.seq
              rows between unbounded preceding and 1 preceding), 0) as ant,
         count(*) over (partition by it.carga_id, it.codigo) as rep
  from "9 - suprimentos".sup_estoque_item it join p on p.carga_id = it.carga_id
)
select i.consorcio as "Consórcio", i.empresa as "Empresa", i.obra_sienge as "Obra SIENGE", i.data_posicao as "Data da Posição", i.exportado_em as "Exportado em",
       case when i.mais_recente then 'Sim' else 'Não' end as "Mais Recente",
       i.insumo as "Insumo", i.codigo as "Código", i.descricao as "Descrição", i.grupo as "Grupo", i.familia as "Família", i.unidade as "Unidade",
       i.quantidade as "Quantidade", i.custo_medio as "Custo Médio", i.custo_total as "Custo Total", i.estoque_minimo as "Estoque Mínimo", i.qtd_reservada as "Quantidade Reservada",
       case when i.tot = 0 then null when i.ant / i.tot < 0.8 then 'A' when i.ant / i.tot < 0.95 then 'B' else 'C' end as "Classe ABC",
       case when i.tot = 0 then null else coalesce(i.custo_total, 0) / i.tot end as "Participação na Obra",
       nullif(concat_ws('; ',
         case when i.quantidade is null or i.quantidade <= 0 then 'quantidade zerada ou negativa' end,
         case when i.custo_total is null then 'sem custo total' end,
         case when i.quantidade is not null and i.custo_medio is not null and i.custo_total is not null and abs(i.quantidade * i.custo_medio - i.custo_total) > 0.05
              then 'custo total diferente de quantidade × custo médio' end,
         case when i.familia is null then 'sem família' end,
         case when i.rep > 1 then 'código repetido na mesma posição' end), '') as "Pendências"
from i;

create or replace view "9 - suprimentos".sup_bi_estoque_posicoes as
select k.nome_original as "Arquivo", k.enviado_em as "Carregado em", p.empresa as "Empresa", p.obra_sienge as "Obra SIENGE",
       case p.obra when 430 then 'Águas Integradas' when 440 then 'Eficiência Hídrica' end as "Consórcio",
       p.exportado_em as "Exportado em", p.data_posicao as "Data da Posição",
       (select count(*) from "9 - suprimentos".sup_estoque_item it where it.carga_id = p.carga_id) as "Itens na Posição",
       (select sum(coalesce(it.custo_total, 0)) from "9 - suprimentos".sup_estoque_item it where it.carga_id = p.carga_id) as "Valor Calculado (itens)",
       p.total_obra as "Total da Obra (relatório)",
       round((select sum(coalesce(it.custo_total, 0)) from "9 - suprimentos".sup_estoque_item it where it.carga_id = p.carga_id) - p.total_obra, 2) as "Diferença Itens x Relatório",
       case when p.data_posicao = max(p.data_posicao) over (partition by p.obra) then 'Sim' else 'Não' end as "Mais Recente"
from "9 - suprimentos".sup_estoque_posicao p join "9 - suprimentos".sup_carga k on k.id = p.carga_id and k.ativa;

create or replace function public.app_sup_bi_estoque()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "9 - suprimentos".sup_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'itens', coalesce((select jsonb_agg(to_jsonb(e) order by e."Consórcio", e."Data da Posição" desc, e."Custo Total" desc nulls last, e."Código") from "9 - suprimentos".sup_bi_estoque e), '[]'::jsonb),
    'posicoes', coalesce((select jsonb_agg(to_jsonb(q) order by q."Consórcio", q."Data da Posição" desc) from "9 - suprimentos".sup_bi_estoque_posicoes q), '[]'::jsonb),
    'cargas', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'nome', k.nome_original, 'obras', k.obras, 'linhas', k.linhas, 'em', k.concluido_em)
        order by k.obras) from "9 - suprimentos".sup_carga k where k.ativa and k.tipo = 'estoque'), '[]'::jsonb));
end $$;

revoke all on function public.app_sup_estoque_posicao(bigint, int, text, text, timestamp, numeric), public.app_sup_bi_estoque() from public, anon;
grant execute on function public.app_sup_estoque_posicao(bigint, int, text, text, timestamp, numeric), public.app_sup_bi_estoque() to authenticated;
