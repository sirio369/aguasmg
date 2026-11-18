-- Projetos · Encerramento: mais de um PDF por documento (2026-11-18)
-- O 1º PDF continua em intervencao_documento (1 por etapa, "Anexar/Substituir"); os demais ficam em
-- intervencao_documento_extra. Só etapas de documento da fase 5 (Encerramento).
-- Anexar um PDF a mais = novo envio: a etapa volta a "enviado", a aprovação da Qualidade volta a "aguardando"
-- (aviso pelo trigger de evento). Remover um PDF a mais não muda o status. Nada muda depois de aprovado.

create table if not exists "13 - projetos_obra".intervencao_documento_extra (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  gid bigint not null,
  tipo text not null,            -- chave da etapa (= intervencao_documento.tipo)
  nome text,
  path text not null,
  folha text,
  enviado_em timestamptz not null default now(),
  enviado_por uuid
);
create index if not exists intervencao_documento_extra_iv on "13 - projetos_obra".intervencao_documento_extra (kind, gid, tipo);
alter table "13 - projetos_obra".intervencao_documento_extra enable row level security;   -- deny-all; acesso só por RPC
revoke all on "13 - projetos_obra".intervencao_documento_extra from anon, authenticated, public;

-- lista os PDFs a mais da intervenção
create or replace function public.app_proj_docs_extras_listar(p_kind text, p_gid bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'nome', nome, 'path', path, 'folha', folha,
                     'enviado_em', enviado_em) order by enviado_em)
    from "13 - projetos_obra".intervencao_documento_extra where kind = p_kind and gid = p_gid), '[]'::jsonb);
end $$;

-- anexa mais um PDF a uma etapa de documento do Encerramento (exige o 1º PDF já anexado)
create or replace function public.app_proj_doc_extra_add(p_kind text, p_gid bigint, p_chave text, p_nome text, p_path text, p_folha text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); v_tipo text; m record; it jsonb; d record; v_folha text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = p_kind and gid = p_gid;
  if v_tipo is null then raise exception 'intervenção não encontrada'; end if;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = p_chave;
  if not found or m.natureza <> 'doc' or m.fase <> 5 then raise exception 'só documentos do Encerramento aceitam mais de um PDF'; end if;
  if not "13 - projetos_obra".proj_ator_pode(v_id, m.ator) then
    raise exception 'sem permissão (%)', case m.ator when 'eng' then 'Projetos · Engenharia' when 'qual' then 'Qualidade' else 'responsáveis de obras' end;
  end if;
  select x into it from jsonb_array_elements("13 - projetos_obra".proj_calc(p_kind, p_gid)->'itens') x where x->>'chave' = p_chave;
  if not (it->>'ativo')::boolean then raise exception 'esta etapa está fora do escopo'; end if;
  if not (it->>'aberta')::boolean then raise exception 'esta etapa ainda não foi liberada'; end if;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa e join "13 - projetos_obra".etapa_modelo a
               on a.tipo = v_tipo and a.chave = e.chave and a.natureza = 'aprovacao' and a.aprova = p_chave
             where e.kind = p_kind and e.gid = p_gid and e.status = 'aprovado') then
    raise exception 'já aprovado pela Qualidade — não aceita mais arquivos'; end if;
  if nullif(btrim(p_path), '') is null then raise exception 'anexe o arquivo'; end if;
  select * into d from "13 - projetos_obra".intervencao_documento where kind = p_kind and gid = p_gid and tipo = p_chave;
  if not found then raise exception 'anexe o primeiro PDF antes'; end if;
  v_folha := case when m.pede_folha then p_folha end;
  if m.pede_folha and coalesce(v_folha, '') not in ('A0','A1','A2','A3','A4') then raise exception 'escolha o tamanho da folha (A0 a A4)'; end if;
  insert into "13 - projetos_obra".intervencao_documento_extra (kind, gid, tipo, nome, path, folha, enviado_por)
  values (p_kind, p_gid, p_chave, p_nome, p_path, v_folha, v_id);
  -- novo envio (mantém a folha do 1º PDF na etapa; o evento registra o arquivo novo)
  perform "13 - projetos_obra".proj_etapa_envio(p_kind, p_gid, v_tipo, p_chave, v_id, null, d.folha, p_path, p_nome);
  perform "13 - projetos_obra".proj_fase_sync(p_kind, p_gid);
  return jsonb_build_object('ok', true);
end $$;

-- remove um PDF a mais (quem pode anexar; não depois de aprovado). Devolve o path p/ apagar do Storage.
create or replace function public.app_proj_doc_extra_remover(p_id uuid)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid := auth.uid(); x record; v_tipo text; m record; v_nome text;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  select * into x from "13 - projetos_obra".intervencao_documento_extra where id = p_id;
  if not found then raise exception 'arquivo não encontrado'; end if;
  select tipo into v_tipo from "13 - projetos_obra".vw_iv where kind = x.kind and gid = x.gid;
  select * into m from "13 - projetos_obra".etapa_modelo where tipo = v_tipo and chave = x.tipo;
  if not found or not "13 - projetos_obra".proj_ator_pode(v_id, m.ator) then raise exception 'sem permissão'; end if;
  if exists (select 1 from "13 - projetos_obra".intervencao_etapa e join "13 - projetos_obra".etapa_modelo a
               on a.tipo = v_tipo and a.chave = e.chave and a.natureza = 'aprovacao' and a.aprova = x.tipo
             where e.kind = x.kind and e.gid = x.gid and e.status = 'aprovado') then
    raise exception 'documento aprovado pela Qualidade não pode ser alterado'; end if;
  delete from "13 - projetos_obra".intervencao_documento_extra where id = p_id;
  select coalesce(nome, email) into v_nome from public.perfil where id = v_id;
  insert into "13 - projetos_obra".intervencao_etapa_evento (kind, gid, chave, evento, arquivo, nome_arquivo, por_uuid, por_nome)
  values (x.kind, x.gid, x.tipo, 'removido', x.path, x.nome, v_id, v_nome);
  return x.path;
end $$;

revoke all on function public.app_proj_docs_extras_listar(text, bigint) from public, anon;
revoke all on function public.app_proj_doc_extra_add(text, bigint, text, text, text, text) from public, anon;
revoke all on function public.app_proj_doc_extra_remover(uuid) from public, anon;
grant execute on function public.app_proj_docs_extras_listar(text, bigint) to authenticated;
grant execute on function public.app_proj_doc_extra_add(text, bigint, text, text, text, text) to authenticated;
grant execute on function public.app_proj_doc_extra_remover(uuid) to authenticated;
