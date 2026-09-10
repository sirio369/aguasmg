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
  `admin`, `campo`, `aprovador`, `almoxarife`, `frotas`, `qsms`. O app carrega o próprio perfil via RPC
  `app_me` (objeto `ME`: `is_admin`, `is_almoxarife`, `pode_aprovar`, `funcao`, `equipes`).
- **Aprovação/notificação é única pro app inteiro** (não crie hierarquia paralela por módulo):
  `perfil.aprovador_uuid`/`aprovador2_uuid` (config. no ⚙️ Usuários — na home ou em Suprimentos) + `sup_aprovadores_de(uid)`
  + `sup_notificar(...)` disparado por **trigger** na tabela de negócio (nunca inline na RPC). Ver
  docs/MODULOS.md §0.9 e §6.4 (segundo módulo a reaproveitar isso, depois de Suprimentos).
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

**Regra de separação (2026-09):** schema define a **audiência**, não só o assunto.
- **Geo-facing** (o time de GIS conecta o QGIS aqui): `1`–`5`, `7`, `8`, e camadas via view.
- **App-only** (invisível ao GIS — sem `USAGE` pra papéis `gis_*`, acesso só via RPC `SECURITY DEFINER`):
  `9`, `10`, `11`, `12`. Tabela nova = decisão explícita no PR de qual lado ela cai.

| Schema | Conteúdo |
|---|---|
| `1 - suporte_geografico` | limites, apoio |
| `2 - infra_agua` | rede, nós de água (`nos_agua`), unidades operacionais, **`vrps`** |
| `3 - comercial` | ligações |
| `4 - redes_terceiros`, `5 - info_copasa` | apoio/cadastro |
| `7 - setorizacao` | **setorização**: `dmc_projetado`/`vrp_projetada` (WaterGEMS), `dmc` (dimensão versionada vigente), `dmc_ligacao`, `dmc_resumo` |
| `8 - coleta_campo` | **coleta de campo geo**: pressão (`mapeamento_pressao`), loggers (`instalacao_logger_calibracao`, `logger_pressao`), pesquisa (`pesquisa_trecho`), **ocorrências da pesquisa** (`ocorrencia`), estanqueidade (`ponto_estanqueidade`), visita a VRP (`vrp_visita`) + views |
| `9 - suprimentos` | almoxarifado (insumos, EPI, equipamentos, notificações) — *app-only* |
| `10 - Frotas` | veículos, condutores/CNH, treinamento QSMS, empréstimos, ocorrências — *app-only* |
| `11 - perdas_nrw` | analítico/config do módulo de Perdas: `parametros_nrw`, `linha_base`, `medicao_entrada`, `consumo_dmc` — *app-only* |
| `12 - retaguarda` | registros de campo que viram processo (Auxiliar de Programação): `captacao_cliente` (PII: CPF/fotos), `abertura_servico` + `vw_captacao`/`vw_abertura_servico` — *app-only* |
| `public` | RPCs + `perfil`, `push_subscription`, `push_config` |

> `6 - analises` foi **aposentado** na reorg de 2026-09 (`logger_pressao` → `8`; `dmc` → `7`; NRW → `11`).

**Papéis GIS (2026-09, consolidado 4 → 2):**
- **`gis_visualizacao`** = *leitura*: `SELECT` em todo o acervo geo (schemas `1`–`5`, `7`, `8`) + `INSERT/UPDATE/DELETE` em `public.layer_styles` (salvar estilo QGIS). Sem escrita em dado geo.
- **`gis_editor`** = *edição*: **herda `gis_visualizacao`** + escreve **só** onde se edita geometria à mão: `7 - setorizacao.dmc_projetado`, `7 - setorizacao.vrp_projetada`, `8 - coleta_campo.instalacao_logger_calibracao`. `dmc`/`dmc_resumo`/`dmc_ligacao` são **só leitura** (saída de recálculo).
- `gis_projetos` / `gis_obras_servicos`: **dropados** (2026-09) — absorvidos pelo modelo de 2 papéis.
- Nenhum papel `gis_*` tem `USAGE` em `9`/`10`/`11`/`12`. Auditoria (deve retornar 0 linhas, ignorando `pg_catalog`/`information_schema`/`net` herdados de `PUBLIC`):
  ```sql
  select r.rolname, n.nspname
  from pg_namespace n
  cross join (values ('gis_visualizacao'),('gis_editor')) r(rolname)
  where has_schema_privilege(r.rolname, n.oid, 'USAGE')
    and n.nspname not in ('1 - suporte_geografico','2 - infra_agua','3 - comercial','4 - redes_terceiros',
                          '5 - info_copasa','7 - setorizacao','8 - coleta_campo','public',
                          'pg_catalog','information_schema','net');
  ```

**Vitrine GIS — `0 - vitrine_gis` (2026-09):** schema de *apresentação* read-only pro QGIS. 13 views `vw_gis_*` sobre schemas `7`/`8` (+ join com `2` na `vw_gis_vrp`), só `geom` + colunas estáveis — sem PII, sem `foto_*`/`gps_*` cru, sem `respostas`/`fotos` jsonb, sem internos de cálculo. Views **definer** (rodam como `postgres`) → sobrevivem à revogação de USAGE em 7/8.
- `GRANT USAGE + SELECT` só pra `gis_visualizacao` (editor herda). Nenhuma view pode referenciar `9`–`12` (checar com `pg_depend`) — se um dado app-only precisar ir pro mapa, **move a tabela pro schema geo** primeiro (ex.: `ocorrencia` `12`→`8` em 2026-09) e só então cria a view curada.
- `vw_gis_dmc_projetada` = `dmc_projetado.geom` + KPIs firmes do `dmc_resumo` (1:1 por `dmc_id`); provisórios (`economias`, `consumo_medio_total`, contagens de VRP/OS) ficam de fora até estabilizar.
- **Trava aplicada (2026-09):** `gis_visualizacao` **não tem mais** USAGE em `7 - setorizacao` / `8 - coleta_campo` — o leitor puro enxerga só `1`–`5` + `0 - vitrine_gis`. O `gis_editor` mantém USAGE em 7/8 + `SELECT`+escrita nas 3 tabelas de edição de geometria (`dmc_projetado`, `vrp_projetada`, `instalacao_logger_calibracao`); o resto de 7/8 ele também lê pela vitrine.
- **Repontar o projeto QGIS** ("Águas MG"): camadas de leitura → `0 - vitrine_gis.vw_gis_*`; as 3 de escrita seguem na tabela crua (conectar como `gis_editor`).

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

> **Detalhe granular por módulo** (telas, estado, funções-chave, RPCs com args, tabelas/colunas e
> "cuidados") em **[`docs/MODULOS.md`](docs/MODULOS.md)**. **Leia a seção do módulo que você vai
> editar antes de mexer** — este mapa aqui é só o panorama.

**Coleta de campo** (schema `8 - coleta_campo`):
- **Mapeamento de pressão** (`pressao`) — leitura de manômetro + foto + GPS. `app_registrar_pressao`.
- **Loggers temporários** (`loggers`/`logger_det`) — ciclo: **pendente → instalado → dados pendentes
  (removido) → concluído** (a remoção sai direto de "instalado"; não há mais promoção automática após
  7 dias). Fotos: HD, leitura, numeração, cavalete, fachada + **foto extra** (opcional); relatório PDF.
  View `vw_loggers` (tem `consorcio`, geom real × planejada; `situacao_atual` é **derivada** das datas —
  não há coluna `situacao` na tabela base `instalacao_logger_calibracao`). Filtro por situação **e por
  consórcio** (ZA1004/ZA0200). No **lápis** (aprovador/admin) dá pra editar/anexar todas as fotos e 3
  campos de **OS COPASA** (instalação/remoção/social). RPCs `app_logger_*` (`_criar`/`_instalar` têm
  `p_foto_extra`; `_editar` recebe paths de foto + OS via `p_campos`).
- **Pesquisa** (`pesquisa`/`ocorrencia`/`produtividade`) — trechos retos + ocorrências + produtividade.
  As **ocorrências** (vazamentos) registradas aqui (`app_ocorrencia_registrar`, tabela
  `"8 - coleta_campo".ocorrencia` — dado geo, exposta no mapa via `0 - vitrine_gis.vw_gis_ocorrencia`)
  alimentam a fila de **Abertura de serviços** (ver Auxiliar de Programação), onde recebem nº de OS.
- **Entrevistadores** (`entrevistadores`) → **Captação de clientes** (`captacao`, view `vw_captacao`),
  **Solicitação de serviços** de campo (`abertura_servicos`) e, na subdivisão **🛟 Suporte**,
  **Roteiro de leitura** (`roteiro`) — mapa por percurso/trecho sobre `vw_roteiro_leitura`(_linha),
  com filtro de percurso/trecho/matrícula e export TXT (só aprovador). RPCs `app_roteiro_*`.
- **Auxiliar de Programação** (`auxiliar_programacao`, na Home › 🧰 Suporte; **só aprovador/admin**,
  botão liberado por `homeGate()` quando o `ME` carrega) — reúne a **retaguarda**:
  **Criação de matrículas** (`matriculas`, fila de captações `app_captacao_fila`/`_os`) e
  **Abertura de serviços** (`programacao_servicos`), que lança o nº da OS da COPASA para as
  **solicitações** (`app_abertura_fila`/`app_abertura_os`) **e** para as **ocorrências da pesquisa**
  (`app_ocorrencia_fila`/`app_ocorrencia_os`).
- **Cadastro técnico** (`cadastro`) — camadas do PostGIS no mapa (rede, ligações, unidades, **VRPs**)
  com busca + marcador "Você" (GPS, `cadOnGps`). RPCs `app_cadastro_geojson` (bbox → GeoJSON) e
  `app_cadastro_buscar`. Cache em IndexedDB versionado por `CAD_VER`.
- **Biblioteca** (`biblioteca`) — documentos de referência (bucket Storage `biblioteca`).

**Suprimentos** (`suprimentos`) — ver §8.

**Frota** (card único `frota` na home; telas internas `condutor`/`frotas`/`qsms`, schema `10 - Frotas`)
— o card abre um **hub estilo Suprimentos** (`frotaInit`/`frotaHome`/`frotaBlocks`) com 4 seções
gateadas: **👤 Colaborador**, **🖊️ Gestor**, **🏢 Equipe administrativa**, **🦺 QSMS**. `frotaOpen(id)`
é só roteador: seta `condTarget`/`frotasTarget` e faz `irPara('condutor'|'frotas'|'qsms')` — o render
de cada fluxo continua onde estava. Detalhe em `docs/MODULOS.md §6.0`. Fluxo: condutor se
auto-cadastra (CNH) → gestor aprova → **apto** (10 dias p/ treinamento) → QSMS agenda e dá baixa
(foto da lista de presença obrigatória) → **ativo**; alerta de CNH vencendo em 30 dias. Só pode ser
vinculado a veículo/equipe/empréstimo quem está `apto`/`ativo` (validado no backend; reeditar um
vínculo já existente não reaplica a checagem — "grandfathering"). **Frotas** (`funcao='frotas'`/admin)
cadastra veículos (tipo/combustível/motorização/centro de custo, consórcio obrigatório, aluguel com
histórico de reajuste, valor de devolução) e aprova ocorrências/manutenções (valor só visível a quem
aprova). Empréstimo de veículo entre condutores — durante o empréstimo, abastecimento/ocorrência/
lavagem somem de quem emprestou e aparecem pra quem recebeu; retomada é só solicitação (quem está com
o carro confirma a devolução). Manutenção tem fluxo próprio (orçamento → aprovação → conclusão,
tabela `frota_manutencao`, separada de ocorrência). Painel de acompanhamento (Frotas) com histórico
completo de movimentações/abastecimentos/lavagens/ocorrências/manutenções e custos agregados por
veículo — "tempo real" é só "atualizado ao abrir a tela", sem websocket. Aprovação/notificação
**reaproveita** o mecanismo de Suprimentos (não é hierarquia própria) — ver docs/MODULOS.md §6
(detalhe completo) e §0.9/§6.4 (o mecanismo em si).

**Avisos/Notificações** (`notificacoes`) — inbox + badge + web push (§7).

**Perdas / NRW** (`public/perdas.html` — **página separada**, não é tela `<main>`) — cockpit de
acompanhamento de perdas por DMC. Card `#cardPerdas` no hub, gated em `homeGate()` **só para o Sander**
(`ME.email`); opaco (`.mod soon`) + 🔒 para os demais. A página tem guarda própria pela sessão Supabase.
Dados ainda em snapshot estático (futuro: RPCs `app_nrw_*`). Detalhe em `docs/MODULOS.md §11`.

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

- **Configurações (admin)** — `supAbrirConfig(from)`, roda dentro de `<main id="suprimentos">`. Duas
  portas: ⚙️ **na home** (`#homeCfg`, `homeGate()` → `ME.is_admin`) abre **👤 Usuários** (acesso, cargo,
  aprovadores, consórcio) com **filtros** no topo (acesso / cargo / consórcio / 1º aprovador); ⚙️ **dentro
  de EPI / Uniforme** (`#supCfg`) abre **🦺 Cargos e cesta de EPI**. Detalhe em `docs/MODULOS.md §5.5`.

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
7. **Documentação junto com o código (obrigatório).** Toda mudança que altere comportamento, telas,
   fluxo, RPCs, tabelas/colunas ou regras de um módulo **deve atualizar, no MESMO PR**:
   [`docs/MODULOS.md`](docs/MODULOS.md) (a seção do módulo + os "cuidados") e, se o panorama mudou, o
   **mapa de módulos** (§6) e/ou estas regras. Criou tela nova? Documente-a e registre-a em `SCREENS`.
   Novo invariante/armadilha aprendida? Acrescente em `docs/MODULOS.md §0`. **PR que muda o app sem
   atualizar a doc não deve ser mergeado.** A doc é sempre o espelho do estado atual em produção.

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
