-- Storage `fotos-campo`: CNH (cnh/) e cartas da antiga Gestão de Pessoas (pessoas/) deixam de ser listáveis
-- por qualquer usuário logado. 2026-10-28 (auditoria dos PRs de frota/pessoas).
-- Antes: policy fotos_campo_auth_select = (bucket_id='fotos-campo') → qualquer authenticated listava e baixava pela API
--   as 55 CNHs e as 4 cartas (ex.: sb.storage.from('fotos-campo').list('cnh')).
-- Agora: nessas pastas só quem subiu o arquivo (owner_id) e admin enxergam a linha; o resto do bucket não muda.
-- Não quebra upload: o upload(...,{upsert:true}) do app faz INSERT ... ON CONFLICT ... RETURNING, que exige SELECT na
--   linha NOVA — e ela é do próprio usuário (owner_id = auth.uid()). Testado com rollback em 2026-10-28.
-- Não muda a exibição: o app só lê foto pela URL pública (SBASE / getPublicUrl), que não passa por RLS; não há .list().
-- Limite: o bucket continua público — quem tiver o caminho exato (uuid) abre a imagem. O caminho só sai pelas RPCs de
--   frota (gestor/admin e o próprio condutor). Fechar de vez = bucket privado + URL assinada (muda o front).
-- Pasta nova com documento pessoal? Acrescente o prefixo na lista abaixo.
-- Rollback: alter policy fotos_campo_auth_select on storage.objects using (bucket_id = 'fotos-campo');
-- Idempotente (alter policy).

alter policy fotos_campo_auth_select on storage.objects
  using (bucket_id = 'fotos-campo'
         and (split_part(name,'/',1) not in ('cnh','pessoas')
              or owner_id = (select auth.uid())::text
              or coalesce("9 - suprimentos".sup_funcao((select auth.uid())),'') = 'admin'));
