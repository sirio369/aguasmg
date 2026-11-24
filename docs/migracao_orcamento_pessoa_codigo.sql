-- Orçamento: código fixo do card de pessoa (P-001…) — 24/11/2026, sw v453. Aplicado como orc_30_pessoa_codigo.
-- Uma numeração só para todos os organogramas; identifica vagas "A definir" no Excel ("Ligado a" / Nome).
-- Sem DROP. Idempotente. app_orc_quadro e app_orc_pessoa_salvar já devolvem to_jsonb(p) (o código vem junto).
create sequence if not exists "19 - orcamento".orc_pessoa_codigo_seq;
alter table "19 - orcamento".orc_pessoa add column if not exists codigo int;
with o as (
  select p.id, row_number() over (order by q.ordem, q.criado_em, p.y, p.x, p.id) n
  from "19 - orcamento".orc_pessoa p join "19 - orcamento".orc_quadro q on q.id = p.quadro_id
  where p.codigo is null)
update "19 - orcamento".orc_pessoa p set codigo = o.n + coalesce((select max(codigo) from "19 - orcamento".orc_pessoa), 0)
from o where o.id = p.id;
select setval('"19 - orcamento".orc_pessoa_codigo_seq', greatest(1, coalesce((select max(codigo) from "19 - orcamento".orc_pessoa), 0)), (select max(codigo) from "19 - orcamento".orc_pessoa) is not null);
alter table "19 - orcamento".orc_pessoa alter column codigo set default nextval('"19 - orcamento".orc_pessoa_codigo_seq');
alter sequence "19 - orcamento".orc_pessoa_codigo_seq owned by "19 - orcamento".orc_pessoa.codigo;
alter table "19 - orcamento".orc_pessoa alter column codigo set not null;
create unique index if not exists orc_pessoa_codigo_unico on "19 - orcamento".orc_pessoa(codigo);
