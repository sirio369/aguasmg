-- Projetos · "Mapeamento de interferências" é exclusivo do HDD (pedido do usuário, 2026-11-03)
-- Tira a etapa e a aprovação dela (fase 1 / fase 2) do modelo de VCA, VRP, registro e macromedidor. Em 03/11 nenhuma
-- intervenção desses tipos tinha etapa, evento ou documento de mapeamento — nada é perdido. Com isso o Liberar
-- (proj_f1_falta) e a fase 2 desses tipos passam a pedir só o Projeto Executivo. O guard abaixo não apaga se já houver uso.
delete from "13 - projetos_obra".etapa_modelo m
 where m.chave in ('mapeamento','aprov_mapeamento') and m.tipo <> 'hdd'
   and not exists (select 1 from "13 - projetos_obra".intervencao_etapa e
                     join "13 - projetos_obra".vw_iv v on v.kind = e.kind and v.gid = e.gid
                    where v.tipo = m.tipo and e.chave = m.chave);
