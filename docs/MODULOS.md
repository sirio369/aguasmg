# AcquaHub — Referência granular por módulo

> Documento de **referência profunda** para o Claude do colaborador. O [`CLAUDE.md`](../CLAUDE.md)
> é o ponto de entrada (onboarding, arquitetura, regras). **Este arquivo detalha módulo a módulo**
> para evitar erros ao editar. Leia a seção do módulo que você vai mexer **antes** de tocar no código.
>
> Tudo vive em **um único** `public/index.html` (`<script type="module">`). Os módulos são separados
> por comentários `// ---------- NOME ----------`. Os números de linha abaixo são **aproximados**
> (mudam a cada edição) — use-os como ponto de partida e confirme com busca pelo cabeçalho.

---

## 0. Invariantes que NUNCA podem ser quebrados

1. **`main` = produção.** Push no `main` → deploy automático no Cloudflare. Trabalhe em branch, abra PR.
2. **Toda mudança em `index.html`/`sw.js` exige subir `const CACHE = 'coleta-vN'` em `sw.js`.**
   **Cheque a versão viva antes** (`curl -s https://campo.aguas-mg.workers.dev/sw.js | grep -o 'coleta-v[0-9]*'`)
   e suba para um número **acima** dela. Docs (`.md`) NÃO são servidos pelo Worker → não precisam de bump.
3. **`node --check` no bloco de script e no `sw.js`** antes de commitar (não há build que pegue erro).
4. **Backend:** DDL via `apply_migration`; teste RPC com **rollback E2E** antes de expor; `grant execute`
   a `authenticated`, `revoke` de `anon`/`public`; `notify pgrst, 'reload schema'`.
5. **Nada de segredos no frontend** (`service_role`, `vapid_private`). RLS + RPCs `SECURITY DEFINER`.
6. **PostgREST e overload de RPC:** adicionar/retirar um parâmetro de uma RPC **cria outra função**
   (overload) — o PostgREST fica ambíguo. Para alterar assinatura: **`drop function ...(assinatura antiga)`
   + `create`** (e re-`grant`). Só use `create or replace` quando a assinatura é idêntica.
7. **`execute_sql` (MCP) retorna só o resultado da ÚLTIMA instrução** → combine com `jsonb_build_object`.
8. **Geometria PostGIS = SRID 31983** (UTM, metros). Para o mapa/lat-lon, `ST_Transform(...,4326)`.
   Distância em metros direto com `ST_Distance` (não converta para `geography`).
9. **Aprovação/notificação: um único mecanismo para o app inteiro.** `perfil.aprovador_uuid` /
   `aprovador2_uuid` (configurados no ⚙️ Usuários — home ou Suprimentos, §5.5) + `"9 - suprimentos".sup_aprovadores_de(uid)`
   (fallback: todo `aprovador`/`admin` ativo) + `"9 - suprimentos".sup_notificar(...)` **disparado por
   trigger** `AFTER INSERT/UPDATE` na tabela de negócio — nunca inline na RPC. Regra de ouro:
   notificação **pessoal** (ao próprio interessado) nunca leva `p_exceto`; notificação de **grupo**
   sempre leva `p_exceto = auth.uid()` (ator). **Módulo novo que precisa de aprovação/notificação →
   reaproveite isso, não crie hierarquia paralela.** Ver §5.5 (origem) e §6.4 (segundo uso, Frotas).
10. **Schema = audiência (reorg 2026-09).** Schemas **geo-facing** (`1`–`5`, `7`, `8`) o time de GIS
    conecta o QGIS. Schemas **app-only** (`9`, `10`, `11 - perdas_nrw`, `12 - retaguarda`) **nunca**
    recebem `GRANT USAGE` a papéis `gis_*` — acesso só via RPC `SECURITY DEFINER`. Dado com PII (CPF,
    fotos de documento) ou config/cálculo interno **não** vai pra schema geo. Tabela nova = escolha
    explícita do lado no PR. `"6 - analises"` foi aposentado (`logger_pressao`→`8`, `dmc`→`7`, NRW→`11`).
    **Exceção pontual:** uma tabela *pode* morar num schema geo (ex.: `8`) e ainda assim ser app-only —
    não é o schema que decide sozinho, é ter **RLS habilitada sem policy pra `gis_*`** (ex.:
    `programacao_pesquisa`, `pp_config`, `rede_pp_segmento`/`_fonte`, §4.3): artefato interno do app que
    convive no mesmo schema da rede por conveniência de FK/trigger, mas não é cadastro curado — quem
    precisa ver isso no QGIS usa a vitrine (`vw_gis_programacao_pesquisa`), nunca a tabela crua.

---

## 1. Fundações compartilhadas (todo módulo depende disso)

### Navegação — `// navegação` (~L751)
- `const SCREENS=[...]` lista os `id` de cada `<main>`. **Adicionou tela nova? Inclua o id aqui**,
  senão `irPara` não a exibe/esconde.
- `irPara(id)` esconde todas as telas menos `id`, marca o nav e chama o `init` do módulo
  (`if(id==='loggers') carregarLoggers();` etc.). **Registrou tela nova com init? Adicione o `if`.**
- Botões: `data-go="tela"` navega; `data-back` volta pra `home`. Botões de voltar próprios
  (`#pgBack`, `#mtBack`, `#rlBack`, ...) têm wiring explícito no fim do respectivo módulo.
- **Gates de papel** rodam em `irPara`/no load do `ME`: `homeGate()` (botão Auxiliar de Programação),
  `entInit()` (subdivisões do Entrevistadores). **Cuidado:** a `home` aparece no boot **sem** passar
  por `irPara`, e `ME` carrega assíncrono — por isso o gate também é chamado quando `app_me` resolve
  (ver §Auth). Botão gated novo → siga esse padrão (nasce `hidden`, revela no gate).

### Perfil / papéis — objeto `ME`
- Carregado por `sb.rpc('app_me')` → `ME = {id,nome,email,cargo,funcao,is_admin,is_almoxarife,pode_aprovar,equipes[]}`.
- `funcao ∈ {admin, campo, aprovador, almoxarife, frotas, qsms}`. `pode_aprovar` = aprovador **ou**
  admin. `is_almoxarife` = almoxarife **ou** admin. `frotas` libera o CRUD completo de veículos/equipes
  em **Frotas** (§6); `qsms` libera a tela **QSMS** (agendar/dar baixa em treinamento, §6.3).
- `supGetMe()` (~L2412) carrega sob demanda e faz fallback `campo` se falhar. No login (§Auth) o `ME`
  é carregado globalmente e dispara os gates.
- **Cuidado:** `ME` pode ser `null` no início. Sempre teste `!!(ME&&ME.pode_aprovar)`.

### Envio online/offline — `// envio` (~L533) + `// IndexedDB` (~L527)
- `enviarOuEnfileirar(item, msgOk)`: se online tenta `enviar(item)`; se falhar/offline, grava na fila
  IndexedDB (`store 'fila'`) e sincroniza depois (`sincronizar()`).
- `enviar(item)`: para cada `item.fotos[param]` (Blob) faz upload em
  `storage.from('fotos-campo').upload('<item.pasta>/<item.id>_<param>.jpg')` e seta
  `fields[param] = path`; depois chama `sb.rpc(item.rpc, fields)`.
  - **Regra de ouro das fotos:** a **chave** de `item.fotos` tem que ser **exatamente o nome do
    parâmetro** da RPC (ex.: `p_foto_hd`). Blobs falsy são pulados (foto opcional = ok).
  - `item = {id, tipo, rpc, pasta, fotos:{p_x:Blob}, fields:{...}}`. Se algum `p_x` é **array**
    (`text[]`) em vez de path escalar, acrescente `fotosArray:['p_x', ...]` — `enviar()` envolve o path
    resultante em `[path]` só para esses params (ver Frotas §6.1, primeiro uso).
- `sincronizar()`: erros com `code` SQLSTATE (5 chars) = rejeição de negócio → descarta o item;
  erro de rede → mantém e tenta depois.
- `comprimir(file)` (~L598): reduz p/ ~1600px/JPEG 0.7 antes do upload.

### GPS — `// GPS` (~L579)
- `iniciarGPS()` faz `watchPosition` e atualiza `gps={lat,lon,acc,alt,ts}`; chama os `*OnGps()` de
  cada módulo (`lgOnGps`, `pqOnGps`, `capOnGps`, `asOnGps`, `cadOnGps`). **Módulo com mapa "Você"
  ou validação por GPS → exponha um `xOnGps()` e some na lista.**
- `PRECISAO_MAX` = tolerância; botões de salvar ficam `disabled` até `gps.acc<=PRECISAO_MAX`.

### Fotos e Storage
- Bucket público **`fotos-campo`**; `fotoURL(path)` monta a URL pública (`SBASE + path`).
- Pastas por módulo (`pasta` do item): `pressao`, `logger`, `abertura`, `captacao`, `ocorrencia`,
  `vrp` (upload direto via `vrpUpload`), `epi` (`epiUpload`). Bucket `biblioteca` é separado (PDFs).

### Relatórios PDF — `REL_CSS` / overlay `#relatorio`
- Padrão: monta HTML num overlay `#relatorio` e chama `window.print()` (CSS `@media print`).
  Usado por loggers (§Loggers), VRP, comprovantes de suprimentos e relatório de veículo (§6.2).

---

## 2. Coleta de campo (schema `"8 - coleta_campo"`)

### 2.1 Mapeamento de pressão — `// UI módulo pressão` (~L592) · tela `pressao`
- Leitura de manômetro + foto + GPS. Salva via `app_registrar_pressao` (fila).
- Alvo opcional vindo do Teste de estanqueidade (`prAlvo`). Botões: `#prEst` (estanqueidade), `#prProd`.
- Subtelas: **Estanqueidade** (`estanqueidade`, `// TESTE DE ESTANQUEIDADE` ~L649, RPC
  `app_estanqueidade_listar`, filtro por consórcio) e **Produtividade de pressão** (`pr_prod`,
  `// PRODUTIVIDADE DE PRESSÃO` ~L4093, RPCs `app_pressao_filtros`/`app_pressao_produtividade`).

### 2.2 Loggers temporários — `// MÓDULO LOGGERS` (~L782) · telas `loggers` / `logger_det`
- **Ciclo (situação DERIVADA, não há coluna):** `pendente → instalado → removido ("dados pendentes")
  → concluido`. **Não existe mais** promoção automática após 7 dias.
- **Tabela base:** `"8 - coleta_campo".instalacao_logger_calibracao`. **View:** `vw_loggers`
  calcula `situacao_atual` a partir das datas (`data_instalacao`, `data_remocao`, `data_finalizacao`)
  e `dias_instalado`. **Não crie coluna `situacao`** — mexa no CASE da view.
- **RPCs:** `app_loggers_listar()` (retorna a lista já achatada), `app_logger_criar` (avulso, já
  instalado), `app_logger_instalar`, `app_logger_remover`, `app_logger_finalizar` (anexa .json +
  OS SIGOS), `app_logger_editar(p_id, p_campos jsonb, p_foto_* ...)`, `logger_pressao_importar`,
  `logger_pressao_stats`.
- **Fotos:** instalação = HD, leitura, numeração, cavalete, fachada + **extra** (opcional);
  remoção = HD + cavalete. Params: `p_foto_hd`, `p_foto_leitura_hd`, `p_foto_numeracao_hd`,
  `p_foto_cavalete`, `p_foto_fachada`, `p_foto_extra`. Colunas: `foto_hd_instalacao`,
  `foto_leitura_hd_instalacao`, `foto_numeracao_hd_instalacao`, `foto_cavalete_instalacao`,
  `foto_fachada`, `foto_extra`, `foto_hd_remocao`, `foto_cavalete_remocao`.
- **OS COPASA:** `os_copasa_instalacao/remocao/social` (texto) — editáveis só pelo **lápis**
  (`formEditarLogger`/`salvarEdicaoLogger`), via `p_campos`. `os_sigos` é da finalização.
- **Lápis** (`editarLogger`, gate `pode_aprovar && !p.novo`): edita campos digitados **e** todas as
  fotos (miniatura atual + substituir/adicionar), inclusive as que faltavam em loggers antigos.
  Salva pela fila (`app_logger_editar` com `p_campos` + `p_foto_*` = paths; `coalesce` mantém o que
  não veio).
- **Estado:** `loggersData`, `lgFiltro`, `lgCons`, `detPonto`, `detFotos`, `lgEnviando`, `lgView`,
  `lgMap`, `lgMarkers`. `LG_SIT` (labels/cores por situação), `LG_CONS` (ZA1004/ZA0200).
- **Pressão / ancoragem:** o relógio do logger é **irreal** (arranca na configuração de bancada; só o
  horário/intervalo relativo vale). Regra: `ts_real = ts + (data_instalacao − 1ª leitura com pressão>0)`,
  coluna **`ts_real`** em `"8 - coleta_campo".logger_pressao` (mantém `ts` bruto p/ auditoria). Janela válida
  = **[data_instalacao, data_remocao]** → descarta o zerado de bancada (início) e o pós-remoção (fim).
  A ancoragem roda **no servidor**, dentro do `logger_pressao_importar` (idempotente; há também
  `logger_pressao_reanchor(id)` para reprocessar). `logger_pressao_stats` e a view **`vw_logger_pressao`**
  (BI, tem coluna `codigo`=label ex. J-4285) usam `ts_real` + janela. `volume`/`intervalo_volume_d`
  **não** dependem disso (vêm das leituras de HD + datas).
- **Pressão no corpo do app (não só no PDF):** `logger_pressao_stats` devolve, além dos agregados
  (mín/média/mediana/máx mca+kpa, série), os **contadores de pulso** (`pulsos_total`, `pulsos_com_pressao`,
  `pulsos_sem_pressao`, `intervalo_min` — esperado 15). `lgPressaoBox(stats)`/`lgCarregarPressao(p,elId,cb)`
  renderizam cards + gráfico (`relPressaoSVG`) + nota de pulsos, com estilo inline (não dependem do REL_CSS).
  Usado: (1) na **finalização** (`fzResumo`) — o botão **Concluir só habilita** quando os dados carregam
  (`pulsos_total>0`); (2) no **logger concluído** (`resumo` → `lgResumoPressao`). Logger sem pressão
  (`pulsos_com_pressao=0`) mostra alerta ⚠️.
- **Exportar CSV** (logger concluído): botão `lgExportarCsv(p)` → RPC `app_logger_pressao_export(id)`
  (espelha `vw_logger_pressao`, janela válida, `ts_real` local) → CSV `;`-separado, decimais com vírgula,
  BOM UTF-8 (abre no Excel PT-BR). Arquivo `logger_<codigo>.csv`.
- **Filtro "concluído" segrega dados:** `app_loggers_listar` devolve `tem_pressao` (bool); o sub-filtro
  `#lgSub` (`lgSub`/`renderSubFiltros`/`lgMatchSub`) aparece só no filtro **concluído** com
  **✅ Com dados de pressão** / **⚠️ Sem dados** (+contagens) — torna visível a quantidade de loggers
  com problema. A lista marca "⚠️ sem dados de pressão" nesses.
- **PDF:** `emitirRelatorio(p)` / `relDocHtml(p)` (`// Relatório do ponto` ~L1039) — seções
  Localização (mapa sugerido×instalado), Instalação, Remoção, Finalização, Pressão (SVG de
  `logger_pressao_stats`) + bloco **OS COPASA** sempre visível.
- **Cuidado:** ao adicionar param de foto/campo a `criar`/`instalar`/`editar`, respeite a regra do
  **drop+create** (invariante §0.6) e re-`grant`. E a chave em `item.fotos` = nome do param.

### 2.3 Pesquisa — `// MÓDULO PESQUISA` (~L2067) · telas `pesquisa` / `ocorrencia` / `produtividade`
- Trechos retos (GPS início→fim) + **ocorrências** + produtividade.
- **Ocorrência** (`ocRegistrar`): `app_ocorrencia_registrar` (fila, pasta `ocorrencia`), tabela
  `"8 - coleta_campo".ocorrencia` (campos `tipo`, `local_ref`, `observacao`, `foto`, `lat/lon`,
  `consorcio`, `usuario` texto, `pesquisa_id`, `origem`). Foto obrigatória. É **dado geo**
  (movida de `"12 - retaguarda"` em 2026-09): visível no QGIS via `0 - vitrine_gis.vw_gis_ocorrencia`
  (curada — sem `foto`/`usuario`/gps cru).
- **Importante:** as ocorrências alimentam a **fila de Abertura de serviços** (§Auxiliar de
  Programação) via `app_ocorrencia_fila`/`app_ocorrencia_os` (colunas `os_numero/os_criada_em/os_por`).
- **Produtividade** (`// MÓDULO PRODUTIVIDADE` ~L2200): RPCs `app_pesquisa_filtros`,
  `app_pesquisa_produtividade` (mapa com ocorrências).

### 2.4 VRPs (levantamento de visita) — `// MÓDULO VRP` (~L1552) · telas `vrp` / `vrp_det`
- Baseado em `"2 - infra_agua".vrps`. Situações: `pendente` / `localizada` / `nao_localizada`.
  Formulário dinâmico `VRP_FORM` com condicionais (`show(a)`); ao visitar, ponto visitado abre o
  **resumo read-only + PDF** (`vrpResumo`/`vrpRelatorio`), não novo formulário.
- **RPCs:** `app_vrp_listar`, `app_vrp_visita_registrar`, `app_vrp_visita_ver`. Tabela `vrp_visita`.
  Upload de fotos via `vrpUpload(blob,suf)` (pasta `vrp`).
- **Filtros:** situação, consórcio, busca (nome/código → mapa), e **"Filtro João"** (`VRP_JOAO`,
  conjunto fixo de 57 códigos; `vrpMatchJ`).
- **Estado:** `vrpData, vrpFiltro, vrpCons, vrpView, vrpMap, vrpMarkers, vrpAtual, vrpAns, vrpFotos,
  vrpUltima, vrpEnviando, vrpBuscaTermo, vrpJoao`.
- **`cd_no_agua` visível para o usuário** (não só na busca): na lista (`vrpRenderLista`) aparece ao
  lado do nome da VRP; no mapa (`vrpRenderMapa`) entra no `bindTooltip` (hover). Já vem de
  `app_vrp_listar` — não precisou mudar RPC.

### 2.5 Cadastro técnico — `// CADASTRO TÉCNICO` (~L1821) · tela `cadastro`
- Camadas PostGIS no mapa por bbox: reservatório, booster/bomba, elevatória, poço, macromedição,
  **VRPs**, rede, ligações (`CAD_DEF`). Camadas `whole:true` baixam a ZA inteira 1x; pesadas usam
  `step` (célula de cache).
- **RPCs:** `app_cadastro_geojson` (bbox→GeoJSON, param `p_layer`), `app_cadastro_buscar`,
  `app_limites_zas`. Cache em **IndexedDB** (`cadcache`) versionado por **`CAD_VER`** (`'vN|'`) —
  **mudou dado/camada do cadastro? Suba `CAD_VER` também**, senão o usuário fica com cache velho.
- **Popup genérico:** `onEachFeature` do `cadAtualizar` não tem template por camada — só faz
  `Object.keys(properties).join('<br>')`. Ou seja, **pra aparecer no popup basta a RPC incluir a
  coluna no `jsonb_build_object` das `properties`**; nada a mexer no frontend. Ex.: `cd_no_agua` das
  unidades operacionais (reservatório/booster+bomba/elevatória/poço/macromedição) foi adicionado só na
  RPC (a coluna já existia em `"2 - infra_agua".unidades_operacionais`, só não estava no `SELECT`).
- Marcador **"Você"** (GPS): `cadOnGps()` cria/atualiza `cadVoce` (não é apagado nos redraws de
  `cadAtualizar`, que só mexe em `cadCamadas`).
- **Estado:** `cadMap, cadCamadas, cadOn (visibilidade por camada), cadRendered, cadMem, cadVoce`.

---

## 3. Entrevistadores — tela `entrevistadores`

Reúne funções de campo + a subdivisão **🛟 Suporte**. (A antiga "Retaguarda" foi movida para o
**Auxiliar de Programação**, §4.)

### 3.1 Captação de clientes — `// MÓDULO CAPTAÇÃO` (~L2266) · tela `captacao`
- Questionário schema-driven no array **`CAP_Q`** (`{s:'seção'}` ou `{c:código,l:rótulo,t:tipo,if:cond}`;
  tipos `txt`/`num`/`sn`/`date`/`time`/`sel:Op1|Op2`). Respostas viram jsonb **keyed pelo `c`** via
  `capCollect`. Salva via `app_captacao_registrar` (fila, pasta `captacao`; fotos
  termo/fachada/doc/comprovante). **Obrigatórios** (em `capValidar`): GPS + `_80` (nome) + `906` (CPF/CNPJ).
- **Reformulado (mais enxuto):** removidos hidrômetro (numeração/capacidade/ano/marca/sequencial/dígitos/
  lacrado/leitura/lacres), imóvel localizado, imóvel esq/dir, localização do padrão, situação/classificação
  de água e esgoto (e seus motivos condicionais), ligação tamponada, esgota na rede/PL/coletivo. Categoria
  virou **dois selects** `CAT_AGUA`/`CAT_ESG` (Res|Pub|Ind|Com); Ramo de atividade consolidado num só (`569`);
  "Há suspeita de irregularidades?" (`998`) substituído por `CONX_AGUA` (Cliente conectado água?) e
  `CONX_ESG` (Cliente conectado esgoto?). Economias (`115`–`122`) mantidas.
- **Tabela base:** `"12 - retaguarda".captacao_cliente` (schema *app-only*, contém PII: CPF, fotos de
  documento — **nunca** exposto a GIS; movido de `"8 - coleta_campo"` na reorg de 2026-09).
- ⚠️ **`vw_captacao`** (view achatada p/ BI, agora em `"12 - retaguarda"`) extrai códigos
  específicos do jsonb → **ajustar a view faz parte de qualquer mudança no `CAP_Q`** (senão os códigos
  removidos ficam como colunas mortas e os novos não aparecem). Recriada na migração
  `vw_captacao_ajuste_perguntas` (`569` → `ramo_atividade`; `+categoria_agua/_esgoto` de `CAT_AGUA`/`CAT_ESG`;
  `+cliente_conectado_agua/_esgoto` de `CONX_AGUA`/`CONX_ESG`). Como remove/renomeia colunas, é
  **DROP+CREATE**. Não conceder a `gis_*` (schema 12 não tem `USAGE` pra GIS).

### 3.2 Solicitação de serviços (campo) — `// ABERTURA DE SERVIÇOS` (~L1394) · tela `abertura_servicos`
- Entrevistador pede abertura de OS (tipo, matrícula, HD, foto do HD, GPS). RPC
  `app_abertura_servico_registrar` (fila, pasta `abertura`). "Minhas solicitações":
  `app_abertura_servico_minhas`. Tabela `"12 - retaguarda".abertura_servico` (movida de
  `"8 - coleta_campo"` na reorg de 2026-09; *app-only*, não exposta a GIS).

### 3.3 Roteiro de leitura (Suporte) — `// SUPORTE › ROTEIRO DE LEITURA` (~L1926) · tela `roteiro`
- Mapa por **percurso/trecho** sobre `"8 - coleta_campo".vw_roteiro_leitura` (pontos, 133k) e
  `vw_roteiro_leitura_linha` (linhas). Carrega **1 percurso por vez** (nunca os 133k).
- **RPCs:** `app_roteiro_percursos()` (585, p/ dropdown), `app_roteiro_pontos(p_percurso,p_trecho)`
  (GeoJSON 4326, com `tipo`/`marco`/`trecho`), `app_roteiro_linhas(p_percurso,p_trecho)` (sem
  `matriculas_csv`), `app_roteiro_matricula(p_matricula)` (percurso+coord p/ zoom).
- Pontos por `tipo`: início/fim do percurso (bolinha grande), início/fim de trecho (média), meio
  (pequena). Filtros: percurso, trecho (com contagem de pontos), matrícula. **Export TXT** das
  matrículas filtradas — **só `pode_aprovar`** (`rlExportarTxt`).
- **Estado:** `rlMap, rlPercursos, rlPerc, rlTrecho, rlData, rlOn, rlDestaque`.

---

## 4. Auxiliar de Programação — tela `auxiliar_programacao`

- **Onde:** Home › 🧰 Suporte. **Gate:** só `pode_aprovar`/admin — botão `#homeAuxProg` nasce
  `hidden`, revelado por `homeGate()` (em `irPara('home')` **e** quando `app_me` resolve).
- Hub com dois botões (retaguarda):

### 4.1 Criação de matrículas — `// CRIAÇÃO DE MATRÍCULAS` (~L1504) · tela `matriculas`
- Fila de captações aguardando matrícula. RPCs `app_captacao_fila(p_filtro)` (pendente/criada/todas)
  e `app_captacao_matricula(p_id,p_matricula)`. Back → `auxiliar_programacao`.
- **Exibe TODOS os campos da captação:** `app_captacao_fila` devolve o `respostas` (jsonb) e o card
  renderiza tudo via `mtDetalhe(resp)`, que **percorre o `CAP_Q`** (rótulos + seções) — então segue o
  formulário automaticamente (mudou o `CAP_Q` → o card acompanha, sem lista hardcoded). Não referencie
  campos por código fixo aqui; itere o `CAP_Q`. (A RPC deixou de devolver `imovel_esquerda/direita`.)

### 4.2 Abertura de serviços — `// PROGRAMAÇÃO DE SERVIÇOS` (~L1439) · tela `programacao_servicos`
- Retaguarda lança o **nº da OS criada na COPASA**. **Duas seções**, mesmos filtros
  (pendente=sem OS / criada=com OS / todas):
  1. **Solicitações de serviço** (`#pgLista`): `app_abertura_fila(p_filtro)` +
     `app_abertura_os(p_id,p_os)` → tabela `abertura_servico`.
  2. **Ocorrências — pesquisa de vazamentos** (`#pgOcLista`): `app_ocorrencia_fila(p_filtro)` +
     `app_ocorrencia_os(p_id,p_os)` → tabela `ocorrencia`.
- Ambas gated a `aprovador/admin` **no backend** (a RPC retorna `[]` p/ quem não é).
- **Estado:** `pgFiltro`. Funções: `pgInit` (carrega as duas listas), `pgCarregar`/`pgSalvarOs`,
  `pgCarregarOc`/`pgSalvarOcOs`.

### 4.3 Programação de pesquisa de vazamento — `// MÓDULO PROGRAMAÇÃO DE PESQUISA` (~L2438) · tela `programacao_pesquisa` (dentro de Auxiliar de Programação)

Time interno (aprovador/admin) desenha polígonos de seleção no mapa (estilo QGIS/leaflet-draw) sobre
a rede cadastral e vincula os trechos selecionados a um colaborador de campo. O geofonista vê "sua"
programação na tela **Pesquisa** e ela some conforme ele registra trechos reais; **Produtividade**
cruza cadastro-programado × cadastro-executado × reporte de campo. Rollback point completo (nuke total,
inclui apagar dados reais — não usar como "desfazer última mudança") em
`docs/rollback_fase_a_programacao_pesquisa.sql`; rollback incremental só da Fase E (segmentação, abaixo)
em `docs/rollback_fase_e_segmentacao_pp.sql`.

#### 4.3.1 Segmentação de rede (Fase E, 2026-09-11) — a unidade de trabalho NÃO é a rede cadastral

O cadastro (`"2 - infra_agua".rede`) tem trechos digitalizados de qualquer tamanho — do típico ramal de
poucos metros a **linhas de até 4 km** (17.350 redes; 8.812 com mais de 40 m; mediana das longas ~289 m).
Cruzar "% do trecho coberto pelo trace GPS" contra uma rede de 400 m é ruim pra dois lados: o geofonista
pode ter andado metade da rua e o sistema mostra **tudo pendente** (a agregação não passa do corte), e um
trace real (curva de rua, deslocamento de calçada) tem mais chance de sair do buffer de tolerância ao
longo de um trecho longo.

**Fix:** toda rede é recortada em pedaços de até `pp_config.seg_max_len_m` (padrão **40 m**) — a
Programação de Pesquisa passou a rodar inteiramente sobre esses pedaços, não mais sobre `rede` direto.
"Andei a rua toda" agora fecha pedaço por pedaço conforme o trace avança, em vez de precisar cobrir 50–60%
de uma linha de centenas de metros de uma vez.

- **Tabela `"8 - coleta_campo".rede_pp_segmento`** — `id` (PK), `rede_id` (FK `rede`, **on delete
  cascade**), `seq` (ordem dentro da rede, 0-based), `geom` (`LineString`, pedaço de `rede.geom`),
  `comprimento_m` (generated, `st_length(geom)`), `no_agua_ini`/`no_agua_fim` — só preenchidos no
  **primeiro**/**último** pedaço de cada rede (as pontas reais da rede na topologia; pedaços internos não
  têm nó real). **~46.260 linhas** (backfill de toda `rede`, não só o que está programado hoje).
- **Tabela `"8 - coleta_campo".rede_pp_segmento_fonte`** — 1 linha por `rede_id` já segmentada:
  `geom_hash` (`md5(st_asewkb(rede.geom))` no momento do corte) + `n_segmentos` + `atualizado_em`. É o
  controle de mudança (ver 4.3.2).
- **Ambas as tabelas** têm RLS habilitada **sem policies** (mesmo padrão de `programacao_pesquisa`/
  `pp_config`) — só acessíveis via função `SECURITY DEFINER` (dono); **não são expostas** a
  `gis_visualizacao`/`gis_editor` nem à vitrine GIS (são artefato interno de matching, não cadastro
  curado — a geometria "de verdade" já está em `rede`/`vitrine_gis`).
- **`pp_config.seg_max_len_m`** (default 40) — muda o tamanho do corte; mudar exige rodar
  `"8 - coleta_campo".pp_segmentar_todas(p_forcar:=true)` pra recortar tudo de novo (ver 4.3.2).

#### 4.3.2 Resiliente a reimportação da base de rede — "mantido e rearranjado"

Requisito explícito: se a base de `rede` for trocada (reimport do cadastro COPASA), o trabalho de
recorte **deve se manter** para redes que não mudaram e **se rearranjar sozinho** para as que mudaram —
sem intervenção manual.

- **`"8 - coleta_campo".pp_segmentar_um(p_rede_id, p_forcar default false)`** — a função central,
  **idempotente por hash de geometria**: compara `md5(st_asewkb(rede.geom))` contra o que está gravado em
  `rede_pp_segmento_fonte`; se bate (e `p_forcar=false`), **não faz nada** — preserva os pedaços, suas
  atribuições (`programacao_pesquisa`) e progresso (`coberto_m`/`status`) intactos. Se mudou (ou a rede é
  nova), **apaga** os pedaços antigos daquela rede (o `on delete cascade` de `programacao_pesquisa
  .segmento_id → rede_pp_segmento.id` **derruba junto** qualquer atribuição/progresso amarrado aos
  pedaços antigos — a programação daquela rede específica precisa ser refeita) e recorta de novo com
  `st_linesubstring` em frações iguais (`st_dump`/`st_geometryn` primeiro, pro caso — hoje inexistente —
  de `rede.geom` ter mais de uma parte).
- **Trigger `trg_rede_pp_segmentar`** (`AFTER INSERT OR UPDATE OF geom ON "2 - infra_agua".rede FOR EACH
  ROW`) chama `pp_segmentar_um(new.id)` automaticamente — reimportação (bulk insert/update) ou edição
  manual pelo `gis_editor` disparam o recorte sozinhas, linha a linha, sem esperar um job.
  **`DELETE` não precisa de trigger:** o `on delete cascade` de `rede_pp_segmento.rede_id → rede.id`
  já limpa os pedaços (e cascade novamente sobre `programacao_pesquisa`) quando uma rede é removida.
- **`"8 - coleta_campo".pp_segmentar_todas(p_forcar default false)`** — varre `rede` inteira chamando
  `pp_segmentar_um` pra cada uma; usado no backfill inicial e pra re-sync manual/forçado (ex.: mudou
  `seg_max_len_m`). Testado: mudar a geometria de 1 rede troca só os `id`s dela (novos, sequenciais) e
  não toca em nenhuma outra; deletar uma rede limpa `rede_pp_segmento`+`_fonte` dela via cascade,
  isolado.
- Nenhuma dessas 3 funções está em `public` (não são RPC do PostgREST) — só chamadas via trigger ou
  manutenção direta (MCP/psql). Se algum dia precisar de um botão de "ressincronizar" no app, criar um
  wrapper `public.app_pp_*` fino com gate de admin, igual `app_pp_recruzar` faz pro cruzamento.

#### 4.3.3 Programador — tela `programacao_pesquisa`

- Mapa leaflet-draw (polígono/retângulo) sobre `rede_pp_segmento` (via `app_rede_bbox`, candidatos por
  bbox, **até 10.000** features — subiu de 4.000 porque a mesma área agora tem ~2,7× mais feições curtas
  em vez de menos feições longas) ou seleção livre por polígono (`app_pp_rede_no_poligono`, **até 8.000**,
  idem). Camada de seleção dedicada (`ppSelLayer`) sempre visível por cima, independente de filtro de
  colaborador/data — ver "cuidado" abaixo.
- **Bug corrigido (2026-09-11, mesmo dia da Fase E):** o `limit` de ambas as RPCs vinha **depois** de um
  `jsonb_agg(...)` sem `group by` — nesse formato o SELECT já colapsa pra 1 linha (o agregado), então
  `limit N` só limitava o nº de linhas de *saída* (sempre 1), **não** a quantidade de feições dentro do
  array. Passou despercebido antes da Fase E porque uma área típica tinha poucas centenas/milhares de
  redes inteiras; com a segmentação (~2,7× mais feições pela mesma área), um zoom "de bairro" chegou a
  devolver **12.622 feições numa chamada só** — o mapa do programador travava/não carregava. Fix: `limit`
  movido pra dentro de uma subconsulta, **antes** do agregado (testado: mesma área agora retorna
  exatamente 10.000, não mais ilimitado).
- Vincula (`app_pp_atribuir(p_rede_ids bigint[], p_colaborador, p_sobrescrever)`) / desvincula
  (`app_pp_desatribuir(p_rede_ids bigint[])`) — **`p_rede_ids` continua com esse nome** (zero mudança no
  frontend), mas **os valores agora são `rede_pp_segmento.id`**, não mais `rede.id`. Desvincular
  **deleta** a linha (sem histórico — decisão de produto: reprogramar é comum, "desprogramar" não deixa
  rastro).
- Lista de colaboradores clicável (`app_pp_colaboradores`, inclui o próprio usuário logado) filtra o mapa
  pra "só a programação dele" (`app_pp_por_colaborador`). Botão "✕ Limpar seleção", filtro "não pesquisado
  desde X" (`p_nao_pesquisado_desde` em `app_rede_bbox`), legenda clicável (filtro de status por cor).
- **Resumo** (`app_pp_resumo`) — km programado/executado/% por colaborador (agrega em subquery — `jsonb_agg`
  direto sobre `count(*)` aninhado dá erro de agregado aninhado).
- **Cuidado (histórico, ainda vale):** nunca re-renderize a camada de seleção a partir de uma camada
  base filtrada (por colaborador/data) — se os trechos recém-selecionados não estiverem nessa camada
  filtrada, a seleção "some" visualmente. A seleção vive em `ppSelFeat`/`ppSelLayer`, desenhada direto,
  nunca via re-fetch.

#### 4.3.4 Cruzamento previsto × realizado — `pp_cruzar_trecho()` (trigger) + `pp_recompute()`

- **Trigger `trg_pp_cruzar`** em `INSERT` de `"8 - coleta_campo".pesquisa_trecho` → `pp_cruzar_trecho()`
  acha os `segmento_id` de `rede_pp_segmento` a até `tol_m + 60` do trecho novo e chama
  `pp_recompute(v_ids)` só pra eles (não recalcula a tabela inteira a cada trecho registrado).
- **`pp_recompute(p_segmento_ids bigint[] default null)`** (null = recalcula tudo — usado por
  `app_pp_recruzar` ao mudar config, e pelo backfill/migração da Fase E):
  1. Zera `coberto_m`/`status='pendente'` dos segmentos alvo.
  2. Pra cada `(segmento, trecho)` a até `tol_m` um do outro: `st_dump(st_linemerge(st_intersection(
     st_buffer(trecho, tol_m), segmento.geom)))` — dumpa em pedacinhos, filtra só os **paralelos**
     (diferença de azimute entre o pedacinho e o trecho ≤ `max_ang_deg`, módulo π via
     `a - pi()*floor(a/pi())` — `mod()` não aceita `double precision`), soma o comprimento
     (`st_union` pra não contar sobreposição de 2+ trechos) → `coberto_m`.
  3. Flip pra `executado`: `coberto_m/comprimento_m >= cov_pct` (padrão **0,5**) — ou **`min_len_m`**
     (padrão 12 m: pedaço **menor** que isso precisa **0,90** de cobertura direta, não `cov_pct`, porque
     em comprimentos bem curtos qualquer imprecisão de buffer derruba a razão).
  4. **Herança por vizinho topológico** (só entre pedaços **na ponta real** de redes diferentes,
     via `no_agua_ini`/`no_agua_fim` — pedaços internos não têm nó real, então não entram aqui): coto
     `< min_len_m` sem cobertura direta, mas com vizinho já `executado` compartilhando nó, também vira
     `executado`. Loop de até 5 passadas (propagação em cadeia).
- **Calibração** (Fase D, 2026-09-10, e ajuste de Fase E após dados reais 2026-09-11): comparar o *trecho
  inteiro* (start→end) contra o *segmento inteiro* falha em segmento comprido/curvo — por isso o dump é
  por **sub-parte** da interseção, não do segmento cru. `app_pp_recruzar(p_tol_m, p_cov_pct,
  p_max_ang_deg, p_min_len_m)` (admin, atualiza `pp_config` + chama `pp_recompute(null)`) é a única forma
  suportada de retunar — **não edite `pp_config` direto por fora dela** fora de manutenção excepcional
  (o `NULL` de cada parâmetro preserva o valor atual). **Valores vigentes (2026-09-11, com dados reais de
  campo; `tol_m` subiu de 12→15 no mesmo dia após revisão visual na Produtividade — pedaço pendente
  correndo paralelo a um executado, mesma rua):** `tol_m=15, cov_pct=0.5, max_ang_deg=35, min_len_m=12,
  seg_max_len_m=40`. Diagnóstico que levou
  a esses valores: pedaços "da mesma rua" que ficavam abaixo do corte por pouco (`ratio` 0,30–0,58 com
  `tol_m=8/cov_pct=0,6`) sobem de forma saudável até uns 12–15 m de tolerância; pedaços de rua/ramal
  **diferente** continuam em `ratio` ≈0 mesmo em `tol_m=20` (o filtro de azimute segura) — não tem
  "vazamento" pra rua errada ao afrouxar dentro dessa faixa. Pedaços muito compridos que só foram
  parcialmente andados **plateauam abaixo do corte mesmo em tolerância larga** — isso é o sistema
  reportando a verdade (ainda falta andar), não um bug; a segmentação (4.3.1) já reduz bastante esse
  efeito ao encurtar o denominador da razão.
- **Tabela `pp_config`** (1 linha, `id=1`): `tol_m`, `cov_pct`, `max_ang_deg`, `min_len_m`,
  `seg_max_len_m`, `atualizado_em`. **RLS habilitada sem policies** (corrigido em 2026-09-11 — estava
  com RLS **desligada**, exposta a leitura/escrita direta por `anon`/`authenticated`; nenhum client-side
  do app lê essa tabela direto, só via `app_pp_recruzar`/`pp_recompute`, então a trava não quebra nada).

#### 4.3.5 Tela Pesquisa (geofonista) e Produtividade (análise)

- **Pesquisa** (`pqInit`/`pqCarregarProg`) — camada roxa da programação do próprio usuário
  (`app_pp_minhas`, enquadra o mapa nela na 1ª carga); popup "🧭 Navegar até aqui" (Google Maps); botão
  📍 recentraliza na posição GPS. Após confirmar um trecho, re-consulta com atraso (o cruzamento no
  servidor pode ter virado programado→executado, some do mapa).
- **Produtividade** — toggle **"🔗 Cruzar com a programação da pesquisa"** (`app_pp_mapa(p_colaborador,
  p_consorcio, p_data_ini, p_data_fim, p_usuario)`) — 3 camadas com legenda-filtro clicável (🟣 pendente
  cadastro · 🟢 executado cadastro · 🔴 reporte de campo) + KPIs (km programado/executado/% cobertura/nº
  pendentes). Respeita os filtros de pessoa/data já existentes na tela.
- **RPCs** `app_pp_minhas`/`app_pp_mapa`: propriedade `segmento_id` no GeoJSON (renomeada de `rede_id`
  na Fase E — nenhum código do frontend lia esse campo por nome, só exibia via popup genérico).

---

## 5. Almoxarifado — `// MÓDULO SUPRIMENTOS` (~L2403) · tela `suprimentos` (schema `"9 - suprimentos"`)

**Nome exibido é "Almoxarifado"** (card da home, título, back-button, cabeçalhos de PDF) — mudou de
"Suprimentos" em 2026-09 (só o rótulo; screen id `suprimentos`, funções `sup_*` e o schema
`"9 - suprimentos"` continuam com o nome antigo, não vale a pena renomear isso).

Home própria (`supHome`) com duas seções: **📦 Áreas** (**Insumos**, **Equipamentos**,
**EPI/Uniforme** — sempre visíveis) e, separada, **📋 Conferência** (**Baixas/Conferência**, só
`is_almoxarife`/admin — visualmente apartada das 3 áreas porque não é "mais uma área", é a etapa de
conferência que consolida as outras). `SUP_ACTS` mapeia act→função; `supBlocks*` montam os menus por
papel (`ME`). Navegação interna por `supArea`/`supHome`/`supGoAct`; back inteligente em `#supBack`.
Helpers de papel no banco: `sup_funcao(uuid)`, `sup_e_almox(uuid)`, `sup_pode_aprovar(uuid)`.

### 5.1 Insumos
- Fluxo: **solicitar → aprovar (aprovador pode editar qtd/cancelar item) → segregar (almoxarife:
  existe/parcial/falta, gera código) → retirar (código) → consumir na OS**.
- RPCs: `sup_materiais_listar` (catálogo, **exclui** categoria EPI/EPC), `sup_minhas_solicitacoes`,
  `sup_fila_aprovacao`, `sup_fila_almoxarife`, `sup_segregar`, `sup_meu_estoque`,
  `sup_meus_equipamentos`(equip), `sup_painel_multi` (Painel das equipes: multi-seleção → estoque
  agregado + por equipe + movimentações). Tabelas `sup_solicitacao`/`_item`, `sup_material`,
  `sup_movimento`; **`sup_saldo` é VIEW** (derivada de `sup_movimento` — não dá DELETE).

### 5.2 Equipamentos
- Rastreio por pessoa via **termo de responsabilidade** (fica **vermelho até aceitar, verde depois**,
  botão dentro do próprio termo). Devolução por código; com defeito → manutenção corretiva.
  Preventiva por tipo (dias). Painel por responsável **destaca quebra/defeito**.
- RPCs: `sup_equip_cadastrar`, `sup_equip_tipo_cadastrar`, `sup_equip_tipos_listar`,
  `sup_equip_listar`, `sup_equip_disponiveis`, `sup_equip_solicitacoes_pendentes`,
  `sup_equip_historico`, `sup_termo_ver`, `sup_termo_aceitar`, `sup_minhas_solic_equip`.
  Tabelas `sup_equipamento`, `sup_equip_tipo`, `sup_termo`, `sup_manutencao`, `sup_equip_solicitacao`.

### 5.3 EPI / Uniforme
- Espelha insumo: **solicitar → aprovar (edita/cancela qtd) → separar (almox, gera código, avisa) →
  retirar (código + foto do colaborador com os EPIs + assinatura)**. Devolução/troca por código, com
  fotos. **Tamanho** por escala: `letra` (P/M/G/GG/EXG) ou `numero` (33–48). EPIs saem do catálogo de
  insumos.
- RPCs: `sup_epi_catalogo`, `sup_epi_minhas_solicitacoes`, `sup_epi_fila_aprovacao`,
  `sup_epi_troca_fila_aprovacao`, `sup_epi_fila_segregar`, `sup_epi_segregar`, `sup_epi_fila_entrega`,
  `sup_epi_meus`, `sup_epi_devolver`, `sup_epi_substituir`, `sup_epi_gestao_colaborador(es)`,
  `sup_epi_ficha` (ficha consolidada). Fotos via `epiUpload` (pasta `epi`).
- **Gestão de EPI liberada também por CARGO (2026-09), não só por acesso (`funcao`).** Os cards
  **Aprovar EPI** (`epi_aprovar`) e **EPIs por colaborador** (`epi_painel`) são liberados pra
  aprovador/admin **ou** para quem tem o `perfil.cargo_id` de **Técnico de Segurança do Trabalho**,
  **Técnico de Qualidade** ou **Coordenador de QSMSS** — mesmo com `funcao='campo'`. Função
  `"9 - suprimentos".sup_epi_gestor(uid)` (`sup_pode_aprovar(uid) OR cargo em (...)`, casado por
  **nome** do cargo, não por id — resiliente a recriação de `sup_cargo`) é o gate único, usado por
  `app_me()` (campo `epi_gestor`, refletido em `supBlocksEpi()` no front) e por **todas** as RPCs de
  gestão de EPI (`sup_epi_fila_aprovacao`, `sup_epi_aprovar`, `sup_epi_rejeitar`,
  `sup_epi_troca_fila_aprovacao`, `sup_epi_troca_aprovar`, `sup_epi_troca_rejeitar`,
  `sup_epi_gestao_colaborador(es)`) — trocou o antigo `sup_pode_aprovar(uid)` só nelas. **Escopo é só
  EPI:** `sup_pode_aprovar` continua intocado pra Insumos/Equipamentos (Encarregado normal), não vira
  cargo-based ali.

### 5.4 Baixas / Conferência (almoxarife)
- Consolida entregas por período p/ baixa no **SIENGE**, **por consórcio** (do perfil de quem retirou).
  RPCs: `sup_baixas_relatorio` (5 args, com `p_consorcio`), `sup_baixas_marcar`,
  `sup_epi_baixa_fila`/`_solicitar`/`_cancelar`, `sup_epi_minhas_baixas`.

### 5.5 Configurações (admin) — `// tela: Configurações` (~L3824)
- **Duas entradas, uma tela** (`supAbrirConfig(from)`, `from` = `'home'` | `'epi'`; roda dentro do
  `<main id="suprimentos">` reusando `#supView`):
  - ⚙️ **na home** (`#homeCfg`, ao lado do `<h1>`, `hidden` até `homeGate()` liberar p/ `ME.is_admin`) →
    seção **👤 Usuários**. Clique seta `supCfgPending=true; supCfgFrom='home'` e `irPara('suprimentos')`;
    `supInit()` vê o flag e abre a config em vez da home de Suprimentos. Voltar → `home`.
  - ⚙️ **dentro de EPI / Uniforme** (`#supCfg` da barra, revelado em `supArea('epi')` p/ `ME.is_admin`) →
    seção **🦺 Cargos e cesta de EPI**. Voltar → `supArea('epi')`.
- **Usuários:** acesso (`sup_admin_set_funcao`), cargo (`sup_admin_set_cargo`), **2 aprovadores
  diretos** (`sup_admin_set_aprovadores(uuid,uuid,uuid)`), **consórcio** (`sup_admin_set_consorcio`).
  Filtros no topo (`#cfgUFiltros`, estado `cfgUF={fu,cu,co,ap}`, `supCfgFiltrosRender`): **acesso**,
  **cargo**, **consórcio** e **1º aprovador** — filtragem client-side em `supCfgUsers` (os handlers de
  edição continuam achando o usuário por id em `cfgUsers`, então salvar sob filtro funciona). Cada um
  dos 4 tem uma opção **"— Não preenchido —"** (sentinela `'__VAZIO__'`, `cfgMatch(val,filtro)` trata
  `null`/`''`) pra achar quem está com o campo em branco (ex.: sem cargo, sem consórcio). O select de
  **1º Aprovador** só lista quem **hoje** está de fato como `aprovador_uuid` de alguém (calculado a
  cada render de `cfgUsers`) — não a lista inteira de usuários.
- **Cargos e cesta de EPI:** cestas por cargo (`sup_cesta_*`, `sup_cargos_*`).
- Equipes (`sup_admin_equipe_*`, `sup_admin_membro_*`) seguem como **código morto** (ver §4 abaixo).
- Notificações de aprovação vão só aos aprovadores diretos (`sup_aprovadores_de`).

---

## 6. Frota — schema `"10 - Frotas"` · tela-hub `frota` (+ telas internas `condutor` / `frotas` / `qsms`)

Um público entra por **um só card** na home (🧰 Suporte › **🚗 Frota**, `data-go="frota"`). Fluxo
único: colaborador vira **condutor** (auto-cadastro de CNH → aprovação do gestor → treinamento de
direção defensiva → ativo), **Frotas** (`funcao='frotas'`/admin) cadastra veículos e aprova
ocorrências, **QSMS** (`funcao='qsms'`/admin) agenda e dá baixa nos treinamentos.

### 6.0 Hub `frota` — `// ----- HUB da Frota` (~L4856)
- Estilo Suprimentos/Insumos: `frotaInit` → `frotaHome` renderiza **seções → botões**; `frotaBlocks()`
  monta as seções e o gate de cada uma (seção sem acesso **não aparece**, diferente do `supArea` que
  mostra bloqueada):
  - **👤 Colaborador** (`on:true`, todo usuário): Minha CNH · Situação do veículo · Abastecimento ·
    Registrar ocorrência · Lavagem · Emprestar / meus empréstimos.
  - **🖊️ Gestor** (`ME.pode_aprovar||is_admin`): Aprovar condutores · Aprovar ocorrências ·
    Aprovar manutenções.
  - **🏢 Equipe administrativa** (`funcao='frotas'||is_admin`): Veículos · Equipes · Condutores ·
    Painel e custos.
  - **🦺 QSMS** (`funcao='qsms'||is_admin`): Treinamentos (agendar / baixa).
- **`frotaOpen(id)` é um roteador** — não duplica render. Seta um alvo e chama `irPara`:
  - ações de Colaborador → `condTarget={sub,act}` + `irPara('condutor')`; `condInit` consome o alvo
    depois do load (`condGoTarget`). Ação que depende de veículo: 0 veículos → `toast`; 1 → auto-seleciona;
    2+ → `condRenderPick(sub)` (lista de placas). "Minha CNH" cai na home do condutor (ou no cadastro se
    ainda não existe). "Aprovar condutores" cai na home (a fila já fica no topo).
  - Gestor/Admin → `frotasTarget` (`'home'|'equipes'|'condutores'|'painel'`) + `irPara('frotas')`;
    `frotasInit` consome. Aprovações de ocorrência/manutenção ficam no topo da home de `frotas`.
  - QSMS → `irPara('qsms')`.
- As telas internas `condutor`/`frotas`/`qsms` **não têm mais card na home**; a barra delas volta pro
  hub (`#condBar`/`#frotasBar`/`#qsmsBar` → `irPara('frota')`). Os `‹ Voltar` **internos** das
  sub-telas continuam indo pra home da própria tela (2 níveis de volta). Deep-links de notificação
  (`supGoAct`, §7) continuam apontando direto pra `condutor`/`frotas`/`qsms` — seguem funcionando.

### 6.1 Condutor — `// condutor/frotas/qsms` (~L4275) · tela `condutor`
- **Ciclo de status** (`frota_condutor.status`): `pendente` → (gestor aprova) → `apto` (banner com
  prazo de **10 dias**, `prazo_treinamento`) → (QSMS agenda + dá baixa no treinamento) → `ativo`.
  Reprovação → `reprovado` (`motivo_reprovacao`), pode reenviar.
- **Auto-cadastro:** `condRenderCadastro`/`condSalvarCnh` → `app_condutor_solicitar` (1º envio) ou
  `app_condutor_atualizar_cnh` (já `apto`/`ativo`, ex.: CNH renovada) — mesma assinatura
  `(p_cnh_numero, p_cnh_categoria, p_cnh_validade, p_cnh_foto)`. Foto via `uploadFoto2(...,'cnh')`
  → bucket `fotos-campo` (**mesmo bucket público das fotos de campo** — sem storage dedicado/privado
  para CNH; se isso virar problema de privacidade, é o primeiro lugar a mexer).
- **Histórico da CNH:** as duas RPCs acima **também** inserem uma linha em
  `frota_condutor_cnh_historico` a cada chamada (1ª vez ou atualização) — tabela **append-only**,
  nunca `UPDATE`, mesmo padrão do histórico de aluguel (§6.2). `app_condutor_cnh_historico()` devolve
  o histórico do próprio condutor (`condRenderCnhHistorico`, botão "Histórico" ao lado de "Atualizar
  CNH"). Condutores que já existiam antes desta RPC existir foram **migrados uma vez** (uma linha
  inicial com os dados atuais de `frota_condutor` no momento da migração) — não há como reconstruir
  atualizações anteriores a isso.
- **Ver a própria CNH:** `condRenderHome` mostra link "Ver foto da CNH" (`SBASE+cnh_foto`) quando
  `condData.cnh_foto` existe — mesmo padrão do link que o gestor já via na fila de aprovação
  (`condPendentes`).
- **Alerta de vencimento:** `app_condutor_meu` retorna `cnh_vencendo` (validade ≤ hoje+30) **e**
  `cnh_dias_para_vencer` (`cnh_validade - current_date`, pode ser negativo se já venceu). Exibido
  como banner (com a contagem de dias) em `condRenderHome` quando `status` é `apto`/`ativo`, e como
  texto ao lado da validade sempre que a CNH existe.
- **Aprovação (gestor):** `condPendentes` vem de `app_condutor_pendentes()` — só quem está em
  `sup_aprovadores_de(condutor.id)` (ou admin) vê a lista. Botão liga a `condAprovar` →
  `app_condutor_aprovar(p_condutor_id, p_aprovado, p_motivo)`.
- **Meu veículo / situação / abastecimento / ocorrência / lavagem / empréstimo:** `condVeiculos` =
  `app_frota_veiculos_listar()` (retorno enxuto p/ não-`frotas`: `id,placa,modelo,tipo,km_atual,
  status,consorcio,ultima_lavagem_em,lavagem_atrasada`). Sub-telas `condRenderSituacao`/
  `condRenderAbastecimento`/`condRenderOcorrencia`/`condRenderLavagem` salvam via
  `app_frota_situacao_salvar`/`app_frota_abastecimento_salvar`/`app_frota_ocorrencia_reportar`/
  `app_frota_lavagem_salvar` (tabelas `frota_checklist_situacao`/`frota_checklist_abastecimento`/
  `frota_ocorrencia`/`frota_lavagem`; foto opcional em todas). **`p_consorcio` não é escolhido na
  tela** — vem direto de `v.consorcio` (o veículo, obrigatoriamente vinculado a um consórcio desde o
  cadastro em Frotas, §6.2). **Combustível do abastecimento é filtrado pelo `tipo_combustivel` do
  veículo** (`combustiveisPermitidos(v)`: `flex`→gasolina/etanol, `gasolina`→só gasolina,
  `diesel`→diesel/diesel S10, `outros`/sem cadastro→todas as opções de `COMBUSTIVEIS`).
  **Offline-first** (igual ao resto da coleta de campo, §1) só em situação/abastecimento —
  `condSalvarSituacao`/`condSalvarAbastecimento` montam um `item` e chamam `enviarOuEnfileirar`; `p_fotos`
  de situação é **array** (`text[]`), por isso o `item` leva `fotosArray:['p_fotos']` (convenção nova
  em `enviar()`, ver §1). **Ocorrência e lavagem são online-only** (chamam a RPC direto, sem fila) —
  ação de exceção/manutenção pontual, não tão crítica offline quanto o checklist do dia a dia.
  **Alerta de lavagem atrasada** (`v.lavagem_atrasada`, banner no card do veículo): calculado **na
  leitura**, sem job/cron — `ultima_lavagem_em` (ou a data de início do vínculo, se nunca lavou) ≤
  hoje − 30 dias. Mesmo padrão de `cnh_vencendo` em `app_condutor_meu`.
  **Quem pode agir num veículo agora** é decidido por `"10 - Frotas".condutor_tem_veiculo(uid,
  veiculo_id)` (função SQL nova, reaproveitada em `app_frota_veiculos_listar` — filtro da lista
  enxuta —, `app_frota_abastecimento_salvar`, `app_frota_ocorrencia_reportar` e
  `app_frota_lavagem_salvar`): **titular** (exclusivo/equipe) **enquanto não há empréstimo ativo**, OU
  **quem está com o empréstimo ativo no momento** (`para_condutor_id`). Durante um empréstimo, o
  veículo **some** da lista enxuta de quem emprestou e **aparece** na de quem recebeu — é assim que
  abastecimento/ocorrência/lavagem "deixam de ficar disponíveis pro condutor anterior" (não é um flag,
  é o próprio filtro de listagem). Situação continua **sem** essa checagem (não fazia parte do pedido;
  se precisar, é achatar o mesmo padrão). `app_frota_ocorrencia_reportar` também aceita
  `funcao in ('frotas','admin')` **sem** precisar estar com o veículo (Frotas reporta em qualquer um).
- **Empréstimo:** `condRenderEmprestimo`/`condSalvarEmprestimo` — condutor busca o destinatário por
  e-mail (`app_perfil_por_email`, que devolve `condutor_status`) e chama
  `app_frota_emprestimo_criar(p_veiculo_id, p_para_condutor_id, p_data_inicio, p_data_fim_prevista)`
  — recusa se o destinatário não estiver `apto`/`ativo` (§6.4/gate de condutor). Lista "Meus
  empréstimos" (`app_frota_meus_emprestimos`, campo `sou_recebedor`) mostra "Devolver veículo" só pra
  quem recebeu e está `ativo` (`app_frota_emprestimo_devolver(p_id)`, confirma a devolução). **Retomada
  (titular quer o veículo de volta):** o titular só **solicita** —
  `app_frota_emprestimo_solicitar_devolucao(p_id)` marca `devolucao_solicitada_em` (idempotente, só
  quem é `de_condutor_id` do empréstimo) e dispara notificação pessoal pra quem está com o carro; **a
  devolução em si continua sendo confirmada por quem está com o veículo** — o titular não pode forçar.
  Decisão de produto explícita (não inverter sem confirmar de novo).
- **Estado:** `condSub, condVeiculoSel, condData, condPendentes, condVeiculos, condEmprestimos`.

### 6.2 Frotas — `// condutor/frotas/qsms` (~L4446) · tela `frotas`
- **Gate de tela vs. gate de conteúdo:** todo mundo entra na tela (pra ver ocorrências pendentes se
  for aprovador, ou os próprios veículos se for condutor comum); `frotasRenderHome` decide o conteúdo
  completo (`const full = ME.funcao==='frotas'||ME.is_admin`) — CRUD de veículo/equipe só aparece pra
  `full`. **O backend também gateia** (`app_frota_veiculos_listar` já filtra por função — ver §6.4).
- **Veículo** (`frotasRenderVeiculoEdit`/`frotasSalvarVeiculo` → `app_frota_veiculo_salvar`, 23 params
  incl. dados de locação `fornecedor/contrato_numero/data_inicio/data_fim_prevista`, uso
  `uso_tipo ∈ {equipe,exclusivo}` com `equipe_id` **xor** `condutor_exclusivo_id`, e os campos de
  cadastro: `tipo` (`select` fixo — `TIPOS_VEICULO`: picape/utilitario/hatch/sedan/suv/caminhao/moto),
  `centro_custo` (texto livre), `tipo_combustivel` (`select` fixo — `COMBUSTIVEIS_VEICULO`:
  flex/gasolina/diesel/outros — **vocabulário diferente** do `COMBUSTIVEIS` usado no abastecimento,
  ver §6.1), `motorizacao` (texto livre, ex. "1.6"), `consorcio` (**obrigatório**, `ZA1004`/`ZA0200` —
  validado na RPC mesmo pra edição; os 2 veículos cadastrados antes desta trave em produção precisam
  ser reabertos e salvos uma vez pra ganhar consórcio). `CHECK` de `tipo`/`tipo_combustivel`/`consorcio`
  também no banco (`frota_veiculo_*_check`).
  **Aluguel tem histórico, não é um campo só:** `p_valor_aluguel` da RPC só é usado **na criação**
  (semeia a 1ª linha); reajuste é sempre via `app_frota_veiculo_aluguel_reajustar(p_veiculo_id,p_valor,
  p_vigente_desde)` (nova linha em `frota_veiculo_aluguel_historico`, nunca `UPDATE`). Tela mostra o
  valor atual (`app_frota_veiculos_listar` traz `valor_aluguel_atual`, subquery do último
  `vigente_desde`) + botões "Reajustar" e "Ver histórico" (`app_frota_veiculo_aluguel_historico`).
  Devolução à locadora: `app_frota_veiculo_devolver(p_id, p_data_fim_real, p_valor_devolucao)` (botão
  só aparece se `!data_fim_real`; `prompt()` pede o valor, mesmo padrão de `condAprovar`).
  **`p_fotos` (até 3, `fvfFoto1/2/3` + `wireFotoPick`) e `p_km_inicial`** — `fotos` é `coalesce`ado
  na edição (não envia nada → mantém as fotos atuais; envia → **substitui todas**, não anexa uma a
  uma). `km_inicial` só é gravado **na criação** (semeia também `km_atual`) — não editável depois, é
  um retrato do que o veículo tinha ao entrar no sistema; veículos cadastrados antes disso ficam com
  `km_inicial` nulo, sem como reconstruir retroativamente.
- **Relatório do veículo** (`frotasRelatorioVeiculo`/`frotasRelatorioHtml` → `app_frota_veiculo_relatorio(p_veiculo_id)`,
  botão "📄 Relatório" no card): reaproveita o overlay `#relatorio`/`REL_CSS` compartilhado (§1, mesmo
  padrão de loggers/VRP/comprovantes de Suprimentos) — identificação, locação, km inicial × atual,
  condutor(es) principal(is) (exclusivo, ou membros da equipe), fotos e o **mesmo cálculo de gastos**
  de `app_frota_custos_por_veiculo` (§6.2 "Custos", Fase 6) só que filtrado a **um** veículo — RPCs
  irmãs, lógica duplicada de propósito (SQL não compartilha CTE entre funções sem view/função auxiliar
  extra) — **se mudar a fórmula de custo numa, muda na outra**.
- **Equipe** (`frotasRenderEquipes`/`feqCarregar` → `app_frota_equipe_salvar(p_id,p_nome,p_membros[])`,
  `app_frota_equipes_listar`; tabelas `frota_equipe`/`frota_equipe_membro`). **Não confundir com** a
  seção "Equipes" de Suprimentos ⚙️ Configurações (`sup_admin_equipe_*`) — aquilo é código morto (RPC
  não existe no banco); esta aqui, de Frotas, é real e funcional.
- **Ocorrências** (manutenção/sinistro/multa/lavagem): `frotasRenderOcorrencia` (Frotas) e
  `condRenderOcorrencia` (condutor, §6.1) → mesma RPC
  `app_frota_ocorrencia_reportar(p_veiculo_id,p_tipo,p_descricao,p_valor,p_data_ocorrencia,p_fotos[],
  p_condutor_no_momento_id,p_motivo_infracao)` (tabela `frota_ocorrencia`; os 2 últimos params são
  `default null`, só preenchidos pra `tipo='multa'` — condutores/PRs antigos que não mandam esses 2
  params continuam funcionando). Fila de aprovação `frotasOcorPend` = `app_frota_ocorrencia_pendentes()`
  — só quem está em `sup_aprovadores_de(condutor_exclusivo_do_veiculo || reportado_por)` (ou admin) vê,
  **e é aí que o valor fica visível** — o card de "veículos designados a você" (não-`full`) nunca lista
  ocorrências nem valor. Aprovação: `frotasOcorAprovar` → `app_frota_ocorrencia_aprovar(p_id,
  p_aprovado,p_motivo)`. **Multa** é `tipo='multa'` na mesma tabela, não uma entidade separada:
  `frotasRenderOcorrencia` mostra 2 campos extras só quando `tipo==='multa'`
  (`#ocfMultaWrap`/`toggleMulta`) — e-mail do **condutor no momento da infração** (resolvido via
  `app_perfil_por_email`, guardado em `condutor_no_momento_id` — pode ser diferente do
  `condutor_exclusivo_id` do veículo, ex.: infração durante um empréstimo) e motivo/tipo da infração
  (`motivo_infracao`). Passa pelo mesmo fluxo pendente→aprovado/reprovado de qualquer ocorrência —
  "encaminhar ao gestor para ciência" (pedido da Geovana) é a própria aprovação/reprovação existente,
  não um mecanismo novo.
- **Condutores** (`frotasRenderCondutores` → `app_frota_condutores_listar()`, `frotas`/admin):
  listagem read-only de **todos** os condutores (qualquer status), nome/e-mail/CNH/prazo de
  treinamento/motivo de reprovação. Aprovar continua sendo só na tela **Condutor** (`condPendentes`,
  §6.1) — esta lista aqui é só visibilidade, não duplica a ação de aprovar.
- **Gate de condutor apto/ativo em toda vinculação a veículo:** `app_perfil_por_email` agora também
  retorna `condutor_status` — usado no frontend (`frotasSalvarVeiculo` p/ condutor exclusivo,
  `feqCarregar` p/ membro de equipe, `condSalvarEmprestimo` p/ destinatário do empréstimo) pra barrar
  quem não está `apto`/`ativo` **antes** de chamar a RPC. **A validação de verdade é no backend**
  (`app_frota_veiculo_salvar`, `app_frota_equipe_salvar`, `app_frota_emprestimo_criar`) — o frontend é
  só UX. **Regra do "grandfathering":** a validação só dispara quando o vínculo está **mudando**
  (condutor exclusivo novo/diferente do que já estava salvo; membro **novo** entrando na equipe).
  Reeditar um veículo/equipe **sem trocar** quem já estava vinculado passa direto, mesmo que essa
  pessoa tenha perdido o status depois — senão qualquer edição de um cadastro antigo travaria por causa
  de um vínculo que já existia antes da regra (foi exatamente o caso dos 2 veículos legados sem
  `consorcio`, ver §6.2 acima — teriam ficado impossíveis de corrigir se a checagem fosse incondicional).
  **Cuidado:** `frotasRenderVeiculoEdit`/`frotasSalvarVeiculo` — o campo de e-mail do condutor
  exclusivo **nasce vazio mesmo em edição** (não tem como pré-preencher e-mail a partir do nome que a
  RPC retorna); deixar em branco **mantém** o condutor já vinculado (frontend reusa
  `vExistente.condutor_exclusivo_id`), só troca se alguém digitar um e-mail novo.
- **Manutenção** (tabela própria `frota_manutencao`, **não** é um `tipo` de `frota_ocorrencia` — ciclo
  de vida diferente demais pra caber no `pendente/aprovado/reprovado` simples de ocorrência):
  `frotasRenderManutencao` (botão "🔧 Manutenção" no card do veículo, Frotas registra
  serviço/orçamento/foto do problema) → `app_frota_manutencao_registrar(p_veiculo_id,
  p_servico_solicitado,p_orcamento_valor,p_fotos_antes[])`, status inicial `pendente`. Aprovação do
  orçamento (**antes** do serviço ser feito): `frotasManutPend` = `app_frota_manutencao_pendentes()`
  (mesmo gate `sup_aprovadores_de(condutor_exclusivo||reportado_por)` de ocorrência) →
  `frotasManutAprovar` → `app_frota_manutencao_aprovar(p_id,p_aprovado,p_motivo)`, status vira
  `aprovado`/`reprovado`. **Só dá pra concluir uma manutenção `aprovado`**
  (`app_frota_manutencao_concluir(p_id,p_data_liberacao,p_fotos_conclusao[])` recusa qualquer outro
  status) — ação fica na tela **Painel › Manutenções** (botão "Marcar como concluída" só aparece pra
  `status==='aprovado'`), não no card do veículo, porque normalmente é feita bem depois da aprovação.
- **Painel** (`frotasRenderPainel` → 6 listas: `frotasRenderPainelLista('movimentacoes'|
  'abastecimentos'|'lavagens'|'ocorrencias'|'manutencoes'|'custos')`, `frotas`/admin): histórico
  **completo** de toda a frota (não filtrado por veículo/condutor — é o que falta nas outras telas,
  que só mostram "meu" ou "pendente"). RPCs `app_frota_movimentacoes_listar`,
  `app_frota_abastecimentos_listar`, `app_frota_lavagens_listar`, `app_frota_ocorrencias_listar`,
  `app_frota_manutencoes_listar` (as 2 últimas diferem das RPCs `_pendentes` homônimas: trazem
  **todo** status, não só `pendente`, e não são filtradas por `sup_aprovadores_de` — visão gerencial
  da Frotas, não fila de aprovação pessoal). **"Tempo real" aqui significa só "sempre atualizado
  quando abre a tela"** — sem Supabase Realtime/websocket (decisão de produto confirmada com a
  Geovana: nenhum módulo do app usa isso hoje, não valia o risco/esforço só pra este painel).
  Cadastros de condutor/veículo e status de aprovação **não têm telas próprias no Painel** — já
  existem em §6.2 (lista de veículos) e "Condutores" logo acima.
- **Custos por veículo** (última das 6 fases pedidas): `app_frota_custos_por_veiculo()` soma, por
  veículo, `frota_veiculo_aluguel_historico` (aluguel), `frota_checklist_abastecimento`
  (abastecimento), `frota_lavagem` (lavagem), `frota_manutencao` **só status `aprovado`/`concluido`**
  (orçamento reprovado ou ainda pendente não é custo real) e `frota_ocorrencia` tipo `multa` **só
  status `aprovado`** (mesmo raciocínio), + `valor_devolucao` do próprio veículo. **Aluguel é o único
  cálculo não-trivial**: cada linha do histórico vira um "período" (do próprio `vigente_desde` até o
  `vigente_desde` da próxima linha menos 1 dia — via `lead()` — ou até `data_fim_real`/hoje se for a
  última), e o custo de cada período é `valor * dias/30.44` (mês médio), somado no fim. `aluguel_mensal_atual`
  é simplesmente a linha de `vigente_desde` mais recente — **cuidado ao testar com dados sintéticos**:
  um "reajuste" com `vigente_desde` **anterior** à data em que o veículo foi cadastrado (o seed inicial
  do aluguel usa `current_date`, não `data_inicio` do contrato) inverte a ordem cronológica esperada e
  o valor "mais recente" pode não ser o que se imagina — não é bug da RPC, é o dado ficando
  inconsistente com a realidade. `custo_total` é a soma de tudo. Read-only, sem RPC de escrita nova.
- **Estado:** `frotasSub, frotasVeiculoSel, frotasVeiculos, frotasEquipes, frotasOcorPend,
  frotasManutPend, frotasCondutores, frotasPainelCache`.

### 6.3 QSMS — `// condutor/frotas/qsms` (~L4577) · tela `qsms`
- Tela só pra `funcao='qsms'`/admin (RPCs recusam com `raise exception 'sem permissao'` pra quem não é
  — testado, ver §6.4). `qsmsAptos` = `app_qsms_condutores_aptos()` (condutores `apto` **sem**
  treinamento `agendado` em aberto). Seleciona vários (`qsmsSelCondutores`) → **Agendar treinamento**
  (`qsmsRenderAgendar` → `app_qsms_treinamento_agendar(p_data,p_horario,p_local,p_instrutor,
  p_condutor_ids[])`, cria `frota_treinamento` + 1 linha por condutor em `frota_treinamento_condutor`).
- **Baixa:** `qsmsRenderBaixa` lista os participantes do treinamento selecionado (`qsmsTreinoSel`),
  QSMS marca presença + anexa foto da lista → `app_qsms_treinamento_baixar(p_treinamento_id,
  p_lista_presenca,p_presentes[])`. **Foto da lista de presença é obrigatória** (bloqueada no
  frontend antes do upload **e** validada na RPC — `p_lista_presenca is null` levanta exceção); ao
  contrário da foto de ocorrência/CNH, aqui não existe caminho "salvar sem foto". Isso **atualiza
  `frota_condutor.status='ativo'`** pra quem está em `p_presentes` — é essa `UPDATE` que dispara a
  notificação de "condutor ativo" (via trigger, não é a própria RPC que notifica — ver §6.4). Quem
  faltou continua `apto` (pode ser reagendado).
- **Estado:** `qsmsSub, qsmsSelCondutores, qsmsTreinoSel, qsmsAptos, qsmsTreinos`.

### 6.4 Notificação/aprovação — reaproveita Suprimentos (não é hierarquia própria)
Frotas **não tem** tabela de aprovadores/setor própria — usa exatamente o mecanismo do invariante
§0.9. Todo disparo é por **trigger**, nunca inline nas RPCs `app_*` (que só gravam):
- `"10 - Frotas".trg_frota_condutor()` (`AFTER INSERT/UPDATE` em `frota_condutor`): cadastro novo/reenvio
  → grupo `sup_aprovadores_de(condutor)`; `apto` → pessoal ao condutor + grupo `qsms`/admin; `reprovado`
  → pessoal; `ativo` → pessoal ao condutor + grupo `sup_aprovadores_de(condutor)`.
- `"10 - Frotas".trg_frota_ocorrencia()` (`frota_ocorrencia`, cobre multa também — mesma tabela):
  INSERT → grupo `sup_aprovadores_de(condutor_exclusivo_do_veiculo ?? reportado_por)` + pessoal a
  esse mesmo alvo (se não foi ele quem reportou); UPDATE de status → pessoal ao alvo.
- `"10 - Frotas".trg_frota_manutencao()` (`frota_manutencao`, INSERT/UPDATE): INSERT → grupo
  `sup_aprovadores_de(condutor_exclusivo_do_veiculo ?? reportado_por)` (aprovação de orçamento,
  `p_exceto`=ator); UPDATE de status pra `aprovado`/`reprovado` → **pessoal a `reportado_por`** (quem
  registrou a manutenção — normalmente Frotas, não o condutor do veículo; por isso o alvo da
  notificação de decisão é diferente do alvo usado pra achar o aprovador).
- `"10 - Frotas".trg_frota_emprestimo()` (`frota_emprestimo`, INSERT/UPDATE): INSERT → pessoal a
  `para_condutor_id` (veículo emprestado); UPDATE com `devolucao_solicitada_em` saindo de `null` →
  pessoal a `para_condutor_id` de novo (titular pediu a devolução, §6.1).
- `"10 - Frotas".trg_frota_treinamento_condutor()` (`frota_treinamento_condutor`, só INSERT): pessoal
  ao condutor agendado (data/local/instrutor).
- **Quem aprova o quê:** definido por `perfil.aprovador_uuid`/`aprovador2_uuid` de **cada pessoa**
  (tela de Suprimentos ⚙️ Configurações — não existe tela própria em Frotas). Sem aprovador configurado
  → cai pra todo `aprovador`/`admin` ativo (`sup_aprovadores_de`, fallback).
- **Cuidado ao mexer:** qualquer RPC nova de escrita em Frotas **não deve chamar `sup_notificar`
  diretamente** — crie/edite o trigger da tabela correspondente. Testado via rollback E2E
  (`set_config('request.jwt.claims',...)` trocando de ator no meio da transação) que a exclusão por
  `p_exceto` funciona corretamente mesmo quando o ator é um dos aprovadores do alvo.

### Tabelas (`"10 - Frotas"`)
`frota_veiculo` (locação, uso exclusivo/equipe, cadastro/combustível/consórcio — §6.2),
`frota_veiculo_aluguel_historico` (1 linha por reajuste, nunca `UPDATE` — histórico do aluguel),
`frota_condutor` (PK = `perfil.id`, status/CNH), `frota_condutor_cnh_historico` (append-only, 1 linha
por envio/atualização de CNH — §6.1), `frota_equipe` + `frota_equipe_membro`,
`frota_checklist_situacao`, `frota_checklist_abastecimento`, `frota_lavagem`,
`frota_emprestimo` (+ `devolucao_solicitada_em`, retomada — §6.1),
`frota_ocorrencia` (+ `condutor_no_momento_id`/`motivo_infracao`, multa — §6.2), `frota_manutencao`
(tabela própria, ciclo `pendente→aprovado/reprovado→concluido`, não é ocorrência — §6.2),
`frota_treinamento` + `frota_treinamento_condutor`.

### Cuidados
- **`consorcio` de `frota_veiculo` é `NULL`-ável no banco** (não dá pra travar `NOT NULL` — 2
  veículos reais já cadastrados antes dessa trave ficaram sem valor) mas **obrigatório na RPC**
  `app_frota_veiculo_salvar` pra qualquer criação/edição a partir de agora. Um veículo antigo com
  `consorcio is null` só se resolve quando alguém abrir e salvar ele de novo.
- **Ninguém com `funcao='qsms'` em produção no momento** — card `#cardQsms` só aparece pra admin até
  alguém ser designado (`sup_admin_set_funcao` em Suprimentos ⚙️ Configurações, mesma RPC de sempre).
- Foto de CNH vai pro bucket público `fotos-campo` (mesmo de fotos de campo) — não há bucket
  privado dedicado a documento de identificação.

## 7. Biblioteca — `// MÓDULO BIBLIOTECA` (~L3996) · tela `biblioteca`
- Documentos de referência (PDF) por categoria. Bucket Storage **`biblioteca`** (público; só admin
  sobe). RPCs `biblioteca_listar`, `biblioteca_admin_listar`, `biblioteca_salvar`, `biblioteca_excluir`.

## 8. Avisos / Notificações + Web Push — `// NOTIFICAÇÕES` (~L4212) e `// WEB PUSH` (~L491)
- **Inbox+badge:** `"9 - suprimentos".sup_notificacao`; RPCs `app_notif_contador`/`app_notif_listar`/
  `app_notif_marcar_lidas`; `ntfBadge`/`ntfInit`; `link` é um "act" → `supGoAct(act)` abre a tela.
- **Disparo:** `sup_notificar(destinos[],tipo,titulo,texto,link,exceto)`. Pessoais **sem** `exceto`;
  de grupo **com** `exceto` (exclui o ator).
- **Web Push:** `public.push_subscription` + `public.push_config` (VAPID; privada só `service_role`);
  RPCs `app_push_inscrever`/`app_push_desinscrever`; Edge Function **`push-send`** (header
  `x-push-secret`); trigger em `sup_notificacao` → `pg_net` → `push-send`. **iOS só com PWA instalado.**
  Chave **pública** VAPID no `index.html` (`VAPID_PUBLIC`); privada **nunca** no front. SW v60+.

## 9. Auth — `// auth` (~L4172)
- `sb.auth.getSession()` / `onAuthStateChange` → `mostrar(session)`: mostra o app, `iniciarGPS()`,
  `ntfBadge()`, `pushAutoSync()`, carrega `ME` (`app_me`) e **dispara `homeGate()`**. Logout limpa `ME`.
- **Cuidado:** a `home` é exibida aqui sem `irPara` e `ME` é assíncrono → gates de botão precisam ser
  chamados no `.then` do `app_me` (não só no `irPara`).

---

## 10. Catálogo rápido de RPCs (as efetivamente usadas pelo app)

**Núcleo:** `app_me`, `app_limites_zas`.
**Pressão:** `app_pressao_filtros`, `app_pressao_produtividade`, `app_estanqueidade_listar`.
**Loggers:** `app_loggers_listar`, `app_logger_criar/instalar/remover/finalizar/editar`,
`logger_pressao_importar/stats`.
**Pesquisa/Ocorrência:** `app_pesquisa_filtros`, `app_pesquisa_produtividade`,
`app_ocorrencia_fila`, `app_ocorrencia_os` (registro via `app_ocorrencia_registrar`).
**VRP:** `app_vrp_listar`, `app_vrp_visita_registrar`, `app_vrp_visita_ver`.
**Cadastro:** `app_cadastro_geojson`, `app_cadastro_buscar`.
**Roteiro:** `app_roteiro_percursos/pontos/linhas/matricula`.
**Entrevistadores/Retaguarda:** `app_abertura_fila`, `app_abertura_os`,
`app_abertura_servico_minhas`, `app_captacao_fila`, `app_captacao_matricula`
(registro via `app_abertura_servico_registrar`, `app_captacao_registrar`).
**Suprimentos:** prefixo `sup_*` (ver §5).
**Condutor/Frotas/QSMS (ver §6):**
`app_condutor_solicitar/meu/pendentes/aprovar/atualizar_cnh/cnh_historico`,
`app_frota_veiculos_listar/veiculo_salvar/veiculo_devolver/veiculo_relatorio`,
`app_frota_veiculo_aluguel_reajustar/aluguel_historico`, `app_frota_condutores_listar`,
`app_frota_movimentacoes_listar`, `app_frota_abastecimentos_listar`, `app_frota_lavagens_listar`,
`app_frota_ocorrencias_listar`, `app_frota_manutencoes_listar`, `app_frota_custos_por_veiculo`
(painel gerencial, §6.2),
`app_frota_equipes_listar/equipe_salvar`,
`app_frota_situacao_salvar`, `app_frota_abastecimento_salvar`,
`app_frota_emprestimo_criar/devolver/solicitar_devolucao`, `app_frota_meus_emprestimos`,
`app_frota_lavagem_salvar`,
`app_frota_ocorrencia_reportar/pendentes/aprovar`,
`app_frota_manutencao_registrar/pendentes/aprovar/concluir`,
`app_qsms_condutores_aptos`, `app_qsms_treinamento_agendar/baixar`, `app_qsms_treinamentos_listar`,
`app_perfil_por_email` (helper genérico: busca `perfil` por e-mail, usado por Frotas e por qualquer
módulo que precise resolver destinatário por e-mail).
**Biblioteca:** `biblioteca_*`. **Notificações/Push:** `app_notif_*`, `app_push_*`.

> Assinaturas completas: `select proname, pg_get_function_identity_arguments(oid) from pg_proc p
> join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 1;` (via MCP).

---

## 11. Perdas / NRW — cockpit em **página dedicada** `public/perdas.html`

Cockpit de acompanhamento de perdas (NRW) por DMC. **Não é uma tela `<main>` do `index.html`** — é
uma **página HTML separada** (`public/perdas.html`, autocontida: CSS/JS próprios, SVG nativo, sem
Leaflet). Por isso **não entra no `SCREENS`** nem no `irPara`. Acesso pelo card do hub que faz
`location.href='perdas.html'`.

- **Entrada (hub):** card `#cardPerdas` ("Perdas (NRW)") na seção 🧰 Suporte do `#home`. Nasce
  `class="mod soon"` (opaco). O gate roda em **`homeGate()`** (§1): libera **só** para
  `ME.email === 'sander.sirio@aguasmg.com.br'` (tira `soon`/🔒 e liga `onclick`); os demais ficam
  opacos e o clique dá `toast('Acesso restrito')`. Segue o padrão de gate da §1 (nasce restrito,
  revela no `homeGate` quando `ME` resolve).
- **Guarda na própria página:** ao final de `perdas.html`, um `<script type="module">` cria um cliente
  supabase-js (mesma `SB_URL`/anon key do app), lê `auth.getSession()` e, se o e-mail ≠ Sander (ou sem
  sessão), mantém o overlay `#nrwGate` (🔒). Funciona offline (a sessão vem do `localStorage` do mesmo
  domínio). É gate de **UX/2ª camada**; o enforcement real virá com **RLS** quando os dados saírem de
  snapshot para RPC.
- **Dados:** hoje é **snapshot estático** embutido no HTML (15 DMCs, VRPs projetadas, OS por causa,
  auditoria cadastral, reincidência de ramais — extraídos de `"7 - setorizacao".dmc`/`dmc_resumo`).
  Indicadores de perda (IPD/%NRW/ILI/MNF) ficam "aguardando Qin/faturamento".
  **Próximo passo:** trocar o snapshot por RPCs `app_nrw_*` (a criar) sobre `"7 - setorizacao"` (geometria/
  cadastro DMC) e `"11 - perdas_nrw"` (`parametros_nrw`, `linha_base`, `medicao_entrada`, `consumo_dmc`).
  Reorg de 2026-09: `dmc` foi de `"6 - analises"` (aposentado) → `"7 - setorizacao"`; as tabelas de
  cálculo/config → `"11 - perdas_nrw"` (*app-only*, sem `USAGE` pra GIS).
- **Estrutura (32 itens de navegação em 6 fases):** 1 Visão (Painel, DMCs, Ficha) · 2 Dados & diagnóstico
  (Medições, Consumo, Balanço, MNF, Eventos) · 3 Ação (Plano por DMC, Componentes IWA, HD, Fraude,
  Auditoria, Rede, Ramais, Pressão) · 4 Execução (OS, Renovação, VRPs, Reservatórios, Setorização;
  Parque, Fiscalização, Recuperação, Leitura, Grandes) · 5 Gestão & decisão (Simulador, ELL, Contrato,
  Indicadores) · 6 Configuração (Parâmetros, Governança).
  (removido o subgrupo "Execução — campo & suporte": Pesquisa ativa, Campanhas & step test, Frota de
  loggers, Modelo hidráulico, Balanço energético, Programação de equipes — esses temas já são cobertos
  pelos módulos de campo do próprio AcquaHub, fora do cockpit.)
- **Voltar ao app:** botão fixo `🏠 Voltar ao AcquaHub` no topo da sidebar (fora da `<nav>`, sem
  `data-s` — não entra na lógica de `go()`/`.navi.on`), `onclick="location.href='index.html'"`.
- **Mini-mapas por submódulo:** `miniChoropleth(svgId,legId,tipId,valueFn,label,height)` reaproveita
  `proj`/`pathd`/`centroid`/`scope` do mapa principal — um SVG pequeno por tela, colorido por um valor
  numérico à escolha, com legenda (mín/máx ou "sem dado/plano" quando todo o escopo dá o mesmo valor) e
  clique no setor → `go('ficha')`. Hoje plugado em 6 telas, todas com **dado real já existente** (nada
  fabricado): `rede` (OS/km — `d.osKm`), `pressao_vrp` (redução FAVAD — `VRPMAP`), `auditoria`
  (irregularidades totais — `AUDITMAP`), `ramais` (reincidência agregada por DMC — `RAMBYDMC`, derivado
  de `RAMCAND`), `nrw_os` (OS de vazamento — `d.os`), `nrw_vrp_gestao` (VRPs exist.+proj. — `d.vrpE+d.vrpP`).
  Serve de base pronta para as RPCs `app_nrw_*`: quando o dado virar persistente, só trocar o `valueFn`
  pelo valor vindo do banco — o desenho/legenda/tooltip/clique não mudam.
- **Cuidados:**
  - **`sw.js`:** `perdas.html` está em `ASSETS` e o handler `fetch` trata HTML **por página** (chave
    `./perdas.html` própria — não sobrescreve o cache do `index.html`). Mexeu em `perdas.html`? Suba o
    `coleta-vN` como em qualquer asset.
  - Gate do card ≠ segurança real: qualquer um com a URL abre a página; o overlay + (futuramente) a RLS
    é que restringem. Não colocar segredo no `perdas.html`.
  - Editar o cockpit: o fonte "de trabalho" é o mesmo arquivo; só cuidar do `<head>` próprio
    (doctype+charset) e do overlay `#nrwGate` + guarda no fim ao regerar a partir do mockup.
