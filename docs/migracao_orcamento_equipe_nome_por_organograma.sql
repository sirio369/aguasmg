-- Orçamento: nome de equipe único POR ORGANOGRAMA (antes: em todos) — 24/11/2026, sw v454. Aplicado como orc_31_equipe_nome_por_organograma.
-- Motivo: colar um organograma em outro (ex.: Consolidado) leva as equipes com o mesmo nome; o Excel sai por organograma,
-- então o filtro por equipe não mistura. Dentro do mesmo organograma continua travado (colar 2× vira "(2)", "(3)" na tela).
-- Só troca índice e a checagem da função; sem mexer em dados.
drop index if exists "19 - orcamento".orc_equipe_nome_unico;
create unique index if not exists orc_equipe_nome_unico_quadro on "19 - orcamento".orc_equipe(quadro_id, "19 - orcamento".orc_nome_norm(nome));
-- app_orc_equipe_salvar(p jsonb): igual à v452, exceto a checagem de nome:
--   v_q := coalesce(quadro da equipe existente, p->>'quadro_id');
--   recusa se existir outra equipe com o mesmo orc_nome_norm(nome) e quadro_id = v_q:
--   'já existe uma equipe chamada "%" neste organograma — use outro nome'
-- app_orc_equipe_nomes() continua no banco, mas a tela não usa mais.
