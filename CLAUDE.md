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
  `app_me` (objeto `ME`: `is_admin`, `is_almoxarife`, `pode_aprovar`, `funcao`, `equipes`). `funcao='qsms'` é
  legado e não libera nada; o acesso à gestão QSMS é `ME.qsms` (admin, `perfil.qsms_acesso` ou cargo de QSMS).
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
  `9`, `10`, `11`, `12`, `15`, `16`. Tabela nova = decisão explícita no PR de qual lado ela cai.

| Schema | Conteúdo |
|---|---|
| `1 - suporte_geografico` | limites, apoio |
| `2 - infra_agua` | rede, nós de água (`nos_agua`), unidades operacionais, **`vrps`** |
| `3 - comercial` | ligações |
| `4 - redes_terceiros`, `5 - info_copasa` | apoio/cadastro |
| `7 - setorizacao` | **setorização**: `dmc_projetado`/`vrp_projetada` (WaterGEMS), `dmc` (dimensão versionada vigente), `dmc_ligacao`, `dmc_resumo` |
| `8 - coleta_campo` | **coleta de campo geo**: pressão (`mapeamento_pressao`), loggers (`instalacao_logger_calibracao`, `logger_pressao`), pesquisa (`pesquisa_trecho`), **ocorrências da pesquisa** (`ocorrencia`), estanqueidade (`ponto_estanqueidade`), visita a VRP (`vrp_visita`), **programação de pesquisa** (`programacao_pesquisa`, `rede_pp_segmento`/`_fonte`, `pp_config` — app-only mesmo estando neste schema geo, sem policy pra `gis_*`) + views |
| `9 - suprimentos` | almoxarifado (insumos, EPI, equipamentos, notificações) — *app-only* |
| `10 - Frotas` | veículos, condutores/CNH, termo de responsabilidade, vínculos (self-service), lavagem, manutenção — *app-only* (QSMS/treinamento, Equipes, Ocorrência e empréstimo **removidos por completo** em 2026-09; **abastecimento removido** em 2026-10-14) |
| `11 - perdas_nrw` | analítico/config do módulo de Perdas: `parametros_nrw`, `linha_base`, `medicao_entrada`, `consumo_dmc` — *app-only* |
| `12 - retaguarda` | registros de campo que viram processo (Auxiliar de Programação): `captacao_cliente` (PII: CPF/fotos), `abertura_servico` + `vw_captacao`/`vw_abertura_servico`, `pesquisa_dia_os` (OS SIGOS do dia de pesquisa por colaborador × consórcio, §4.3.9) — *app-only* |
| `14 - pessoas` | **legado** da antiga Gestão de Pessoas (removida do app em 2026-10): candidatos (PII), admissão, checklist, desligamento — *app-only*; pode ser dropado com `docs/migracao_remove_gestao_pessoas.sql` |
| `15 - telemetria` | **telemetria do CCO COPASA** (vazão/volume macro, nível reservatório, bombas/pressão booster): `tele_unidade` (dimensão + cruzamento c/ cadastro), `tele_leitura` (formato longo), `tele_carga` + views `vw_cobertura`/`vw_cadastro_sem_tele` — *app-only* |
| `16 - qsms` | **Segurança do Trabalho / QSMS** (2026-10-28): APR, PT (altura) e PET (espaço confinado) digitais — `qsms_atividade`, `qsms_formulario`, `qsms_participante` (assinaturas), `qsms_medicao` (gases), `qsms_evento` (verificações); nada pode ser apagado (trigger) — *app-only* |
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
- **`vw_gis_cadastro_comercial` (2026-09-17):** cadastro comercial concentrado por **matrícula**, 1 linha por ligação (134 k) sobre `"3 - comercial".ligacoes` (que mistura cadastro + roteiro de leitura E-341 + perdas). Resolve, via **subconsulta escalar** (mantém 1:1, sem fan-out), o **nome da rua** (`"1 - suporte_geografico".logradouros` por `cd_localidade`+`cd_logradouro` — o mesmo código existe em >1 localidade; fallback por `consorcio` só quando `cd_localidade` é nulo) e o **bairro** (`bairros` por `cd_localidade`||`lpad(cd_bairro,6)`, com fallback `'Bairro <cd>'`); monta `endereco` (rua+número+complemento), `roteiro_leitura` (`setor-rota-face-sequencia`) e `consorcio_nome`. Traz o **setor de leitura** cru (`setor`) **e** o **`setor_efetivo`** (2026-09-17): as 76 avulsas (`setor='00' and rota='00'`, flag `avulsa`) herdam o setor do ponto de leitura real mais próximo (mesma ancoragem da `vw_roteiro_leitura`, mas inline — a subconsulta nearest-neighbor só roda p/ as avulsas, sem o windowing da view de roteiro). Sem PII (`ligacoes` não tem nome de cliente/CPF). **Cobertura (2026-10-23):** bairro 98,6% (1.892 sem nome), rua 99,98% (Contagem e Betim; `logradouros` agora tem Betim). `geom` nativo 31983.
- **Situação da ligação — fonte única `ligacoes` (2026-10-23, sw v272):** `"3 - comercial".ligacoes.situacao` (CD_SITUACA, água: R/I/F/P) é a situação oficial; `situacao_lig` (CD_SITUA_1) parece ser de esgoto e **não** é usada pelo app. Nova coluna **`situacao_desde`** (DT_SITUACA = data da última mudança). **Priorização de HD** (`hd_priorizacao.situacao_lig`, snapshot) e **fiscalização** (`situacao_atual`) passaram a ler a `ligacoes` (antes: micromedição do último mês); `app_nrw_hd_sync_situacao()` atualiza só as matrículas que mudaram e recalcula os derivados via `app_nrw_hd_recompute_derive(p_matriculas)`. As RPCs `app_nrw_hd_ranking/detalhe` e `app_nrw_fraude_ranking/detalhe` devolvem `situacao_desde` (fraude_detalhe: `endereco.situacao_lig` foi trocado por `endereco.situacao` + `situacao_desde`). `vw_gis_cadastro_comercial` **não tem mais `volume`/`consumo_medio`** (volume é só da micromedição) e ganhou `situacao_desde`. **Rotina diária** (script local `COPASA/scripts/atualizacao_cadastro/8_sync_ligacoes_situacao.py`): lê só 4 campos do `cliente.dbf`, envia em lotes a `app_ligacoes_sync_situacao(jsonb)` (diff no servidor, histórico em `ligacoes_situacao_hist`) e chama `app_ligacoes_pos_sync()`. Nenhum volume do cliente.shp é usado.
- **Cadastro de ligações e nós — carga de 23/10/2026 (COPASA 202609):** `ligacoes` (135.096 = +223 novas, consórcio pelo polígono de `limite_za`) ganhou `economias_com/ind/pub/cat4` (QT_ECONO_1..4; `economias` = QT_ECONOMI = residencial, inferido), `categoria` (residencial|comercial|industrial|publica|cat4|mista|sem_economia), `ramo_atividade`, `grupo_faturamento`, `situacao_desde`; **`volume` e `consumo_medio` foram REMOVIDAS da tabela** (volume é só da `micromedicao_historico`); `valor_faturado` ficou como estava (defasado). A geometria vem do ponto do `cliente.shp` (NÃO de NU_COORDEN/NU_COORD_1, que divergem >1 m em ~5,3 mil imóveis). Rotina diária: `COPASA/scripts/atualizacao_cadastro/9_sync_ligacoes.py` → RPC `app_ligacoes_sync` (diff no servidor; histórico de situação/geometria em `ligacoes_situacao_hist`) + `app_ligacoes_pos_sync`. `vw_gis_cadastro_comercial` expõe as colunas novas (44 colunas). `nos_agua` ganhou `estado`, `diametro`, `pressao`; `cota` agora = QT_COTA__1 (NULL = sem cota; antes recebia QT_COTA_IN, 0 em 99,97%); 1.066 nós novos (+2 em `unidades_operacionais`), textos corrigidos (mojibake 757→4). Script `10_sync_nos.py` (RPC `app_nos_sync`, `--simular` só conta). Backups `_bkp_*_20261023` nos schemas 2 e 3.
- **Logradouros, bairros e limite da ZA — carga de 23/10/2026:** `logradouros` 12.875 (+4.851, inclui Betim) com `cd_localidade` (CD_LOCAL_1), `cd_localidade_log`, `num_min2/num_max2` (outro lado da via); ~2,2 mil linhas antigas ainda sem localidade. `bairros` 155 (+28) com **polígono inteiro** (não mais recortado pela ZA; decisão do usuário para cruzar com os clientes). `limite_za` ZA1004 atualizado (−0,27%); 4 ligações antigas ficaram fora do próprio limite. Scripts `11_sync_logradouros.py` e `12_sync_bairros_limite.py` (`--simular` só conta); RPCs `app_logradouros_sync`, `app_bairros_sync`, `app_limite_za_set`. Backups `_bkp_logradouros|bairros|limite_za_20261023` (schema 1).
- **Ordens de serviço e municípios — carga de 23/10/2026:** `"5 - info_copasa".ordens_servico` passou de 11.941 (só vazamento/falta d'água) para **78.695** com **todos os tipos de serviço** (575 códigos; o filtro por vazamento continua `cd_servico like '148%'/'149%'` ou `de_servico ilike '%vazamento%'` — hoje 15.009). Colunas novas: `tempo_d`, `vol_uti`, `cd_bairro`, `grupo_servico` (DE_GRUPO_S, filtra o tipo sem ilike), `dt_limite`, `sigla_unidade`; índice único em `nu_os`. Matrícula 0 → NULL, tempo_atend <0 ou >8.760 h → NULL, geometria = ponto do .shp, consórcio pelo polígono da ZA. Rodar o `13_sync_os.py` todo dia também fecha as OS abertas (atualiza parecer/execução). `municipios` ganhou `sigla_gerencia`, `cd_nivel3`, `dt_inicio_concessao`, `dt_fim_concessao` (atributos COPASA; geometria IBGE mantida) e **Ibirité** (única que toca as ZAs; geometria COPASA). Scripts `13_sync_os.py`, `14_sync_municipios.py` (`--simular`); RPCs `app_os_sync`, `app_municipios_sync`; backups `_bkp_ordens_servico|municipios_20261023`.
- **Fiscalização — classes pelo cadastro (2026-10-24):** `mm_matricula_stats.classificacao` agora considera `ligacoes.situacao`/`situacao_desde`: *fraude_potencial* e *factivel* só valem se o cadastro ainda é I/F/P; se virou Real depois dos meses anômalos → **`reativada`** (3.127, ~20 mil m³/mês regularizados; fora da lista de suspeitos, lente `p_lente='reativadas'`); se já era Real antes → **`divergencia_cadastro`** (6). O score deixa de pontuar `meses_irregular` nessas classes; `app_nrw_mm_stats_rebuild` aplica a regra nas próximas rodadas; `n_anomalas` (mm_resumo/mm_dmc) não conta `reativada`. Backup `_bkp_mm_matricula_stats_20261024`.
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
- **Loggers** (card "Loggers" → hub `loggers_hub` com **Temporários**/**Fixos** → `loggers`/`logger_det`) —
  os dois modos usam a **mesma tela**; `lgModo` filtra pela flag `logger_temporario` (true=temp, false=fixo)
  e define a flag na criação (`app_logger_criar.p_temporario`). Ciclo: **pendente → instalado → dados pendentes
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
  As **ocorrências** (vazamentos e, desde 2026-10-27, **fraudes** — tipos `Fraude - …`; vazamento = tudo que não é
  fraude) registradas aqui (`app_ocorrencia_registrar`, consórcio pelo ponto, tabela
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
  passadas + ocorrências/reporte ativáveis — ocorrência com popup e atalho p/ o card na Abertura de serviços —,
  produtividade por colaborador com ocorrências/km = (vazamentos + fraudes) ÷ km de rede, matriz ocorrências por
  tipo × local que abre a Abertura já filtrada; a Abertura de serviços — ocorrências filtra por tipo, local e
  consórcio). O cruzamento roda em
  **pedaços de rede** (`"8 - coleta_campo".rede_pp_segmento`, ≤ `pp_config.seg_max_len_m`, **não** a rede
  cadastral inteira) — buffer (`pp_config.tol_m`) + alinhamento de azimute (`max_ang_deg`) + % de
  cobertura (`cov_pct`, ou `min_len_m`+herança de vizinho pra cotos curtos). Detalhe completo, incl. a
  segmentação resiliente a reimportação da base de rede, em `docs/MODULOS.md §4.3`.
- **Entrevistadores** (`entrevistadores`) → só o que é de campo do entrevistador: **Captação de clientes**
  (`captacao`, view `vw_captacao`), **Solicitação de serviços** de campo (`abertura_servicos`) e
  **Registro de ocorrência** (`ent_ocorrencia`). **Ocorrências registradas** (`ent_oc_gestao`) e
  **Roteiro de leitura** (`roteiro`) **saíram daqui** (2026-10 reorg) e vivem agora no Auxiliar de Programação.
- **Auxiliar de Programação** (`auxiliar_programacao`, na Home › 🧰 Suporte) — **acesso geral próprio da tela**
  (reorg 2026-10): gate `homeGate()` por **`ME.aux_acesso`** (= `perfil.aux_acesso`, admin sempre), controlado por
  uma **⚙️ engrenagem geral** (`#apCfg`, admin) que abre a tela **`aux_acesso`** (lista de usuários com toggle,
  `auxAcInit`/`auxAcRender`, RPCs `app_aux_acesso_listar`/`app_aux_acesso_set` — espelham `dev_acesso`). A
  **engrenagem exclusiva de VRP saiu**: a Gestão de VRPs agora é liberada pelo mesmo acesso geral
  (`app_me.vrp_gestao` e `vrp_pode_gestao()` passaram a incluir `aux_acesso`). Seed de continuidade: os
  **aprovadores** existentes receberam `aux_acesso=true`. `apInit()` monta o hub (barra as não-autorizadas) em
  **3 categorias**:
  - **🧾 Serviços comerciais:** Criação de matrículas (`matriculas`) · **Abertura de serviços** (`programacao_servicos`
    em `pgModo='comercial'` — só a seção de **solicitações** `app_abertura_fila`/`_os`) · Ocorrências registradas
    (`ent_oc_gestao`) · Roteiro de leitura (`roteiro`, `app_roteiro_*`) · **Priorização de troca de HD** e
    **Fiscalização de irregularidades** (abrem `perdas.html?s=hdpri` / `?s=fraudepri` — ver Perdas/NRW) · **Situação dos Imóveis** (`perdas.html?s=situacao`, 2026-10-30: ligações por situação R/I/F/P e por **há quantos dias** estão nela — `ligacoes.situacao`/`situacao_desde` —, filtros em dropdown sobre um mapa em largura total com limite das ZAs + polígono e um botão de export .xlsx com a contagem; RPCs `app_sit_imoveis_resumo/lista/mapa`, gate `_nrw_fraude_gate`). *(Análise
    por matrícula / `?s=mm` foi removida do Auxiliar em 2026-10-20; a tela segue existindo no cockpit NRW.)*
  - **🎧 Pesquisa de Vazamentos:** Programação de pesquisa (`programacao_pesquisa`) · Acompanhamento da pesquisa
    (`pp_acomp`, §4.3.8) · **Abertura de serviços** (`programacao_servicos` em `pgModo='pesquisa'` — só a seção de
    **ocorrências** de vazamento `app_ocorrencia_fila`/`_os`) · **Relatório diário** (`pp_diario`, 2026-10-30: lista de
    blocos dia × colaborador × consórcio no estilo da Gestão de Pavimento — abas Pendente de OS/OS criada/Todos, chips de
    prazo, filtros de consórcio, colaborador e dia; o backoffice lança a **OS SIGOS do dia** no bloco (`"12 - retaguarda".pesquisa_dia_os`)
    e cada bloco abre a folha p/ imprimir/PDF — produção do dia, mapa estático e o detalhe de cada vazamento e de cada
    fraude com foto e descrição (fraude fora do vaz/km); `app_pp_diario_lista`/`app_pp_diario_os`/`app_pp_relatorio_diario`, §4.3.9).
  - **🔧 Gestão de VRPs:** Gestão de serviços (`vrpman_serv`) · Ficha cadastral (`vrpman_fichas`) · Cronograma
    preventivo (`vrpman_prev`) — **migradas do hub `vrpman`** (gate `ME.vrp_gestao`; ⚙️ acesso `vrpman_cfg` admin).
  - **🧱 Gestão de Pavimento:** Pavimentos a recompor (`pavprog`) — lista os registros de campo do módulo
    **Gestão de Pavimento** (`pavimento`, na Home › 🛠️ Execução) agrupados por ponto, com filtro por **consórcio** e
    **serviço de origem**, fotos e export .xlsx. Ver módulo Gestão de Pavimento abaixo.
  - **Abertura de serviços segmentada:** a mesma tela `programacao_servicos` serve as duas frentes; `pgModo`
    (comercial/pesquisa) esconde a seção que não é do contexto, sem duplicar código.
- **Gestão de Pavimento** (2026-10-21) — registra pavimentos a recompor após serviços. **Duas telas:**
  (1) **`pavimento`** (Home › 🛠️ Execução) = formulário de campo: serviço de origem (vazamento/ramal/fiscalização/
  vrp/rede_vca/rede_hdd/dmc), OS SIGOS, **coordenada travada no GPS** (`pavOnGps`, trava ≤`PRECISAO_MAX` 15m —
  "Fique próximo ao local"), **multi-seleção de tipos de pavimento** (chips: grama/asfalto/concreto/bloquete/
  paralelepípedo/pedra portuguesa/piso especial/piso tátil/meio-fio/sarjeta) e, por tipo, **dimensão + 2 fotos
  obrigatórias** (câmera **ou galeria**). Salva **1 registro por tipo** (mesmo `grupo` uuid) via a fila offline
  (`enviarOuEnfileirar`, fotos `p_foto1`/`p_foto2`). (2) **`pavprog`** (Auxiliar de Programação) = lista agrupada por
  ponto, com cabeçalho espelhado na "abertura de serviços — ocorrências" (**tabs de status** Pendente de criação/Pendente
  de execução/Executada/Todas +
  **visão Lista/Mapa** Leaflet) e **controle de prazo** (aging de `created_at`, faixas **0–3/4–5/>5 dias**, chips clicáveis
  com contagem que filtram), filtros **consórcio + serviço de origem (dropdown multi-seleção `.msdd`)**, fotos
  (bucket público `fotos-campo`) e export .xlsx (gate `aux_acesso`). **Distinção OS criada × pendente** (como a ocorrência da pesquisa): o programador
  lança a **OS SIGOS da recomposição de cada tipo** no card (**1 campo por tipo** → `app_pav_os_itens(p_itens [{id,os}])`,
  2026-10-28) → o relógio de pendência conta até **todos** os tipos terem OS. (`os_sigos`=OS de origem, do campo, 1 por
  registro; `os_recomposicao`=OS da recomposição, **por tipo**, lançada no `pavprog`.) `app_pav_os(p_grupo,p_os)` fica só
  p/ app em cache (≤ v281): "A, B" numérico com nº de partes = nº de tipos é distribuído na ordem do card (alfabética do tipo).
  **Etapa de execução** (2026-10-28): depois da OS, cada tipo tem "Executado em [data]" + "Marcar executado"
  (`app_pav_executar(p_id,p_data)`) → etapas por tipo **criação → execução → executada**; o ponto fica na mais atrasada.
  Backend: `"8 - coleta_campo".pav_recomposicao` (1 linha/tipo, geom 4326, `os_recomposicao`/`os_recomp_em`/`os_recomp_por`,
  `execucao_data`/`execucao_em`/`execucao_por`, RLS deny-all) + RPCs definer `app_pav_registrar` (authenticated) /
  `app_pav_minhas` / `app_pav_listar` / `app_pav_os_itens` / `app_pav_executar` / `app_pav_os` (admin|aux_acesso). sw v282.
- **Segurança do Trabalho + QSMS** (2026-10-28, schema `16 - qsms`) — substitui a **APR** (modelo COPASA), a **PT**
  de trabalho em altura (FOR_PG_22, do consórcio) e a **PET** de espaço confinado (COPASA) de papel. **Formulário é só
  preenchimento: sai emitido (ou impedido) — nada fica aberto.** **Campo** (`seg`, Home › 🛠️ Execução, sem gate):
  atividade = tipo de intervenção + OS (texto) + GPS travado + data/hora/usuário; endereço, bairro, município e
  consórcio **pela coordenada** (`app_seg_local`/`qsms_local`); a APR sugere fases/riscos/EPIs pelo tipo, exige foto da
  sinalização; quem preenche é o responsável (travado, só assina) e os executantes vêm da lista; PT/PET só saem de APR
  que as indique e **reaproveitam a equipe e as assinaturas da APR** (PT: só o liberador assina; PET: papéis
  entra/vigia); travas ("Não" impede; gás fora do limite impede); cada atividade (APR + PT/PET) é um bloco com
  **PDF único** (capa + formulários). Offline pela fila
  (`item.anexos`, ids `seg-<ts>`), rascunho e cópia local em IndexedDB `seg_local`. **Gestão** (`qsms`, Home › 🧰
  Suporte, gate `ME.qsms` + ⚙️ `qsms_acesso`): **hub em categorias** como o Almoxarifado — **⛑️ APR e derivados**
  (`qsms_ind` Indicadores · `qsms_form` Formulários: por atividade, lista/mapa/XLSX, filtros por situação da verificação,
  tipo, responsável e PT/PET, **uma verificação por atividade** que avisa o autor) e **🦺 EPI** (`qsms_epi_painel` = painel de EPI,
  RPC `app_qsms_epi_painel`; `qsms_cesta` = a tela "Cargos e cesta de EPI" da engrenagem do Almoxarifado reaproveitada,
  editável por quem tem QSMS; `qsms_epi_col` = a tela "EPIs por colaborador" do Almoxarifado reaproveitada). RPCs `app_seg_*`/`app_qsms_*`. Detalhe em `docs/MODULOS.md §18`.
- **Cadastro técnico** (`cadastro`) — camadas do PostGIS no mapa (rede, ligações, unidades, **VRPs**,
  **limite das ZAs** — contorno tracejado via `app_limites_zas` + máscara escurecendo o fundo fora das ZAs, 2026-10-29)
  com busca + marcador "Você" (GPS, `cadOnGps`, pane próprio sempre por cima). RPCs `app_cadastro_geojson` (bbox → GeoJSON) e `app_cadastro_buscar`. Cache em IndexedDB versionado
  por `CAD_VER` (recarregou o `limite_za`? suba `CAD_VER`).
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
veículo nenhum), **Veículos** (self-service acima), **checklist diário** (layout em cartão; os lembretes
diários automáticos das 7h30 e 16h50 foram **removidos** em 2026-10-28 — `docs/migracao_remove_lembretes_frota.sql`;
lembrete de checklist hoje só pelo módulo Avisos, enquanto houver aviso vigente), **Manutenção** e **Lavagem** — cada uma é uma tela de
**histórico + ação**, não só
um formulário avulso (**renomeadas na 5ª rodada**, eram "Registrar problema (manutenção)"/"Solicitar
lavagem", iam direto pro formulário sem mostrar nada do que já existia). Estes 3 últimos ficam
**desabilitados no hub** enquanto o colaborador não tiver veículo vinculado. **Abastecimento removido
por completo (2026-10-14):** o controle de combustível (veículo + equipamento) e todos os relatórios
de abastecimento saíram do módulo — tabelas `frota_checklist_abastecimento`/`frota_equipamento_abastecimento`
e as 5 RPCs `app_frota_%abastec%` foram dropadas (backup em `"_bkp_frota_abastec_20261013"`); `custo_total`
de `app_frota_custos_por_veiculo`/`app_frota_veiculo_relatorio` não soma mais combustível. Checklist agora começa
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
tem 3 submódulos com filtro de veículo/colaborador/data (lavagens/manutenções/
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
direto do hub deve ser `irPara('frota')`, nunca `='home'`. **Fluxos de 2026-10-16 (e-mail Amanda):** multas/ocorrências/avarias (`frota_registro`, cadastro só da equipe de frotas, aviso só ao colaborador + gestor), manutenção preventiva agendada direto pela Frotas e aviso de ocorrência de checklist pra equipe de frotas — avisos pra "equipe de frotas" usam `frota_responsaveis()` (inclui a engrenagem `frota_admin`), ver docs/MODULOS.md §6.6.

**Meus colaboradores** (`meus_colab`, home › Suporte, só aprovador/admin) — substitui a antiga Gestão de
Pessoas (removida em 2026-10). Aprovador vê os colaboradores **ativos** que o têm como Aprovador 1/2 (admin vê todos):
quantitativos por área/consórcio/projeto/cargo/modalidade + ficha com e-mail etc. RPC `app_meus_colaboradores`;
aviso "novo colaborador" por trigger em `public.perfil` quando o aprovador é vinculado. Ver docs/MODULOS.md §12.
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
**Menu (2026-10-22):** `hdpri`/`mm`/`macro` voltaram ao `#nav` do cockpit (Dados & diagnóstico / Execução — comercial); saíram Painel, Componentes IWA, OS/reparos, Parque, Recuperação, Grandes consumidores e Performance contratual (ver `docs/MODULOS.md §11`).
**Balanço hídrico (2026-10-22, `s-nrw_balanco`, real):** checklist dinâmico de dados do balanço IWA (ZA inteira) — quadro IWA clicável com rastreio da origem de cada componente; itens em `"11 - perdas_nrw".bh_checklist_item` verificados ao vivo por `app_nrw_checklist()`; ajuste manual (admin, nota obrigatória, histórico em `bh_checklist_log`) via `app_nrw_checklist_salvar`.
**Histórico fechado por ZA (2026-10-29, `s-historico`, real):** série dez/2023 → hoje de macro/micro/VP/IP/IRVP — fechamento COPASA até fev/2025 em `"11 - perdas_nrw".historico_za` + meses do sistema, via `app_nrw_historico(p_consorcio)` (chama `app_nrw_resultado`); gráfico com variáveis liga/desliga, linha × coluna e visão sazonal jan–dez por ano (volumes e % em 2 gráficos com o mesmo eixo x).
**Reorg 2026-10:** **Priorização de troca de HD** (`s-hdpri`), **Fiscalização de irregularidades** (`s-fraudepri`,
2026-10-20) e **Análise do micromedido** (`s-mm`; desde 2026-10-26 com bloco **Indicadores de micromedição** da linha de base — sem Abertura por DMC/Análise por matrícula) são acessadas pelo **Auxiliar de Programação** via
deep-link `perdas.html?s=hdpri` / `?s=fraudepri` / `?s=mm` (sem item de menu no cockpit; estão em `AUX_TOOLS`).
O gate da página libera essas ferramentas para **aprovador/admin/`aux_acesso` mesmo sem `dev_acesso`**; nesse caso
entra em **`body.aux-solo`** (esconde o `#nav`, mostrando só a ferramenta + "Voltar ao AcquaHub"). As telas e RPCs
(`app_nrw_hd_*`/`app_nrw_mm_*`/`app_nrw_fraude_*`) continuam no `perdas.html` — só mudou a porta de entrada.
A **Fiscalização** (`fr*`) reaproveita `mm_matricula_stats` (sem motor novo); RPCs `app_nrw_fraude_resumo/ranking/mapa/detalhe`
com gate `admin|dev_acesso|aux_acesso`; lentes grandes-consumidores / **consumo com ligação irregular** (`meses_irregular`) /
**leitura estimada** (`meses_estimada`=`qt_vol_est>0`, coluna nova, rebuild do mm patcheado) / abaixo-da-vizinhança; mapa com
polígono + export .xlsx p/ SIGOS. **Fora de escopo:** priorização por DMC e estimativa de recuperação de volume.
⚠️ **`cd_situaca` (R/I/F/P) = situação da LIGAÇÃO** (Real/Inativo/Factível/Potencial), não da leitura — não confundir.
**HD — recomendação e "troca efetiva" (2026-10-20d, só DB):** dimensionamento por `ref_dim = greatest(mediana, least(p90, média_4m))` (robusto a pico isolado); coluna `hd_priorizacao.media_4m`. **`cal_recomendado` só muda de calibre quando `adequacao` é sub/superdimensionado** (consumo > 1,5× máx da faixa, ou < mín) — migração de faixa que ainda cabe no calibre atual **mantém o calibre**. Flag `troca_efetiva` = `(cal_recomendado≠cap) OU (idade≥idade_alta)` esconde do radar as trocas de mesmo calibre em medidor novo (eram 64%). `app_nrw_hd_resumo/_mapa/_ranking` filtram `troca_efetiva` por padrão (`p_incluir_sem_troca` nos três = select **"Todo o parque de HDs"** no cabeçalho, 2026-10-29). **Filtro por idade (2026-10-29, sw v300):** painel histograma **Idade do medidor** (seleção múltipla por coluna **ou** intervalo de/até) → `p_idades int[]` (30 = 30+, -1 = sem idade) / `p_idade_min`/`p_idade_max` nas 3 RPCs; `_resumo` devolve `por_idade` + `idade_media`. `app_nrw_hd_rebuild` e `_rebuild_chunk` patcheados. **Situação da ligação (2026-10-22):** `situacao_lig` (filtro ativa/inativa + remanejamento) passou a vir de **`"0 - vitrine_gis".vw_gis_micromedicao_atual.situacao_ligacao`** (último mês da micromedição; `"3 - comercial".ligacoes` só fallback) — o cadastro divergia em 22% (28,6k matrículas). Mesmo ancoramento na view na Fiscalização (`app_nrw_fraude_ranking/_detalhe`, lá sem impacto: já usava o último mês via `mm_matricula_stats.situacao_atual`).

**Vitrine (TV)** (`vitrine`, home › 🚧 Em desenvolvimento — gate `dev_acesso` pela engrenagem da categoria, no card e na RPC; apresentação em loop de atividades de campo + indicadores, ao vivo via `app_vitrine_dados`; ver docs/MODULOS.md §17). **Avisos** (`avisos`, **admin-only**, home › 🚧 Em desenvolvimento (card só p/ admin, sem `dev_acesso`) — avisos genéricos: pop-up + lembretes push para um público montado por consórcio/função/cargo/pessoas/condição, modo de exibição (sempre/1x por dia/1x só/"Li e entendi") com registro de quem viu, botão p/ qualquer tela ou link externo; job único `aviso-lembretes` a cada 15 min; ver docs/MODULOS.md §19). **Telemetria (CCO)** (`telemetria`, **admin-only**, home › 🚧 Em desenvolvimento — schema `15 - telemetria`) — importa os
CSVs exportados do sistema CCO da COPASA (vazão/volume macro, nível reservatório, bombas/pressão booster),
identifica a unidade pelo nome do arquivo, grava em **formato longo** (`tele_leitura`) e cruza com o cadastro
(`tele_unidade.cadastro_tabela`). Upload por dropzone → prévia → **Processar** (lotes via `app_tele_ingest`,
pela sessão do usuário, **sem service key**; idempotente + incremental) + painel **Cobertura × cadastro**
(`app_tele_cobertura`). Backfill histórico também pelo script `scripts/telemetria/ingest_telemetria.py`.
Detalhe em `docs/MODULOS.md §16`.

**Gestão de VRPs** (`vrpman` hub; funções `vm*`, schema `8 - coleta_campo`) — gestão de serviços de manutenção nas VRPs,
**separado do módulo `vrp`** (que é só levantamento/visita primária). Card 🔧 **"VRPs – Campo"** na seção **🛠️ Execução**
(promovido de "Em desenvolvimento" em 2026-10-01; **sem gate `dev_acesso`** — entra por `data-go="vrpman"`); o card antigo "VRPs" da seção Execução foi removido (o módulo `vrp` vive em Campo como "Visita primária"). **Reorg 2026-10:** o hub `vrpman` ficou **só com 🏗️ Campo**; a **🧰 Gestão (Gestão de serviços/Ficha cadastral/Cronograma preventivo) migrou para o Auxiliar de Programação › Gestão de VRPs** (back → `auxiliar_programacao`; **acesso governado pelo acesso geral do Auxiliar `aux_acesso`** — a engrenagem exclusiva `vrpman_cfg` saiu da navegação; `vrp_pode_gestao()`/`ME.vrp_gestao` passaram a incluir `aux_acesso`). Visita primária (`vrp`): back agora → `vrpman`. **Campo:** "Minhas OS / Executar" (`app_vrp_os_minhas`) + Nova OS
corretiva → wizard de 5 telas sobre cabeçalho autofill, fotos (`vmUpload`→`fotos-campo/vrp-os/`), GPS, conclusão
`app_vrp_os_concluir`; + card **Visita primária** (abre o módulo `vrp` antigo). Ficha+histórico (`app_vrp_ficha`,
`#vmFicha`) e relatório PDF (`vmReport`). **Gestão = 3 cards diretos no hub** (`vmHub`, sem tela intermediária; ⚙️ acesso na seção Gestão): **Gestão de serviços**
(`vrpman_serv`: OS + Pendências; filtro por **colaborador**, mostra "programado para" + **Desprogramar**
`app_vrp_os_desprogramar`), **Ficha cadastral** (`vrpman_fichas`: lista/mapa de **todas** as VRPs via
`app_vrp_ficha_listar` → ficha por VRP com histórico que **mescla OS novas + visitas primárias antigas**, cada uma em
popup), **Cronograma preventivo** (`vrpman_prev`: farol + resumo). OS SIGOS editável, pendência → gerar corretiva,
⚙️ acesso `vrp_gestao_acesso` (`app_vrp_acesso_*`). OS interna `VRP-OS-AAAA-NNNN`. Tabelas
`vrp_os`/`vrp_pendencia`/`vrp_prev_config`/`vrp_prev_vrp` (schema 8, app-only) + RPCs `app_vrp_*` (definer; gestão por
`vrp_pode_gestao`). **Status início→fim** (2026-10-02): `programada`→`concluida`/`concluida_pendencia`/`improdutiva` (sem `em_execucao`/`retorno`; "não liberada"/"vazou" geram pendência→`concluida_pendencia`). **Pendência = OS corretiva derivada**, com vínculo pai↔corretiva exposto em `app_vrp_pendencias_listar`/`_os_ver` (coluna "Vínculo", link "abrir corretiva"). **Programar** só VRP sem serviço aberto (`app_vrp_os_programaveis` + bloqueio em `app_vrp_os_programar`); OS na Gestão são chips com contagem (sem cards). **Pressão de projeto** = `vrps.pres_max` (montante) / `pres_saida` (jusante = 🎯 setpoint que a equipe deixa na VRP), mostrada no cabeçalho da OS, no topo da ficha e no popup do Cadastro técnico; Betim carregada da planilha do projeto em 2026-10-29. Detalhe em `docs/MODULOS.md §15`.

**Projetos · Intervenções** (`projetos` hub → `projeto_campo`/`projeto_det`/`projeto_sup`/`projeto_cfg`/
`projeto_acesso`/`projeto_resumo`/`projeto_rel`) — acompanhamento diário de obra (macromedidores, VRPs, redes
VCA/HDD). Suporte tem 2 telas: **Configuração** (`projeto_cfg`) e **Resumo por período** (`projeto_resumo` —
KPIs+timeline por dia/intervenção/atividade+CSV, sobre o feed `pjAllAvancos`). ⚠️ **Protótipo:** avanços não são
gravados (`pjLeafHist` é mock) e nada persiste — ver fragilidades em `docs/MODULOS.md §8`. **Card em 🛠️ Execução
(2026-09-29)** — Projetos **saiu de "Em desenvolvimento"**: `data-go="projetos"` **visível a todos**, sem gate de
`dev_acesso`. As RPCs de leitura/campo (`app_proj_intervencoes`/`_estados`/`_avancos`/`_avancos_iv`/`_docs_listar`/
`_avanco_registrar`/`_estado_set`) passaram a exigir **só autenticação**; as de config de documento (`app_proj_doc_set`/
`_remover`) e de acesso (`app_proj_acesso_*`) seguem no gate **Suporte** = admin **ou** `proj_sup_acesso`. Ou seja, o
campo vê/lança avanços; a **Configuração (Suporte)** continua restrita por `pjPodeSup()`.
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
pelo **tipo de componente** (`pjSel`); toda intervenção abre com **OS SIGOS** (campo numérico, fora do avanço/escopo) seguida da **Autorização de Intervenção de Via** (PDF obrigatório anexado na tela de lançamento, ex-"Alvará"; sem ela não fecha 100%) e as de **HDD** têm os PDFs **Relatório de Furo** e **Relatório de Solda** antes do As Built (2026-10-22/28); a **Licença ambiental saiu** (2026-10-28). **Excluir intervenção** (🗑️ no topo do `projeto_cfg`, Suporte, só sem lançamento → `app_proj_intervencao_excluir`, apaga geometria+estado+docs de forma definitiva, rastro em `intervencoes_audit`); ramal por **OS SIGOS + Hidrômetro** (+ imóvel, as-built A1/A2/A3/P1).
**Documentos:** anexar/abrir/remover ficam **na configuração** (`projeto_cfg`); no `projeto_rel` é **só abrir**.
**Importar intervenções (2026-10):** card em Projetos › 🧰 Suporte (gate `pjPodeSup`) → tela `projeto_import`
(`pjImportInit`) que **lê um `.gpkg` no navegador via sql.js** (cdnjs, lazy), decodifica a geometria GPKG→WKT
(LINESTRING 31983), mapeia atributos (template `id/projeto/cidade/dmc/tipo/dn/tubulacao/situacao_atual/extensao_m`,
com fallback do gpkg cru do WaterGEMS: ZONE→dmc, LENGTH_→extensão, D→dn, MATERIAL→tubulação), prévia + campos
padrão, e grava em `"7 - setorizacao".intervencoes_lineares` via **RPC `app_proj_intervencao_importar(p_rows jsonb)`**
(SECURITY DEFINER, gate admin/`proj_sup_acesso`, idempotente por `id`). Botão **⭳ template CSV** + spec de colunas
na própria tela. Objetivo: o setor de projetos/Suporte importa **sem depender de SQL manual**.
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
