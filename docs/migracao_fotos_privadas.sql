-- LGPD (diagnóstico 06/11/2026): documentos e imagens pessoais saem do bucket PÚBLICO `fotos-campo`.
-- Bucket público = qualquer um com o link abre o arquivo sem login (a policy do #244 só escondia da listagem).
-- Novo bucket PRIVADO `fotos-privadas` p/ as pastas com dado pessoal:
--   cnh/     foto/PDF da CNH (Frota)
--   pessoas/ legado da antiga Gestão de Pessoas
--   epi/     foto do colaborador com os EPIs, assinaturas de entrega e do termo de frota
--   seg/     APR/PT/PET: assinaturas e fotos
--   sst/     QSMS campo: assinaturas e fotos
-- O app passa a enviar essas pastas p/ cá e a exibir por URL assinada (1 h). Os caminhos gravados nas
-- tabelas NÃO mudam (continuam 'cnh/…', 'epi/…'): o bucket é escolhido pelo prefixo.
-- Os arquivos antigos são movidos pelo script scripts/storage/mover_fotos_privadas.ps1 (Storage API,
-- chave service_role digitada na hora) — rodar SÓ depois do front com sw v331 publicado.

insert into storage.buckets (id, name, public, file_size_limit)
values ('fotos-privadas', 'fotos-privadas', false, 10485760)
on conflict (id) do update set public = false;

-- Quem pode LER (= gerar URL assinada) um arquivo do bucket privado.
create or replace function public.fotos_priv_pode_ler(p_name text, p_owner text)
returns boolean language sql stable security definer set search_path = public as $$
  select case split_part(p_name, '/', 1)
    -- CNH: dono do upload, o próprio condutor, equipe de frota (frota_admin/funcao frotas) e admin
    when 'cnh' then
         p_owner = auth.uid()::text
      or auth.uid() = any("10 - Frotas".frota_responsaveis())
      or exists (select 1 from "10 - Frotas".frota_condutor c where c.id = auth.uid() and c.cnh_foto = p_name)
      or exists (select 1 from "10 - Frotas".frota_condutor_cnh_historico h where h.condutor_id = auth.uid() and h.cnh_foto = p_name)
    -- legado da Gestão de Pessoas: só admin
    when 'pessoas' then coalesce("9 - suprimentos".sup_funcao(auth.uid()), '') = 'admin'
    -- EPI / APR-PT-PET / QSMS: qualquer usuário logado (as telas que mostram já são gateadas no app)
    when 'epi' then true when 'seg' then true when 'sst' then true
    else false end
  or coalesce("9 - suprimentos".sup_funcao(auth.uid()), '') = 'admin';
$$;
revoke execute on function public.fotos_priv_pode_ler(text, text) from public, anon;
grant  execute on function public.fotos_priv_pode_ler(text, text) to authenticated;

create policy fotos_priv_select on storage.objects for select to authenticated
  using (bucket_id = 'fotos-privadas' and public.fotos_priv_pode_ler(name, owner_id));

create policy fotos_priv_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos-privadas' and split_part(name, '/', 1) in ('cnh','pessoas','epi','seg','sst'));

-- upsert de reenvio da fila offline (mesmo caminho) = update do próprio arquivo
create policy fotos_priv_update on storage.objects for update to authenticated
  using (bucket_id = 'fotos-privadas' and owner_id = auth.uid()::text)
  with check (bucket_id = 'fotos-privadas' and owner_id = auth.uid()::text);
