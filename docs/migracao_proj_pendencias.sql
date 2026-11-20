-- Projetos › Obras › Pendências (2026-11-20)
-- Leitura: as etapas do pipeline (documentos, links, OS, aprovações — fases 1, 2, 3 e 5) de TODAS as intervenções,
-- numa chamada só, p/ a tela `projeto_pend`. Mesmo cálculo da intervenção aberta (proj_calc), só com os campos que a
-- tela usa. A execução (fase 4) vem da árvore de avanço que o app já carrega (app_proj_estados).
-- Sem escrita, sem mudança em tabela. Front tem plano B (app_proj_pipeline por intervenção) se esta função faltar.

CREATE OR REPLACE FUNCTION public.app_proj_pendencias()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('kind', c->>'kind', 'gid', (c->>'gid')::bigint,
             'itens', (select coalesce(jsonb_agg(jsonb_build_object(
                         'chave', x->'chave', 'fase', x->'fase', 'ordem', x->'ordem', 'ator', x->'ator',
                         'natureza', x->'natureza', 'nome', x->'nome', 'aprova', x->'aprova', 'ativo', x->'ativo',
                         'status', x->'status', 'feito', x->'feito', 'pend_legado', x->'pend_legado',
                         'acionavel', x->'acionavel', 'dias', x->'dias', 'faixa', x->'faixa',
                         'comentario', x->'comentario') order by (x->>'ordem')::int), '[]'::jsonb)
                       from jsonb_array_elements(c->'itens') x))
           order by c->>'kind', (c->>'gid')::bigint)
    from (select "13 - projetos_obra".proj_calc(kind, gid) c from "13 - projetos_obra".vw_iv) t
    where c is not null), '[]'::jsonb);
end
$function$;

REVOKE ALL ON FUNCTION public.app_proj_pendencias() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.app_proj_pendencias() TO authenticated;
