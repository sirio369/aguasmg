# Como contribuir — AcquaHub

Leia junto com [`CLAUDE.md`](./CLAUDE.md) (arquitetura, banco, módulos e regras técnicas).

## Regra nº 1: o `main` é produção

Um push no `main` **deploya automaticamente** no Cloudflare (Worker "campo" →
https://campo.aguas-mg.workers.dev). Não há build nem staging. Portanto:

- **Nunca** commite direto no `main`.
- Trabalhe em **branch** e abra **Pull Request**. O merge (após revisão) é o que vai pra produção.

## Fluxo de trabalho

```bash
git checkout main && git pull
git checkout -b minha-mudanca          # branch curta e descritiva
# ... edite public/index.html / public/sw.js ...
```

Antes de commitar:

1. **Suba a versão do cache** em `public/sw.js`: `const CACHE = 'coleta-vN'` → `N+1`.
   Sem isso, os usuários continuam vendo a versão antiga.
2. Se mexeu em dados/camadas do **Cadastro técnico**, incremente também `CAD_VER` (`'vN|'`) no
   `index.html`.
3. **Cheque a sintaxe** do bloco de script (não há build que pegue erros):
   ```bash
   cd public
   node -e "const fs=require('fs');const h=fs.readFileSync('index.html','utf8');const i=h.indexOf('<script type=\"module\">');const s=h.indexOf('>',i)+1;const e=h.indexOf('</script>',s);fs.writeFileSync('_chk.mjs',h.slice(s,e));"
   node --check _chk.mjs && echo OK && rm _chk.mjs
   node --check sw.js && echo SW_OK
   ```

Commit e PR:

```bash
git add -A
git commit -m "Descrição curta do que mudou"
git push origin minha-mudanca
# abra o PR no GitHub
```

Depois do merge, **confirme o deploy** (leva ~30–60 s):

```bash
curl -s https://campo.aguas-mg.workers.dev/sw.js | grep -o 'coleta-v[0-9]*'
```

### Se o deploy travar (plano B)

O build automático do Cloudflare às vezes trava/enfila (ex.: vários PRs em sequência). Nesse caso,
publique direto da sua máquina — mesmo comando, sem depender do runner deles:

```bash
git checkout main && git pull          # garanta o main atualizado
npx wrangler login                     # só na 1ª vez (abre o navegador → Allow)
npx wrangler deploy                    # sobe public/ para o Worker "campo" em segundos
```

Dica: desmarcar **"Builds for non-production branches"** (Worker → Settings → Builds) faz cada PR
gerar **1 build** (só no merge do `main`) em vez de 2, reduzindo a fila.

## PRs pequenos, sempre

O app é essencialmente **um `index.html` gigante**. Dois editando o mesmo arquivo geram conflito com
facilidade. Então: PRs pequenos e frequentes, e combinem quem mexe em qual bloco/módulo.

## Mudanças no banco (Supabase)

- A lógica vive em **RPCs `SECURITY DEFINER`** no schema `public`. Use **migração** para DDL.
- Teste a RPC com **rollback E2E** (ver `CLAUDE.md` §4) antes de expor.
- Conceda `execute` a `authenticated`; revogue de `anon`/`public`.
- **Nunca** coloque `service_role`, chave VAPID privada ou segredos no frontend.

## Checklist antes de pedir revisão

- [ ] Testado no app real (celular e/ou desktop), console limpo.
- [ ] `coleta-vN` incrementado (e `CAD_VER` se aplicável).
- [ ] `node --check` passou em `index.html` e `sw.js`.
- [ ] Sem segredos no código; RLS/grants corretos nas RPCs novas.
- [ ] Descrição do PR explica o quê e por quê.
