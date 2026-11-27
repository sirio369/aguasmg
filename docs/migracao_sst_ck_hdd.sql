-- Checklist de Segurança — Perfuração Direcional Horizontal (HDD/MND): 3º tipo de sst_checklist ('hdd'). 2026-11-27.
-- Mesma tabela/itens/RPC dos checklists POP-022 (reaterro e recomposição); só libera o tipo e nomeia nas views do BI.
-- Pode rodar mais de uma vez.
alter table "16 - qsms".sst_checklist drop constraint if exists sst_checklist_tipo_check;
alter table "16 - qsms".sst_checklist add constraint sst_checklist_tipo_check check (tipo = any (array['reaterro','recomposicao','hdd']));

-- app_sst_ck_registrar: aceita 'hdd' (resto igual à docs/migracao_sst_ck_os_opcional.sql)
do $m$
declare v text;
begin
  select pg_get_functiondef('public.app_sst_ck_registrar(uuid,jsonb,jsonb)'::regprocedure) into v;
  if position($q$not in ('reaterro','recomposicao')$q$ in v) > 0 then
    v := replace(v, $q$not in ('reaterro','recomposicao')$q$, $q$not in ('reaterro','recomposicao','hdd')$q$);
    execute v;
  end if;
end $m$;
revoke all on function public.app_sst_ck_registrar(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.app_sst_ck_registrar(uuid, jsonb, jsonb) to authenticated;

create or replace view "16 - qsms".bi_sst_checklist as
 SELECT id AS "ID", data AS "Data", consorcio AS "Consórcio",
    CASE tipo WHEN 'reaterro' THEN 'Reaterro' WHEN 'hdd' THEN 'HDD' ELSE 'Recomposição de pavimento' END AS "Checklist",
    os AS "OS", tipo_intervencao AS "Tipo de Intervenção", equipe AS "Equipe", tipo_pavimento AS "Tipo de Pavimento",
    usuario_nome AS "Fiscal", encarregado_nome AS "Encarregado",
    CASE resultado WHEN 'conforme' THEN 'Conforme' WHEN 'nao_conforme' THEN 'Não conforme' ELSE 'Pendente' END AS "Resultado",
    (SELECT count(*) FROM "16 - qsms".sst_checklist_item x WHERE x.checklist_id = c.id AND x.resultado = ANY (ARRAY['C','NC']))::integer AS "Itens Verificados",
    (SELECT count(*) FROM "16 - qsms".sst_checklist_item x WHERE x.checklist_id = c.id AND x.resultado = 'C')::integer AS "Conformes",
    (SELECT count(*) FROM "16 - qsms".sst_checklist_item x WHERE x.checklist_id = c.id AND x.resultado = 'NC')::integer AS "NCs",
    (SELECT count(*) FROM "16 - qsms".sst_checklist_item x WHERE x.checklist_id = c.id AND x.resultado = 'NA')::integer AS "N/A",
    endereco AS "Endereço", bairro AS "Bairro", municipio AS "Município", observacoes AS "Observações"
   FROM "16 - qsms".sst_checklist c
  WHERE anulado_em IS NULL;

create or replace view "16 - qsms".bi_sst_checklist_item as
 SELECT x.checklist_id AS "Checklist ID", c.data AS "Data", c.consorcio AS "Consórcio",
    CASE c.tipo WHEN 'reaterro' THEN 'Reaterro' WHEN 'hdd' THEN 'HDD' ELSE 'Recomposição de pavimento' END AS "Checklist",
    c.equipe AS "Equipe", x.ordem AS "Ordem", x.grupo AS "Grupo", x.item AS "Item", x.resultado AS "Resultado", x.obs AS "Observação"
   FROM "16 - qsms".sst_checklist_item x
     JOIN "16 - qsms".sst_checklist c ON c.id = x.checklist_id
  WHERE c.anulado_em IS NULL;
