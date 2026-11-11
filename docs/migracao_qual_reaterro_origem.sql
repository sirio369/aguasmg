-- Ensaio de reaterro (Qualidade) — origem do pedido de projeto (2026-11-11)
-- A fila do pavimento já trazia as 2 fotos do registro de campo; o pedido de um bloco de obra dos Projetos chegava sem nada
-- da origem. Agora cada pedido de projeto traz 'origem' = lançamentos de Reaterro do bloco (data, valor, autor, fotos), lidos de
-- "13 - projetos_obra".intervencao_avanco pelo caminho do bloco ('<rotulo> › Reaterro…'; raiz da VCA = 'Reaterro…').
-- O front mostra as fotos e um botão que abre a intervenção (projeto_det) ou o ponto na Gestão de Pavimento.
create or replace function public.app_qual_reaterro_fila(p_consorcio text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not "8 - coleta_campo".pav_qualidade_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object('pav', public.app_pav_qual_listar(p_consorcio), 'proj', (
    select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'kind',r.kind,'gid',r.gid,'bloco',r.bloco,'rotulo',r.rotulo,
             'lbl',"13 - projetos_obra".proj_reat_lbl(r.kind, r.gid, r.rotulo),'tipo',v.tipo,'projeto',v.projeto,'cod',v.id,'consorcio',v.consorcio,
             'status_em',r.status_em,'pedido_em',r.pedido_em,'pedido_nome',r.pedido_nome,
             'lat',coalesce(r.lat, st_y(p.pt)),'lon',coalesce(r.lon, st_x(p.pt)),
             'hist',"13 - projetos_obra".proj_reat_hist(r.id),
             'origem',(select coalesce(jsonb_agg(jsonb_build_object('em',a.ts,'caminho',a.caminho,'valor',a.valor,'unidade',a.unidade,
                         'por',a.autor_nome,'obs',a.obs,'fotos',coalesce(to_jsonb(a.fotos),'[]'::jsonb)) order by a.ts desc), '[]'::jsonb)
                         from (select * from "13 - projetos_obra".intervencao_avanco a
                                where a.kind = r.kind and a.gid = r.gid
                                  and starts_with(lower(a.caminho), lower(case when coalesce(r.rotulo,'') = '' then '' else r.rotulo || ' › ' end) || 'reaterro')
                                order by a.ts desc limit 10) a)
           ) order by r.status_em), '[]'::jsonb)
      from "13 - projetos_obra".proj_reaterro r
      join "13 - projetos_obra".vw_iv v on v.kind = r.kind and v.gid = r.gid
      left join lateral (select st_transform(st_pointonsurface(g.geom), 4326) pt from (
          select geom from "7 - setorizacao".intervencoes_pontuais where r.kind = 'ponto' and gid = r.gid
          union all select geom from "7 - setorizacao".intervencoes_lineares where r.kind = 'linha' and gid = r.gid) g limit 1) p on true
     where r.status = 'aguardando' and (p_consorcio is null or v.consorcio = p_consorcio)));
end $function$;
revoke all on function public.app_qual_reaterro_fila(text) from public, anon;
grant execute on function public.app_qual_reaterro_fila(text) to authenticated;
