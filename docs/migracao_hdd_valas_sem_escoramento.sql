-- 2026-11-25 · HDD: tira o "Escoramento" de dentro de cada vala de perfuração (pedido do usuário).
-- As valas continuam (Escavação, Reaterro, Recomposição de pavimento). Só sai o Escoramento SEM avanço (p nulo ou 0).
-- Em 25/11: 57 intervenções, 118 escoramentos, 0 com avanço e 0 lançamentos no log → nenhum avanço perdido.
-- O % (proj_calc / fisc_proj_pct) é calculado pela árvore: onde o Escoramento estava ativo e em 0%, o % das valas sobe.
-- O app faz a mesma limpeza ao carregar (pjVala sem Escoramento + reconciliação), então app e banco ficam iguais.

-- 1) backup das linhas afetadas
create table if not exists "13 - projetos_obra"._bkp_proj_estado_20261125_escoramento as
select e.* from "13 - projetos_obra".intervencao_estado e
where exists (select 1 from jsonb_array_elements(e.arv) t, jsonb_array_elements(t->'f') g, jsonb_array_elements(g->'f') c
              where (t->>'c'='av_valas' or t->>'n' ~* '^valas de (entrada|perfura)') and c->>'n' ~* '^escoramento$');

-- 2) remove o Escoramento sem avanço das valas (mantém a ordem dos nós)
update "13 - projetos_obra".intervencao_estado e
set arv = (
  select jsonb_agg(
    case when (t->>'c'='av_valas' or t->>'n' ~* '^valas de (entrada|perfura)') and jsonb_typeof(t->'f')='array'
      then jsonb_set(t,'{f}',(
        select coalesce(jsonb_agg(
          case when jsonb_typeof(g->'f')='array'
            then jsonb_set(g,'{f}',coalesce((select jsonb_agg(c order by ci) from jsonb_array_elements(g->'f') with ordinality c(c,ci)
                                              where not (c->>'n' ~* '^escoramento$' and coalesce((c->>'p')::numeric,0)=0)),'[]'::jsonb))
            else g end order by gi),'[]'::jsonb)
        from jsonb_array_elements(t->'f') with ordinality g(g,gi)))
      else t end order by ti)
  from jsonb_array_elements(e.arv) with ordinality t(t,ti))
where exists (select 1 from jsonb_array_elements(e.arv) t, jsonb_array_elements(t->'f') g, jsonb_array_elements(g->'f') c
              where (t->>'c'='av_valas' or t->>'n' ~* '^valas de (entrada|perfura)') and c->>'n' ~* '^escoramento$'
                and coalesce((c->>'p')::numeric,0)=0);

-- 3) conferência: deve dar 0
select count(*) from "13 - projetos_obra".intervencao_estado e, jsonb_array_elements(e.arv) t, jsonb_array_elements(t->'f') g, jsonb_array_elements(g->'f') c
where (t->>'c'='av_valas' or t->>'n' ~* '^valas de (entrada|perfura)') and c->>'n' ~* '^escoramento$';
