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
   `aprovador2_uuid` (configurados no ⚙️ Usuários — home ou Suprimentos, §5.6) + `"9 - suprimentos".sup_aprovadores_de(uid)`
   (fallback: todo `aprovador`/`admin` ativo) + `"9 - suprimentos".sup_notificar(...)` **disparado por
   trigger** `AFTER INSERT/UPDATE` na tabela de negócio — nunca inline na RPC. Regra de ouro:
   notificação **pessoal** (ao próprio interessado) nunca leva `p_exceto`; notificação de **grupo**
   sempre leva `p_exceto = auth.uid()` (ator). **Módulo novo que precisa de aprovação/notificação →
   reaproveite isso, não crie hierarquia paralela.** Ver §5.6 (origem) e §6.4 (segundo uso, Frotas).
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
- **Botões da home menores (2026-09):** override `#home .grid`/`#home .mod`/`#home .mod .ic`/
  `#home .mod .nm` (gap 6px, padding 8px 6px, ícone 19px, rótulo 10,5px) — **só na home**, não mexe em
  `.mod`/`.grid` globais (Frota, área de Almoxarifado etc. continuam do tamanho normal). Motivo: com
  12 cards em grid 2 colunas, o tamanho antigo não cabia numa tela sem rolar (medido 375×667: ~264px
  de sobra). Testado com harness fora do app (mede `getBoundingClientRect` real, sem o `min-height:100%`
  do `.wrap` mascarar a medida) — estes valores dão ~36px de folga no mesmo 375×667.

### Perfil / papéis — objeto `ME`
- Carregado por `sb.rpc('app_me')` → `ME = {id,nome,email,cargo,funcao,is_admin,is_almoxarife,pode_aprovar,equipes[]}`.
- `funcao ∈ {admin, campo, aprovador, almoxarife, frotas, qsms}`. `pode_aprovar` = aprovador **ou**
  admin. `is_almoxarife` = almoxarife **ou** admin. `frotas` libera o CRUD completo de veículos e a
  seção "Equipe administrativa" em **Frotas** (§6). `qsms` **não libera mais nada** (2026-09 — a tela
  que abria foi removida por completo, §6.3); o valor continua existindo só por compatibilidade de
  quem já tinha esse acesso configurado.
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
  `logger_pressao_stats`, `app_logger_set_multiplicador`.
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
- **Multiplicador de pressão (2026-09, só no logger concluído):** card **antes do card "Mínima"**
  (`lgMultCardHtml`), input + botão pequeno **💾 Salvar** — editável só para quem já vê o lápis
  (`ME.pode_aprovar`; demais colaboradores veem o valor aplicado, somente leitura). Padrão **1**.
  Coluna `instalacao_logger_calibracao.multiplicador_pressao` (numeric, `check > 0`), gravada por
  `app_logger_set_multiplicador(p_id, p_multiplicador)` (mesmo gate do lápis: `sup_funcao in
  ('admin','aprovador')`). **O multiplicador entra dentro do próprio cálculo kPa→mca — nunca mexe no
  kPa bruto:** `mca = round(kpa * multiplicador / 9.80665, 4)`. Aplicado em **todo lugar que deriva
  mca a partir do kPa cru**, então salvar atualiza tudo junto, sem passo manual extra:
  `logger_pressao_stats` (cards + gráfico do app + PDF, e devolve o valor atual em `multiplicador`)
  e a view **`vw_logger_pressao`** (CSV `app_logger_pressao_export` e qualquer BI que leia a view —
  ela também expõe a coluna crua `multiplicador_pressao` p/ auditoria). `vw_loggers`/`app_loggers_listar`
  também repassam `multiplicador_pressao`. Salvar recarrega `lgCarregarPressao(...,true)` na hora —
  cards, gráfico e o próprio card do multiplicador atualizam juntos. **Não aparece no PDF** (removido
  2026-09 — o multiplicador é detalhe operacional do app/CSV, não precisa poluir o relatório impresso;
  o número que importa pro relatório, já corrigido, continua nos 4 cards Mínima/Média/Mediana/Máxima).
- **Card "📐 Modelo (previsto)" (2026-09):** card extra logo acima do grid Mínima/Média/Mediana/Máxima
  (`lgCardModelo`, borda tracejada p/ não confundir com dado medido), com o valor de projeto/simulação
  (`instalacao_logger_calibracao.pressao`, já vinha em `p.pressao_modelo` via `app_loggers_listar` —
  não precisou de RPC/coluna nova). Só aparece quando o ponto tem valor de modelo **e** há amostra de
  pressão (`d.n>0`). Em `lgPressaoBox(d, pressaoModelo)`, usado tanto no **logger concluído**
  (`lgResumoPressao`) quanto no **preview de finalização** (`fzResumo`) — comparação lado a lado entre
  previsto e medido nos dois lugares onde a caixa de pressão aparece. **No PDF** (`relPressaoHtml`)
  mora no **tópico 5 · Pressão**, junto dos cards medidos — **saiu do tópico 1 · Localização**
  (2026-09) onde ficava sozinho, sem nada pra comparar do lado.
- **Exportar CSV** (logger concluído): botão `lgExportarCsv(p)` → RPC `app_logger_pressao_export(id)`
  (espelha `vw_logger_pressao`, janela válida, `ts_real` local) → CSV `;`-separado, decimais com vírgula,
  BOM UTF-8 (abre no Excel PT-BR). Arquivo `logger_<codigo>.csv`. **Pressão em 4 colunas (2026-09), pra
  deixar o multiplicador auditável linha a linha:** `Pressao_Inicial_kPa` (bruto, nunca muda) →
  `Multiplicador` → `Pressao_Final_kPa` (=inicial×multiplicador, nova coluna `pressao_final_kpa` na
  view) → `Pressao_Final_mca` (=final_kPa/9,80665 — mesmo valor que já aparecia nos cards/PDF).
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
**EPI/Uniforme**, **Ferramentas** — sempre visíveis) e, separada, **📋 Conferência**
(**Baixas/Conferência**, só `is_almoxarife`/admin — visualmente apartada das 4 áreas porque não é
"mais uma área", é a etapa de conferência que consolida as outras). `SUP_ACTS` mapeia act→função;
`supBlocks*` montam os menus por papel (`ME`). Navegação interna por `supArea`/`supHome`/`supGoAct`;
back inteligente em `#supBack`. Helpers de papel no banco: `sup_funcao(uuid)`, `sup_e_almox(uuid)`,
`sup_pode_aprovar(uuid)`.

### 5.1 Insumos
- Fluxo: **solicitar → aprovar (aprovador pode editar qtd/cancelar item) → segregar (almoxarife:
  existe/parcial/falta, gera código) → retirar (código) → consumir na OS**.
- RPCs: `sup_materiais_listar` (catálogo, **exclui** categoria EPI/EPC **e itens `ferramenta`**),
  `sup_minhas_solicitacoes`, `sup_fila_aprovacao`, `sup_fila_almoxarife`, `sup_segregar`,
  `sup_meu_estoque`, `sup_meus_equipamentos`(equip), `sup_painel_multi` (Painel das equipes:
  multi-seleção → estoque agregado + por equipe + movimentações). Tabelas `sup_solicitacao`/`_item`,
  `sup_material`, `sup_movimento`; **`sup_saldo` é VIEW** (derivada de `sup_movimento` — não dá DELETE).
- **Painel das equipes com drill-down (2026-09):** na tabela de estoque agregado, tocar num item
  abre/fecha (um de cada vez) um painel "Quem tem" logo abaixo, listando colaborador+saldo — cruza o
  `agregado` clicado contra o `por_equipe[].estoque` que a própria RPC já retorna (sem round-trip
  extra). Implementado em `supEstTableDrill(cont,agg,porArr)`, chamado por `supVPainel` no lugar do
  antigo `supEstTable` — **compartilhado com o Painel de Ferramentas** (§5.4), não existe em EPI.
- **Materiais `ferramenta=true` não aparecem aqui** (ver §5.4) — `sup_material` ganhou a coluna
  `ferramenta boolean` (2026-09): 274 itens reclassificados (trena, alicate, cone, escada, talha,
  cadeira/banqueta etc. — cadeira de rodas e fita zebrada ficaram de fora, são insumo/EPC normal).
  `sup_consumir` **bloqueia** consumo de item `ferramenta` com erro explícito ("ferramenta não se
  consome, use a devolução ao almoxarifado"). Outros 38 itens (blindado, biodigestor, EE compacta,
  pórtico, detector de gás, cilindro de calibração, compressores, geradores, marteletes etc.) foram
  **desativados** (`ativo=false`) do catálogo de Insumos para virar `sup_equipamento` cadastrado à mão
  (não migrados automaticamente).

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

### 5.4 Ferramentas (2026-09) — `// ===== FERRAMENTAS =====`
- **4ª área da home, estrutura própria** (Campo/Gestão/Almoxarifado — igual Insumos, não é uma aba
  dentro de Insumos): item reusável (trena, alicate, cone, escada, cadeira/banqueta, talha, cinto de
  segurança etc., ver §5.1) que se **empresta e devolve**, nunca se consome. `supBlocksFerramenta()`
  monta os 3 blocos; ids `ferramenta_*` em `SUP_ACTS`; estado `ferCat`/`ferCartS`.
  - **Campo:** `ferramenta_solicitar` (`supVFerramentaSolicitar`, catálogo `sup_ferramenta_catalogo` +
    `sup_ferramenta_solicitar`) e `ferramenta_pedidos` (`supVFerramentaPedidos` — 3 blocos na mesma
    tela: **estoque atual** com o colaborador via `sup_ferramenta_meu_estoque` + checkbox/qtd por item
    e botão **"Solicitar devolução"**; **devoluções em andamento** com o código de 4 dígitos
    (`sup_ferramenta_minhas_devolucoes`) e opção de cancelar; **histórico de solicitações**
    (`sup_ferramenta_minhas_solicitacoes`), com código de retirada quando `segregada`).
  - **Gestão:** `ferramenta_aprovar` (`supVFerramentaAprovar`, fila `sup_ferramenta_fila_aprovacao` +
    RPCs **compartilhadas** `sup_aprovar`/`sup_rejeitar` — mesma UI de ajuste de qtd/cancelamento de
    Insumos) e `ferramenta_painel` (reaproveita `supVPainel('sup_ferramenta_painel_multi')` — mesma
    função parametrizada do Painel de Insumos, incluindo o drill-down "quem tem" do §5.1).
  - **Almoxarifado:** `ferramenta_almox` (`supVFerramentaAlmox`, fila `sup_ferramenta_fila_almoxarife`
    + `supAlmoxCard`/`supAlmoxWire` **reaproveitados como estão** — chamam `sup_segregar`/`sup_entregar`,
    que são agnósticas de material) e **`ferramenta_recebimento`** (`supVFerramentaRecebimento`, tela
    nova sem equivalente em Insumos: lista `sup_ferramenta_devolucao_fila_recebimento`, almoxarife
    digita o **código de 4 dígitos que o colaborador informa de viva voz** e confirma via
    `sup_ferramenta_devolucao_confirmar` — o código nunca é mostrado nessa tela, só na tela do
    colaborador, pra servir de prova de handoff físico).
- **Dois códigos, dois fluxos simétricos:** retirada usa `codigo_retirada` (padrão já existente de
  Insumos/EPI); devolução usa um `codigo` novo gerado por `sup_ferramenta_devolucao_solicitar` — em
  ambos os casos quem *recebe* fisicamente é quem digita o código pra confirmar (almoxarife entrega
  pedindo o código de retirada; almoxarife recebe pedindo o código de devolução).
- Tabelas novas: `sup_ferramenta_devolucao` (status `solicitada`/`confirmada`/`cancelada`, `codigo`,
  `colaborador_uuid`, `recebido_por`) e `sup_ferramenta_devolucao_item` (`material_id`, `quantidade`).
  Confirmar devolução grava um `sup_movimento` tipo **`devolucao`** negativo (zera o saldo do
  colaborador) — esse valor do enum existia desde sempre mas estava sem uso até este módulo.
- Notificações (`sup_trg_ferramenta_devolucao`, trigger AFTER INSERT/UPDATE em
  `sup_ferramenta_devolucao`): solicitar devolução avisa `almoxarife`+`admin`
  (`link='ferramenta_recebimento'`); confirmar avisa o colaborador (`link='ferramenta_pedidos'`).
- RPCs novas (todas `SECURITY DEFINER`, grants revisados — funções novas nascem com EXECUTE liberado
  pra `PUBLIC` por padrão do Postgres, teve que revogar+regrant `authenticated` explicitamente):
  `sup_ferramenta_catalogo`, `sup_ferramenta_solicitar`, `sup_ferramenta_minhas_solicitacoes`,
  `sup_ferramenta_meu_estoque`, `sup_ferramenta_devolucao_solicitar`, `sup_ferramenta_minhas_devolucoes`,
  `sup_ferramenta_devolucao_cancelar`, `sup_ferramenta_fila_aprovacao`, `sup_ferramenta_fila_almoxarife`,
  `sup_ferramenta_painel_multi`, `sup_ferramenta_devolucao_fila_recebimento`,
  `sup_ferramenta_devolucao_confirmar`.

### 5.5 Baixas / Conferência (almoxarife)
- Consolida entregas por período p/ baixa no **SIENGE**, **por consórcio** (do perfil de quem retirou).
  RPCs: `sup_baixas_relatorio` (5 args, com `p_consorcio`), `sup_baixas_marcar`,
  `sup_epi_baixa_fila`/`_solicitar`/`_cancelar`, `sup_epi_minhas_baixas`.
- **Nunca inclui item `ferramenta`** (fix 2026-09 — tinha ficado de fora do rollout do §5.4): ferramenta
  se empresta/devolve, não é custo consumido, então não faz sentido baixar no SIENGE junto com insumo.
  `sup_baixas_relatorio`'s CTE `ins` filtra `and not m.ferramenta`.

### 5.6 Configurações (admin) — `// tela: Configurações` (~L3824)
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

## 6. Frota — schema `"10 - Frotas"` · tela-hub `frota` (+ telas internas `condutor` / `frotas`)

Um público entra por **um só card** na home (🧰 Suporte › **🚗 Frota**, `data-go="frota"`). Fluxo
**(reformulado 2026-09, 3ª rodada)**: **Frotas** (`funcao='frotas'`/admin) cadastra a CNH do
colaborador → colaborador é avisado e **assina o termo de responsabilidade de condução** (assinatura
eletrônica, igual EPI) → ativo → colaborador **se vincula a um veículo disponível sozinho**
(self-service, tela **Veículos** do próprio Colaborador — não é mais o gestor quem faz isso).
Colaborador faz **checklist diário** (com botão de reportar problema embutido), abastece e
**solicita** lavagem; Frotas **agenda** a lavagem (data/horário/local) e o colaborador confirma a
execução depois. Problema reportado vira **solicitação de manutenção**: colaborador solicita →
gestor aprova → Frotas agenda (data + custo) → Frotas conclui. **Ao terminar de usar o veículo, o
colaborador se desvincula sozinho, liberando-o pra outra pessoa** — **não existe mais empréstimo
como mecanismo separado**: "emprestar" é simplesmente desvincular + a outra pessoa vincular (ver
§6.1). Equipes, ocorrência genérica, aluguel com histórico de reajuste e a etapa de treinamento de
direção defensiva (QSMS) **já haviam sido removidos por completo** numa rodada anterior (ver
§6.3/§6.4 e "Tabelas" abaixo).

### 6.0 Hub `frota` — `// ----- HUB da Frota` (~L4856)
- Estilo Suprimentos/Insumos: `frotaInit` → `frotaHome` renderiza **seções → botões**; `frotaBlocks()`
  monta as seções e o gate de cada uma (seção sem acesso **não aparece**, diferente do `supArea` que
  mostra bloqueada). `frotaInit` também busca `app_frota_meu_veiculo()` (→ `frotaMeuVeiculo`) **antes**
  de renderizar, pra decidir quais botões ficam habilitados:
  - **👤 Colaborador** (`on:true`, todo usuário): Minha CNH (só dados de CNH — não lista mais
    veículos, ver §6.1) · **Veículos** (novo — vincular/desvincular a si mesmo, self-service, §6.1) ·
    Checklist diário · Abastecimento · Registrar problema (manutenção) · Solicitar lavagem — **estes
    últimos 4 ficam desabilitados** (`disabled`, opacidade reduzida) **enquanto `frotaMeuVeiculo` é
    `null`** (colaborador sem veículo vinculado não tem o que fazer neles). **"Emprestar" foi
    removida** — não existe mais como ação própria.
  - **🖊️ Gestor** (`ME.pode_aprovar||is_admin`): **Aprovar manutenções** (tela própria, novo 2026-09
    — antes esse botão levava, por bug, pra tela de Veículos) · **Relatório** (novo aqui — antes era
    "Painel e custos" dentro de Equipe administrativa; virou responsabilidade de quem acompanha/
    aprova, não de quem opera o cadastro, §6.2).
  - **🏢 Equipe administrativa** (`funcao='frotas'||is_admin`): Veículos · Condutores · Lavagens a
    agendar · Manutenções a agendar. **"Histórico" e "Painel"/"Relatório" saíram daqui** (Histórico
    virou um item dentro de Relatório, que foi pro Gestor, ver acima e §6.2).
- **`frotaOpen(id)` é um roteador** — não duplica render. Seta um alvo e chama `irPara`:
  - ações de Colaborador → `condTarget={sub,act}` + `irPara('condutor')`; `condInit` consome o alvo
    depois do load (`condGoTarget`). Ação que precisa de veículo (`situacao`/`abastecimento`/
    `ocorrencia`/`lavagem`) sem `condMeuVeiculo` → `toast` (segunda trava, além do botão desabilitado
    no hub). `veiculos_meu`→`condSub='veiculos'` (tela self-service, §6.1); "Minha CNH" sempre cai na
    home do condutor.
  - Gestor/Admin → `frotasTarget` (`'condutores'|'painel'|'lavagem_fila'|'manutencao_fila'|
    'manutencao_aprovar'`) + `irPara('frotas')`; `frotasInit` consome. **"Histórico" não é mais um
    alvo direto** — só se chega lá de dentro de Relatório ou do Detalhe de um veículo (§6.2).
- As telas internas `condutor`/`frotas` **não têm mais card na home**; a barra delas volta pro
  hub (`#condBar`/`#frotasBar` → `irPara('frota')`). Deep-links de notificação (`supGoAct`, §7)
  apontam pra `condutor`/`frotas` com o alvo certo já setado (ex.: `frota_lavagem_agendar` →
  `frotasTarget='lavagem_fila'`; `frota_manutencao_aprovar` → `frotasTarget='manutencao_aprovar'`,
  corrigido nesta rodada — antes caía sem alvo, mesmo bug do botão do hub).

### 6.1 Condutor — `// condutor/frotas` (~L4275) · tela `condutor`
- **Ciclo de status (reformulado 2026-09)** (`frota_condutor.status`): o **gestor de frota cadastra
  a CNH** (não é mais autocadastro) → `termo_pendente` → colaborador **assina o termo de
  responsabilidade** → `ativo`. Os status `pendente`/`apto`/`reprovado` continuam **válidos no
  `CHECK`** só por compatibilidade com histórico — nenhuma RPC nova os produz. Os 5 condutores reais
  que existiam antes desta mudança (2 `apto`, 3 `ativo`) foram migrados uma vez pra `termo_pendente`
  e notificados a assinar — **nenhum condutor jamais tinha assinado nada antes**, o termo é documento
  novo (decisão registrada aqui: se a intenção era só cobrir daqui pra frente, os 3 que já eram
  `ativo` precisam ser revertidos manualmente).
- **Cadastro pelo gestor:** tela **Frotas › Condutores** (`frotasRenderCondutores`, §6.2) lista
  **todos os colaboradores** (`app_frota_usuarios_completo()`, não só quem já tem CNH) com busca e
  filtros (Todos/Sem CNH/Termo pendente/Ativo/Isento). Clicar abre `frotasRenderCondutorCadastro` →
  `app_frota_condutor_cadastrar(p_uid, p_cnh_numero, p_cnh_categoria, p_cnh_validade, p_cnh_foto)`
  (`funcao in ('frotas','admin')`) — cadastra **ou atualiza** a CNH de qualquer colaborador, sempre
  deixando `status='termo_pendente'` e emitindo um **termo novo** (cancela qualquer termo pendente
  anterior primeiro, pra não acumular). **Isento:** tick `perfil.frota_isento` (`app_frota_isentar`,
  mesmo gate) — marca quem nunca vai dirigir, some da contagem "Sem CNH" sem precisar de linha em
  `frota_condutor`. Foto continua opcional, via `uploadFoto2(...,'cnh')` → bucket `fotos-campo`
  (**mesmo bucket público das fotos de campo** — sem storage dedicado/privado para CNH).
- **Autoatualização (colaborador):** `condRenderCadastro`/`condSalvarCnh` agora só serve pra
  **atualizar** CNH já cadastrada (ex.: renovou) — `app_condutor_atualizar_cnh`, mesma assinatura de
  antes. Também reabre o termo (novo `termo_pendente` + termo novo) — qualquer mudança de CNH exige
  reassinar. **Não existe mais autocadastro inicial** (`app_condutor_solicitar` continua definida no
  banco, mas nada no frontend chama — o ponto de entrada agora é sempre o gestor).
- **Histórico da CNH:** as duas RPCs acima **também** inserem uma linha em
  `frota_condutor_cnh_historico` a cada chamada (1ª vez ou atualização) — tabela **append-only**,
  nunca `UPDATE`, mesmo padrão do histórico de aluguel (§6.2). Ganhou a coluna **`atualizado_por`**
  (2026-09) — antes só o próprio colaborador escrevia aqui, agora pode ser o gestor de frota; sem essa
  coluna não dava pra saber quem de fato registrou aquela versão. `app_condutor_cnh_historico()`
  devolve o histórico do próprio condutor (`condRenderCnhHistorico`, botão "Histórico" ao lado de
  "Atualizar CNH"). Condutores que já existiam antes desta RPC existir foram **migrados uma vez** (uma
  linha inicial com os dados atuais de `frota_condutor` no momento da migração) — não há como
  reconstruir atualizações anteriores a isso.
- **Termo de responsabilidade de condução** (tabela nova `frota_termo`, 1 linha por
  cadastro/atualização de CNH — nunca `UPDATE` de conteúdo, só de `status`): PDF via o mesmo overlay
  `#relatorio`/`REL_CSS` dos loggers/equipamento (`frotaTermoVer`/`frotaTermoHtml`), com **assinatura
  eletrônica em canvas** (não é só clique como o termo de equipamento, §5.2) — reaproveita
  `epiSigInit`/`epiCanvasBlob`/`epiUpload` da retirada de EPI **como estão**, sem duplicar a lógica de
  captura. Vermelho/verde igual ao termo de equipamento (`TERMO_CSS`, compartilhado). `condIrTermo`
  (banner "Minha CNH") abre pra assinar; `condIrTermoVer`/`frCondVerTermo` abrem read-only
  (`canSign=false`) — condutor já ativo, ou gestor conferindo. `app_frota_termo_ver(p_termo_id)` gate:
  o próprio condutor, ou `funcao in ('frotas','admin','aprovador')`. `app_frota_termo_assinar(p_termo_id,
  p_assinatura)`: só o próprio condutor, só termo `pendente` — grava `assinatura_path`, `assinado_em`,
  e **atualiza `frota_condutor.status='ativo'`** (é essa `UPDATE` que dispara a notificação "está
  ATIVO", via trigger — mesma mecânica de antes, só a causa mudou de "treinamento confirmado" pra
  "termo assinado"). Reaproveita a coluna `treinamento_confirmado_em` pra guardar o timestamp da
  assinatura — nome ficou desatualizado (era específico de treinamento), não valeu a pena renomear
  só por isso.
- **Ver a própria CNH:** `condRenderHome` mostra link "Ver foto da CNH" (`SBASE+cnh_foto`) quando
  `condData.cnh_foto` existe.
- **Alerta de vencimento:** `app_condutor_meu` retorna `cnh_vencendo` (validade ≤ hoje+30) **e**
  `cnh_dias_para_vencer` (`cnh_validade - current_date`, pode ser negativo se já venceu). Exibido
  como banner (com a contagem de dias) em `condRenderHome` quando `status==='ativo'`, e como
  texto ao lado da validade sempre que a CNH existe.
- **Checklist diário, abastecimento, problema (manutenção), lavagem — todos no ÚNICO veículo
  vinculado ao colaborador (reformulado 2026-09, 3ª rodada):** `condMeuVeiculo` =
  `app_frota_meu_veiculo()` (objeto único ou `null` — **substitui** o antigo `condVeiculos`/lista;
  desde que um vínculo só pode existir por vez por pessoa, não faz mais sentido escolher entre
  vários). Mesmo formato de antes (`id,placa,modelo,tipo,km_atual,status,consorcio,
  ultima_lavagem_em,lavagem_atrasada`), só que **um objeto, não array** — todas as 4 telas abaixo
  usam esse veículo direto, **sem seletor de placa** (não existe mais `condRenderPick`/
  `condVeiculoSel` — ficaram sem sentido com 1 veículo só por pessoa).
  - **Checklist** (`condRenderSituacao`/`condSalvarSituacao` → `app_frota_situacao_salvar`, tabela
    `frota_checklist_situacao`, **layout refeito 2026-09** — itens do checklist em linhas
    label+checkbox alinhadas dentro de um cartão único, em vez da lista solta de antes; campo
    renomeado de "Avarias / observações" pra só **"Observações"** — continua indo pro mesmo
    `p_avarias` da RPC, só mudou o rótulo, não o schema) ganhou um botão **"🔧 Encontrou um
    problema? Registrar"** que leva direto pra `condSub='ocorrencia'` (o formulário de manutenção,
    ver abaixo) — checklist e problema são passos separados, mas o segundo é um atalho de dentro do
    primeiro.
  - **Registrar problema** (`condRenderOcorrencia`, **reformulado 2026-09** — não existe mais
    "ocorrência" genérica): tipo do problema (`TIPO_PROBLEMA`: pneu furado/freio/motor/elétrica/
    suspensão/bateria/ar-condicionado/vidro-retrovisor/outro — **multa, sinistro e lavagem foram
    removidos da lista**, lavagem virou fluxo próprio abaixo), detalhamento + **foto obrigatória**
    (antes era opcional), **sem campo de valor** (o custo só entra depois, quando Frotas agenda —
    ver §6.2) → `app_frota_manutencao_solicitar(p_veiculo_id,p_tipo_problema,p_servico_solicitado,
    p_fotos_antes[])`, grava direto em `frota_manutencao` com `status='pendente'`. **Não existe mais
    a tabela/RPC de "ocorrência"** — o antigo `app_frota_ocorrencia_reportar` e a tabela
    `frota_ocorrencia` foram **apagados** (estavam sempre vazios, nenhum dado real a preservar).
  - **Lavagem** (`condRenderLavagem`, **reformulado 2026-09**): colaborador só **solicita**
    (`app_frota_lavagem_solicitar(p_veiculo_id)`, sem formulário — nenhum dado a preencher ainda).
    Frotas agenda (data/horário/local, ver §6.2) e notifica; aí o colaborador vê em "🧼 Minhas
    lavagens" (`app_frota_minhas_lavagens`) um botão **"Registrar execução"**
    (`condRenderLavagemRealizar` → `app_frota_lavagem_realizar(p_id,p_valor,p_foto)`, valor/foto
    opcionais) que fecha o ciclo. Tabela `frota_lavagem` ganhou `status`
    (`solicitada→agendada→realizada|cancelada`) + `solicitado_em/agendado_por/data_agendada/
    horario_agendado/local_agendado/realizado_em` — as colunas antigas `data`/`valor`/`foto`
    passaram a significar "da execução", só preenchidas no fim do ciclo.
  - **`p_consorcio` não é escolhido na tela** — vem direto de `v.consorcio` (o veículo,
    obrigatoriamente vinculado a um consórcio desde o cadastro em Frotas, §6.2). **Combustível do
    abastecimento virou lista fixa `COMBUSTIVEIS` (2026-09, 3ª rodada): Etanol/Diesel/Arla** —
    **substitui** a lista antiga (gasolina/etanol/diesel/diesel S10/GNV) filtrada por
    `combustiveisPermitidos(v)`, que foi **removida** (a função não existe mais). Não é mais
    filtrado pelo `tipo_combustivel` do veículo — são só 3 opções fixas pra qualquer veículo.
    `CHECK` do banco (`frota_checklist_abastecimento_tipo_combustivel_check`) atualizado junto.
    **Campo "Posto" removido do formulário** — a RPC ainda aceita `p_posto` (não foi tirado da
    assinatura, quebraria `CREATE OR REPLACE`), mas o frontend sempre manda `null`.
  - **Offline-first** (igual ao resto da coleta de campo, §1) só em checklist/abastecimento —
    `condSalvarSituacao`/`condSalvarAbastecimento` montam um `item` e chamam `enviarOuEnfileirar`;
    `p_fotos` do checklist é **array** (`text[]`), por isso o `item` leva `fotosArray:['p_fotos']`
    (convenção nova em `enviar()`, ver §1). **Problema/manutenção e lavagem são online-only**
    (chamam a RPC direto, sem fila).
  - **Alerta de lavagem atrasada** (`v.lavagem_atrasada`, banner no card do veículo): calculado **na
    leitura**, sem job/cron — última lavagem `realizada` (ou a data de início do vínculo, se nunca
    lavou) ≤ hoje − 30 dias. Mesmo padrão de `cnh_vencendo` em `app_condutor_meu`.
  - **Quem pode agir num veículo agora** é decidido por `"10 - Frotas".condutor_tem_veiculo(uid,
    veiculo_id)` (reaproveitada em `app_frota_meu_veiculo`, `app_frota_abastecimento_salvar`,
    `app_frota_manutencao_solicitar` e `app_frota_lavagem_solicitar`) — **simplificada nesta rodada**
    pra checar só **vínculo aberto** (`frota_veiculo_vinculo`, `desvinculado_em is null`); a
    cláusula de empréstimo-ativo foi removida (empréstimo não existe mais como mecanismo separado,
    ver "Vincular/desvincular" abaixo). Checklist continua **sem** essa checagem no backend (só o
    frontend já auto-seleciona `condMeuVeiculo`). `app_frota_manutencao_solicitar`/
    `app_frota_lavagem_solicitar` também aceitam `funcao in ('frotas','admin')` **sem** precisar de
    vínculo (Frotas solicita em qualquer um).
- **Vincular/desvincular — self-service, substitui empréstimo (reformulado 2026-09, 3ª rodada):**
  tela **Veículos** do Colaborador (`condRenderVeiculos`, `condSub='veiculos'`). **Um veículo só
  pode ter um vínculo aberto por vez, e uma pessoa só pode estar vinculada a um veículo por vez**
  (2 índices únicos parciais em `frota_veiculo_vinculo` — `where desvinculado_em is null` — impedem
  o contrário no banco, não só na RPC). Sem vínculo: `app_frota_veiculos_disponiveis()` lista os
  veículos com `status='disponivel'`; **"Vincular"** chama `app_frota_veiculo_vincular_me(p_veiculo_id)`
  (recusa se o colaborador não estiver `ativo`, ou se o veículo não estiver `disponivel`) — sem
  aprovação, é **imediato**. Com vínculo: mostra o veículo + **"Desvincular"**
  (`app_frota_veiculo_desvincular_me()`) — some o vínculo e o veículo volta a `disponivel`. **Ambas
  as RPCs também fazem o `UPDATE` de `frota_veiculo.status`** (`disponivel⇄em_uso`) como efeito
  colateral do vínculo — não é um campo escolhido à parte. **"Emprestar" não existe mais como ação
  própria** — pra passar o veículo adiante, a pessoa A se desvincula e a pessoa B se vincula; é o
  mesmo mecanismo, só que em dois passos de duas pessoas diferentes, o que também simplificou
  bastante a superfície (nada de status `ativo`/aguardando devolução paralelo ao vínculo). A tabela
  `frota_emprestimo` (1 linha real, histórica) **foi mantida, só ficou sem interface** — ver
  "Tabelas" abaixo.
- **Estado:** `condSub, condMeuVeiculo, condLavagemSel, condData, condMinhasLavagens`.

### 6.2 Frotas — `// condutor/frotas` (~L4446) · tela `frotas`
- **`app_frota_veiculos_listar()` virou admin-only nesta rodada** (`frotas`/admin — antes um
  colaborador comum também conseguia chamar e recebia uma lista enxuta "designada a ele"; isso saiu
  de cena com o self-service de vínculo, §6.1). Quem cai na tela `frotas` sem ser `full`
  (`ME.funcao==='frotas'||ME.is_admin` — ex.: clicando num link de notificação antigo) vê uma
  mensagem genérica encaminhando pra Colaborador/Gestor; `frotasRender` busca o veículo-lista com
  `try/catch` silencioso (`frotasVeiculos=[]` em caso de erro de permissão) pra não quebrar a tela
  nesse caso.
- **Veículos, com filtro no topo e card enxuto (redesenhado 2026-09, 3ª rodada):** a lista
  (`frotasRenderHome`) ganhou filtro por **tipo** (`select` de `TIPOS_VEICULO`) e por **nome do
  condutor vinculado** (busca livre, `_matNorm`, client-side sobre `frotasVeiculos` já carregado —
  sem RPC nova). O card do veículo foi enxugado (placa, status em badge colorido — ver
  `STATUS_VEICULO_LABEL` —, modelo/ano/km, tipo, vinculado/lavagem) e ganhou **um único botão "Ver
  detalhes"** — Editar, Vincular/desvincular, Histórico, Relatório e Devolver à locadora, que antes
  eram 5 botões espremidos no card, **agora moram dentro do Detalhe** (ver abaixo).
- **Veículo, radicalmente simplificado (2026-09):** `frotasRenderVeiculoEdit`/`frotasSalvarVeiculo`
  → `app_frota_veiculo_salvar` (18 params — **caiu de 23**: fora `uso_tipo`/`equipe_id`/
  `condutor_exclusivo_id`/`p_valor_aluguel`). **Foco só em cadastro/lista** — vínculo com pessoa
  virou tela própria (ver "Vincular/desvincular" abaixo), "Equipes" e "Painel"/"Condutores" saíram
  do submenu de Veículos.
  - **`tipo` agora é uma lista fechada de 9 categorias reais de obra** (`TIPOS_VEICULO`, `CHECK`
    `frota_veiculo_tipo_check` no banco): administrativo, basculante tipo toco c/ cabine
    suplementar, retroescavadeira 4x4 c/ concha de 45cm, caminhão pipa, caminhão vácuo, utilitário
    pick-up especial, utilitário pick-up simples, van 10 passageiros, caminhão carroceria 3/4 ou VUC
    c/ cabine suplementar — **substitui** a lista genérica antiga (picape/hatch/sedã/SUV/...). O
    único veículo real (`picape`) foi migrado pra `pickup_simples` na troca.
  - **`centro_custo` virou `select` fechado** (`CENTROS_CUSTO_FROTA`, 33 pares `[código Nível 4,
    descrição Nível 3]` — ex. `['01.001.007.002','GESTÃO DO PROJETO']`). **A regra é usar o código
    completo do item "Equipamentos" (Nível 4), mas mostrar a descrição do pai (Nível 3)** — o Nível 4
    quase sempre se chama só "EQUIPAMENTOS", não identifica nada sozinho. Lista fixa no frontend, sem
    `CHECK` no banco (mudar a lista de centros de custo não deve exigir migração). O único veículo
    real teve o `centro_custo` antigo (texto livre "4.2.8", formato incompatível) **zerado** na
    migração — precisa ser reaberto e salvo de novo com o valor certo do dropdown.
  - **Aluguel removido, só sobra o campo `contrato_numero`** (já existia) — pra vincular ao contrato
    de locação existente. **`app_frota_veiculo_aluguel_reajustar`/`_historico` foram apagados** (a
    tabela `frota_veiculo_aluguel_historico`, com 1 linha real de reajuste, **foi mantida** — só
    ficou desconectada da UI, não tinha por que apagar dado financeiro real).
  - `consorcio` continua **obrigatório** (`ZA1004`/`ZA0200`, validado na RPC e no banco).
  - **`p_fotos` (até 3, `fvfFoto1/2/3` + `wireFotoPick`) e `p_km_inicial`** — sem mudança: `fotos` é
    `coalesce`ado na edição (substitui todas se enviar algo novo); `km_inicial` só gravado na
    criação. Devolução à locadora (`app_frota_veiculo_devolver`) sem mudança.
- **Detalhe do veículo** (`frotasRenderVeiculoDetalhe`, `frotasSub='veiculo_detalhe'`, **novo
  2026-09, 3ª rodada** — abre a partir do botão "Ver detalhes" da lista): identificação/locação/km +
  seção **Vínculo** (mostra quem está vinculado, se alguém, com botão pra gerenciar) + botões
  **Editar** (`veiculo_edit`, mesma tela de sempre), **Histórico** (pré-preenchido com este veículo,
  `frHistBackTo='veiculo_detalhe'` pra o "‹ Voltar" saber pra onde retornar), **Relatório** (mesmo
  overlay de sempre) e **Devolver à locadora** (se ainda não devolvido). É o único lugar de onde se
  chega em "Vincular/desvincular" agora — não tem mais atalho direto no card da lista.
- **Vincular/desvincular — visão admin** (`frotasRenderVinculo`, alcançável só pelo Detalhe do
  veículo acima): **desde o self-service de §6.1, é principalmente um mecanismo de exceção** (o
  colaborador normalmente se vincula/desvincula sozinho) — mas continua existindo pra Frotas
  corrigir situações (colaborador esqueceu de se desvincular, precisa reatribuir manualmente etc.).
  Mostra quem está vinculado com botão **Desvincular** (`app_frota_veiculo_desvincular(p_vinculo_id)`)
  — só aparece o formulário de **Vincular** por e-mail (`app_frota_veiculo_vincular(p_veiculo_id,
  p_condutor_id)`) quando o veículo **não** tem ninguém vinculado (desde a 3ª rodada, só dá pra ter
  **um** vínculo aberto por vez, não mais vários — ver §6.1; as duas RPCs também recusam com
  mensagem clara se o veículo já estiver ocupado ou a pessoa já vinculada em outro lugar, e fazem o
  mesmo `UPDATE` de `status` que a versão self-service).
- **Histórico** (`frotasRenderHistorico`, alcançável pelo Detalhe do veículo **ou** de dentro de
  Relatório, ver abaixo — `frHistBackTo` guarda de onde veio pro "‹ Voltar" certo): busca por
  **veículo** (dropdown) ou por **colaborador** (e-mail), com filtro de período —
  `app_frota_historico_veiculo(p_veiculo_id,p_data_ini,p_data_fim)` /
  `app_frota_historico_condutor(p_condutor_id,p_data_ini,p_data_fim)`. Cada uma junta, numa timeline
  só ordenada por data: vínculo/desvínculo, checklist (com status/km/avarias) e manutenção
  solicitada — **mais empréstimo/devolução histórico**, se o veículo tiver algum registro de antes
  da remoção do mecanismo (§6.1) — é a tela que responde "quem estava com esse veículo em tal data"
  ou "por quais veículos essa pessoa já passou", útil pra investigar sinistro (ver também "Registro
  de checklist" abaixo).
- **Registro de checklist / linha do tempo pra sinistro:** não é uma tela separada — é o próprio
  **Histórico** acima, filtrado por veículo: cada checklist (`frota_checklist_situacao`) aparece na
  timeline com status (`ok`/`com_pendencia`), km e avarias, ao lado de vínculos/empréstimos/
  manutenções do mesmo período — dá pra reconstruir "quem estava com o carro, em que km, com que
  problema reportado" num intervalo de datas.
- **Lavagens a agendar** (`frotasRenderLavagemFila` → `app_frota_lavagem_fila_agendar()`, lista
  `status='solicitada'`) → **Agendar** (`frotasRenderLavagemAgendar` → `app_frota_lavagem_agendar(
  p_id,p_data,p_horario,p_local)`, data e local obrigatórios) — dispara notificação pro colaborador
  (`link='frota_minhas_lavagens'`) com data/horário/local pra ele ir até o ponto de lavagem.
- **Aprovar manutenções** (`frotasRenderManutencaoAprovar`, `frotasSub='manutencao_aprovar'`, tela
  própria do **Gestor** — **corrigido 2026-09, 3ª rodada**: o botão do hub e o link de notificação
  `frota_manutencao_aprovar` caíam os dois, por bug, na tela de Veículos, sem fila de aprovação
  nenhuma visível) → `app_frota_manutencao_pendentes()` (já existia, só não tinha tela própria
  ligada) lista `status='pendente'`, aprovar/reprovar via `app_frota_manutencao_aprovar(p_id,
  p_aprovado,p_motivo)` (RPC sem mudança).
- **Manutenções a agendar** (`frotasRenderManutencaoFila` → `app_frota_manutencoes_agendar_fila()`,
  lista `status='aprovado'`) → **Agendar** (`frotasRenderManutencaoAgendar` →
  `app_frota_manutencao_agendar(p_id,p_data_agendada,p_orcamento_valor)`, data e **custo** obrigatórios
  — é só **aqui** que o valor entra no fluxo, não no reporte do colaborador) → status vira `agendado`.
  Concluir (`app_frota_manutencao_concluir`, exige `status='agendado'` — antes exigia `'aprovado'`)
  fica dentro do Painel › Manutenções, igual antes.
- **Condutores (reformulado 2026-09)** (`frotasRenderCondutores`/`frotasRenderCondutorCadastro` →
  `app_frota_usuarios_completo()`, `frotas`/admin): lista **todo mundo** (`perfil` LEFT JOIN
  `frota_condutor` LEFT JOIN termo mais recente), não só quem já tem CNH — busca por nome/e-mail +
  filtro (Todos/Sem CNH/Termo pendente/Ativo/Isento). Clicar num colaborador abre a mesma tela pra
  cadastrar/atualizar CNH (se ainda não tem) ou ver status + link pro termo (se já tem) — **esta lista
  agora É o ponto de entrada do fluxo**, não só visibilidade (ver §6.1). `app_frota_condutores_listar`
  (a RPC antiga, só condutores já existentes) continua definida no banco mas nada mais chama.
- **Gate de condutor ativo em toda vinculação a veículo:** `app_perfil_por_email` retorna
  `condutor_status` — usado no frontend (`frotasRenderVinculo`, visão admin acima) pra barrar quem
  não está `ativo` **antes** de chamar a RPC. **A validação de verdade é no backend**
  (`app_frota_veiculo_vincular`/`app_frota_veiculo_vincular_me`) — o frontend é só UX.
- **Relatório, com filtros (renomeado + redesenhado 2026-09, 3ª rodada — era "Painel e custos",
  ficava em Equipe administrativa)** (`frotasRenderPainel` → grid de 5 submódulos, estilo `.mod`/
  `.grid` igual o hub — antes era uma lista solta de links de texto: `abastecimentos`, `lavagens`,
  `manutencoes`, `custos`, e **`historico`** — que agora é um item **dentro** de Relatório em vez de
  botão próprio no hub, ver §6.0). **`agora mora na categoria Gestor`**, não mais em Equipe
  administrativa — é uma tela de acompanhamento/auditoria, não de operação do cadastro.
  **"Movimentações (empréstimos)" foi removida da lista** — não sobrava o que mostrar sem o
  mecanismo de empréstimo ativo (§6.1); `app_frota_movimentacoes_listar` (as duas sobrecargas, a
  antiga sem filtro e a com filtro de pp13) foram **apagadas**. Os 3 submódulos restantes com filtro
  (abastecimentos/lavagens/manutenções) ganharam filtro de **veículo** (dropdown), **colaborador**
  (e-mail → resolvido pra uuid via `app_perfil_por_email`) e **período** (`p_data_ini`/`p_data_fim`)
  numa rodada anterior — sem mudança nesta. `PAINEL_CFG` (const) só descreve `{rpc,titulo,row}` por
  tipo; `frotasRenderPainelLista` monta o formulário de filtro + chama `carregar()`.
  **"Tempo real" aqui significa só "sempre atualizado quando busca"** — sem Supabase Realtime.
- **Custos por veículo** (`app_frota_custos_por_veiculo()`, **sem filtro** — visão agregada por
  veículo, dentro de Relatório): soma `frota_checklist_abastecimento` (abastecimento), `frota_lavagem`
  **só `status='realizada'`** (lavagem), `frota_manutencao` **só status `agendado`/`concluido`**
  (é só nesses dois estágios que `orcamento_valor` está de fato preenchido) + `valor_devolucao` do
  próprio veículo. `custo_total` é a soma de tudo. Read-only, sem mudança nesta rodada.
- **Estado:** `frotasSub, frotasVeiculoSel, frVeicFiltroTipo, frVeicFiltroCond, frHistVeiculoSel,
  frHistCondutorSel, frHistBackTo, frLavagemSel, frManutSel, frotasCondutores, frCondBusca,
  frCondFiltro, frCondSel, frotasPainelCache, frPnlFiltro`.

### 6.3 QSMS / treinamento de direção defensiva — **REMOVIDO por completo em 2026-09**
A pedido explícito do usuário ("não deverá haver processo de treinamento de direção defensiva... será
construído em outro momento") — a etapa que existia entre `apto` e `ativo` foi substituída pela
assinatura do termo de responsabilidade (§6.1). **Ao contrário da 1ª rodada da reformulação (que só
tinha desconectado a tela), esta 2ª rodada apagou de fato**: tela (`<main id="qsms">`), todas as
funções `qsms*` do frontend, as 4 RPCs `app_qsms_*`, o trigger `trg_frota_treinamento_condutor` e as
tabelas `frota_treinamento`/`frota_treinamento_condutor` (as 4 linhas de dado real que existiam já
tinham sido substituídas pelo termo assinado retroativo na 1ª rodada — não sobrava nada a preservar).
O link de notificação `qsms_treinamento` (de avisos bem antigos) e o próprio `funcao='qsms'` como
valor de acesso **continuam existindo** no banco (não valia quebrar histórico de notificação por
causa disso), só não abrem mais nada — `supGoAct` não tem mais um `case` pra esse link.
**Se/quando reconstruir:** vai precisar recriar tela, RPCs e tabelas do zero; não reaproveita nada
desta remoção.

### 6.4 Notificação/aprovação — reaproveita Suprimentos (não é hierarquia própria)
Frotas **não tem** tabela de aprovadores/setor própria — usa exatamente o mecanismo do invariante
§0.9. Todo disparo é por **trigger**, nunca inline nas RPCs `app_*` (que só gravam):
- `"10 - Frotas".trg_frota_condutor()` (`AFTER INSERT/UPDATE` em `frota_condutor`): `termo_pendente`
  → pessoal ao condutor ("assine o termo", `link='condutor_termo'`); `reprovado` → pessoal (legado,
  não produzido por nenhuma RPC ativa); `ativo` → pessoal ao condutor + grupo `frotas`/admin.
  **Cuidado que já mordeu uma vez:** a condição precisa cobrir **INSERT e UPDATE** — `termo_pendente`
  é atingido tanto por `INSERT` (1º cadastro, feito pelo gestor) quanto por `UPDATE` (recadastro); um
  trigger que só olha `TG_OP='UPDATE'` deixa o 1º cadastro **sem notificar ninguém** (pego no teste
  E2E antes de ir pra produção).
- `"10 - Frotas".trg_frota_manutencao()` (`frota_manutencao`, INSERT/UPDATE, **reformulado 2026-09**):
  INSERT → grupo `sup_aprovadores_de(reportado_por)` (não depende mais de condutor exclusivo do
  veículo — não existe mais); UPDATE de status → pessoal a `reportado_por` em **`aprovado`**,
  **`reprovado`** (com motivo), **`agendado`** (novo — com a data) e **`concluido`** (novo).
- `"10 - Frotas".trg_frota_lavagem()` (`frota_lavagem`, INSERT/UPDATE): INSERT →
  grupo `frotas`/admin ("lavagem solicitada", `link='frota_lavagem_agendar'`); UPDATE→`agendada` →
  pessoal ao colaborador que solicitou, com data/horário/local (`link='frota_minhas_lavagens'`).
- **Removidos:** `trg_frota_ocorrencia` (tabela apagada), `trg_frota_treinamento_condutor` (tabela
  apagada, §6.3) e, **nesta rodada (2026-09, 3ª)**, `trg_frota_emprestimo` (junto com a função que ele
  chamava) — a tabela `frota_emprestimo` continua existindo (1 linha histórica), só não recebe mais
  `INSERT`/`UPDATE` de nenhuma RPC ativa, então o trigger nunca mais dispararia mesmo que existisse.
- **Quem aprova o quê:** definido por `perfil.aprovador_uuid`/`aprovador2_uuid` de **cada pessoa**
  (tela de Suprimentos ⚙️ Configurações — não existe tela própria em Frotas). Sem aprovador configurado
  → cai pra todo `aprovador`/`admin` ativo (`sup_aprovadores_de`, fallback).
- **Cuidado ao mexer:** qualquer RPC nova de escrita em Frotas **não deve chamar `sup_notificar`
  diretamente** — crie/edite o trigger da tabela correspondente. Testado via rollback E2E
  (`set_config('request.jwt.claims',...)` trocando de ator no meio da transação).

### Tabelas (`"10 - Frotas"`)
`frota_veiculo` (cadastro/combustível/consórcio/contrato — §6.2; **`uso_tipo`/`equipe_id`/
`condutor_exclusivo_id` ficaram sem uso**, ninguém mais escreve neles, não foram dropados; **`status`
agora também é escrito automaticamente por `app_frota_veiculo_vincular(_me)`/
`app_frota_veiculo_desvincular(_me)`** — `disponivel⇄em_uso`, além dos valores manuais
`manutencao`/`baixado`, 2026-09 3ª rodada),
`frota_veiculo_aluguel_historico` (**sem interface própria desde 2026-09** — 1 linha real de reajuste
preservada, não apagada), `frota_veiculo_vinculo` (**nova 2026-09, regra apertada na 3ª rodada:
2 índices únicos parciais (`where desvinculado_em is null`) garantem no máximo 1 vínculo aberto por
veículo E no máximo 1 por pessoa** — antes permitia vários simultâneos por veículo; nenhuma linha
existente violava a regra nova, então a migração foi direta, sem necessidade de fechar vínculos
manualmente), `frota_condutor` (PK = `perfil.id`, status/CNH), `frota_condutor_cnh_historico`
(append-only, + `atualizado_por` desde 2026-09 — §6.1), `frota_termo` (1 linha por termo emitido,
`status` pendente/assinado/cancelado, `assinatura_path` — §6.1), `frota_checklist_situacao`,
`frota_checklist_abastecimento` (**`tipo_combustivel` agora só aceita etanol/diesel/arla, 2026-09 3ª
rodada** — `CHECK` trocado, 0 linhas na tabela no momento da troca, sem migração de dado),
`frota_lavagem` (ganhou `status`/`solicitado_em`/`agendado_por`/`data_agendada`/`horario_agendado`/
`local_agendado`/`realizado_em` — §6.1/§6.2), `frota_emprestimo` (**sem interface própria desde
2026-09, 3ª rodada** — mesmo tratamento do histórico de aluguel: RPCs e trigger apagados, 1 linha
real preservada, virou só leitura via Histórico, §6.2), `frota_manutencao` (ganhou
`tipo_problema`/`data_agendada`, ciclo `pendente→aprovado/reprovado→agendado→concluido` — §6.1/§6.2).
`public.perfil` ganhou `frota_isento` (não é tabela de Frotas mas é usada só por ela).
**Apagadas** (estavam vazias ou já totalmente substituídas, sem dado real a perder):
`frota_equipe`/`frota_equipe_membro` (substituída por `frota_veiculo_vinculo`), `frota_ocorrencia`
(substituída por `frota_manutencao` direto), `frota_treinamento`/`frota_treinamento_condutor`
(substituída pelo termo assinado, §6.3).

### Cuidados
- **`consorcio` de `frota_veiculo` é `NULL`-ável no banco** (não dá pra travar `NOT NULL` — o veículo
  real já cadastrado antes dessa trave ficou sem valor num momento) mas **obrigatório na RPC**
  `app_frota_veiculo_salvar` pra qualquer criação/edição a partir de agora.
- **`centro_custo` do único veículo real foi zerado na migração de 2026-09** (formato antigo "4.2.8"
  incompatível com os códigos novos de 4 níveis) — precisa reabrir e salvar de novo escolhendo do
  dropdown.
- **`funcao='qsms'` não abre mais nada no app** (2026-09) — a tela que ela liberava foi removida
  (§6.3). Quem tiver esse acesso configurado não perde nada de errado, só não tem mais nenhum botão
  extra por causa dele.
- **`"10 - Frotas".condutor_tem_veiculo` estava com `EXECUTE` de `PUBLIC` por padrão do Postgres**
  (função nunca tinha grants explícitos geridos, ao contrário de toda RPC `app_*`) — **sem risco
  real** (função interna, fora do schema `public`, PostgREST não expõe; só chamada de dentro de
  outras `SECURITY DEFINER` que já rodam como `postgres`), mas revogado de `PUBLIC` e concedido só a
  `postgres` nesta rodada por higiene — encontrado na varredura de grants de rotina após mexer na
  função (§0, invariante de grants).
- Foto de CNH e assinatura do termo vão pro bucket público `fotos-campo` (mesmo de fotos de campo) —
  não há bucket privado dedicado a documento de identificação.

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
**Condutor/Frotas (ver §6, reformulado 2026-09 — self-service de vínculo substitui empréstimo):**
`app_condutor_meu/atualizar_cnh/cnh_historico`,
`app_frota_usuarios_completo`, `app_frota_condutor_cadastrar`, `app_frota_isentar`,
`app_frota_termo_ver/assinar` (termo de responsabilidade, substitui aprovação+treinamento),
`app_frota_veiculos_listar/veiculo_salvar/veiculo_devolver/veiculo_relatorio` (`veiculos_listar`
**admin-only** desde a 3ª rodada — veículo simplificado, sem uso/equipe/exclusivo/aluguel,
`tipo`/`centro_custo` viraram lista fechada, §6.2),
`app_frota_meu_veiculo`, `app_frota_veiculos_disponiveis`, `app_frota_veiculo_vincular_me`,
`app_frota_veiculo_desvincular_me` (self-service — colaborador vincula/desvincula a si mesmo, sem
aprovação, **novas 2026-09 3ª rodada**, §6.1),
`app_frota_veiculo_vincular/desvincular` (mesmo vínculo pessoa↔veículo, visão **admin** de exceção —
só quando o veículo já não está ocupado por ninguém, §6.2),
`app_frota_historico_veiculo/historico_condutor` (timeline p/ investigação de sinistro, §6.2),
`app_frota_abastecimentos_listar`, `app_frota_lavagens_listar`, `app_frota_manutencoes_listar` (com
filtro de veículo/condutor/data), `app_frota_custos_por_veiculo` (Relatório, §6.2),
`app_frota_situacao_salvar`, `app_frota_abastecimento_salvar`,
`app_frota_lavagem_solicitar/fila_agendar/agendar/realizar`, `app_frota_minhas_lavagens` (ciclo
solicitar→agendar→confirmar, §6.1/§6.2),
`app_frota_manutencao_solicitar/pendentes/aprovar/agendar/concluir`, `app_frota_manutencoes_agendar_fila`
(ciclo solicitar→aprovar→agendar-com-custo→concluir, substitui "ocorrência" pra qualquer problema
mecânico, §6.1/§6.2),
`app_perfil_por_email` (helper genérico: busca `perfil` por e-mail, usado por Frotas e por qualquer
módulo que precise resolver destinatário por e-mail).
**Removidas por completo** (não há mais linha no banco): `app_frota_veiculo_aluguel_
reajustar/aluguel_historico`, `app_frota_equipes_listar/equipe_salvar`, `app_frota_ocorrencia_
reportar/pendentes/aprovar`, `app_frota_ocorrencias_listar`, `app_qsms_*` (condutores_aptos,
treinamento_agendar/baixar, treinamentos_listar), e, **nesta rodada (2026-09, 3ª)**:
`app_frota_emprestimo_criar/devolver/solicitar_devolucao`, `app_frota_meus_emprestimos`,
`app_frota_movimentacoes_listar` (as duas sobrecargas). **Legado, ainda no banco mas sem chamador no
frontend:** `app_condutor_solicitar/pendentes/aprovar`, `app_frota_condutores_listar` (substituídas
pelo fluxo de cadastro-pelo-gestor).
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
