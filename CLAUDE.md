# AcquaHub — Base de conhecimento do app

> Documento de contexto para o Claude. Se você está abrindo este repositório no Claude Code,
> ele é lido automaticamente. Também pode ser colado no início de uma conversa para dar ao
> assistente a mesma base de conhecimento de quem já trabalha no app.
> **Não contém segredos** — chaves privadas/serviço ficam no Supabase, nunca no código.

## Comece aqui (onboarding em ~10 min)

> Se você é o Claude do novo colaborador: guie-o por estes passos na ordem, um de cada vez,
> confirmando cada um antes de seguir. Os detalhes técnicos estão nas seções numeradas abaixo.

1. **Acessos** — confirme que você recebeu e aceitou os convites: **GitHub** (repo
   `sirio369/aguasmg`, permissão de escrita) e **Supabase** (projeto `lwttadkctfznidzvmury`).
   Cloudflare normalmente **não** é necessário (o deploy é automático pelo push — ver §3).
2. **Pré-requisitos** (instale na sua máquina, no seu terminal):
   - **Git**, **Node.js LTS** (traz o `npx`).
   - **Claude Code CLI:** `npm install -g @anthropic-ai/claude-code`.
3. **Clone o repositório:**
   ```bash
   git clone https://github.com/sirio369/aguasmg.git
   cd aguasmg/pwa
   ```
4. **Conecte o Claude ao Supabase (MCP)** — siga a **§10**: gere seu token pessoal e crie o
   `.mcp.json` (já ignorado pelo git). Isso permite ao Claude aplicar migrações e rodar SQL.
5. **Abra no Claude Code:** rode `claude` dentro de `aguasmg/pwa`. Este `CLAUDE.md` é lido
   automaticamente — o assistente já parte com todo o contexto do app.
   - Valide o MCP pedindo: *"liste as tabelas do schema `9 - suprimentos`"*.
6. **Faça um PR de teste** (para exercitar o fluxo sem risco):
   ```bash
   git checkout -b teste-onboarding
   ```
   - Faça uma mudança mínima e visível (ex.: um comentário ou um texto de tela em `public/index.html`).
   - **Incremente** `const CACHE = 'coleta-vN'` em `public/sw.js` (ver §3).
   - **Cheque a sintaxe** (ver `CONTRIBUTING.md`): `node --check` no script e no `sw.js`.
   - Commit, `git push origin teste-onboarding`, abra o **Pull Request** no GitHub (o template
     aparece preenchido). Peça revisão ao Sander; **não** faça merge direto no `main`.
7. **Leia as Regras de ouro (§9)** antes de mexer pra valer. Resumo: nunca commitar no `main`;
   sempre subir `coleta-vN`; PRs pequenos; nada de segredos no frontend.

Pronto — a partir daqui, o resto do documento é referência (arquitetura, banco, módulos, push).

## 1. O que é

**AcquaHub** (nome interno "Coleta Águas MG") é um **PWA de campo** para o programa de redução de
perdas de água da COPASA na RMBH (Consórcios Águas Integradas — ZA1004/Contagem — e Eficiência
Hídrica — ZA0200/Betim). Usado por equipes de campo, encarregados e almoxarife, no celular
(offline-first) e no desktop.

Dois consórcios aparecem o tempo todo nos dados:
- **ZA1004** = Contagem
- **ZA0200** = Betim

## 2. Stack e arquitetura

- **Frontend:** HTML/CSS/JS **puro, sem build**. Praticamente **um único arquivo**:
  `public/index.html` (~250 KB) com um grande `<script type="module">`. Mapa via **Leaflet**;
  banco via **supabase-js** carregado do `esm.sh`.
- **Service Worker:** `public/sw.js` — cache offline + web push.
- **Backend:** **Supabase** (Postgres + PostGIS + Auth + Storage + Edge Functions). Toda a lógica
  vive em **RPCs** `SECURITY DEFINER` no schema `public`, chamadas por `sb.rpc('nome', {args})`.
- **Offline-first:** fila em **IndexedDB** + Service Worker; ações de campo são enfileiradas quando
  offline e sincronizadas depois.

### Layout do repositório
```
pwa/
  public/
    index.html        ← O APP (quase tudo está aqui)
    sw.js             ← service worker (cache + push)
    manifest.webmanifest, icon.png, logo.png
  wrangler.jsonc      ← config do Cloudflare Worker (Worker "campo", serve ./public)
  README.md, CLAUDE.md, CONTRIBUTING.md
```

## 3. Deploy (importante entender antes de mexer)

- **Push no `main` → deploy automático** no Cloudflare (Worker estático **"campo"**, serve `public/`).
  Não há etapa de build nem GitHub Action. **O que entra no `main` vai pra produção.**
- URL de produção: **https://campo.aguas-mg.workers.dev**
- **Toda mudança em `index.html`/`sw.js` exige subir a versão do cache** (senão o usuário continua
  vendo a versão antiga): em `public/sw.js`, incremente `const CACHE = 'coleta-vN'`.
  - Se a mudança altera dados de camadas do **Cadastro técnico**, incremente também `CAD_VER`
    (`'vN|'`) dentro do `index.html` para invalidar o cache do IndexedDB do cadastro.
- **Verificar o deploy** (a propagação leva ~30–60 s): faça o poll do sw publicado até bater a versão:
  ```bash
  curl -s https://campo.aguas-mg.workers.dev/sw.js | grep -o 'coleta-v[0-9]*'
  ```
- **Checar sintaxe antes de commitar** (o app não tem build que pegue erros): extraia o bloco
  `<script type="module">` para um `.mjs` e rode `node --check`.

### Deploy manual (plano B — quando o build do Cloudflare travar)
O build automático do Cloudflare (Workers Builds) roda `npx wrangler deploy` num runner deles e
**às vezes trava/enfila** (principalmente com vários PRs em sequência). Quando isso acontecer, publique
direto da sua máquina — é o **mesmo** comando, sem depender do runner:
```bash
cd <repo>/pwa
npx wrangler login     # só na 1ª vez nesta máquina (abre o navegador → Allow)
npx wrangler deploy    # sobe public/ para o Worker "campo" em segundos
```
Confirme com o poll do `sw.js` (o `coleta-vN` deve bater). Isso publica exatamente o que está no seu
working copy — então garanta que está no `main` atualizado (`git checkout main && git pull`) antes.
Dica: desmarcar **"Builds for non-production branches"** (Worker → Settings → Builds) reduz a fila
pela metade (1 build por PR, só no merge do `main`).

### Service Worker (`sw.js`)
- `index.html` é **network-first** (online sempre pega a versão nova; offline usa cache).
- Demais assets: cache-first.
- Handlers de **push** e **notificationclick** (deep-link para a tela certa) — ver §7.

## 4. Supabase

- **Project ref:** `lwttadkctfznidzvmury` · **URL:** `https://lwttadkctfznidzvmury.supabase.co`
- A **anon key** fica embutida no `index.html` (é pública por design; RLS protege tudo).
- **Nunca** exponha `service_role`, `vapid_private` ou segredos no frontend.
- Ferramenta de trabalho: **Supabase MCP** (o assistente aplica migrações e roda SQL direto).
  Cada colaborador configura o MCP com **seu próprio token** do Supabase (você tem acesso ao projeto).

### Padrões de banco
- **RLS ligada** e restritiva; o acesso do app se dá por **RPCs `SECURITY DEFINER`** no `public`
  (granted a `authenticated`, revogado de `anon`/`public`).
- Helpers de papel (schema `"9 - suprimentos"`): `sup_funcao(uuid)`, `sup_e_almox(uuid)`
  (= almoxarife/admin), `sup_pode_aprovar(uuid)` (= aprovador/admin).
- **Perfil/roles:** tabela `public.perfil` (id, email, nome, cargo, **funcao**, ...). Funções:
  `admin`, `campo`, `aprovador`, `almoxarife`. O app carrega o próprio perfil via RPC `app_me`
  (objeto `ME`: `is_admin`, `is_almoxarife`, `pode_aprovar`, `funcao`, `equipes`).
- **Geometria:** PostGIS, **SRID 31983** (UTM, metros). Distâncias em metros direto com `ST_Distance`
  (não converta pra `geography`: dá erro "Only lon/lat supported"). Para exibir no mapa, transforme
  para 4326.
- **Ao rodar SQL:** `execute_sql` do MCP retorna **apenas o resultado da última instrução**. Para
  checar várias coisas numa tacada, combine com `jsonb_build_object(...)`.
- **Teste E2E com rollback** (validar RPC sob um usuário sem gravar nada):
  ```sql
  do $$ begin
    perform set_config('request.jwt.claims',
      json_build_object('sub','<uuid>','role','authenticated')::text, true);
    -- chame as RPCs ...
    raise exception 'ROLLBACK_OK :: %', '<resumo>';
  end $$;
  ```

### Esquemas (cadastro técnico + operação)
| Schema | Conteúdo |
|---|---|
| `1 - suporte_geografico` | limites, apoio |
| `2 - infra_agua` | rede, nós de água (`nos_agua`), unidades operacionais, **`vrps`** |
| `3 - comercial` | ligações |
| `4 - redes_terceiros`, `5 - info_copasa`, `6 - analises`, `10 - Frotas` | apoio/cadastro |
| `8 - obras & servicos` | coleta de campo (pressão, loggers, pesquisa, captação, abertura de serviços) |
| `9 - suprimentos` | almoxarifado (insumos, EPI, equipamentos, notificações) |
| `public` | RPCs + `perfil`, `push_subscription`, `push_config` |

## 5. Convenções do frontend (`index.html`)

- **Um arquivo grande**; funções agrupadas por módulo, com comentários `// ---------- NOME ----------`.
- Telas: `const SCREENS=[...]`; navegação por `irPara('idDaTela')`; botões `data-go="tela"`.
- Helpers globais: `$` (querySelector), `toast(msg)`, `sb` (cliente supabase), `ME` (perfil),
  `gps` (última posição).
- **Envio de ações (online/offline):** `supEnviar(item, okMsg, after)` e a fila `enviarOuEnfileirar`
  gravam numa store IndexedDB e sincronizam. Ações que **precisam de resposta do servidor na hora**
  (ex.: gerar código, aceitar termo) são feitas **online** e avisam se offline.
- **Estilo:** usa variáveis CSS (`var(--acc)`, `var(--card)`, `var(--line)`, `var(--bad)`,
  `var(--ok-bg)`, `var(--warn-bg)`, ...). Reaproveite-as em vez de cores fixas.
- **Relatórios/PDF** (termo de equipamento, comprovantes, ficha de logger): overlay `#relatorio`
  com `REL_CSS`, impressão via `window.print()`.

## 6. Mapa de módulos (tela → funções/RPCs principais)

**Coleta de campo** (schema `8 - obras & servicos`):
- **Mapeamento de pressão** (`pressao`) — leitura de manômetro + foto + GPS. `app_registrar_pressao`.
- **Loggers temporários** (`loggers`/`logger_det`) — ciclo de vida (planejado→instalado→finalizado),
  5 fotos, relatório PDF; view `vw_loggers` (tem `consorcio`, geom real × planejada). Filtro por
  situação **e por consórcio** (ZA1004/ZA0200). RPCs `app_logger_*`.
- **Pesquisa** (`pesquisa`/`ocorrencia`/`produtividade`) — trechos retos + ocorrências + produtividade.
- **Entrevistadores** (`entrevistadores`) → **Captação de clientes** (`captacao`, view `vw_captacao`)
  e **Solicitação/Abertura de serviços** (`abertura_servicos`/`programacao_servicos`/`matriculas`).
- **Cadastro técnico** (`cadastro`) — camadas do PostGIS no mapa (rede, ligações, unidades, **VRPs**)
  com busca. RPCs `app_cadastro_geojson` (bbox → GeoJSON) e `app_cadastro_buscar`. Cache em IndexedDB
  versionado por `CAD_VER`.
- **Biblioteca** (`biblioteca`) — documentos de referência (bucket Storage `biblioteca`).

**Suprimentos** (`suprimentos`) — ver §8.

**Avisos/Notificações** (`notificacoes`) — inbox + badge + web push (§7).

## 7. Notificações e Web Push

- **Inbox + badge:** tabela `"9 - suprimentos".sup_notificacao` (destino_uuid, tipo, titulo, texto,
  link/act, lida). RPCs `app_notif_contador`/`app_notif_listar`/`app_notif_marcar_lidas`. No app:
  `ntfBadge`, `ntfInit`; o `link` é um "act" (ex.: `epi_segregar`) que abre a tela certa via
  `supGoAct(act)`.
- **Disparo:** triggers em `sup_notificacao` e nas tabelas de solicitação chamam
  `sup_notificar(destinos[], tipo, titulo, texto, link, exceto)`. Regra: notificações **pessoais**
  (ao solicitante/colaborador) **não** passam `exceto`; só as de **grupo** (aprovadores/almoxarifes)
  excluem o ator.
- **Web Push (SW v60+):**
  - Tabelas `public.push_subscription` (assinaturas) e `public.push_config` (chaves VAPID + segredo;
    privada, só `service_role` lê). RPCs `app_push_inscrever`/`app_push_desinscrever`.
  - Edge Function **`push-send`** (verify_jwt=false; auth por header `x-push-secret`) envia via
    `web-push`, apaga assinaturas mortas (404/410).
  - Trigger em `sup_notificacao` → `pg_net.http_post` → `push-send` (espelha o inbox: todo aviso vira push).
  - App: botão "Ativar avisos push" na tela **Avisos**; `pushAutoSync` no login; SW com `push` +
    `notificationclick` (deep-link). **iOS só funciona com o PWA instalado** (Adicionar à Tela de Início, 16.4+).
  - **Chave pública VAPID** está no `index.html` (const `VAPID_PUBLIC`). A **privada e o segredo**
    ficam só em `push_config` — não printe.

## 8. Suprimentos / Almoxarifado (schema `9 - suprimentos`)

Home dividida em três áreas: **Insumos**, **Equipamentos**, **EPI / Uniforme** (+ **Baixas/Conferência**
para o almoxarife). Papéis liberam ações via `ME`. `SUP_ACTS` mapeia act→função; `supBlocks*` monta os menus.

- **Insumos** — fluxo: solicitar → aprovar → **segregar** (almoxarife, existe/parcial/falta, gera
  código) → **retirar** (código). Tabelas `sup_solicitacao`/`_item`, `sup_material` (catálogo),
  `sup_saldo`/`sup_movimento` (kardex por equipe). RPCs `sup_solicitar`/`sup_aprovar`/`sup_segregar`/
  `sup_entregar`/`sup_consumir`. Catálogo via `sup_materiais_listar` (exclui categoria `EPI / EPC`).
- **Equipamentos** — rastreio por pessoa via **termo de responsabilidade**. Emitir → **aceitar dentro
  do próprio termo** (documento fica **vermelho até aceitar, verde depois**) → usar → devolver por
  código (com defeito → abre manutenção corretiva). Preventiva por tipo (dias). Tela "Equipamentos por
  responsável" mostra movimentações e **destaca quebra/defeito**. Tabelas `sup_equipamento`,
  `sup_equip_tipo`, `sup_termo`, `sup_manutencao`, `sup_equip_solicitacao`. RPCs `sup_equip_*`,
  `sup_termo_*`, `sup_equip_historico`.
- **EPI / Uniforme** — espelha o fluxo de insumo: solicitar → aprovar (sem código) → **Separar EPI**
  (almoxarife, gera código, avisa o colaborador) → **retirada** (código + foto do colaborador com os
  EPIs + assinatura). Status: solicitada/aprovada/**segregada**/entregue/rejeitada. Devolução/troca por
  código, com fotos. **Tamanho** por escala: `letra` (P/M/G/GG/EXG) ou `numero` (33–48, calçados/botas).
  Tabelas `sup_epi*`. RPCs `sup_epi_*` (`_solicitar`/`_aprovar`/`_segregar`/`_entregar`/`_fila_*`/`_baixa_*`).
- **Baixas / Conferência** — consolida entregas por período para conferência/baixa no SIENGE.

## 9. Regras de ouro ao alterar o app

1. **Nunca commite direto no `main`.** Trabalhe em branch, abra PR (o `main` deploya sozinho).
2. **Subiu mudança em `index.html`/`sw.js`? Incremente `coleta-vN` no `sw.js`** (e `CAD_VER` se mexeu
   no cadastro). Verifique o deploy pelo `sw.js` publicado.
3. **Rode `node --check`** no bloco de script antes de commitar (não há build que pegue erro de sintaxe).
4. **Backend:** prefira **migração** (`apply_migration`) para DDL; teste RPC com **rollback E2E** antes
   de expor; conceda `execute` a `authenticated` e revogue de `anon`/`public`.
5. **Segurança:** nada de `service_role`/`vapid_private`/segredos no frontend. Escolha a opção mais
   privada em qualquer coisa externa.
6. **Reaproveite** funções e variáveis CSS existentes; siga o estilo e a densidade de comentários do
   arquivo. É um arquivo enorme editado por poucas pessoas — **PRs pequenos** evitam conflito.

## 10. Conectar o Claude ao Supabase (MCP) — setup do colaborador

Para o Claude aplicar migrações e rodar SQL neste projeto (como quem já trabalha no app), configure o
**Supabase MCP**. Faça isso uma vez, na sua máquina.

**Pré-requisitos**
- **Node.js LTS** instalado (dá acesso ao `npx`).
- **Claude Code CLI** (`npm install -g @anthropic-ai/claude-code`).
- Acesso ao projeto Supabase (você já foi adicionado ao projeto `lwttadkctfznidzvmury`).

**1) Gere o SEU token pessoal** (não use o de outra pessoa):
Supabase Dashboard → canto superior direito (conta) → **Account → Access Tokens** →
**Generate new token** → copie o valor `sbp_...`. Guarde — ele só aparece uma vez.

**2) Configure o MCP** no arquivo `.mcp.json` (na raiz do projeto onde você roda o Claude Code, ou no
seu config de usuário do Claude). ⚠️ O fluxo OAuth novo do Supabase (`https://mcp.supabase.com/mcp`)
**está quebrado** ("Unrecognized client_id"); use o método por `npx` + token:

```jsonc
{
  "mcpServers": {
    "supabase": {
      "command": "npx",
      "args": [
        "-y",
        "@supabase/mcp-server-supabase@latest",
        "--project-ref=lwttadkctfznidzvmury"
        // opcional: "--read-only"  → só leitura, se você só quer inspecionar
      ],
      "env": { "SUPABASE_ACCESS_TOKEN": "sbp_COLE_SEU_TOKEN_AQUI" }
    }
  }
}
```

- `--project-ref` **trava o MCP neste projeto** (recomendado).
- Reinicie o Claude Code; peça algo como "liste as tabelas do schema `9 - suprimentos`" para validar.

**3) Segurança do token** (importante):
- O token fica em **texto puro** no `.mcp.json`. **Nunca** commite/compartilhe esse arquivo — este repo
  já ignora `.mcp.json` no `.gitignore`.
- Se vazar, **revogue** no mesmo lugar em que foi gerado (Account → Access Tokens) e gere outro.
- O token dá **acesso administrativo** ao projeto via API de gestão — trate como senha.

**Como o Claude trabalha no banco depois de conectado** (ver também §4):
- DDL → `apply_migration`; consultas/scripts → `execute_sql` (retorna só o resultado da **última**
  instrução → combine com `jsonb_build_object`).
- Valide RPC com **rollback E2E** antes de expor; conceda `execute` a `authenticated`, revogue de
  `anon`/`public`.
- **Edge Functions** (ex.: `push-send`) são publicadas via `deploy_edge_function`.
- Rode `get_advisors` de vez em quando (checa RLS/segurança).
- Há também um **MCP do QGIS** (opcional) que fala com o mesmo PostGIS, para trabalho de GIS/cadastro.
