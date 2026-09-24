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
| `8 - coleta_campo` | **coleta de campo geo**: pressão (`mapeamento_pressao`), loggers (`instalacao_logger_calibracao`, `logger_pressao`), pesquisa (`pesquisa_trecho`), **ocorrências da pesquisa** (`ocorrencia`), estanqueidade (`ponto_estanqueidade`), visita a VRP (`vrp_visita`), **programação de pesquisa** (`programacao_pesquisa`, `rede_pp_segmento`/`_fonte`, `pp_config` — app-only mesmo estando neste schema geo, sem policy pra `gis_*`) + views |
| `9 - suprimentos` | almoxarifado (insumos, EPI, equipamentos, notificações) — *app-only* |
| `10 - Frotas` | veículos, condutores/CNH, termo de responsabilidade, vínculos (self-service), lavagem, manutenção — *app-only* (QSMS/treinamento, Equipes, Ocorrência e empréstimo **removidos por completo** em 2026-09) |
| `11 - perdas_nrw` | analítico/config do módulo de Perdas: `parametros_nrw`, `linha_base`, `medicao_entrada`, `consumo_dmc` — *app-only* |
| `12 - retaguarda` | registros de campo que viram processo (Auxiliar de Programação): `captacao_cliente` (PII: CPF/fotos), `abertura_servico` + `vw_captacao`/`vw_abertura_servico` — *app-only* |
| `14 - pessoas` | Gestão de Pessoas: candidatos em contratação (PII: CPF/endereço), admissão, checklist de setup do novo funcionário — *app-only* (`13 - projetos_obra` está reservado no roteiro do módulo Projetos, §8 do MODULOS.md, ainda não criado) |
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

**Vitrine GIS — `0 - vitrine_gis` (2026-09):** schema de *apresentação* read-only pro QGIS. 14 views `vw_gis_*` (inclui `vw_gis_cadastro_comercial` sobre `3 - comercial`, abaixo) sobre schemas `7`/`8` (+ join com `2` na `vw_gis_vrp`), só `geom` + colunas estáveis — sem PII, sem `foto_*`/`gps_*` cru, sem `respostas`/`fotos` jsonb, sem internos de cálculo. Views **definer** (rodam como `postgres`) → sobrevivem à revogação de USAGE em 7/8.
- `GRANT USAGE + SELECT` só pra `gis_visualizacao` (editor herda). Nenhuma view pode referenciar `9`–`12` (checar com `pg_depend`) — se um dado app-only precisar ir pro mapa, **move a tabela pro schema geo** primeiro (ex.: `ocorrencia` `12`→`8` em 2026-09) e só então cria a view curada.
- `vw_gis_dmc_projetada` = `dmc_projetado.geom` + KPIs firmes do `dmc_resumo` (1:1 por `dmc_id`); provisórios (`economias`, `consumo_medio_total`, contagens de VRP/OS) ficam de fora até estabilizar.
- **`vw_gis_cadastro_comercial` (2026-09-17):** cadastro comercial concentrado por **matrícula**, 1 linha por ligação (134 k) sobre `"3 - comercial".ligacoes` (que mistura cadastro + roteiro de leitura E-341 + perdas). Resolve, via **subconsulta escalar** (mantém 1:1, sem fan-out), o **nome da rua** (`"1 - suporte_geografico".logradouros` por `consorcio`+`cd_logradouro`) e o **bairro** (`bairros` por `cd_localidade`||`lpad(cd_bairro,6)`, com fallback `'Bairro <cd>'`); monta `endereco` (rua+número+complemento), `roteiro_leitura` (`setor-rota-face-sequencia`) e `consorcio_nome`. Traz o **setor de leitura** cru (`setor`) **e** o **`setor_efetivo`** (2026-09-17): as 76 avulsas (`setor='00' and rota='00'`, flag `avulsa`) herdam o setor do ponto de leitura real mais próximo (mesma ancoragem da `vw_roteiro_leitura`, mas inline — a subconsulta nearest-neighbor só roda p/ as avulsas, sem o windowing da view de roteiro). Sem PII (`ligacoes` não tem nome de cliente/CPF). **Cobertura:** bairro ~95%; **rua 99,99% em Contagem (ZA1004) e 0% em Betim (ZA0200)** — a `logradouros` só tem Contagem carregada (Betim = 0 logradouros; falta importar a base, não é erro de join). `geom` nativo 31983.
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
  `.mod`/`.grid` (cards de módulo) são **globais**, reaproveitados em vários hubs (home, Frota,
  Almoxarifado...) — se só uma tela precisa de ajuste de tamanho, use um override escopado
  (`#idDaTela .mod{...}`), como em `#home` (2026-09, botões menores pra caber sem rolar).
- **Relatórios/PDF** (termo de equipamento, comprovantes, ficha de logger): overlay `#relatorio`
  com `REL_CSS`, impressão via `window.print()`.
- **Mapas (Leaflet):** todo mapa novo deve chamar `mapAddCamadaBase(map,tileOpts,ctlPos)` em vez de
  criar seu próprio `L.tileLayer(...)` — é o que dá o botão pequeno de alternar rua/satélite (Esri
  World Imagery, grátis) já usado nos 9 mapas do app (2026-09). Detalhe em `docs/MODULOS.md` §1.

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
  **Multiplicador de pressão** (2026-09, só no logger concluído, antes do card "Mínima"): fator
  (padrão 1, editável só por quem já vê o lápis) aplicado **junto com** a conversão kPa→mca — nunca
  no kPa cru. Coluna `multiplicador_pressao`, RPC `app_logger_set_multiplicador`; entra dentro de
  `logger_pressao_stats` e da view `vw_logger_pressao`, então cards, gráfico, CSV e qualquer BI que
  leia a view saem todos já corrigidos, sem passo extra — **não aparece no PDF** (removido 2026-09,
  é detalhe operacional do app/CSV). **CSV (2026-09)** mostra as 4 etapas do cálculo por linha:
  `Pressao_Inicial + Unidade_Inicial → Multiplicador → Pressao_Ajustada → Pressao_Final + Unidade_Final
  → Converteu_MCA` — **colunas sem unidade no nome, unidade só na pressão em coluna própria (2026-09-16)**;
  `Unidade_Inicial` é dinâmica (`kPa` no "Sim", `mca` no "Não"), `Unidade_Final` sempre `mca`. A view
  `vw_logger_pressao` foi recriada (drop+create) com esses nomes (`pressao_inicial`/`pressao_ajustada`/
  `pressao_final`/`unidade_*`/`converteu_mca`); a vitrine `vw_gis_logger_pressao` **também** foi renomeada
  igual (saíram `pressao_kpa`/`pressao_mca` — **repontar a camada no QGIS**). Detalhe em `docs/MODULOS.md §2.2`.
  **Seletor "Necessário conversão para MCA?" (2026-09-16):** na tela de conclusão + no logger concluído,
  segmento Sim/Não (`instalacao_logger_calibracao.converter_mca`, default true, RPC
  `app_logger_set_converter_mca`) muda só o divisor — `mca = kpa*mult/DIV`, `DIV=9,80665` (Sim) ou `1`
  (Não = dados já em MCA, só aplica o multiplicador). Espelhado em `logger_pressao_stats`/`vw_logger_pressao`.
  **Card "Modelo (previsto)"** (2026-09): logo acima do grid Mínima/Média/Mediana/Máxima, com
  `p.pressao_modelo` (já existia, sem RPC nova) — comparação rápida modelo × medido, no logger
  concluído e no preview de finalização. **No PDF mora no tópico 5 · Pressão** (saiu do tópico
  1 · Localização, onde ficava sem nada pra comparar do lado).
- **Pesquisa** (`pesquisa`/`ocorrencia`/`produtividade`) — trechos retos + ocorrências + produtividade.
  As **ocorrências** (vazamentos) registradas aqui (`app_ocorrencia_registrar`, tabela
  `"8 - coleta_campo".ocorrencia` — dado geo, exposta no mapa via `0 - vitrine_gis.vw_gis_ocorrencia`)
  alimentam a fila de **Abertura de serviços** (ver Auxiliar de Programação), onde recebem nº de OS.
- **Programação de pesquisa de vazamento** (`programacao_pesquisa`, dentro de Auxiliar de Programação;
  só aprovador/admin) — o programador desenha polígonos no mapa (`app_pp_rede_no_poligono`) e vincula
  as redes selecionadas a um colaborador (`app_pp_atribuir`/`app_pp_desatribuir`, tabela
  `"8 - coleta_campo".programacao_pesquisa`). O geofonista vê sua programação na tela **Pesquisa**
  (camada roxa, `app_pp_minhas`) e ela some conforme ele registra trechos reais; **Produtividade** cruza
  cadastro-programado × cadastro-executado × reporte de campo × **histórico de execuções** (`app_pp_mapa`
  — a 4ª camada, 2026-09, é um log permanente/insert-only em `pp_execucao`, independente do ciclo de
  atribuição ao vivo, que pode ser resetado/reprogramado à vontade sem perder o registro histórico de
  quando cada trecho foi pesquisado). **Redesenho 2026-09 (Fases 1-4, ver docs/MODULOS.md §4.3.7-4.3.8):**
  o TR exige **5 passadas** de toda a rede → conceito de "passada" (`pp_execucao.n_passada`), `pp_recompute`
  só conta traço posterior à programação, e o módulo foi separado por público: geofonista tem Pesquisa +
  "Minha produtividade" pessoal simplificada (`app_pesquisa_minha`, `auth.uid()`); time interno tem, no
  Auxiliar de Programação, **Programar** (rede colorida por nº de passadas 0×..5+×) + **Acompanhamento**
  (tela `pp_acomp`: KPIs com 2 km + vaz/km por km de rede, progresso das 5 passadas, mapa heatmap de
  passadas + ocorrências/reporte ativáveis, resumo por colaborador). O cruzamento roda em
  **pedaços de rede** (`"8 - coleta_campo".rede_pp_segmento`, ≤ `pp_config.seg_max_len_m`, **não** a rede
  cadastral inteira) — buffer (`pp_config.tol_m`) + alinhamento de azimute (`max_ang_deg`) + % de
  cobertura (`cov_pct`, ou `min_len_m`+herança de vizinho pra cotos curtos). Detalhe completo, incl. a
  segmentação resiliente a reimportação da base de rede, em `docs/MODULOS.md §4.3`.
- **Entrevistadores** (`entrevistadores`) → **Captação de clientes** (`captacao`, view `vw_captacao`),
  **Solicitação de serviços** de campo (`abertura_servicos`) e, na subdivisão **🛟 Suporte**,
  **Roteiro de leitura** (`roteiro`) — mapa por percurso/trecho sobre `vw_roteiro_leitura`(_linha),
  com filtro de percurso/trecho/matrícula e export TXT (só aprovador). RPCs `app_roteiro_*`.
- **Auxiliar de Programação** (`auxiliar_programacao`, na Home › 🧰 Suporte; **só aprovador/admin**,
  botão liberado por `homeGate()` quando o `ME` carrega) — reúne a **retaguarda**:
  **Criação de matrículas** (`matriculas`, fila de captações `app_captacao_fila`/`_os`) e
  **Abertura de serviços** (`programacao_servicos`), que lança o nº da OS da COPASA para as
  **solicitações** (`app_abertura_fila`/`app_abertura_os`) **e** para as **ocorrências da pesquisa**
  (`app_ocorrencia_fila`/`app_ocorrencia_os`); **Programação de pesquisa** (programar+atribuir trechos) e
  **Acompanhamento da pesquisa** (`pp_acomp`, dashboard de resultados do time interno — ver §4.3.8).
- **Cadastro técnico** (`cadastro`) — camadas do PostGIS no mapa (rede, ligações, unidades, **VRPs**)
  com busca + marcador "Você" (GPS, `cadOnGps`). RPCs `app_cadastro_geojson` (bbox → GeoJSON) e
  `app_cadastro_buscar`. Cache em IndexedDB versionado por `CAD_VER`.
- **Biblioteca** (`biblioteca`) — documentos de referência (bucket Storage `biblioteca`).

**Suprimentos** (`suprimentos`) — ver §8.

**Frota** (card único `frota` na home; telas internas `condutor`/`frotas` — schema `10 - Frotas`) —
o card abre um **hub estilo Suprimentos** (`frotaInit`/`frotaHome`/`frotaBlocks`) com 3 seções
gateadas: **👤 Colaborador**, **🖊️ Gestor**, **🏢 Equipe administrativa** (esta — incl. o **Relatório** —
liberada **só por admin + engrenagem** `frota_admin`; o cargo `funcao='frotas'` não é usado e saiu dos
gates, 2026-09-16). `frotaOpen(id)` é só
roteador: seta `condTarget`/`frotasTarget` e faz `irPara('condutor'|'frotas')`. Detalhe em
`docs/MODULOS.md §6.0`. QSMS/treinamento, Equipes, Ocorrência genérica e aluguel-com-histórico foram
**removidos por completo** numa rodada anterior; **nesta rodada (2026-09, 3ª) o empréstimo também
foi removido** — não é mais um mecanismo próprio, "emprestar" é só desvincular + a outra pessoa
vincular (ver abaixo). Fluxo atual: o **gestor de frota cadastra a CNH** do colaborador (tela Frotas
› Condutores, lista *todos* os colaboradores + busca/filtro + tick "isento" —
`app_frota_usuarios_completo`/`app_frota_condutor_cadastrar`/`app_frota_isentar`) → colaborador
**assina eletronicamente o termo de responsabilidade de condução** (PDF via overlay `#relatorio`,
assinatura em canvas igual EPI — `frotaTermoVer`/`app_frota_termo_assinar`) → **ativo** →
**colaborador se vincula sozinho a um veículo disponível** (tela **Veículos**, self-service —
`app_frota_meu_veiculo`/`app_frota_veiculos_disponiveis`/`app_frota_veiculo_vincular_me`/
`_desvincular_me`; Frotas mantém uma versão admin das mesmas RPCs, sem sufixo `_me`, só pra exceção).
**Um veículo só pode ter um vínculo aberto por vez, e uma pessoa só um veículo** — 2 índices únicos
parciais em `frota_veiculo_vinculo` garantem isso no banco; vincular/desvincular também faz o veículo
oscilar `status` entre `disponivel`/`em_uso` automaticamente. **Veículo, radicalmente simplificado:**
`app_frota_veiculo_salvar` (18 params, **admin-only**: `app_frota_veiculos_listar` também virou
admin-only nesta rodada) cadastra só identificação/combustível/motorização + **`tipo`** (lista
fechada de 9 categorias reais de obra) + **`centro_custo`** (`select` de 16 pares código-Nível-4/
descrição-Nível-3, `CENTROS_CUSTO_FROTA` — subconjunto curado pelo usuário 2026-09-15) + `consorcio`
(obrigatório; dropdown mostra os **nomes** dos consórcios — "Águas Integradas"=ZA1004,
"Eficiência Hídrica"=ZA0200 — valor gravado continua o código ZA) + `contrato_numero` (vincula a um contrato de locação
já existente — sem aluguel próprio). Tela de Frotas ganhou filtro (tipo/condutor) no topo da lista e
um "Ver detalhes" por veículo que abre Editar/Vínculo(admin)/Histórico/Relatório/Devolver numa página
só, em vez de 5 botões no card. **Colaborador**, no seu módulo: CNH (só dados de CNH, não lista mais
veículo nenhum), **Veículos** (self-service acima), **checklist diário** (layout em cartão, lembrete
automático 7:30 da manhã pra quem tem vínculo ativo + CNH ativa, `pg_cron` +
`frota_checklist_lembrete_diario`), abastecimento (combustível agora é só Etanol/Diesel/Arla, sem
campo "posto"), **Manutenção** e **Lavagem** — cada uma é uma tela de **histórico + ação**, não só
um formulário avulso (**renomeadas na 5ª rodada**, eram "Registrar problema (manutenção)"/"Solicitar
lavagem", iam direto pro formulário sem mostrar nada do que já existia). Estes 4 últimos ficam
**desabilitados no hub** enquanto o colaborador não tiver veículo vinculado. Checklist agora começa
com os itens **desmarcados por padrão** (5ª rodada — antes vinham todos pré-marcados, então "tudo OK"
era o estado inicial mesmo sem checar nada). **Lavagem** tem ciclo próprio: colaborador solicita
(bloqueado se já houver uma pendente) → Frotas agenda (data/horário/local, notifica) → colaborador
confirma execução (`frota_lavagem`, status `solicitada→agendada→realizada`) — toda a lista fica na
tela de Lavagem, não mais embutida em "Minha CNH" (removida de lá na 5ª rodada). **Manutenção**
também: colaborador solicita (sem valor) → gestor aprova/reprova → Frotas agenda **só a data** (sem
custo — 5ª rodada, custo saiu do agendamento) → **o próprio colaborador dá baixa** (novo — antes não
existia jeito nenhum de concluir fora do papel frotas/admin) quando busca o veículo no mecânico,
informando aí o **custo final** (`app_frota_manutencao_concluir`, permissão ampliada pra aceitar
quem reportou, além de frotas/admin; Frotas mantém um atalho de reforço em Relatório › Manutenções).
Agendar/concluir também fazem `frota_veiculo.status` oscilar por `manutencao` (rótulo que já
existia, mas nenhuma RPC escrevia até agora) e voltar a `em_uso`/`disponivel` ao concluir. **Histórico**
(por veículo ou por colaborador, com filtro de período) junta vínculos/checklists/manutenções (+
empréstimos históricos, se houver) numa timeline só — é a tela de investigação de sinistro; é um item
**dentro de** Relatório (abaixo). **Relatório** ("Painel e custos" antigo, na categoria **Gestor**)
tem 4 submódulos com filtro de veículo/colaborador/data (abastecimentos/lavagens/manutenções/
histórico) + custos por veículo sem filtro (soma manutenção **só `status='concluido'`** agora, não
mais `agendado` também — nunca tinha valor real nesse estágio). Aprovação/notificação **reaproveita**
o mecanismo de Suprimentos (não é hierarquia própria) — ver docs/MODULOS.md §6 (detalhe completo) e
§0.9/§6.4 (o mecanismo em si). **Todo campo "e-mail do colaborador" virou dropdown de nome**
(Vincular admin, Histórico, Relatório) e **as mensagens de notificação/erro do módulo tiveram a
acentuação corrigida**. **Navegação (5ª rodada):** cada subtela mostra só **um** botão de voltar — a
barra fixa do topo (`#condBar`/`#frotasBar`) some fora da tela-raiz de cada módulo, já que toda
subtela sempre teve seu próprio "‹ Voltar" contextual (os dois apareciam juntos antes). A tela
**Veículos** perdeu 3 seções-atalho (Condutores/Lavagens a agendar/Manutenções a agendar) que
duplicavam botões já existentes no hub. **Cuidado de bastidor (5ª rodada):** `CREATE OR REPLACE
FUNCTION` que só acrescenta parâmetro cria um **overload novo**, não substitui o original — a regra
(§0.6) já dizia pra usar `drop function`+`create` nesse caso, mas foi esquecida 2x; achados e
limpos overloads órfãos em 4 RPCs (detalhe em docs/MODULOS.md §6 "Cuidados"). **Revisão de UI/QA
(6ª rodada, 2026-09):** rótulos amigáveis centralizados (`labelOf`/`statusBadge`, corrige Histórico e
Relatório de Manutenções que mostravam valor cru do banco) · `.relBadge` dos relatórios em PDF
ganhou `color` padrão (estava branco-em-branco no Relatório do Veículo, VRP e termo assinado) ·
`prompt()`/`confirm()` nativos viraram tela própria em Reprovar manutenção, Devolver à locadora e
"Marcar como concluída" do admin (não dava pra automatizar em teste de navegador) · checklist e
abastecimento agora recusam com o veículo em `manutencao` (RPC + botão desabilitado no hub) · novo
`qa/smoke_test_frota.sql` (6 blocos com rollback garantido, cobre overloads/grants/vínculo/
manutenção/lavagem/o gate novo) — roda contra produção porque criar branch de teste no Supabase
exige uma confirmação de custo (`confirm_cost`) fora do alcance das ferramentas desta sessão.
**Correção de navegação (7ª rodada, 2026-09):** esconder a barra fixa na 5ª rodada expôs 9 botões
"‹ Voltar" hardcoded pra `condSub`/`frotasSub='home'` em subtelas abertas **direto do hub**
(Checklist, Veículos, Abastecimento, Manutenção, Lavagem, Condutores, Lavagens/Manutenções a
agendar) — corrigidos pra `irPara('frota')`. "Registrar problema" (2 pontos de entrada: Checklist e
Manutenção) ganhou variável de contexto `condOcorrenciaBackTo`, mesmo padrão de `frHistBackTo`.
Detalhe em `docs/MODULOS.md §6` "Cuidados". **Regra pra telas novas:** "‹ Voltar" de subtela aberta
direto do hub deve ser `irPara('frota')`, nunca `='home'`.

**Gestão de Pessoas** (`pessoas`, schema `14 - pessoas`) — Fase 1: fluxo de candidato em
contratação até a ativação, com aprovação de vaga restrita a uma lista fechada de gestores por
área (`"14 - pessoas".area_aprovador`, ~18 áreas → 6 pessoas, mantida por SQL direto). RH cadastra
o candidato escolhendo o gestor da área na lista fechada (`app_pessoas_candidato_cadastrar`,
`p_gestor_uuid` validado contra `area_aprovador`) → **só esse gestor mapeado** (ou `funcao='admin'`
como override) aprova/reprova **e** confirma área/empresa/projeto numa única RPC
(`app_pessoas_candidato_aprovar`, gate `candidato.gestor_uuid=auth.uid() or funcao='admin'`) — área
não é mais texto livre nem escolha manual pra quem cobre 1 área só (5 dos 6 gestores):
`app_pessoas_minhas_areas()` devolve as áreas do próprio chamador, o frontend auto-preenche quando
é 1 linha só e só mostra `<select>` pra quem cobre várias (Raulmar); `custo_direto_indireto`
**deixou de ser escolhido** (2026-09-24) — a RPC deriva sozinha: `projeto='Ambos'`→`Indireto`,
projeto específico→`Direto` → RH gera a carta proposta e depois anexa o PDF assinado fora do sistema
(`app_pessoas_carta_gerar`/`app_pessoas_carta_anexar`/`app_pessoas_candidato_marcar_assinado`) → RH
ativa no primeiro dia, vinculando a um `perfil` já existente (dropdown restrito a quem ainda não
tem `codigo_area` preenchido — `app_pessoas_usuarios_listar(p_apenas_ativos,p_somente_novos)`, o
módulo **não cria conta nova**) e gravando CPF/matrícula/admissão/tamanhos de uniforme
(`app_pessoas_candidato_ativar` —
também atualiza `public.perfil`, fonte única de verdade dessas colunas pro resto do app; um
`perfil` só liga a um `candidato` por vez, índice único parcial). Dados confidenciais do candidato
(CPF/endereço/formação/salário/motivo de reprovação) só aparecem pro gestor mapeado da vaga +
RH/admin, nunca pro par genérico `aprovador_uuid`/`aprovador2_uuid` de `perfil` — esse par só entra
depois que o colaborador já está `ativo`, e só vê campos simples (nome/área/empresa/admissão) via
`app_pessoas_meus_colaboradores`. Notificação/trigger segue o invariante §0.9: trigger
`"14 - pessoas".trg_candidato()` (nunca chamado inline), cobrindo INSERT (avisa só o gestor
mapeado) e as transições de UPDATE pra `proposta_pendente` (avisa RH) e `ativo` (avisa o gestor **e**
o aprovador1/2 do `perfil` ativado, "novo colaborador"). RH também **desliga** colaboradores pela
tela Colaboradores (`app_pessoas_colaborador_desligar` — zera `perfil.ativo`, grava `demissao` +
histórico em `"14 - pessoas".desligamento`) — a gestão de pessoas do dia a dia (admissão e
desligamento) passa a ser sempre por este módulo, não mais só por edição direta de planilha/banco.
Acesso de RH é concedido pela engrenagem ⚙️ do próprio hub (admin-only), igual Frotas. RH configura
os valores de referência dos benefícios (`"14 - pessoas".beneficio_premissa`, tela "Premissas de
benefícios") e marca sim/não por candidato (substituiu o texto livre `beneficios`) — a RPC soma o
custo estimado só pra visão interna do RH, a carta em si mantém texto fixo por benefício, sem
imprimir valores. Painel de headcount/orçamento por área fica para uma Fase 2. Detalhe em
`docs/MODULOS.md §12`.

**Avisos/Notificações** (`notificacoes`) — inbox + badge + web push (§7).

**Perdas / NRW** (`public/perdas.html` — **página separada**, não é tela `<main>`) — cockpit de
acompanhamento de perdas por DMC. Card `#cardPerdas` na categoria **🚧 Em desenvolvimento**, gated em
`homeGate()` por **`ME.dev_acesso`** (controle de acesso por engrenagem — ver abaixo); opaco (`.mod soon`) + 🔒
para quem não tem. A página tem guarda própria pela sessão Supabase.
Dados ainda em snapshot estático (futuro: RPCs `app_nrw_*`). Detalhe em `docs/MODULOS.md §11`.

**Projetos · Intervenções** (`projetos` hub → `projeto_campo`/`projeto_det`/`projeto_sup`/`projeto_cfg`/
`projeto_acesso`/`projeto_resumo`/`projeto_rel`) — acompanhamento diário de obra (macromedidores, VRPs, redes
VCA/HDD). Suporte tem 2 telas: **Configuração** (`projeto_cfg`) e **Resumo por período** (`projeto_resumo` —
KPIs+timeline por dia/intervenção/atividade+CSV, sobre o feed `pjAllAvancos`). ⚠️ **Protótipo:** avanços não são
gravados (`pjLeafHist` é mock) e nada persiste — ver fragilidades em `docs/MODULOS.md §8`. Card
`#cardProj` (categoria **🚧 Em desenvolvimento**) gated em `homeGate()` por **`ME.dev_acesso`**, igual ao Perdas.
**Controle de acesso "Em desenvolvimento" (2026-09):** engrenagem ⚙️ na categoria (`#homeDevAcesso`, só admin,
`homeGate` mostra) → tela `dev_acesso` (`devAcessoInit`/`devAcessoRender`, espelha `supAreaGate`): lista usuários
com toggle. Backend: coluna **`perfil.dev_acesso`** (admin sempre) + RPCs `app_dev_acesso_listar`/`app_dev_acesso_set`
(admin-only) + `app_me` repassa `dev_acesso`. **Aposentou o gate por e-mail hardcoded.** **Hub em 2 categorias
(espelha o Almoxarifado):** **🏗️ Campo** (`projeto_campo` mapa/lista + `projeto_det` lançar avanços) e **🧰
Suporte** (card **⚙️**; `projeto_sup` mapa/lista+filtros → `projeto_cfg` configurar escopo/quantidade + **cadeado
de liberação**), gateada por `pjPodeSup()` = admin **ou** grant por pessoa definido no **mini-cadeado 🔐** →
`projeto_acesso` (protótipo em localStorage; futuro `proj_acesso`/`ME.proj_areas`). **Cadeado (1 por intervenção,
`iv.locked`):** o Suporte configura e **libera**; enquanto em configuração os **avanços ficam bloqueados** no
campo. **Congelamento por item (`pjHasAdv`):** mesmo com o cadeado aberto, item com lançamento não sai do escopo
(toggle 🔒, `−` da quantidade bloqueado). Toggle **No escopo?** em toda atividade E subatividade; peça começa
pelo **tipo de componente** (`pjSel`), ramal por **OS SIGOS + Hidrômetro** (+ imóvel, as-built A1/A2/A3/P1).
**Documentos:** anexar/abrir/remover ficam **na configuração** (`projeto_cfg`); no `projeto_rel` é **só abrir**.
Dados de exemplo em `PJ_IVS` (sem backend ainda; futuro: RPCs `app_proj_*`). Detalhe em `docs/MODULOS.md §8`.

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

## 8. Almoxarifado (schema `9 - suprimentos`)

**Exibido como "Almoxarifado"** (só o rótulo — screen id `suprimentos`, funções `sup_*` e o schema
seguem com o nome antigo). Home em duas seções: **📦 Áreas** — **Insumos**, **Equipamentos**,
**EPI / Uniforme**, **Ferramentas** — e, separada, **📋 Conferência** — **Baixas/Conferência**.
Papéis liberam ações via `ME`. `SUP_ACTS` mapeia act→função; `supBlocks*` monta os menus.
**Acesso às categorias Almoxarifado (de cada área) e Conferência não é mais por `is_almoxarife`** —
2026-09-16 virou **5 engrenagens ⚙️ admin-only** (uma por área: baixas/insumo/equip/epi/ferramenta),
tabela `sup_acesso_area` + RPCs `app_sup_area_listar`/`_set` + `ME.sup_areas`; front `supAreaAcesso(key)`
/`supAreaGate`. `sup_e_almox` virou aditivo (admin/almoxarife OU qualquer área concedida). Detalhe em
`docs/MODULOS.md §5`.

- **Configurações (admin)** — `supAbrirConfig(from)`, roda dentro de `<main id="suprimentos">`. Duas
  portas: ⚙️ **na home** (`#homeCfg`, `homeGate()` → `ME.is_admin`) abre **👤 Usuários** (acesso, cargo,
  aprovadores, consórcio) com **filtros** no topo (acesso / cargo / consórcio / 1º aprovador); ⚙️ **dentro
  de EPI / Uniforme** (`#supCfg`) abre **🦺 Cargos e cesta de EPI**. Detalhe em `docs/MODULOS.md §5.6`.

- **Insumos** — fluxo: solicitar → aprovar → **segregar** (almoxarife, existe/parcial/falta, gera
  código) → **retirar** (código). Tabelas `sup_solicitacao`/`_item`, `sup_material` (catálogo),
  `sup_saldo`/`sup_movimento` (kardex por equipe). RPCs `sup_solicitar`/`sup_aprovar`/`sup_segregar`/
  `sup_entregar`/`sup_consumir`. Catálogo via `sup_materiais_listar` (exclui categoria `EPI / EPC` e
  itens `ferramenta=true`, ver abaixo). Painel das equipes tem **drill-down**: tocar um item do
  estoque agregado mostra quem tem (`supEstTableDrill`), sem round-trip extra.
- **Ferramentas** (2026-09) — item reusável (trena, alicate, cone, escada, talha etc.) que se
  **empresta e devolve**, nunca se consome — `sup_material.ferramenta=true` fica fora do catálogo de
  Insumos e `sup_consumir` bloqueia consumo desses itens. **4ª área própria** (Campo/Gestão/Almox igual
  Insumos): Campo = **Solicitar ferramenta** + **Minhas ferramentas** (estoque atual com botão
  "Solicitar devolução" embutido + histórico); Gestão = **Aprovar solicitações** (reaproveita
  `sup_aprovar`/`sup_rejeitar`) + **Painel das equipes** (mesma função parametrizada e drill-down de
  Insumos); Almoxarifado = **Separação e entrega** (reaproveita `supAlmoxCard`/`sup_segregar`/
  `sup_entregar`) + **Recebimento** (tela nova: almoxarife confirma devolução digitando o código de
  4 dígitos que o colaborador informa, nunca mostrado nessa tela). Dois códigos simétricos: retirada
  (`codigo_retirada`, padrão já existente) e devolução (`codigo` novo, tabela `sup_ferramenta_devolucao`
  + `_item`; confirmar grava `sup_movimento` tipo **`devolucao`** negativo — enum que existia sem uso
  até agora). RPCs `sup_ferramenta_*` (catálogo/solicitar/meu_estoque/fila_aprovacao/fila_almoxarife/
  painel_multi/devolucao_*). Notifica por trigger (`sup_trg_ferramenta_devolucao`). Detalhe em
  `docs/MODULOS.md §5.4`.
- **Equipamentos** — rastreio por pessoa via **termo de responsabilidade**. Emitir → **aceitar dentro
  do próprio termo** (documento fica **vermelho até aceitar, verde depois**) → usar → devolver por
  código (com defeito → abre manutenção corretiva). Preventiva por tipo (dias). Tela "Equipamentos por
  responsável" mostra movimentações e **destaca quebra/defeito**. **Equipamentos cadastrados**
  (Almoxarifado, 2026-09: inventário do acervo com filtro de tipo/nome-nº-série/situação — Em estoque ×
  Em uso × Manutenção — agrupado por tipo, só leitura sobre `sup_equip_listar`; ver `docs/MODULOS.md
  §5.2`). Tabelas `sup_equipamento`, `sup_equip_tipo`, `sup_termo`, `sup_manutencao`,
  `sup_equip_solicitacao`. RPCs `sup_equip_*`, `sup_termo_*`, `sup_equip_historico`.
- **EPI / Uniforme** — espelha o fluxo de insumo: solicitar → aprovar (sem código) → **Separar EPI**
  (almoxarife, gera código, avisa o colaborador) → **retirada** (código + foto do colaborador com os
  EPIs + assinatura). Status: solicitada/aprovada/**segregada**/entregue/rejeitada. Devolução/troca por
  código, com fotos. **Tamanho** por escala: `letra` (P/M/G/GG/EXG) ou `numero` (33–48, calçados/botas).
  Tabelas `sup_epi*`. RPCs `sup_epi_*` (`_solicitar`/`_aprovar`/`_segregar`/`_entregar`/`_fila_*`/`_baixa_*`).
  **Gestão de EPI (Aprovar EPI + EPIs por colaborador)** liberada também por **cargo** (não só
  `funcao`): `"9 - suprimentos".sup_epi_gestor(uid)` — aprovador/admin **ou** cargo em
  {Técnico de Segurança do Trabalho, Técnico de Qualidade, Coordenador de QSMSS}. Ver `docs/MODULOS.md §5.3`.
- **Baixas / Conferência** — consolida entregas por período para conferência/baixa no SIENGE. **Nunca
  inclui item `ferramenta`** (fix 2026-09 — ferramenta empresta/devolve, não é custo consumido).

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
