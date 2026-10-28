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
   (fallback: todo `aprovador`/`admin` ativo) — que define **quem é avisado E quem pode aprovar** (fila/aprovar/rejeitar
   checam `"9 - suprimentos".sup_e_aprovador_de(aprovador, solicitante)`, §5.0) + `"9 - suprimentos".sup_notificar(...)` **disparado por
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
11. **Consórcio de um registro de campo não vem do `localStorage 'consorcio'`** — esse valor só é gravado
    pela tela de Pressão (quem nunca lançou pressão manda `null`). Resolva **no servidor**: ZA do ponto
    (`"1 - suporte_geografico".limite_za`) → valor do app → `perfil.consorcio` (ex.: `app_pav_registrar`, §2.6;
    `app_abertura_servico_registrar`, §3.2; `app_ocorrencia_registrar`, §2.3). O perfil fica por último: a mesma
    pessoa atende as duas ZAs. Pior que `null` é o valor **errado**: na ocorrência da pesquisa 8/19 estavam na ZA
    oposta ao ponto (o aparelho tinha o consórcio da última Pressão).

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
- `ME.qsms` (2026-10-28) = acesso à gestão **QSMS · Segurança do Trabalho** (§18): admin, engrenagem
  `perfil.qsms_acesso` ou cargo de QSMS (`"16 - qsms".qsms_pode`). Não tem relação com `funcao='qsms'`.
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
  - **Número variável de arquivos** (assinaturas): `item.anexos={chave:Blob}` + `anexosParam` (default
    `p_anexos`) → cada Blob sobe como `<pasta>/<id>_<chave>.jpg` e a RPC recebe **um jsonb** `{chave: path}`
    (Segurança do Trabalho §18, primeiro uso). Canvas de assinatura → JPEG com fundo branco antes (`segSigJpeg`).
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

### Mapas — camada base rua/satélite (2026-09, novo) — `mapAddCamadaBase(map,tileOpts,ctlPos)`
- **Todo mapa Leaflet do app** (9 instâncias: Estanqueidade `estMap`, Loggers `lgMap`, VRP `vrpMap`,
  Cadastro técnico `cadMap`, Roteiro de leitura `rlMap`, Pesquisa `pqMap`, Produtividade `prodMap`,
  Programação de pesquisa `ppMap`, Produtividade de pressão `prpMap`) passou a chamar essa função em
  vez de montar seu próprio `L.tileLayer(...).addTo(map)` — antes só existia OpenStreetMap, sem opção
  de satélite. A função cria as duas camadas (`rua` = OpenStreetMap, `sat` = Esri World Imagery,
  `https://server.arcgisonline.com/.../World_Imagery/...`, grátis, sem chave/custo) e adiciona um
  **botão pequeno** (`L.Control` customizado, mesmo padrão do botão "📍" de `pqMap`) que alterna entre
  as duas com um toque só (`🛰️`↔`🗺️`) — **decisão deliberada**: cogitou-se usar o `L.control.layers`
  nativo do Leaflet (painel expansível com nomes), mas um botão de toque único é mais rápido em campo
  (uma mão, sem abrir painel primeiro).
- **Assinatura:** `tileOpts` (opcional) repassa opções extras pras DUAS camadas — hoje só usado por
  `ppMap`, que já dimia o OSM (`opacity:.55`, pro traçado de rede colorido por cima se destacar) e
  precisa da mesma opacidade no satélite. `ctlPos` (opcional, default `'topright'`) posiciona o botão —
  só `ppMap` passa `'topleft'`, porque `'topright'` já tem a barra de desenho (`L.Control.Draw`) daquele
  módulo; **cuidado ao adicionar controle novo num mapa existente:** confira que posição já está
  ocupada antes de deixar no default.
- **Mapa novo no futuro → sempre chame esta função**, nunca `L.tileLayer(...).addTo(map)` direto — é
  assim que o toggle satélite continua valendo pra tudo sem precisar lembrar módulo por módulo.

### Mapas — contorno das ZAs (2026-09-15) — `mapAddLimiteZA(map)`
- Desenha o **limite das ZAs** (contorno tracejado, não-interativo, sob os dados) pra ajudar a delimitar
  as áreas de cada consórcio. Chamado logo após `mapAddCamadaBase` nos mapas de **Pesquisa** (`pqMap`),
  **Produtividade** (`prodMap`), **Acompanhamento** (`paMap`) e **Programação** (`ppMap`).
- Fonte: RPC `app_limite_za(p_consorcio default null)` → `"1 - suporte_geografico".limite_za` (2 polígonos:
  ZA0200 Betim / ZA1004 Contagem), simplificado (`st_simplifypreservetopology(geom,15)`) → ~19 KB. **Sem
  gate de papel** (o geofonista também vê). O resultado é cacheado em `_limiteZaData` e reusado nos 4
  mapas (1 fetch por sessão).

---

## 2. Coleta de campo (schema `"8 - coleta_campo"`)

### 2.1 Mapeamento de pressão — `// UI módulo pressão` (~L592) · tela `pressao`
- Leitura de manômetro + foto + GPS. Salva via `app_registrar_pressao` (fila).
- **Duas fotos (2026-09):** **Foto do manômetro** (obrigatória, `fotoBlob`→`p_foto`) e **Foto do número HD**
  (opcional, `fotoHdBlob`→`p_foto_hd`, inputs `.fFotoHd`/preview `#fotoHdPrev`). Ambas vão no `item.fotos`
  (`enviar` faz upload por param e seta o path). Coluna nova `"8 - coleta_campo".mapeamento_pressao.foto_hd`
  + param `p_foto_hd` na RPC (recriada com `drop`+`create` p/ não gerar overload — regra §0.6; grant só `authenticated`).
- **Unidade de medida (2026-09):** ao lado do valor há `#pressao_un` (**MCA/BAR/KPA**, default MCA). O valor é
  **convertido p/ mca no cliente** antes de enviar (`vmca`: kpa÷9,80665; bar×10,1971621; mca as-is) — a coluna
  do banco (`p_pressao_mca`) continua sempre em **mca**, sem mudança de backend. `prAposSalvar(vmca)`.
- Alvo opcional vindo do Teste de estanqueidade (`prAlvo`). Botões: `#prEst` (estanqueidade), `#prProd`.
- Subtelas: **Estanqueidade** (`estanqueidade`, `// TESTE DE ESTANQUEIDADE` ~L649, RPC
  `app_estanqueidade_listar`, filtro por consórcio) e **Produtividade de pressão** (`pr_prod`,
  `// PRODUTIVIDADE DE PRESSÃO` ~L4093, RPCs `app_pressao_filtros`/`app_pressao_produtividade`).
  No mapa da produtividade, o **popup de cada ponto** traz pressão/**cota**/**cota+pressão**/HD/data/coletor +
  **link "📷 Ver foto do manômetro"** (`SBASE+pr.foto`, aba nova) quando há foto. **Chips de métrica**
  (`#prpMetric`/`PR_MET`/`prpSetMetric`, 2026-09-24) alternam a visualização entre **Pressão** (mca, escala de
  cor fixa 10–50), **Cota** e **Cota + Pressão** (m, escala de cor **automática** por min/máx dos pontos) —
  muda a cor + o rótulo do marcador e recalcula os cards (média/mín/máx) no cliente a partir de `prpData`.
  `app_pressao_produtividade` devolve `foto` **e `cota`** (=`cota_m`) nas `properties` dos pontos.
- **Camadas COPASA no mapa da estanqueidade (2026-09):** no modo Mapa há chips toggle (`#estCamadas`,
  `EST_CAM`/`estCamRender`/`estCamToggle`) para **Zonas de pressão** (`"5 - info_copasa".zonas_pressao_copasa`,
  137, azul) e **DMCs** (`"5 - info_copasa".dmcs_existentes_copasa`, 23, laranja) — polígonos com **fill 30% +
  borda weight 2** (mesmo padrão de ativar/desativar do Cadastro técnico). GeoJSON (4326, `ST_SimplifyPreserveTopology 1m`)
  via RPC **`app_estanq_poligonos(p_layer)`** (`zonas_pressao`|`dmcs`, definer, só `authenticated`); cache em
  localStorage (`est_cam_zp`/`est_cam_dmc`). Camadas ficam **abaixo** dos pontos (`bringToBack`); começam desligadas.
- **Popup no ponto do mapa (2026-09):** clicar num marcador abre popup (`bindPopup`+`popupopen`) com **🧭 Navegar
  até o local** (link Google Maps, `target=_blank`) e **📝 Preencher informações** (`.estPopFill` → `estSelecionar`
  → tela de pressão). Antes o clique ia direto p/ a tela de pressão; o tooltip de hover foi mantido.

### 2.2 Loggers — `// MÓDULO LOGGERS` (~L782) · telas `loggers_hub` / `loggers` / `logger_det`
- **Card "Loggers"** (home, antes "Loggers temporários") → **hub `loggers_hub`** com 2 botões:
  **⏱️ Temporários** e **📌 Fixos**. Os dois abrem a **mesma tela `loggers`**; o modo (`lgModo`
  ∈ `temp|fixo`, global) **filtra a lista** e **define a flag** de qualquer logger criado ali.
- **Flag `instalacao_logger_calibracao.logger_temporario`** (boolean, default **false**): `true`=temporário,
  `false`=fixo. Marcada `true` nos **97** remanescentes da limpeza de 2026-10-17 (ver abaixo). A listagem
  (`app_loggers_listar`) devolve a coluna; o front filtra por `lgModo` (temp = flag true). Criação
  (`app_logger_criar`, **param novo `p_temporario boolean default true`**) grava conforme o botão
  (`lgModo==='temp'`). A tela `loggers` volta pro `loggers_hub` (botão `#lgVoltarHub`), não pra home.
- **Limpeza 2026-10-17:** removidos todos os `pendente`, `dados pendentes` (removido) e `concluído`
  **sem dados de pressão** (135 loggers + 62k linhas de `logger_pressao` via FK CASCADE); backup em
  `"8 - coleta_campo"._bkp_loggers_del_20261017`/`_bkp_logger_pressao_del_20261017`. Restaram **97**
  concluídos com pressão, todos `logger_temporario=true`.
- **Ciclo (situação DERIVADA, não há coluna):** `pendente → instalado → removido ("dados pendentes")
  → concluido`. **Não existe mais** promoção automática após 7 dias.
- **Tabela base:** `"8 - coleta_campo".instalacao_logger_calibracao`. **View:** `vw_loggers`
  calcula `situacao_atual` a partir das datas (`data_instalacao`, `data_remocao`, `data_finalizacao`)
  e `dias_instalado`. **Não crie coluna `situacao`** — mexa no CASE da view.
- **RPCs:** `app_loggers_listar()` (retorna a lista já achatada), `app_logger_criar` (avulso, já
  instalado), `app_logger_instalar`, `app_logger_remover`, `app_logger_finalizar` (anexa .json +
  OS SIGOS), `app_logger_editar(p_id, p_campos jsonb, p_foto_* ...)`, `logger_pressao_importar`,
  `logger_pressao_stats`, `app_logger_set_multiplicador`, `app_logger_set_converter_mca`.
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
- **Seletor "Necessário conversão para MCA?" (2026-09-16, na tela de conclusão + no logger concluído):**
  card `lgMcaCardHtml`/`lgMcaWire` (segmento **Sim / Não**) **acima** do multiplicador, mesma permissão
  (`ME.pode_aprovar`; só-leitura pros demais, e escondido quando é o padrão "Sim"). Coluna
  `instalacao_logger_calibracao.converter_mca` (boolean, **default true**), gravada por
  `app_logger_set_converter_mca(p_id,p_converter)` (gate `sup_funcao in ('admin','aprovador')`).
  **Semântica:** entra no MESMO cálculo, mudando só o divisor — `mca = round(kpa * multiplicador / DIV, 4)`,
  `DIV = 9,80665` quando `converter_mca=true` (kPa→mca, como sempre) **ou `1` quando `false`** (assume que
  os dados **já estão em MCA** — não converte, só aplica o multiplicador). Espelhado em
  `logger_pressao_stats` (devolve `converter_mca`) e na view `vw_logger_pressao` (nova coluna
  `converter_mca` no fim; CSV/BI saem coerentes). O **multiplicador permanece** editável e persistente do
  mesmo jeito. Ambos os controles agora aparecem também na **tela de conclusão** (`fzResumo`, chamada de
  `lgCarregarPressao(...,true)`), não só no logger já concluído.
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
  BOM UTF-8 (abre no Excel PT-BR). Arquivo `logger_<codigo>.csv`.
- **Colunas sem unidade no nome + unidade em coluna própria (2026-09-16) — reestruturação da view
  `vw_logger_pressao` e do CSV.** Tirou-se a unidade do nome das colunas; a unidade da **pressão** virou
  coluna à parte (temperatura/bateria ficaram sem unidade, a pedido). Fluxo por linha:
  `Pressao_Inicial` + **`Unidade_Inicial`** → `Multiplicador` → `Pressao_Ajustada` (=inicial×multiplicador)
  → `Pressao_Final` + **`Unidade_Final`** (sempre `mca`) → **`Converteu_MCA`** (Sim/Não) → `Temperatura` →
  `Bateria`. **`Unidade_Inicial` é dinâmica pelo seletor:** `kPa` quando converte (Sim) — a inicial é o
  bruto do sensor e só a final vira mca; **`mca` quando NÃO converte** (Não) — o dado já vem em mca e só
  recebe o multiplicador. `Pressao_Final = pressao_inicial*mult/DIV` (`DIV=9,80665` no Sim, `1` no Não).
  **Colunas antigas renomeadas na view:** `pressao_kpa`→`pressao_inicial`, `pressao_final_kpa`→
  `pressao_ajustada`, `pressao_mca`→`pressao_final`, `multiplicador_pressao`→`multiplicador`; novas
  `unidade_inicial`/`unidade_final`/`converteu_mca`. Como `create or replace view` não renomeia coluna,
  a view foi **`drop`+`create`** (junto com a dependente **`0 - vitrine_gis.vw_gis_logger_pressao`**). A
  **vitrine também foi renomeada** (a pedido, 2026-09-16): passou a expor `pressao_inicial`/`unidade_inicial`/
  `pressao_final`/`unidade_final`/`converteu_mca` (saíram `pressao_kpa`/`pressao_mca`); `grant select` a
  `gis_visualizacao` refeito. ⚠️ **Repontar a camada no projeto QGIS** — os campos `pressao_kpa`/`pressao_mca`
  deixaram de existir na vitrine. `app_logger_pressao_export` e `lgExportarCsv` seguem os novos nomes.
  **Cota + rótulo na vitrine (2026-09-24):** a base `vw_logger_pressao` passou a expor **`cota`** (= `i.elev`
  do ponto do logger); a vitrine **`vw_gis_logger_pressao`** ganhou **`cota`**, **`cota_mais_pressao`**
  (= `cota + pressao_final`, a linha piezométrica) e **`rotulo`** no formato **`XX mca | XX m - XX m`**
  (pressão | cota – cota+pressão, arredondados; só pressão quando não há cota). `grant select` a
  `gis_visualizacao` mantido — usar `rotulo` como campo de rótulo no QGIS.
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
- **Tipos (`#ocTipo`, 2026-10-27):** dois grupos — **Vazamento** (visível · não visível (ruído) · extravasamento ·
  cavalete/hidrômetro) e **Fraude** (`Fraude - Derivação de ramal` · `- Ligação clandestina` · `- Rompimento de
  lacre` · `- Corte violado` · `- Hidrômetro violado`). **`Outro` saiu** do dropdown (3 registros antigos seguem
  valendo). O texto do option é o valor gravado em `tipo`. **Regra única: vazamento = tipo que não começa com
  `Fraude`** — front `ocEhFraude()` (+ `OC_TIPOS_VAZ`/`OC_TIPOS_FRAUDE`/`OC_ROT` rótulos curtos, junto da Abertura
  de serviços) e SQL `tipo not ilike 'fraude%'` no `app_pp_acompanhamento`. Tipo novo de fraude: começar com
  `Fraude - ` e incluir em `OC_TIPOS_FRAUDE`.
- **Consórcio (2026-10-27):** `app_ocorrencia_registrar` grava a ZA do ponto (§0.11) — antes gravava o
  `localStorage`, e 8/19 estavam na ZA errada; backfill feito (backup das chaves em
  `"8 - coleta_campo"._bkp_ocorrencia_consorcio_20261027`, `docs/migracao_pesquisa_ocorrencias_fraude.sql`).
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
- **Export Excel (2026-10, só `pode_aprovar`):** botão **⬇ Excel** (`#vrpXls`, revelado por `vrpXlsGate()` em
  `vrpCarregar`) → `vrpExportarXlsx()` exporta a **lista filtrada** (situação/consórcio/busca/Filtro João): cadastro
  (consórcio, VRP, nó, diâmetro + colunas extras de `VRP_XLS_EXTRA` que vierem preenchidas em `app_vrp_listar`,
  observação, lat/lon), situação, quem/quando vistoriou e **todas as respostas da última vistoria** (`VRP_FORM`
  sem fotos; fotos só a contagem). As respostas vêm de `app_vrp_visita_ver` (1 chamada por VRP não pendente,
  6 em paralelo) — **sem RPC nova nem mudança de banco**. Gate só no front (como o export TXT do Roteiro):
  as RPCs usadas já são abertas a `authenticated`.
- **`cd_no_agua` visível para o usuário** (não só na busca): na lista (`vrpRenderLista`) aparece ao
  lado do nome da VRP; no mapa (`vrpRenderMapa`) entra no `bindTooltip` (hover). Já vem de
  `app_vrp_listar` — não precisou mudar RPC.

### 2.5 Cadastro técnico — `// CADASTRO TÉCNICO` (~L1821) · tela `cadastro`
- Camadas PostGIS no mapa por bbox: reservatório, booster/bomba, elevatória, poço, macromedição,
  **VRPs**, **Válvulas de manobra**, **Hidrantes**, rede, ligações, **rede de gás** (`CAD_DEF`). Camadas `whole:true` baixam a ZA inteira 1x; pesadas usam
  `step` (célula de cache).
  - **Rede de gás (2026-09, `CAD_VER v5→v6`):** camada **`rede_gas`** (GASMIG, `"4 - redes_terceiros".rede_gas`,
    1.271 linhas MULTILINESTRING, âmbar `#f9a825`, `whole:true`, começa desligada). Só leitura/visualização;
    branch `rede_gas` na RPC `app_cadastro_geojson` (props id/material/diametro/municipio) — popup genérico.
  - **Hidrantes (2026-10-05):** camada **`hidrantes`** — view **`"2 - infra_agua".unidades_hidrantes`**
    (hidrantes = `nos_agua` com `cd_no_agua LIKE 'HDT%'`, 80 pts, indigo `#3949ab`, `whole:true`, começa ligada).
    Espelha o padrão de `unidades_macromedicao` (view no schema `"2 - infra_agua"`, carregável direto no QGIS como
    camada PostGIS key=`id`/srid 31983). Branch `hidrantes` na RPC `app_cadastro_geojson`
    (props cd_no_agua/nome/funcao/cota/referencia) — popup genérico. `CAD_VER` inalterado (a chave de cache da
    camada nova já é distinta; camadas existentes não mudaram de dado).
  - **Válvulas de manobra (2026-10-15, sw v249):** camada **`caixas_manobra`** — tabela **`"2 - infra_agua".caixas_manobra`**
    (448 caixas de manobra = **válvulas/registros de abre-fecha** do sistema; blue-grey `#455a64`, `whole:true`, **começa desligada**
    — chip que o usuário liga para ver todas). **Exclui VRP** (tabela própria `vrps`, chip próprio). Geom é **MultiPolygon** →
    o branch `caixas_manobra` da RPC devolve o **ponto representativo** (`ST_PointOnSurface`) p/ render igual às demais unidades
    (circleMarker); props cd_no_agua/tipo(tipo_co)/material/cota/referencia. **Só ZA1004 tem dado** hoje (Betim = 0). `CAD_VER`
    inalterado (chave de cache nova distinta; camadas existentes não mudaram).
- **RPCs:** `app_cadastro_geojson` (bbox→GeoJSON, param `p_layer`), `app_cadastro_buscar`,
  `app_limites_zas`. Cache em **IndexedDB** (`cadcache`) versionado por **`CAD_VER`** (`'vN|'`) —
  **mudou dado/camada do cadastro? Suba `CAD_VER` também**, senão o usuário fica com cache velho.
- **Popup genérico:** `onEachFeature` do `cadAtualizar` não tem template por camada — só faz
  `Object.keys(properties).join('<br>')`. Ou seja, **pra aparecer no popup basta a RPC incluir a
  coluna no `jsonb_build_object` das `properties`**; nada a mexer no frontend. Ex.: `cd_no_agua` das
  unidades operacionais (reservatório/booster+bomba/elevatória/poço/macromedição) foi adicionado só na
  RPC (a coluna já existia em `"2 - infra_agua".unidades_operacionais`, só não estava no `SELECT`).
  - **Amarração do trecho (2026-09-22, `CAD_VER v4→v5`):** mesma técnica — a **rede** agora traz no popup
    `trecho` (`nu_trecho`) e **`amarração`** (`no_agua_ini → no_agua_fim`, composta na RPC; 100% preenchida,
    17.350 trechos); a **ligação** traz `trecho` (`nu_trecho`, amarração da ligação ao trecho de rede;
    100% preenchida). Colunas já existiam em `"2 - infra_agua".rede` / `"3 - comercial".ligacoes`, só não
    estavam no `jsonb_build_object`. A rede também traz **`observação`** (`rede.observacao`, ~8% preenchida) —
    incluída **só quando não-vazia** (concatenando `|| case when ... jsonb_build_object('observação',...) else '{}' end`),
    pra não poluir o popup dos 92% sem observação com uma linha `—`. **VRPs e unidades já expõem `cd_no_agua`**
    (o nó de amarração delas) — nada a fazer. Só a RPC mudou; frontend inalterado além do bump de `CAD_VER`.
- Marcador **"Você"** (GPS): `cadOnGps()` cria/atualiza `cadVoce` (não é apagado nos redraws de
  `cadAtualizar`, que só mexe em `cadCamadas`).
- **Estado:** `cadMap, cadCamadas, cadOn (visibilidade por camada), cadRendered, cadMem, cadVoce`.

### 2.6 Gestão de Pavimento — `// ---------- GESTÃO DE PAVIMENTO ----------` · tela `pavimento` (2026-10-21)
- **Objetivo:** registrar em campo o **pavimento a recompor** depois de um serviço (vazamento, ramal, VRP, rede, DMC etc.), com fotos e georreferência, para o time de programação programar a recomposição.
- **Formulário (`pavInit`/`pavRenderTipos`/`pavRenderBlocos`/`pavValidar`):**
  - **Serviço de origem** (select, `PAV_ORIGEM`): vazamento · ramal · fiscalização · vrp · rede_vca · rede_hdd · dmc.
  - **OS SIGOS** de origem (texto, opcional).
  - **Coordenada travada no GPS** (`pavOnGps`): mostra lat/lon ao vivo, **sem edição**; banner "Fique próximo ao local para salvar a coordenada" até `gps.acc ≤ PRECISAO_MAX` (15 m) — mesma trava anti-lançamento-remoto da pressão/loggers.
  - **Tipos de pavimento = multi-seleção** (chips `PAV_TIPOS`: grama/asfalto/concreto/bloquete/paralelepípedo/pedra portuguesa/piso especial/piso tátil/meio-fio/sarjeta). Cada tipo selecionado **abre um bloco** com **dimensão** + **2 fotos obrigatórias** (câmera **e galeria**, `comprimir` 1600px). Estado em `pavState={tipo:{dimensao,f1,f2}}`.
  - **Salvar:** gera um `grupo` uuid e envia **1 item por tipo** pela **fila offline** (`enviarOuEnfileirar`, `rpc:'app_pav_registrar'`, `pasta:'pavimento'`, fotos `p_foto1`/`p_foto2`). "Meus últimos registros" via `app_pav_minhas` (agrupado por grupo).
- **Backend:** tabela **`"8 - coleta_campo".pav_recomposicao`** (1 linha por **tipo**, colunas `grupo`/`servico_origem`/`os_sigos`/`tipo_pavimento`/`dimensao`/`foto1`/`foto2`/`lat`/`lon`/`gps_precisao`/`geom`(Point 4326)/`consorcio`/`usuario_*`; RLS **deny-all**, acesso só via RPC definer). RPCs: `app_pav_registrar(...)` (gate authenticated — qualquer usuário de campo; grava `usuario_uuid`/email/nome de `auth`; **`consorcio` = ZA cujo `"1 - suporte_geografico".limite_za` contém o ponto → senão `p_consorcio` → senão `perfil.consorcio`** — 2026-10-27, `docs/migracao_pav_consorcio.sql`; antes vinha só do `localStorage 'consorcio'`, que **só a tela de Pressão grava**, e 22/23 registros ficaram sem consórcio — backfill feito, backup `"8 - coleta_campo"._bkp_pav_consorcio_20261027`), `app_pav_minhas()` (do próprio usuário), `app_pav_listar(p_consorcio,p_servico_origem)` (gate **admin|aux_acesso**, agrupa por grupo → `itens[]`, cada item com `id` + a sua OS da recomposição — §4.4). Fotos no bucket **público** `fotos-campo` (pasta `pavimento/`). sw **v261**.

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
- Entrevistador pede abertura de OS (tipo, matrícula, HD, foto do HD, GPS). Tipos (`#as_tipo`): 106000,
  1480000, 1490000, 1177900 (117 79 00 — Substituição de Hidrômetro, incluído em 2026-10), FAT0900, 3020000;
  o rótulo gravado em `tipo_label` vem do `case` dentro da RPC (código novo → atualizar o `case` também; o do 1177900 está em `docs/migracao_abertura_servico_1177900.sql`). RPC
  `app_abertura_servico_registrar` (fila, pasta `abertura`). "Minhas solicitações":
  `app_abertura_servico_minhas`. Tabela `"12 - retaguarda".abertura_servico` (movida de
  `"8 - coleta_campo"` na reorg de 2026-09; *app-only*, não exposta a GIS).
- **Consórcio (2026-10-27):** a RPC grava `consorcio` = ZA do `limite_za` que contém o ponto → `p_consorcio` →
  `perfil.consorcio` (`docs/migracao_abertura_servico_consorcio.sql`). Antes vinha só do `localStorage` (§0.11) e
  7/7 estavam sem consórcio — backfill feito (backup `"12 - retaguarda"._bkp_abertura_consorcio_20261027`). O perfil
  **não** serve de fonte principal: entrevistadores atendem as duas ZAs (4/7 divergiam); o ponto bateu com o
  consórcio da matrícula em `"3 - comercial".ligacoes` em 7/7.

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

### 3.4 Registro de ocorrência — `// REGISTRO DE OCORRÊNCIA (Entrevistadores)` · telas `ent_ocorrencia` / `ent_oc_gestao`
- **Registro (qualquer entrevistador):** matrícula do imóvel (digitada) + **uma** ocorrência:
  `cliente_nao_informado` (1) Cliente não informado · `resistencia` (2) Resistência do cliente em passar
  informações · `ligou_copasa` (3) Cliente ligou para a COPASA? → **Sim/Não**; se **Sim**, "O que a COPASA
  orientou?" é obrigatório · `policia` (4) Polícia acionada. + **Detalhamento** (texto livre, opcional).
  GPS é gravado **se houver**, mas **não bloqueia** o envio (diferente da Solicitação de serviços).
  Sem foto. Vai pela fila offline (`enviarOuEnfileirar`, sem `pasta`). O entrevistador **não** vê lista.
- **Gestão (`ent_oc_gestao`, só `pode_aprovar`):** botão no bloco **📋 Gestores** da tela
  Entrevistadores (`#entOcGest`, liberado em `entInit()`); filtro De/Até (padrão: mês corrente) +
  consórcio (client-side) + **⬇ Excel** (`exportarXlsx`).
- **RPCs:** `app_entrevista_ocorrencia_registrar(p_id,p_matricula,p_tipo,p_ligou_copasa,p_orientacao_copasa,
  p_detalhamento,p_lat,p_lon,p_precisao,p_consorcio,p_dispositivo)` (valida tipo e a regra do item 3) e
  `app_entrevista_ocorrencia_listar(p_de,p_ate)` (datas inclusivas no fuso de SP; devolve `[]` se não for
  aprovador/admin).
- **Tabela:** `"12 - retaguarda".entrevista_ocorrencia` (*app-only*: matrícula + relato do cliente;
  RLS ligada sem policy, acesso só via RPC). `check` garante que `ligou_copasa`/`orientacao_copasa` só
  existem no tipo 3. Migração: `docs/migracao_entrevista_ocorrencia.sql`.
- **Estado:** `eoLigou` (null/true/false), `egUltimo` (última lista carregada, base do export).

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
- **Ocorrências: referência geográfica + Lista/Mapa (2026-09-15).** O card de ocorrência mostra, além
  do link `📍 Mapa`: o **par de coordenadas** (`lat,lon` já vinham na RPC, só passaram a ser exibidos,
  selecionáveis) e um **endereço/nº** best-effort via **reverse-geocode Nominatim/OSM** — client-side,
  `revGeo(lat,lon)` (cache em `_revGeoCache`, serializado + delay 1,1 s pra respeitar o rate-limit do
  Nominatim; preenche o `<span class="pgOcEnd">` de forma assíncrona via `pgOcFillEnderecos`). Sem CSP
  e o SW não intercepta cross-origin, então a chamada vai direto à rede; se falhar, o card mostra
  "endereço indisponível" e segue. O card é gerado por `pgOcCard(s,popup)` — **reusado** na lista e no
  popup do mapa. **Toggle 📋 Lista / 🗺️ Mapa** (`#pgOcTabs`, estado `pgOcMode`, `pgOcRenderTabs`/
  `pgOcAplicarView`): o mapa (`#pgOcMapa`, `pgOcCarregarMapa`, `mapAddCamadaBase` + `layerGroup`)
  plota um `circleMarker` por ocorrência (vermelho=sem OS, verde=com OS) sobre **os mesmos dados
  filtrados** (`pgOcData`, recarregado a cada troca de filtro pendente/criada/todas); clicar no ponto
  abre um **popup com o mesmo card** (inclui input+Salvar da OS, fiado no `popupopen`). Salvar fecha o
  popup e recarrega. `pgInit` chama `pgOcRenderTabs`.
- **Ocorrências: filtros + card compacto + deep-link (2026-10-27).** Três selects lado a lado acima do Lista/Mapa
  (no celular o consórcio desce): **tipo** (`#pgOcFTipo` — "Todos os vazamentos"/`@vaz`, "Todas as fraudes"/`@fraude`
  ou o tipo exato, com **contagem** em cada opção; tipo antigo fora da lista, ex. `Outro`, aparece se houver),
  **local** (`#pgOcFLocal`, sw v278 — o **combinado tipo × local** dá o porte da equipe, ex. vazamento não visível na
  rede; contagens de cada dropdown respeitam os outros dois filtros) e **consórcio** (`#pgOcFCons`). Filtro **no cliente** sobre `pgOcData` (`pgOcFiltrado`), vale p/ lista e mapa; estado
  `pgOcFTipo`/`pgOcFCons` sobrevive ao Salvar OS e à troca de aba. `pgCarregarOc` só busca; quem desenha é
  `pgOcRender`. **Card (`.occ`, CSS global):** grid de 2 colunas — esquerda: tipo (⚠️ vazamento / 🚩 fraude) +
  tags local/consórcio, endereço, 👤 nome (`usuario_nome`, do perfil) · 📌 coordenada, 💬 obs; direita (sob a data):
  📷 Foto/📍 Mapa, ✓ OS e o campo de OS. ≤600px e no popup (`.occ.pop`) a coluna da direita desce. Não usar
  `.sub` dentro do card (margem inferior de 16px — era o que deixava o card alto). **Deep-link:**
  `pgOcAbrir(id,temOs)` (chamado pelo popup do Acompanhamento, §4.3.8) abre em modo pesquisa, na aba certa
  (pendente/OS criada), limpa os filtros, rola até o card (`data-occ`) e o destaca (`.occ.foco`); o "‹ voltar"
  segue `pgBackTo` (volta ao Acompanhamento nesse caso). `app_ocorrencia_fila` passou a devolver `usuario_nome`.

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
  **deleta** a linha. Reprogramar (`sobrescrever=true`, o que o frontend sempre manda) **apaga+recria**
  a linha (id novo, `programado_em=agora`) — **sem trava, mesmo se já `executado`**: reprogramar/
  re-pesquisar o mesmo trecho é comum e tem que continuar livre (o TR exige **5 passadas** de toda a
  rede ao longo do contrato). Isso é **seguro** porque `programacao_pesquisa` é só a **atribuição atual
  (a passada corrente)** — o fato permanente "isso foi pesquisado em tal data, na Nª passada" mora no
  histórico, ver **4.3.6**. **Por que apaga+recria e não `UPDATE` no lugar (Fase 1, 2026-09-14):** cada
  passada precisa de um `programacao_pesquisa.id` **novo**, senão o dedup do histórico (que é por
  `programacao_id`, 4.3.6) **bloquearia** o lançamento da 2ª passada. Apagar a linha antiga não perde
  nada — a passada concluída já está salva em `pp_execucao` (o `on delete set null` do backlink só
  desliga o vínculo). (Uma trava de imutabilidade foi tentada e revertida antes disso — bloqueava
  reprogramar trecho já executado, o que quebrava a re-pesquisa legítima.)
- Lista de colaboradores clicável (`app_pp_colaboradores`, inclui o próprio usuário logado) filtra o mapa
  pra "só a programação dele" (`app_pp_por_colaborador`). Botão "✕ Limpar seleção", filtro "não pesquisado
  desde X" (`p_nao_pesquisado_desde` em `app_rede_bbox`).
- **Legenda-filtro por nº de passadas (2026-09-14, substituiu status por cor):** a rede é colorida por
  **quantas vezes cada trecho já foi pesquisado** — `Programado` (roxo, atribuído pendente, é overlay pra
  não reatribuir) + `0×` (**vermelho** `#dc2626`) / `1×` / `2×` / `3×` / `4×` / `5+×` (escala teal, =
  `pp_execucao` count). **As 3 RPCs que alimentam o mapa** expõem `n_passada` por segmento: `app_rede_bbox`
  (toda a rede), `app_pp_rede_no_poligono` (seleção por polígono) e **`app_pp_por_colaborador`** (modo
  geofonista — **fix 2026-09-15: faltava o `n_passada` aqui, então o executado do colaborador aparecia
  `0×` vermelho em vez de `1×` teal**). Categoria de cor: `ppCat(p)` = `'programado'` se
  `pp_status='pendente'`, senão `'p'+min(n_passada,5)`. (As antigas "livre / sem pesquisa recente /
  pesquisado" saíram.)
- **Filtro isola por categoria (2026-09-15):** a legenda-filtro (`ppFiltro`, Set) passou de *toggle*
  (cada faixa liga/desliga, default tudo ligado) pra **isolar** — igual ao mapa do Acompanhamento:
  clicar `0×` mostra **só** `0×` (esconde o resto); clicar mais faixas soma; nada selecionado = mostra
  tudo. Antes o clique só *desligava* a faixa, o que confundia ("cliquei em 0× e o 1× não sumiu").
- **Cuidado de performance (fix 2026-09-15 — `statement_timeout=8s` do papel `authenticated` estourava
  em cache frio):** `app_rede_bbox` agora **enriquece só depois do LIMIT** — um CTE `cand` faz só o bbox
  + `limit 10000` (barato, índice GiST), e as subconsultas caras (`ultima_pesquisa` espacial, `n_passada`,
  `programado_para`, `pp_status`) rodam só nesses ≤10000, não mais pra *todos* os segmentos do bbox antes
  de limitar (num zoom largo/cold podiam ser ~46k subconsultas espaciais). O `p_nao_pesquisado_desde`
  passou a filtrar **depois** do enrich (mudança de semântica só no caso raro de >10000 no viewport).
  E o `progresso_passadas` do `app_pp_acompanhamento` usa `comprimento_m` (coluna, 100% populada) em vez
  de `st_length(geom)`, pra não desserializar 46k geometrias no cold. Warm ~1s; a mudança é pro cold.
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
  2. Pra cada `(segmento, trecho)` a até `tol_m` um do outro **e com o trecho posterior à programação
     do segmento** (`t.inicio_ts >= programado_em at time zone 'America/Sao_Paulo'` — **filtro da Fase 1,
     2026-09-14**; ver "Por que o filtro de tempo" abaixo): `st_dump(st_linemerge(st_intersection(
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
  📍 recentraliza na posição GPS. **Sumiço instantâneo do executado (Fase 2, 2026-09-14):** ao confirmar
  um trecho **online**, o `pqCarregarProg` é re-disparado **quando o envio resolve** (encadeado no
  `.then` do `enviarOuEnfileirar`), não mais num `setTimeout` chutado — o cruzamento roda **síncrono**
  dentro do `INSERT` do trecho (`trg_pp_cruzar`→`pp_recompute`), então ao voltar o await o segmento já
  está `executado` e some da camada roxa na hora. **Offline:** fica pra `sincronizar()`, que também
  re-carrega a camada roxa se a tela Pesquisa estiver aberta quando a fila sobe.
- **Minha produtividade (geofonista) — simplificada na Fase 3 (2026-09-14):** era uma tela de análise
  (dropdown "Todos os coletores", cards de km andado/velocidade/vaz-km, toggle "Cruzar com a
  programação" com 4 camadas). Virou **consulta pessoal** do geofonista: **sempre o usuário logado**
  (`auth.uid()`, sem dropdown), 3 camadas fixas — 🟣 **pendente** da programação dele (ATEMPORAL — é a
  lista de tarefas, o filtro de data **não** a afeta) · 🟢 **pesquisado** no período · 🔴 **reporte de
  campo** no período — e 3 cards (km pendente · km de rede pesquisado · km andado). A análise profunda
  (dois km, vaz/km por km de rede, cruzamento, histórico entre passadas, comparação entre coletores)
  migrou pro **Acompanhamento** do time interno (Fase 4, ver 4.3.7).
  - **RPC nova `app_pesquisa_minha(p_data_ini, p_data_fim)`** (`SECURITY DEFINER`, baseada em
    `auth.uid()` — nada de nome/uuid vindo do cliente). Chaves `pendente`/`executado`/`reporte`, cada uma
    FeatureCollection + `n` + `km`. `pendente` vem de `programacao_pesquisa` (status pendente, sem filtro
    de data); `executado` de `pp_execucao` (filtrado por `executado_em`); `reporte` de `pesquisa_trecho`.
  - **Pegadinha do casamento traço↔usuário:** `pesquisa_trecho.usuario` grava
    `full_name` do JWT **ou** o e-mail como fallback (visto: gravou e-mail, enquanto `perfil.nome` é o
    nome de exibição). Então o `reporte` casa por **`usuario in (nome, email)`** do próprio `auth.uid()`,
    não só por nome — senão os traços dele não apareceriam.
  - **RPCs `app_pesquisa_produtividade`/`app_pesquisa_filtros` ficaram órfãs** do frontend (a tela não
    as usa mais); deixadas no banco por ora (a Fase 4 terá sua própria RPC de análise).
- **RPCs `app_pp_minhas`/`app_pp_mapa`:** propriedade `segmento_id` no GeoJSON (renomeada de `rede_id`
  na Fase E — nenhum código do frontend lia esse campo por nome, só exibia via popup genérico).
  `app_pp_mapa` (com a camada `historico_execucoes`, 4.3.6) passa a servir a tela de **Acompanhamento**
  (Fase 4), não mais a produtividade do geofonista.

#### 4.3.6 Histórico permanente de execuções — `pp_execucao` (2026-09-14, novo)

**Por quê:** `programacao_pesquisa` é o **ciclo de atribuição atual** de um segmento — livremente
desvinculável/reprogramável (4.3.3), inclusive depois de `executado`. Isso é necessário (pesquisar o
mesmo trecho de novo é legítimo — filtro "não pesquisado desde X"), mas sozinho tem um problema: a
**única** cópia do fato "isso já foi pesquisado, em tal data" vivia ali (`rede_pp_segmento` não tem
coluna de status própria — 4.3.1), então desvincular ou reprogramar um trecho já executado apagava
esse fato **sem deixar rastro** — o "pesquisado (cadastro)" simplesmente sumia. Uma trava de
imutabilidade (bloquear desvincular/reprogramar se `status='executado'`) foi tentada e revertida no
mesmo dia: ela resolvia isso mas também travava o trecho **pra sempre**, impedindo até a re-pesquisa
legítima.

**Solução:** tabela nova **insert-only** (nunca editada/apagada pelo app — mesmo espírito de
`pesquisa_trecho`, o "reporte de campo"), que registra **um lançamento permanente** toda vez que um
segmento vira `executado` de verdade. `programacao_pesquisa` continua podendo ser resetada/apagada à
vontade — o histórico já está salvo em outro lugar.

- **`"8 - coleta_campo".pp_execucao`** — `segmento_id` (FK `rede_pp_segmento`, `ON DELETE SET NULL` —
  não trava nem cai junto se a rede for re-segmentada, 4.3.1), `rede_id` (estável, não muda com
  resegmentação), `geom` (**snapshot** da geometria no momento — não depende do segmento ainda existir),
  `comprimento_m`/`coberto_m`/`colaborador_uuid`/`programado_por`/`programado_em`/`executado_em`/
  `primeiro_trecho_id` (cópia do estado de `programacao_pesquisa` no instante do flip), `origem`
  (`cobertura_direta` | `heranca_vizinho` | `desconhecido`), **`n_passada`** (Fase 1 — a Nª vez que
  **esse segmento** foi pesquisado: `1 + count(*)` de linhas já existentes em `pp_execucao` pro mesmo
  `segmento_id` no instante do insert; meta do TR = 5), **`programacao_id`** (FK
  `programacao_pesquisa.id`, `ON DELETE SET NULL`, **`UNIQUE`** — é a chave de deduplicação, ver
  abaixo). RLS ligada, **sem policy** — mesmo padrão de `programacao_pesquisa`/`pp_config` (só acessível
  via função `SECURITY DEFINER`, dona da tabela bypassa RLS por não ter `FORCE ROW LEVEL SECURITY`).
- **Trigger `trg_pp_log_execucao`** (`AFTER UPDATE OF status ON programacao_pesquisa ... WHEN (NEW.status
  = 'executado' AND OLD.status <> 'executado')` → `pp_log_execucao()`) — loga automaticamente em
  **qualquer** transição pendente→executado, não importa o caminho de escrita (hoje só `pp_recompute`
  escreve `status`, mas o trigger não depende disso).
  - `pp_recompute` marca a **origem** do flip com `perform set_config('pp.origem_flip', '...', true)`
    logo antes de cada um dos dois `UPDATE`s que viram status (cobertura direta / herança de vizinho) —
    o trigger lê `current_setting('pp.origem_flip', true)`. É só sinalização, não muda a lógica de
    cálculo do `pp_recompute` em nada.
  - **Pegadinha achada e corrigida no mesmo dia — dedup é por `programacao_id`, não por
    `segmento_id`/status:** `pp_recompute` **sempre** reseta pra `pendente` e recalcula do zero, mesmo
    quando só está reconfirmando um trecho que já estava `executado` (ex.: qualquer trecho novo
    pesquisado a até `tol_m+60` de um segmento já pronto reprocessa ele via `trg_pp_cruzar`) — cada
    recompute desses geraria uma transição `pendente→executado` **de novo** e o trigger logaria um
    lançamento duplicado a cada recompute de vizinhança, não um por evento real. Fix: `pp_execucao.
  programacao_id` é `UNIQUE`, e o insert do trigger usa `ON CONFLICT (programacao_id) DO NOTHING` — como
  o `id` de uma linha de `programacao_pesquisa` fica estável durante toda a vida daquele ciclo de
  atribuição (só muda quando desvincula+re-atribui = ciclo novo), isso deduplica corretamente:
  **N recomputes do mesmo ciclo → 1 lançamento**; **desvincular + atribuir de novo (ciclo novo, `id`
  novo) → lançamento novo**, mesmo no mesmo `segmento_id`. Testado (rollback E2E): 4 flips seguidos do
  mesmo ciclo → 1 linha em `pp_execucao`; ciclo novo depois → 2ª linha, `id`s distintos.
- **`app_pp_mapa`** ganhou a chave `historico_execucoes` (FeatureCollection + `n`) — mesmos filtros
  `p_colaborador/p_usuario/p_consorcio/p_data_ini/p_data_fim` das outras chaves, junta com `rede`
  (consórcio/`nu_trecho`) e `perfil` (nome). Frontend: 4º `fchip` ("Histórico de execuções", cor
  `#0891b2`, **`prodFilt.H` começa `false`** — as outras 3 camadas começam ligadas, essa é opt-in por
  ser potencialmente densa/sobreposta), renderizado tracejado (`dashArray:'2,6'`) pra não se confundir
  com a camada sólida "pesquisado (cadastro)"; tooltip mostra colaborador/data/comprimento e "herdado do
  vizinho" quando `origem='heranca_vizinho'`.
- **Ainda lendo estado ao vivo:** `app_pp_resumo`/`app_pp_por_colaborador`/`app_pp_minhas`/KPIs de
  `app_pp_mapa` leem o estado **ao vivo** de `programacao_pesquisa` (passada corrente). A tela de
  Acompanhamento (Fase 4, ver 4.3.7) é que vai somar/analisar histórico entre passadas via `pp_execucao`.

#### 4.3.7 Motor de passadas e redesenho do módulo (Fases 1-5 feitas 2026-09-14)

**Contexto:** o TR exige pesquisar **toda a rede 5 vezes** ao longo do contrato. Isso tornou o conceito
de "passada" (Nª pesquisa de cada trecho) de primeira classe, e motivou um redesenho do módulo separado
por **público**: o geofonista (campo) só executa + consulta o simples; o time interno (encarregado)
programa + analisa o profundo.

**Fase 1 — motor de passadas (backend, feito, em produção):**
- **Ordem obrigatória "programa → pesquisa".** `pp_recompute` só conta um trecho de campo se ele for
  **posterior** à programação do segmento (`t.inicio_ts >= programado_em`, 4.3.4). Trecho órfão (sem
  programação) ou anterior à programação **não** vira execução. Isso é o que garante, no banco, o
  princípio "sem programação não há execução" — sem precisar de trava agressiva na inserção do trecho.
- **Cada passada = uma linha nova.** Reprogramar um segmento (`app_pp_atribuir` com `sobrescrever`, 4.3.3)
  **apaga+recria** a linha → `id` novo, `programado_em=agora`. Com isso, um trecho já executado numa
  passada **não reacende sozinho** na passada seguinte (o trecho antigo agora é anterior ao novo
  `programado_em`); a passada N+1 exige **traço novo**. E como o `id` é novo, o dedup do histórico (por
  `programacao_id`, 4.3.6) deixa passar o lançamento da passada nova. `pp_execucao.n_passada` guarda o nº.
- **Testado (rollback E2E):** trecho anterior à programação é ignorado; posterior executa e loga
  `n_passada=1`; reprogramar abre passada 2 (não reaproveita o traço antigo, exige novo); ruído de
  recompute na mesma passada não duplica; `sobrescrever=false` não mexe em atribuição existente.

**Fase 2 — Pesquisa do geofonista (feita):** sumiço instantâneo do executado — ver 4.3.5.
**Fase 3 — "Minha produtividade" do geofonista, simplificada (feita):** ver 4.3.5.
**Fase 4 — tela de Acompanhamento do time interno (feita):** ver **4.3.8** abaixo.
**Fase 5 — trava de UX no campo (feita):** na tela Pesquisa, "▶ Iniciar trajeto" fica **desabilitado**
quando o geofonista não tem programação ativa (`app_pp_minhas` retorna 0), com aviso "sem programação
ativa — a pesquisa só conta dentro da sua programação". Flag `pqTemProg`/`pqAtualizarIniBtn` +
guarda em `pqIniciar`. **Permissivo offline:** só bloqueia quando sabemos (online, `app_pp_minhas` ok)
que não há programação — em erro/offline mantém liberado (pode ter programação, só sem sinal agora), pra
não travar campo sem rede. O banco já garante a regra (Fase 1); isto é a camada de clareza na UX.

#### 4.3.8 Tela Acompanhamento da pesquisa (Fase 4, 2026-09-14) — `pp_acomp` (Auxiliar de Programação)

Dashboard do **time interno** (aprovador/admin — herda o gate do Auxiliar de Programação), ao lado da
tela Programar. Módulo JS `pa*` (`paInit`/`paAtualizar`/…), reaproveita `prodHojeStr`/`prodMesIniStr`.
Cinco blocos: **filtros** (consórcio · colaborador · período) → **KPIs** → **progresso do TR** →
**mapa** → **resumo por colaborador**.
- **Dois km distintos (decisão de produto):** `km_andado` = soma dos `pesquisa_trecho` (o quanto a
  pessoa **andou**, com repetição de rua) · `km_rede_pesquisado` = soma dos segmentos que viraram
  execução no período via `pp_execucao` (o quanto de **rede** foi coberto). O indicador **`vaz/km` usa o
  km de rede**, não o km andado (densidade de vazamento por rede inspecionada). Velocidade média = km
  andado / tempo.
- **Progresso do TR (as 5 passadas):** barra empilhada mostrando quanto da rede já foi pesquisada 0/1/…/
  5+ vezes (cinza → teal escuro). É **cumulativo da rede inteira** (por consórcio) — **não** filtra por
  data/colaborador (o TR é um total, não um recorte de período).
- **Mapa de resultado — passadas + ocorrências + reporte (revisado 2026-09-14):** é uma tela de
  **análise de resultado**, então saiu o "programado" e a "cobertura de programação" (isso é da tela
  Programar, não daqui). O mapa é o **heatmap por nº de passadas** (base, `0×` **vermelho** `#dc2626`
  = nunca pesquisado → `5+×` teal escuro; `PA_PASS_COL`, mudou de cinza pra vermelho em 2026-09-15 porque
  o cinza sumia no mapa; usado também na legenda-filtro da Programação), por viewport via
  `app_pp_passadas_bbox`, recarrega no `moveend` — 46k segmentos, inviável de uma vez) +
  duas camadas **ativáveis** (chips acima do mapa): **Ocorrências** (pontos de vazamento, ligado por
  padrão) e **Reporte de campo** (trajeto real início→fim do colaborador — pedido do usuário pra comparar
  "o que andou" com o nº de passadas, desligado por padrão). O heatmap tem um **filtro-legenda dentro do
  mapa** (canto inf. dir., **exatamente igual ao da tela Programar** — 2026-09-15): clicar num bucket
  `0×`..`5+×` **isola** aquela faixa (multi-seleção; vazio = todas), `paPassSel` (Set). **Só re-renderiza
  o viewport atual filtrado, SEM dar zoom no clique** — o `fitBounds`-no-clique foi removido porque, como
  `0×` é ~99% da rede (a rede quase toda ainda não pesquisada), clicar `0×` dava zoom-out e enchia a tela
  de vermelho, parecendo que não filtrava. **Bug de camada órfã corrigido (2026-09-15):** o mapa
  rastreava o heatmap numa variável (`paHeat`) e removia só ela — mas `moveend` (pan/zoom) dispara vários
  `paCarregarMapa` **concorrentes** sobre `sb.rpc` async, e as chamadas antigas deixavam heatmaps
  **órfãos** (vermelho) no mapa; ao filtrar, só a rastreada saía, os órfãos vermelhos ficavam. Fix: um
  **`layerGroup` único** (`paLayerGrp`) com `clearLayers()` + **guarda de geração** (`paGen` — só a
  chamada mais nova, após o `await`, limpa e desenha). É o mesmo padrão da Programação (que usa
  `ppRedeLayer` layerGroup, por isso nunca teve órfã). **Não** tem mais o toggle de modo nem as camadas
  "pesquisado"/"histórico" — eram redundantes: o heatmap de passadas **é** derivado do histórico
  (`pp_execucao`). ("Pesquisado (cadastro)" era o estado ao-vivo do ciclo atual; "histórico" é o log
  permanente — pra análise só o histórico importa, e ele já vira o heatmap.)
- **KPIs (6, 2026-10-27):** km de rede pesquisado · km andado · vazamentos · **fraudes** · **ocorrências / km de
  rede** (`ocorr_km` = (vazamentos + fraudes) ÷ km de rede — substituiu o vaz/km na tela; a RPC ainda devolve
  `vaz_km`) · velocidade média. **Vazamentos não contam fraude** (§2.3).
- **Popup da ocorrência no mapa (2026-10-27):** clicar no ponto abre tipo, data de envio (`data_hora` = hora em
  que chegou ao servidor), nome de quem enviou, OS (se houver), 📷 foto, 🧭 Navegar (Google Maps) e **"Abrir na
  abertura de serviços ›"** → `pgOcAbrir` (§4.2). `paOcPopup`; é um `L.popup().openOn(paMap)` **avulso**, não
  `bindPopup`: o autoPan do popup dispara `moveend` → `paCarregarMapa` → `clearLayers`, que fecharia um popup
  preso ao marcador. `app_pp_passadas_bbox` devolve `foto`, `local`, `usuario_nome` nas ocorrências.
- **Abaixo do mapa, 2 blocos (2026-10-27, sw v278 — substituíram "Vazamentos por colaborador", "Ocorrências
  reportadas por colaborador" e "Resumo por colaborador", que se repetiam):**
  - **Produtividade por colaborador** (`paResumo`, colunas `PA_RES_COLS`): km andado · km de rede (com barra) ·
    vazamentos · fraudes · ocorr./km · km/h. **Cabeçalho ordena** (`paResSort`, padrão km de rede ↓); rodapé
    **Equipe** = os KPIs. Universo (`resumo`) = quem teve **rede executada, trecho andado ou ocorrência** no
    filtro (antes: só quem tinha rede programada/executada em qualquer data — quem só andou/reportou sumia e quem
    só foi programado aparecia zerado). Quem reporta sem lançar trecho aparece com km 0 e ocorr./km 0.
  - **Ocorrências por tipo e local** (`paMatriz`, `app_pp_acompanhamento.matriz` = `[{tipo,local,n,com_os}]`):
    linhas = tipos agrupados Vazamento / Fraude (todos os da lista, + antigos que aparecerem; subtotal no
    cabeçalho do grupo), colunas = locais (`OC_LOCAIS`/`OC_LOC_ROT`), total por linha e coluna, célula colorida pela
    intensidade (tooltip com com/sem OS). **Tocar na célula** → `pgOcAbrirFiltro(tipo,local,consórcio)` abre a
    Abertura de serviços na aba **Todas** já filtrada (§4.2). Período/colaborador do Acompanhamento **não** viajam
    (a Abertura não tem esses filtros), então lá pode haver mais cards que a célula.
  - `app_pp_acompanhamento.ocorrencias` (nome × tipo) ficou só p/ a v277 — pode sair da RPC depois do deploy da
    v278 (`docs/migracao_pesquisa_produtividade_matriz.sql`).
- **RPCs (SECURITY DEFINER, gate aprovador/admin):** `app_pp_acompanhamento(p_consorcio, p_colaborador,
  p_data_ini, p_data_fim)` → `kpis` + `progresso_passadas` (6 buckets 0..5) + `resumo` (km
  rede/andado/vaz/fraudes/ocorr-km/vaz-km/velocidade por colaborador) + `matriz` (tipo × local); `app_pp_passadas_bbox(xmin,ymin,xmax,ymax,
  p_consorcio, p_colaborador, p_data_ini, p_data_fim)` → `passadas` (heatmap) + `reportes` + `ocorrencias`
  (as duas últimas filtradas por consórcio/colaborador/data; casamento traço↔usuário por **nome OU
  email**, mesma pegadinha da 4.3.5). O dropdown "Todos os coletores" de análise vive **aqui** (tela do
  time interno). `app_pp_mapa` deixou de ser usado por esta tela.
- **Fora de escopo (registrado):** integração de um relatório do **SIGOS/COPASA** pra trazer a execução
  do vazamento (localizado ou não) — fica pra outro momento (decisão do usuário, 2026-09-14).
- **Ideia registrada p/ a tela Programar (interno):** filtro por nº de passadas (0 / 1 / 2 / …) sobre os
  segmentos candidatos — pro programador puxar "tudo em 0 passadas" (1ª rodada) ou "tudo em 2" (hora da
  3ª). Precisa `app_rede_bbox`/`app_pp_rede_no_poligono` exporem a contagem de passadas por segmento
  (join com `pp_execucao`).
- **Decisões do produto (2026-09-14):** passada contada **por segmento** (não rodada global
  sincronizada — "fechar rodada 1 antes da 2" é meta de rastreio, **sem trava**); próxima passada aberta
  **manual** pelo programador (nada de reabertura automática por prazo, por ora).

### 4.4 Gestão de Pavimento — `// --- Auxiliar de Programação: Gestão de Pavimento` · tela `pavprog` (2026-10-21)
- Categoria **🧱 Gestão de Pavimento** no hub do Auxiliar → card `data-go="pavprog"` (gate `aux_acesso`). Espelha a "abertura de serviços" da pesquisa: lista os registros do módulo de campo (`pavimento`, §2.6) **agrupados por ponto** (grupo), miniaturas das fotos (URL pública `fotos-campo`) e link de mapa. RPC `app_pav_listar` (gate admin|aux_acesso). *(2026-10-21c: botão Exportar removido; `pavpCons` select enxuto + `#pavpOrigDd` lado a lado, mesma pegada visual `.pavddsel`/`.msdd-btn`.)*
- **Cabeçalho espelhado na "abertura de serviços — ocorrências" (2026-10-21b):** **tabs de status** `.seg` (`#pavpStatusSeg`: ~~Pendentes / OS criada~~ → desde 2026-10-28 **Pendente de criação [default] / Pendente de execução / Executada / Todas**, ver "Etapa de execução" abaixo) + **alternância de visão** `.seg` (`#pavpViewSeg`: 📋 Lista / 🗺️ Mapa, `pavProgSetView`). **Mapa** (`#pavpMapa`, `pavProgMapa`): Leaflet (`L.map`+`mapAddCamadaBase`) com `circleMarker` colorido por faixa de prazo (pendentes) / teal (com OS), popup e `fitBounds`.
- **Filtros (client-side exceto consórcio):** consórcio (select, server-side — `app_pav_listar` filtra `consorcio = p_consorcio`, por isso o registro **precisa** ter consórcio; ver §2.6) · **serviço de origem = dropdown multi-seleção** (`.msdd`/`#pavpOrigDd` — botão + painel de checkboxes, `pavpRenderOrigDd`; fecha ao clicar fora) · **prazo = chips clicáveis com contagem** no `#pavpResumo` (🟢 no prazo / 🟡 atenção / 🔴 atrasado — cada chip mostra o nº e filtra; clicar força status=Pendentes). Removidos o select de prazo e o de ordenação (ordem fixa = mais antigos primeiro).
- **Controle de prazo (a partir da data de solicitação `created_at`):** `pavDias`/`pavBucket` (`PAV_SLA=[3,5]` → **0–3 no prazo · 4–5 atenção · >5 atrasado**) → badge colorido "faixa · há N dias" + borda esquerda; **o relógio conta só enquanto NÃO há OS** de recomposição.
- **Distinção OS criada × pendente (espelha a ocorrência da pesquisa):** o programador **lança a OS SIGOS da recomposição** no card pendente. Colunas na tabela `pav_recomposicao`: `os_recomposicao`/`os_recomp_em`/`os_recomp_por`. (⚠️ `os_sigos` = OS **de origem**, preenchida no campo, 1 por registro; `os_recomposicao` = OS **da recomposição**, preenchida aqui, **1 por tipo**.) sw v264.
- **OS da recomposição POR TIPO (2026-10-28, sw v282, `docs/migracao_pav_os_por_tipo.sql`):** antes havia 1 campo por grupo (`app_pav_os` gravava a mesma OS em todas as linhas) e a equipe digitava "OS1, OS2" no campo único. Agora **cada tipo pendente tem o seu campo** no card (`.pavosinp`, `data-id` = id da linha, placeholder "nº da OS SIGOS · <tipo>") + "Criar OS" → `pavProgCriarOS` grava **todos os campos preenchidos do ponto** numa chamada à RPC **`app_pav_os_itens(p_itens jsonb [{id,os}])`** (gate admin|aux_acesso; grava `os_recomposicao`/`os_recomp_em`/`os_recomp_por` **só na linha do tipo**; `os` vazio → limpa). Vírgula/ponto-e-vírgula no campo é bloqueada ("uma OS por tipo"). **Pendente = algum tipo sem OS** (`pavEhPend` olha `itens[]` → o relógio de prazo segue enquanto faltar OS em algum tipo). Tipo com OS mostra "✓ OS <nº> · lançada por X em dd/mm"; badge do card "✓ OS <nº>" (1 OS) ou "✓ OS criadas" (várias); popup do mapa lista "Tipo: OS" (`pavOsResumo`). `pavProgExport` (sem botão desde 21/10c) exporta status/OS **por tipo**.
  - **`app_pav_listar`**: cada item traz `id`/`os_recomposicao`/`os_recomp_em`/`os_recomp_por`; o `os_recomposicao` do grupo continua só p/ app em cache (1 OS → ela; várias → "A, B" na ordem do card).
  - **Legado `app_pav_os(p_grupo,p_os)`** (app em cache ≤ v281): se vier "A, B" só com números e nº de partes = nº de tipos, distribui **na ordem do card** (`order by tipo_pavimento`); senão grava igual em todas (como antes).
  - **Ordem do card = alfabética pela chave do tipo** (`app_pav_listar … order by tipo_pavimento`), não a ordem dos chips nem a de criação. Era a ordem que o programador via ao digitar "OS1, OS2" — critério usado na conversão dos dados antigos.
  - **Conversão dos dados antigos (2026-10-28, aprovada pelo usuário via planilha):** 5 grupos "OS1, OS2" → 1 OS por tipo na ordem do card (10 linhas; `os_recomp_em`/`os_recomp_por` intactos). Backup `"8 - coleta_campo"._bkp_pav_os_tipo_20261028` (12 linhas/6 grupos; reverter = `update … set os_recomposicao=b.os_recomposicao from _bkp… b where r.id=b.id`). **Pendente:** grupo `fed92e6c` (concreto + piso especial) ficou **AVALIAR** e segue com o texto antigo — a 2ª parte é a nota "não contem opção de recomposição de piso no SICOM", não uma OS. Planilha, snapshot e SQL em `COPASA/scripts/pav_os_por_tipo/` (fora do repo).
- **Etapa de execução (2026-10-28, sw v282, `docs/migracao_pav_execucao.sql`):** o rastro não para na OS. Fluxo **por tipo**: **pendente de criação** (sem OS) → **pendente de execução** (OS lançada) → **executada** (`pavEtapaItem`). O **ponto** fica na etapa **mais atrasada** dos seus tipos (`pavEtapa`) — é ela que define a aba, a cor da borda/badge (prazo / teal `⏳ Pendente de execução` / cinza `🏁 Executada`, `PAV_ETAPA_COR`) e a cor do marcador no mapa. O **prazo** (chips + relógio) continua medindo só a **criação** da OS (`pavEhPend` = etapa criação).
  - **Card:** tipo com OS e sem execução mostra **"Executado em [data]" + "Marcar executado"** (`.pavexdt` `type=date`, padrão = hoje, `max` = hoje, `min` = dia do registro) → `pavProgExecutar` pede `confirm()` e grava **só aquele tipo** (diferente do "Criar OS", que grava todos os campos preenchidos). Executado → "🏁 Executado em dd/mm/aaaa · marcado por X" (`pavFmtDia` formata `AAAA-MM-DD` sem passar por `Date`, p/ não voltar 1 dia no fuso). Sem botão de desfazer na tela (a RPC aceita `p_data null`).
  - **Banco:** colunas novas em `pav_recomposicao`: `execucao_data` (date, dia informado) / `execucao_em` (timestamptz, quando marcou) / `execucao_por`. RPC **`app_pav_executar(p_id uuid, p_data date)`** (gate admin|aux_acesso; exige OS; recusa data no futuro ou anterior ao registro; `null` desfaz). `app_pav_os_itens` com `os` vazio também limpa a execução. `app_pav_listar` devolve `execucao_*` em cada item.
  - **Export** (`pavProgExport`): coluna **Status** = etapa do tipo + **Executado em** / **Execução marcada por**.

---

## 5. Almoxarifado — `// MÓDULO SUPRIMENTOS` (~L2403) · tela `suprimentos` (schema `"9 - suprimentos"`)

**Nome exibido é "Almoxarifado"** (card da home, título, back-button, cabeçalhos de PDF) — mudou de
"Suprimentos" em 2026-09 (só o rótulo; screen id `suprimentos`, funções `sup_*` e o schema
`"9 - suprimentos"` continuam com o nome antigo, não vale a pena renomear isso).

Home própria (`supHome`) com duas seções: **📦 Áreas** (**Insumos**, **Equipamentos**,
**EPI/Uniforme**, **Ferramentas** — os cards sempre visíveis) e, separada, **📋 Conferência**
(**Baixas/Conferência** — visualmente apartada das 4 áreas porque não é "mais uma área", é a etapa de
conferência que consolida as outras). `SUP_ACTS` mapeia act→função; `supBlocks*` montam os menus por
papel (`ME`). Navegação interna por `supArea`/`supHome`/`supGoAct`; back inteligente em `#supBack`.
Helpers de papel no banco: `sup_funcao(uuid)`, `sup_e_almox(uuid)`, `sup_pode_aprovar(uuid)`.

**Acesso às categorias Almoxarifado/Conferência por engrenagem (2026-09-16, estilo Frota §6.0).** A
categoria **Almoxarifado** de cada área (Insumos/Equipamentos/EPI/Ferramentas) e a **Conferência**
(Baixas) **deixaram de ser gated por `is_almoxarife`** e passaram a ser controladas por **5 engrenagens
independentes** (⚙️ no cabeçalho de cada seção, **só admin**), uma por "área":
`baixas`/`insumo`/`equip`/`epi`/`ferramenta`. Tabela **`"9 - suprimentos".sup_acesso_area(colaborador_uuid,
area)`**; RPCs admin-only `app_sup_area_listar(p_area)`/`app_sup_area_set(p_area,p_uuid,p_on)`;
`app_me` devolve o mapa **`ME.sup_areas`** (`{baixas,insumo,equip,epi,ferramenta}`→bool; admin=todas).
Front: `supAreaAcesso(key)` (= `is_admin || sup_areas[key]`) gateia os blocos Almoxarifado (`supBlocks*`)
e a Conferência; `supCatArea(cat)` mapeia cat→área; `supAreaGate(areaKey,backFn)`/`supAreaGateRender`
são a tela da engrenagem (multi-seleção com busca, admin travado "acesso sempre"). **Seed:** os
almoxarifes atuais entraram nas 5 áreas (mantêm a visibilidade, agora removível). **Backend:**
`sup_e_almox(uid)` virou **aditivo** — `admin/almoxarife OU qualquer área concedida` — então as ~41 RPCs
que já gateavam por ele destravam automaticamente pra quem for concedido, **sem editar cada uma**
(superset → nada perde acesso). ⚠️ *Contrapartida:* o backend é **coarse** — quem tem QUALQUER área
concedida passa em `sup_e_almox` em todas as telas de almoxarife (a visibilidade fina é no front, por
área). Trava dura por área no backend fica pra uma 2ª rodada se necessário.

### 5.0 Aprovação = Aprovador 1/2 do solicitante (2026-10)
- **Insumos, Ferramentas, EPI e Troca de EPI** seguem a engrenagem **Aprovador 1/2** do perfil
  (`perfil.aprovador_uuid`/`aprovador2_uuid`, ⚙️ Usuários §5.6): a **fila** só mostra — e
  **aprovar/rejeitar** só aceitam — pedidos de quem tem o usuário logado como Aprovador 1 ou 2.
  Regra única no banco: **`"9 - suprimentos".sup_e_aprovador_de(aprovador, solicitante)`**
  (= `aprovador = any(sup_aprovadores_de(solicitante))`, então herda o **fallback**: solicitante sem
  aprovador configurado → qualquer `aprovador`/`admin` ativo). **Admin** (são 2) vê e aprova pedidos de **todos, menos os próprios** — os admins se aprovam entre si.
- RPCs que usam a regra: `sup_fila_aprovacao`, `sup_aprovar`, `sup_rejeitar`,
  `sup_ferramenta_fila_aprovacao` (ferramenta aprova/rejeita pelas mesmas `sup_aprovar`/`sup_rejeitar`),
  `sup_epi_fila_aprovacao`, `sup_epi_aprovar`, `sup_epi_rejeitar`, `sup_epi_troca_fila_aprovacao`,
  `sup_epi_troca_aprovar`, `sup_epi_troca_rejeitar`. Migração: `docs/migracao_aprovacao_por_aprovador.sql`.
- **Antes** qualquer aprovador/admin (e, no EPI, qualquer `sup_epi_gestor`, que inclui Téc. Segurança/
  Téc. Qualidade/Coord. QSMSS por cargo) via e aprovava pedido de qualquer pessoa — auditoria de
  2026-10-01 achou aprovações cruzadas entre áreas. **Admin vê/aprova todos, menos o próprio pedido**. `sup_epi_gestor` continua existindo só para **liberar o menu**
  de EPI no front (`ME.epi_gestor`); não dá mais poder de aprovação.
- **Autoaprovação bloqueada (aplicado em produção 2026-10-01, `docs/migracao_bloqueia_autoaprovacao.sql`):**
  ninguém aprova o próprio pedido — nem admin — em `sup_aprovar`, `sup_epi_aprovar`, `sup_epi_troca_aprovar`,
  `app_frota_manutencao_aprovar` (reportado_por) e `app_condutor_aprovar` (própria CNH); as 4 filas de aprovação
  não listam o próprio pedido. `sup_e_aprovador_de` também exige `aprovador <> solicitante`. Auditoria que
  motivou: 7 autoaprovações (EPI #22/#32/#37/#99, Insumos #1061/#1158, Manutenção de frota #1).
- ⚠️ **Cuidado:** fila/aprovação nova em Suprimentos → use `sup_e_aprovador_de`, nunca
  `sup_pode_aprovar`/`sup_epi_gestor` (esses só dizem "é aprovador de alguém", não "de quem").

### 5.1 Insumos
- Fluxo: **solicitar → aprovar (aprovador pode editar qtd/cancelar item) → segregar (almoxarife:
  existe/parcial/falta, gera código) → retirar (código) → consumir na OS**.
- **Cabeçalho das telas de separação do almoxarife (2026-10-13):** todos os cards de separação
  (Insumos/Ferramentas via `supAlmoxCard`, EPI via `supEpiSegCard`) mostram agora, via o helper
  compartilhado **`supSolicHead(s)`**: **nº · badge do consórcio de origem** (`supConsBadge` →
  `CONSORCIO_NOME`: ZA1004 "Águas Integradas" teal / ZA0200 "Eficiência Hídrica" roxo) + **👤
  solicitante** + **🗓️ data/hora da solicitação** (`supData(criado_em)`). Assim o almoxarife sabe
  de qual almoxarifado segregar. As RPCs `sup_fila_almoxarife` / `sup_ferramenta_fila_almoxarife` /
  `sup_epi_fila_segregar` passaram a retornar **`consorcio`** (= `perfil.consorcio` do solicitante).
  (De passagem, removido o `${s.equipe}` do head antigo do `supAlmoxCard`, que vinha `undefined`.)
- **Aprovador + entrega de EPI (2026-10-13):** o `supSolicHead` passou a mostrar também **✅ aprovado
  por X** (quem aprovou a solicitação). As 4 RPCs de fila do almoxarife (`sup_fila_almoxarife`,
  `sup_ferramenta_fila_almoxarife`, `sup_epi_fila_segregar`, `sup_epi_fila_entrega`) agora devolvem
  **`aprovador`** (= `perfil.nome` por `aprovador_uuid`) — ver `docs/migracao_almox_aprovador_consorcio.sql`.
  Além disso, a **entrega de EPI** (lista `epiEntregaLista` + detalhe `epiEntregaDetalhe`) passou a
  exibir **consórcio + data da solicitação + aprovador** (a `sup_epi_fila_entrega` ganhou `consorcio`);
  o detalhe usa o próprio `supSolicHead`. Mudança só aditiva nas RPCs.
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
- **Equipamentos cadastrados** (`eq_inventario`, categoria **Almoxarifado**, só almoxarife — 2026-09-15):
  inventário do acervo pro almoxarife ter gestão do que cadastrou. `supVEqInventario()` lê o mesmo
  `sup_equip_listar` (sem RPC nova) e monta filtros no topo — **busca** (nome ou nº de série),
  **tipo** (`select` com os tipos presentes) e **situação** em chips: Todos / Em estoque / Em uso /
  Manutenção (a chip Manutenção só aparece se houver algum). A **situação** é derivada por
  `eqInvSituacao(e)`: `manutencao_aberta||status='manutencao'` → *manutenção*; senão
  `status='em_uso'` → *em uso*; senão *em estoque* (`status='disponivel'`). A lista vem **agrupada por
  tipo** (`🧰 <tipo> (n)`; `tipo` nulo → "Sem tipo"), com resumo de contagens no topo; cada card mostra
  nº de série, chip de status (`eqStatusChip`), responsável (se em uso) e badges de manutenção/
  devolução solicitada/preventiva vencida. Estado em `eqInvData/eqInvTipo/eqInvBusca/eqInvSit`;
  filtros redesenham só `#eqInvLista` (a busca não perde foco).
- **Consórcio no equipamento (2026-10-22, sw v266):** coluna `sup_equipamento.consorcio` (ZA1004=**Águas Integradas**/Contagem · ZA0200=**Eficiência Hídrica**/Betim). **Cadastrar equipamentos**: dropdown de consórcio **obrigatório** (`sup_equip_cadastrar` ganhou `p_consorcio` — §0.6: 4→5 args). **Equipamentos cadastrados** (`eq_inventario`): passou a **permitir edição** — chip de consórcio no card + botão **✏️** que abre form inline (nome/consórcio/série/obs) → nova RPC **`sup_equip_editar(p_id,p_nome,p_consorcio,p_num_serie,p_obs)`** (almox) p/ adicionar consórcio nos já existentes; ganhou **filtro de consórcio** (`#eqInvCons`, inclui "— sem consórcio —"). **Solicitar equipamento** (`supVEqSolicitar`): **filtro de consórcio** (`#eqSolCons`) que filtra o dropdown de equipamentos (`supEqSolRenderOpts`). `sup_equip_listar`/`_disponiveis` devolvem `consorcio`; helpers `SUP_CONS`/`supConsLbl`/`SUP_CONS_OPTS`.
- RPCs: `sup_equip_cadastrar`, `sup_equip_tipo_cadastrar`, `sup_equip_tipos_listar`,
  `sup_equip_listar` (usada tb. pelo inventário acima — já traz tipo/status/responsável/
  manutencao_aberta/devolucao_solicitada/preventiva_*), `sup_equip_disponiveis`,
  `sup_equip_solicitacoes_pendentes`, `sup_equip_historico`, `sup_termo_ver`, `sup_termo_aceitar`,
  `sup_minhas_solic_equip`.
  Tabelas `sup_equipamento`, `sup_equip_tipo`, `sup_termo`, `sup_manutencao`, `sup_equip_solicitacao`.

### 5.3 EPI / Uniforme
- Espelha insumo: **solicitar → aprovar (edita/cancela qtd) → separar (almox, gera código, avisa) →
  retirar (código + foto do colaborador com os EPIs + assinatura)**. Devolução/troca por código, com
  fotos. **Tamanho** por escala: `letra` (P/M/G/GG/EXG) ou `numero` (33–48). EPIs saem do catálogo de
  insumos.
- **Rascunho anti-reload na retirada (2026-10-13):** no Android, abrir a câmera (`capture`) pode fazer
  o SO descartar a Activity da webview; ao voltar, o PWA recarrega do zero e perdia foto/código/CAs/
  assinatura. Correção: `epiEntregaDetalhe` mantém um **rascunho em `localStorage`** (`epi_entrega_rascunho`,
  helpers `epiDraftWrite`/`epiDraftClear`/`epiDraftColetar`) — salvo a cada digitação, **antes de abrir a
  câmera** (click no input) e quando a foto/assinatura chegam. No boot (`mostrar`→`app_me`→
  `epiEntregaTentarRestaurar`, 1×/carregamento, janela de 30 min, ignorado se há deep-link `?ntf=`),
  `epiEntregaRestaurar` reabre a entrega já preenchida (gate `supAreaAcesso('epi')`; se a solicitação já
  saiu da fila, descarta e mostra a lista). O canvas de assinatura ganhou `cv._restore(dataURL)` e um
  hook `cv._onend`. Rascunho é limpo ao **confirmar** a retirada ou tocar **‹ Voltar**.
- RPCs: `sup_epi_catalogo`, `sup_epi_minhas_solicitacoes`, `sup_epi_fila_aprovacao`,
  `sup_epi_troca_fila_aprovacao`, `sup_epi_fila_segregar`, `sup_epi_segregar`, `sup_epi_fila_entrega`,
  `sup_epi_meus`, `sup_epi_devolver`, `sup_epi_substituir`, `sup_epi_gestao_colaborador(es)`,
  `sup_epi_ficha` (ficha consolidada). Fotos via `epiUpload` (pasta `epi`).
- **Gestão de EPI liberada também por CARGO (2026-09), não só por acesso (`funcao`).** Os cards
  **Aprovar EPI** (`epi_aprovar`) e **EPIs por colaborador** (`epi_painel`; a mesma tela também abre no QSMS › EPI —
  `supVEpiPainel(root,pre)` desenha no container recebido, §18) são liberados pra
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
- **Correção de navegação (2026-09-15) — Ferramentas reusa código de Insumos que assumia o contexto de
  Insumos:** (1) `supAlmoxWire` (fiação de segregar/entregar, compartilhada) recarregava fixo em
  `supVAlmox` (fila de **Insumos**) — na tela **Ferramentas › Separação e entrega**, concluir uma
  segregação ou entrega **pulava pra fila de Insumos**. Agora `supAlmoxWire(refreshFn)` recebe a função
  de refresh (default `supVAlmox`; `supVFerramentaAlmox` passa a si mesma). (2) `supGoAct` (deep-link de
  notificação) setava `supAreaId='insumos'` pra qualquer act não-`eq_`/`epi_` — os acts `ferramenta_*`
  (devolução: `ferramenta_recebimento` p/ almoxarife, `ferramenta_pedidos` p/ colaborador) abriam a tela
  certa mas na **área Insumos** (botão voltar "‹ Insumos", voltava pra Insumos). Corrigido o prefixo
  `ferramenta_`→`'ferramenta'`. **Regra:** ao reusar `supAlmoxWire`/`supAcao` numa área nova (não-Insumos),
  passe sempre o refresh da própria área; e todo prefixo de act novo precisa entrar no mapeamento de
  `supAreaId` do `supGoAct`.

### 5.5 Baixas / Conferência (almoxarife)
- Consolida entregas por período p/ baixa no **SIENGE**, **por consórcio** (do perfil de quem retirou).
  RPCs: `sup_baixas_relatorio` (5 args, com `p_consorcio`), `sup_baixas_marcar`,
  `sup_epi_baixa_fila`/`_solicitar`/`_cancelar`, `sup_epi_minhas_baixas`.
- **Ferramentas passaram a entrar na baixa (2026-09-16, a pedido do usuário — reverte o fix anterior
  que as excluía).** `sup_baixas_relatorio` agora tem 3 CTEs: `ins` (`not m.ferramenta`), `fer`
  (`m.ferramenta`, `tipo='ferramenta'`, mesmo caminho `sup_solicitacao_item`) e `epi`; o filtro `bxTipo`
  ganhou a opção **"Só ferramentas"** e o "todos" virou "Insumos, ferramentas e EPIs". `sup_baixas_marcar`
  aceita `p_tipo='ferramenta'` (roteia pro mesmo `update sup_solicitacao_item` do insumo). Cada linha
  mostra um **pill de tipo** (📦/🔧/🦺).
- **Export XLSX (2026-09-16):** botão **⬇ XLSX** exporta a lista filtrada (o `bxUltimo` corrente) via
  helper genérico `exportarXlsx(nome,aba,aoa)` — carrega **SheetJS sob demanda** por `import()` do CDN
  oficial (`cdn.sheetjs.com/xlsx-0.20.3/package/xlsx.mjs`, cacheado em `_xlsxLib`); colunas
  Consórcio/Tipo/Código/Descrição/Tamanho/Unidade/Quantidade/Nº entregas/Status. Reutilizável por
  outras telas.

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
- Notificações de aprovação vão só aos aprovadores diretos (`sup_aprovadores_de`) — e, desde 2026-10,
  **só eles aprovam** (fila + aprovar/rejeitar, §5.0).

---

## 6. Frota — schema `"10 - Frotas"` · tela-hub `frota` (+ telas internas `condutor` / `frotas`)

Um público entra por **um só card** na home (🧰 Suporte › **🚗 Frota**, `data-go="frota"`). Fluxo
**(reformulado 2026-09, 3ª rodada)**: **Frotas** (`funcao='frotas'`/admin) cadastra a CNH do
colaborador → colaborador é avisado e **assina o termo de responsabilidade de condução** (assinatura
eletrônica, igual EPI) → ativo → colaborador **se vincula a um veículo disponível sozinho**
(self-service, tela **Veículos** do próprio Colaborador — não é mais o gestor quem faz isso).
Colaborador faz **checklist diário** (com botão de reportar problema embutido) e usa as
telas próprias de **Lavagem** e **Manutenção** — cada uma é histórico + ação, não só um formulário
avulso (ver §6.1). **Abastecimento foi removido por completo em 2026-10-14 (ver §6.5).** Frotas **agenda** a lavagem (data/horário/local) e o colaborador confirma a
execução depois. Problema reportado vira **solicitação de manutenção**: colaborador solicita →
gestor aprova → Frotas agenda (só a **data** — o custo não entra mais aqui) → **o colaborador (ou,
como reforço, a Frotas) dá baixa** quando busca o veículo no mecânico, informando o **custo final**
nesse momento (**5ª rodada, 2026-09** — antes só Frotas concluía, e o custo entrava errado na
agenda, antes de se saber o valor real). **Ao terminar de usar o veículo, o colaborador se
desvincula sozinho, liberando-o pra outra pessoa** — **não existe mais empréstimo como mecanismo
separado**: "emprestar" é simplesmente desvincular + a outra pessoa vincular (ver §6.1). Equipes,
ocorrência genérica, aluguel com histórico de reajuste e a etapa de treinamento de direção defensiva
(QSMS) **já haviam sido removidos por completo** numa rodada anterior (ver §6.3/§6.4 e "Tabelas"
abaixo). **Navegação (5ª rodada):** cada subtela mostra **um único botão de voltar** — a barra fixa
do topo (`#condBar`/`#frotasBar`, "‹ Frota") só aparece na tela-raiz de cada módulo; qualquer subtela
usa o próprio "‹ Voltar" contextual (ver §6.0).

### 6.0 Hub `frota` — `// ----- HUB da Frota` (~L4856)
- Estilo Suprimentos/Insumos: `frotaInit` → `frotaHome` renderiza **seções → botões**; `frotaBlocks()`
  monta as seções e o gate de cada uma (seção sem acesso **não aparece**, diferente do `supArea` que
  mostra bloqueada). `frotaInit` também busca `app_frota_meu_veiculo()` (→ `frotaMeuVeiculo`) **antes**
  de renderizar, pra decidir quais botões ficam habilitados:
  - **👤 Colaborador** (`on:true`, todo usuário): Minha CNH (só dados de CNH — não lista mais
    veículos nem lavagens, ver §6.1) · **Veículos** (vincular/desvincular a si mesmo, self-service,
    §6.1) · Checklist diário · **Manutenção** · **Lavagem** — **estes últimos 3
    ficam desabilitados** (`disabled`, opacidade reduzida) **enquanto `frotaMeuVeiculo` é `null`**
    (colaborador sem veículo vinculado não tem o que fazer neles). **Checklist diário
    também desabilita (6ª rodada) se `frotaMeuVeiculo.status==='manutencao'`** — flag
    `bloqueiaManutencao:true` no item; Manutenção e Lavagem continuam liberados nesse caso (ver §6.1
    "Cuidados" sobre o gate real ficar na RPC, não só aqui). Os botões de Manutenção/Lavagem
    **renomeados na 5ª rodada** (eram "Registrar problema (manutenção)"/"Solicitar lavagem" —
    ficaram genéricos porque agora abrem uma tela de histórico + ação, não só um formulário avulso,
    ver §6.1). **"Emprestar" não existe mais como ação própria.**
  - **🖊️ Gestor** (`ME.pode_aprovar||is_admin`): **Aprovar manutenções** (tela própria). *(O **Relatório**
    saiu daqui em 2026-09-15 → foi pra Equipe administrativa, pra ser controlado pela engrenagem.)*
  - **🏢 Equipe administrativa** (`is_admin || frota_admin` — **só admin + engrenagem**, 2026-09-16):
    Veículos · Condutores · Lavagens a agendar · Manutenções a agendar · **Relatório** (histórico/custos de
    acompanhamento, §6.2 — movido de Gestor em 2026-09-15 pra que quem for liberado na engrenagem veja).
    **O cargo `funcao='frotas'` NÃO é usado (não existe ninguém com ele) e foi tirado dos gates** `adm`
    (`frotaBlocks`) e `full` (`frotasRenderHome`), a pedido do usuário — o acesso à categoria inteira,
    incluindo o Relatório, vem **exclusivamente da engrenagem (+ admin)**.
    - **Engrenagem ⚙️ (2026-09-15, admin-only) — quem vê a Equipe administrativa:** no cabeçalho da seção
      (só pra `is_admin`), abre `frotaAdminGate()` (sub-view de `#frotaView`, back → `frotaHome`): lista os
      usuários ativos com busca e um checkbox por pessoa (`app_frota_admin_listar`/`app_frota_admin_set`,
      admin-only). Marca o flag **`perfil.frota_admin`** (exposto no `ME` pelo `app_me`). **Só o admin
      aparece travado** ("acesso pelo cargo" = `funcao='admin'`); todos os outros têm checkbox
      **destravável** — inclusive quem já é `frota_admin` (antes `acesso_pelo_cargo` incluía `frotas` e o
      próprio `frota_admin`, o que travava a concessão e impedia revogar; corrigido 2026-09-16). **O backend
      acompanha:** as RPCs `app_frota_*` gateadas incluem `or coalesce(frota_admin,false)` (o `funcao='frotas'`
      segue tolerado no SQL por ser inócuo, mas não concede nada na prática). **Regra:** RPC nova de Equipe
      administrativa deve incluir `frota_admin` no gate.
- **`frotaOpen(id)` é um roteador** — não duplica render. Seta um alvo e chama `irPara`:
  - ações de Colaborador → `condTarget={sub,act}` + `irPara('condutor')`; `condInit` consome o alvo
    depois do load (`condGoTarget`). Ação que precisa de veículo (`situacao`/
    `manutencao`/`lavagem`) sem `condMeuVeiculo` → `toast` (segunda trava, além do botão desabilitado
    no hub). `veiculos_meu`→`condSub='veiculos'` (tela self-service, §6.1); "Minha CNH" sempre cai na
    home do condutor. **`manutencao` (5ª rodada, renomeado de `ocorrencia` — nome antigo remontava a
    um conceito já removido) → `condSub='manutencao'`** (a tela de histórico, não mais direto no
    formulário de reportar problema).
  - Gestor/Admin → `frotasTarget` (`'condutores'|'painel'|'lavagem_fila'|'manutencao_fila'|
    'manutencao_aprovar'`) + `irPara('frotas')`; `frotasInit` consome. **"Histórico" não é mais um
    alvo direto** — só se chega lá de dentro de Relatório ou do Detalhe de um veículo (§6.2).
- **Uma barra, um botão de voltar por tela (5ª rodada):** cada subtela de `condutor`/`frotas` já
  renderizava seu próprio "‹ Voltar" contextual (ex.: de Vínculo volta pro Detalhe do veículo, não
  pro hub) — mas a barra fixa do topo (`#condBar`/`#frotasBar`, "‹ Frota") **também** ficava visível
  o tempo todo, então toda subtela mostrava **dois** jeitos de voltar (um pro hub, sempre; outro
  contextual). `condSetBar()`/`frotasSetBar()` (chamadas no topo de `condRender`/`frotasRender`)
  escondem a barra fixa sempre que `condSub`/`frotasSub !== 'home'` — só a tela-raiz de cada módulo
  (onde não há "‹ Voltar" próprio) continua mostrando "‹ Frota". Deep-links de notificação
  (`supGoAct`, §7) apontam pra `condutor`/`frotas` com o alvo certo já setado (ex.:
  `frota_lavagem_agendar` → `frotasTarget='lavagem_fila'`; **`frota_minhas_lavagens`/
  `frota_manutencao` (5ª rodada) → `condTarget={sub:'lavagem'|'manutencao',...}`, antes caíam sem
  alvo na home do condutor (CNH), não na tela relevante**).

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
  **Anexo aceita PDF além de foto (2026-09-17):** os dois pickers de CNH (gestor `frcFoto` e
  colaborador `condfFoto`) usam `fotoPickHtml(...,{pdf:true})` — ganham um 3º botão **📄 PDF**
  (`accept="application/pdf"`) ao lado de Câmera/Galeria. O `fotoPickHtml`/`wireFotoPick`/`uploadFoto2`
  passaram a ser genéricos: PDF **não** é comprimido (imagem segue via `comprimirGeral`), mostra
  "📄 PDF anexado" no lugar do preview `<img>`, e sobe como `.pdf`/`application/pdf` (helper
  `foto2EhPdf`); a exibição já era **link** ("Ver foto da CNH"), então abre PDF ou imagem igual. O
  bucket `fotos-campo` teve `application/pdf` **adicionado ao `allowed_mime_types`** (antes só
  jpeg/png/webp). `opts.pdf` é opcional → todos os outros forms que usam `fotoPickHtml` seguem só-imagem.
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
  captura. Vermelho/verde igual ao termo de equipamento (`TERMO_CSS`, compartilhado). **Conteúdo do
  termo (2026-09-15):** além da declaração geral (a)-(e), a seção "Termo" lista as **17 normas de
  utilização de veículos** da empresa (`FROTA_TERMO_NORMAS`, const no frontend — texto legal, não vem do
  banco) + uma linha de "declaro ter lido e concordo". Os itens 14 e 16 da lista original do usuário eram
  idênticos → mantido só uma vez. `condIrTermo`
  (banner "Minha CNH") abre pra assinar; `condIrTermoVer`/`frCondVerTermo` abrem read-only
  (`canSign=false`) — condutor já ativo, ou gestor conferindo. `app_frota_termo_ver(p_termo_id)` gate:
  o próprio condutor, ou `funcao in ('frotas','admin','aprovador')`. `app_frota_termo_assinar(p_termo_id,
  p_assinatura)`: só o próprio condutor, só termo `pendente` — grava `assinatura_path`, `assinado_em`,
  e **atualiza `frota_condutor.status='ativo'`** (é essa `UPDATE` que dispara a notificação "está
  ATIVO", via trigger — mesma mecânica de antes, só a causa mudou de "treinamento confirmado" pra
  "termo assinado"). Reaproveita a coluna `treinamento_confirmado_em` pra guardar o timestamp da
  assinatura — nome ficou desatualizado (era específico de treinamento), não valeu a pena renomear
  só por isso.
- **Ver a foto/PDF da CNH:** `condRenderHome` mostra link "Ver foto da CNH" (`SBASE+cnh_foto`) pro
  próprio condutor quando `condData.cnh_foto` existe. **Do lado do gestor (2026-09-23):**
  `frotasRenderCondutorCadastro` ganhou o mesmo link ("ver CNH", ao lado de "ver termo") — antes
  `app_frota_usuarios_completo()` não devolvia `cnh_foto`, então o gestor só via número/categoria/
  validade em texto e não conseguia conferir o arquivo anexado sem entrar como o próprio condutor;
  a RPC agora devolve `cnh_foto` também. Mesmo helper `fotoURL(p)` (=`SBASE+p`) dos dois lados.
- **Alerta de vencimento:** `app_condutor_meu` retorna `cnh_vencendo` (validade ≤ hoje+30) **e**
  `cnh_dias_para_vencer` (`cnh_validade - current_date`, pode ser negativo se já venceu). Exibido
  como banner (com a contagem de dias) em `condRenderHome` quando `status==='ativo'`, e como
  texto ao lado da validade sempre que a CNH existe.
- **Checklist diário, problema (manutenção), lavagem — todos no ÚNICO veículo
  vinculado ao colaborador (reformulado 2026-09, 3ª rodada; abastecimento removido 2026-10-14):** `condMeuVeiculo` =
  `app_frota_meu_veiculo()` (objeto único ou `null` — **substitui** o antigo `condVeiculos`/lista;
  desde que um vínculo só pode existir por vez por pessoa, não faz mais sentido escolher entre
  vários). Mesmo formato de antes (`id,placa,modelo,tipo,km_atual,status,consorcio,
  ultima_lavagem_em,lavagem_atrasada`), só que **um objeto, não array** — todas as 4 telas abaixo
  usam esse veículo direto, **sem seletor de placa** (não existe mais `condRenderPick`/
  `condVeiculoSel` — ficaram sem sentido com 1 veículo só por pessoa).
  - **Checklist** (`condRenderSituacao`/`condSalvarSituacao` → `app_frota_situacao_salvar`, tabela
    `frota_checklist_situacao`, itens do checklist em linhas label+checkbox alinhadas dentro de um
    cartão único; campo "Observações" vai pro mesmo `p_avarias` da RPC) ganhou um botão **"🔧
    Encontrou um problema? Registrar"** que leva direto pra `condSub='ocorrencia'` (o formulário de
    manutenção, ver abaixo) — checklist e problema são passos separados, mas o segundo é um atalho
    de dentro do primeiro. **Itens começam desmarcados (5ª rodada)** — antes vinham todos pré-`checked`,
    então "tudo OK" era o estado inicial mesmo sem o colaborador de fato ter olhado cada item; agora
    é preciso marcar item por item pra registrar `p_status='ok'` de verdade. **Até 6 fotos opcionais
    (2026-09-28)** — antes só `sitfFoto1`; `app_frota_situacao_salvar` ganhou `p_foto2..p_foto6 text
    default null` **no fim da assinatura** (aditivo — não removeu/renomeou `p_fotos text[]`
    existente) e monta o array final com `coalesce(p_fotos,'{}') || array_remove(array[p_foto2..6],
    null)`. Mesmo assim, como Postgres/PostgREST tratam qualquer mudança na lista de parâmetros
    como um **overload novo** mesmo só acrescentando opcionais no fim (não é um "replace" de
    verdade), foi preciso **dropar explicitamente a assinatura antiga de 14 parâmetros** depois de
    criar a nova de 19 — confirmado ao vivo que não sobrou overload ambíguo e que chamadas no
    formato antigo (14 params) continuam resolvendo normal contra a função nova.
  - **Checklist por faces + supervisão + manutenção automática (2026-10-15, sw v250):** o checklist ganhou
    robustez. Mantém os **itens de segurança** (6 toggles) e acrescenta uma seção **"Faces do veículo"** com
    **9 faces** (`FR_FACES`: capô, dianteira, lat. esq./dir. dianteira, lat. esq./dir. traseira, teto, traseira,
    **motor**) — cada face com **foto obrigatória** + toggle **"Tem ocorrência?"** + descrição (obrigatória quando há
    ocorrência). Nova coluna **`frota_checklist_situacao.faces jsonb`** (array `{face,label,foto,ocorrencia,descricao}`).
    `app_frota_situacao_salvar` recriado (⚠️ §0.6: assinatura de 20 params **dropada**; nova com **`p_faces jsonb`**)
    e agora, se houver ≥1 face com ocorrência, **insere UMA `frota_manutencao`** (status `pendente`, `tipo_problema='checklist'`
    — valor **adicionado ao CHECK** `frota_manutencao_tipo_problema_check`) com `servico_solicitado` juntando as faces +
    descrições e `fotos_antes` = fotos das ocorrências → cai na fila do responsável de frotas. ⚠️ **O checklist deixou de ser
    offline-first** (`condSalvarSituacao` agora é **online**: sobe as 9 fotos, monta `p_faces` com os paths e chama a RPC;
    falha pede conexão) — o peso de 9 fotos + tecer paths no jsonb não cabia na fila offline. O botão/atalho "Registrar
    problema" de dentro do checklist saiu (as ocorrências por face o substituem). As 6 fotos genéricas também saíram (as faces
    cobrem).
  - **Supervisão de checklists da equipe (2026-10-15):** novo card **📋 "Checklists da equipe"** no hub (bloco **Gestor**,
    visível a **aprovador OU admin OU responsável de frotas** — `frotaBlocks` ganhou `on` por ação + bloco `on=gestor||adm`;
    `frotaOpen`→`frotasTarget='chk_equipe'`). Tela `chk_equipe` (`frotasRenderChkEquipe`): **matriz veículo × últimos N dias**
    (7/15/30) com ✓ feito · ⚠ feito com ocorrência · ✕ não fez; toque numa célula abre o **detalhe** (`chk_detalhe`/
    `frotasRenderChkDetalhe` — itens, observações e faces com foto/descrição). **Escopo:** RPC `app_frota_checklist_supervisao(p_dias)`
    — admin/`frota_admin` veem **todos** os veículos com vínculo ativo; o **aprovador** vê só os veículos cujo condutor atual o
    tem como `aprovador_uuid`/`aprovador2_uuid`. Detalhe por `app_frota_checklist_detalhe(p_id)` (gated: admin/frotas, aprovador
    do autor, ou o próprio). Ambas definer, `authenticated`. Validado E2E (admin 11 linhas, aprovador 2, detalhe ok).
  - **Manutenção** (`condRenderManutencao`, `condSub='manutencao'`, **tela própria desde a 5ª
    rodada** — antes o botão do hub ia direto pro formulário de reportar problema, sem nenhum
    histórico visível): lista tudo que o colaborador já reportou (`app_frota_minhas_manutencoes()`,
    nova — não existia forma alguma do colaborador ver suas próprias manutenções antes disso) com
    status (`pendente→aprovado/reprovado→agendado→concluido`) e um botão **"🔧 Reportar problema"**
    que abre o formulário (`condRenderOcorrencia`, sem mudança de conteúdo): tipo do problema
    (`TIPO_PROBLEMA`: pneu furado/freio/motor/elétrica/suspensão/bateria/ar-condicionado/
    vidro-retrovisor/outro), detalhamento + **foto obrigatória**, **sem campo de valor** (o custo só
    entra na conclusão, não na solicitação nem no agendamento — ver abaixo) →
    `app_frota_manutencao_solicitar(p_veiculo_id,p_tipo_problema,p_servico_solicitado,
    p_fotos_antes[])`, grava com `status='pendente'`; ao salvar volta pra `condSub='manutencao'`
    (a lista), não mais pra "Minha CNH". **Dar baixa (`condSub='manutencao_concluir'`, 5ª rodada —
    faltava por completo antes): quando a manutenção está `agendado`**, a lista mostra "Registrar
    conclusão" → data de liberação + **custo final** (opcional) + foto opcional →
    `app_frota_manutencao_concluir(p_id,p_data_liberacao,p_fotos_conclusao,p_orcamento_valor)`.
    **É o próprio colaborador quem dá baixa agora** (foi ele quem foi buscar o carro no mecânico) —
    a RPC aceita `v_id=reportado_por` **ou** `funcao in ('frotas','admin')` (Frotas mantém um
    caminho de reforço em Painel › Manutenções, ver §6.2). Ao concluir, `frota_veiculo.status`
    volta de `manutencao` pra `em_uso` (se ainda tiver vínculo aberto) ou `disponivel`.
  - **Lavagem** (`condRenderLavagem`, `condSub='lavagem'`, **tela própria desde a 5ª rodada** —
    mesmo motivo da Manutenção acima): lista o histórico completo (`app_frota_minhas_lavagens()`)
    com status (`solicitada→agendada→realizada|cancelada`) e um botão **"Solicitar lavagem"**
    (`app_frota_lavagem_solicitar(p_veiculo_id)`, sem formulário) — **escondido se já existir uma
    solicitação em aberto** (`solicitada` ou `agendada`), pra evitar solicitação duplicada por
    engano. Frotas agenda (data/horário/local, ver §6.2) e notifica; o item `agendada` na lista
    ganha um botão **"Registrar execução"** (`condRenderLavagemRealizar` →
    `app_frota_lavagem_realizar(p_id,p_valor,p_foto)`, valor/foto opcionais) que fecha o ciclo e
    volta pra `condSub='lavagem'` (antes voltava pra "Minha CNH", que também mostrava essa lista
    embutida — **removida de lá na 5ª rodada**, CNH agora só mostra dados de CNH). Tabela
    `frota_lavagem` tem `solicitado_em/agendado_por/data_agendada/horario_agendado/local_agendado/
    realizado_em` — as colunas `data`/`valor`/`foto` significam "da execução", só preenchidas no
    fim do ciclo.
  - **`p_consorcio` não é escolhido na tela** — vem direto de `v.consorcio` (o veículo,
    obrigatoriamente vinculado a um consórcio desde o cadastro em Frotas, §6.2).
  - **Abastecimento removido (2026-10-14):** a tela de abastecimento do colaborador (`condRenderAbastecimento`/
    `condSalvarAbastecimento`), a lista fixa `COMBUSTIVEIS` (Etanol/Diesel/Arla) e a tabela/RPC do
    banco saíram por completo (ver §6.5). `situacao` segue como ação offline que precisa de veículo.
  - **Online-only (2026-10-15):** checklist/situação **deixou de ser offline-first** quando ganhou as faces
    (9 fotos + `p_faces` jsonb com os paths — não cabia na fila). `condSalvarSituacao` agora sobe as fotos e chama a
    RPC direto. **Problema/manutenção e lavagem** sempre foram online-only. (Histórico: antes `condSalvarSituacao` usava
    `enviarOuEnfileirar` com `fotosArray:['p_fotos']`.)
  - **Alerta de lavagem atrasada** (`v.lavagem_atrasada`, banner no card do veículo): calculado **na
    leitura**, sem job/cron — última lavagem `realizada` (ou a data de início do vínculo, se nunca
    lavou) ≤ hoje − 30 dias. Mesmo padrão de `cnh_vencendo` em `app_condutor_meu`.
  - **Quem pode agir num veículo agora** é decidido por `"10 - Frotas".condutor_tem_veiculo(uid,
    veiculo_id)` (reaproveitada em `app_frota_meu_veiculo`,
    `app_frota_manutencao_solicitar` e `app_frota_lavagem_solicitar`) — **simplificada nesta rodada**
    pra checar só **vínculo aberto** (`frota_veiculo_vinculo`, `desvinculado_em is null`); a
    cláusula de empréstimo-ativo foi removida (empréstimo não existe mais como mecanismo separado,
    ver "Vincular/desvincular" abaixo). Checklist continua **sem checagem de vínculo** no backend (só
    o frontend já auto-seleciona `condMeuVeiculo`). `app_frota_manutencao_solicitar`/
    `app_frota_lavagem_solicitar` também aceitam `funcao in ('frotas','admin')` **sem** precisar de
    vínculo (Frotas solicita em qualquer um). **Checklist passou a recusar se
    `frota_veiculo.status='manutencao'` (6ª rodada)** — o veículo não está fisicamente com o
    colaborador nesse estado; o hub também desabilita o botão nesse caso (ver §6.0), mas quem
    garante de verdade é a RPC (deep-link de notificação passa por cima do botão desabilitado).
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
- **Estado:** `condSub, condMeuVeiculo, condData, condMinhasLavagens, condLavagemSel,
  condManutencoes, condManutencaoSel`. **`condMinhasLavagens`/`condManutencoes` viraram lazy (5ª
  rodada)** — antes `condMinhasLavagens` era buscado junto com `condMeuVeiculo` em **todo** load do
  Condutor (mesmo em telas que não usavam); agora só `condRenderLavagem`/`condRenderManutencao`
  buscam, no momento em que a tela abre — uma chamada a menos em cada navegação que não precisa
  desse dado.

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
  eram 5 botões espremidos no card, **agora moram dentro do Detalhe** (ver abaixo). **Removidas as 3
  seções-atalho abaixo da lista (5ª rodada)** — "Condutores"/"Lavagens a agendar"/"Manutenções a
  agendar" apareciam aqui *e* como botões próprios no hub (§6.0); mesma ação, dois caminhos —
  ficaram só no hub, essa tela agora é só a lista de veículos + cadastro.
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
  - **`centro_custo` é um `select` fechado** (`CENTROS_CUSTO_FROTA`, `[código Nível 4, descrição Nível 3]`
    — ex. `['01.001.007.002','GESTÃO DO PROJETO']`). **A regra é usar o código completo do item
    "Equipamentos" (Nível 4), mas mostrar a descrição do pai (Nível 3)** — o Nível 4 quase sempre se chama
    só "EQUIPAMENTOS", não identifica nada sozinho. Lista fixa no frontend, sem `CHECK` no banco (mudar a
    lista de centros de custo não exige migração). **Reduzida de 33 → 16 opções pelo usuário (2026-09-15)**
    — subconjunto das frentes que de fato usam veículo; um veículo com `centro_custo` fora da lista nova só
    exibe o código cru (`labelOf` degrada graciosamente), sem quebrar. O único veículo real teve o
    `centro_custo` antigo (texto livre "4.2.8", formato incompatível) **zerado** na migração — precisa ser
    reaberto e salvo de novo com o valor certo do dropdown.
  - **`tipo_combustivel` (dropdown `#fvfCombustivel`, `COMBUSTIVEIS_VEICULO`):** lista atualizada para
    **Etanol / Diesel / Outros** (2026-09-16) — **substitui** Flex/Gasolina/Diesel/Outros. Sem `CHECK` no
    banco; veículo com valor antigo (`flex`/`gasolina`) só exibe o código cru via `labelOf` até ser
    reaberto e salvo.
  - **`consorcio` (dropdown `#fvfConsorcio`, obrigatório):** mostra os **nomes** dos consórcios —
    **Águas Integradas** (valor `ZA1004`) e **Eficiência Hídrica** (valor `ZA0200`) — 2026-09-15. O
    **valor gravado continua o código `ZA1004`/`ZA0200`** (todo o resto do app filtra por ZA), só o rótulo
    do dropdown mudou. O relatório do veículo ainda exibe o código cru em `Consórcio` (não pedido mudar).
  - **Aluguel removido, só sobra o campo `contrato_numero`** (já existia) — pra vincular ao contrato
    de locação existente. **`app_frota_veiculo_aluguel_reajustar`/`_historico` foram apagados** (a
    tabela `frota_veiculo_aluguel_historico`, com 1 linha real de reajuste, **foi mantida** — só
    ficou desconectada da UI, não tinha por que apagar dado financeiro real).
  - `consorcio` continua **obrigatório** (`ZA1004`/`ZA0200`, validado na RPC e no banco).
  - **`p_fotos` (até 3, `fvfFoto1/2/3` + `wireFotoPick`) e `p_km_inicial`** — sem mudança: `fotos` é
    `coalesce`ado na edição (substitui todas se enviar algo novo); `km_inicial` só gravado na
    criação. **Devolução à locadora virou tela própria** (`frotasRenderVeiculoDevolver`,
    `frotasSub='veiculo_devolver'`, 6ª rodada — antes era `confirm()`+`prompt()` nativos); RPC
    `app_frota_veiculo_devolver` sem mudança.
- **Detalhe do veículo** (`frotasRenderVeiculoDetalhe`, `frotasSub='veiculo_detalhe'`, **novo
  2026-09, 3ª rodada** — abre a partir do botão "Ver detalhes" da lista): identificação/locação/km +
  seção **Vínculo** (mostra quem está vinculado, se alguém, com botão pra gerenciar) + botões
  **Editar** (`veiculo_edit`, mesma tela de sempre), **Histórico** (pré-preenchido com este veículo,
  `frHistBackTo='veiculo_detalhe'` pra o "‹ Voltar" saber pra onde retornar), **Relatório** (mesmo
  overlay de sempre) e **Devolver à locadora** (se ainda não devolvido — tela própria desde a 6ª
  rodada, ver abaixo). É o único lugar de onde se
  chega em "Vincular/desvincular" agora — não tem mais atalho direto no card da lista.
- **Vincular/desvincular — visão admin** (`frotasRenderVinculo`, alcançável só pelo Detalhe do
  veículo acima): **desde o self-service de §6.1, é principalmente um mecanismo de exceção** (o
  colaborador normalmente se vincula/desvincula sozinho) — mas continua existindo pra Frotas
  corrigir situações (colaborador esqueceu de se desvincular, precisa reatribuir manualmente etc.).
  Mostra quem está vinculado com botão **Desvincular** (`app_frota_veiculo_desvincular(p_vinculo_id)`)
  — só aparece o formulário de **Vincular** (4ª rodada: **dropdown de colaboradores `ativo`**,
  `frotasCarregarColaboradores()`/`app_frota_usuarios_completo` — não mais campo de e-mail livre;
  manda o `id` do `<option>` direto como `p_condutor_id`, sem round-trip por `app_perfil_por_email`)
  quando o veículo **não** tem ninguém vinculado (desde a 3ª rodada, só dá pra ter **um** vínculo
  aberto por vez, não mais vários — ver §6.1; as duas RPCs também recusam com mensagem clara se o
  veículo já estiver ocupado ou a pessoa já vinculada em outro lugar, e fazem o mesmo `UPDATE` de
  `status` que a versão self-service). **Fotos na entrega (2026-09-28, opcional, até 3):**
  `frota_veiculo_vinculo` ganhou coluna nova `fotos text[]`; `app_frota_veiculo_vincular` ganhou
  `p_fotos text[] default null` **no fim** da assinatura (mesmo cuidado do checklist acima — a
  assinatura antiga de 2 parâmetros foi dropada explicitamente depois de criar a de 3, pra não
  sobrar overload ambíguo). Fotos sobem via `uploadFoto2`/`Promise.all` antes de chamar a RPC (não
  passa pela fila offline — essa tela já é admin/online-only).
- **Histórico** (`frotasRenderHistorico`, alcançável pelo Detalhe do veículo **ou** de dentro de
  Relatório, ver abaixo — `frHistBackTo` guarda de onde veio pro "‹ Voltar" certo): busca por
  **veículo** (dropdown) ou por **colaborador** (4ª rodada: **dropdown de todos os colaboradores**,
  sem filtro de status — histórico pode envolver gente já inativa/reprovada; antes era campo de
  e-mail livre + `app_perfil_por_email`), com filtro de período —
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
  ligada) lista `status='pendente'`, aprovar direto ou **reprovar via tela própria**
  (`frotasRenderManutencaoReprovar`, `frotasSub='manutencao_reprovar'`, 6ª rodada — antes o motivo
  vinha de `prompt()` nativo) → `app_frota_manutencao_aprovar(p_id,p_aprovado,p_motivo)` (RPC sem
  mudança).
- **Manutenções a agendar** (`frotasRenderManutencaoFila` → `app_frota_manutencoes_agendar_fila()`,
  lista `status='aprovado'`) → **Agendar** (`frotasRenderManutencaoAgendar` →
  `app_frota_manutencao_agendar(p_id,p_data_agendada)`, **só data — sem custo (5ª rodada)**: o
  formulário pedia "custo estimado" aqui, antes de o veículo sequer ir pro mecânico, o que não fazia
  sentido — o valor real só se sabe na volta. A assinatura **encolheu de 3 pra 2 parâmetros**
  (precisou `DROP FUNCTION` primeiro — Postgres não deixa remover parâmetro via `CREATE OR REPLACE`).
  Ao agendar, `frota_veiculo.status` vira **`manutencao`** (novo efeito colateral — antes o veículo
  ficava marcado `em_uso`/`disponivel` o tempo todo mesmo estando no mecânico; o rótulo "Em
  manutenção" já existia em `STATUS_VEICULO_LABEL` só que nunca era escrito por nenhuma RPC).
  **Concluir agora é principalmente o colaborador** (ver §6.1 "dar baixa") — `frotasSub='painel_
  manutencoes'` mantém um botão "Marcar como concluída" como **reforço/exceção pra Frotas**
  (`data-mancluir` → tela própria `frotasRenderManutencaoConcluirAdmin`, `frotasSub='manutencao_
  concluir_admin'`, 6ª rodada — antes eram 2 `prompt()` sequenciais, data e custo — chamando a mesma
  `app_frota_manutencao_concluir` com `p_orcamento_valor`). `app_frota_manutencao_concluir` ganhou
  esse 4º parâmetro (`p_orcamento_valor numeric default null`) e a permissão foi ampliada pra aceitar
  `v_id=reportado_por` **além de** `funcao in ('frotas','admin')`. Ao concluir, restaura
  `frota_veiculo.status` (`em_uso` se ainda tiver vínculo aberto, senão `disponivel`).
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
  ficava em Equipe administrativa)** (`frotasRenderPainel` → grid de 4 submódulos, estilo `.mod`/
  `.grid` igual o hub — antes era uma lista solta de links de texto: `lavagens`,
  `manutencoes`, `custos`, e **`historico`** — que agora é um item **dentro** de Relatório em vez de
  botão próprio no hub, ver §6.0). **`agora mora na categoria Gestor`**, não mais em Equipe
  administrativa — é uma tela de acompanhamento/auditoria, não de operação do cadastro.
  **"Movimentações (empréstimos)" foi removida da lista** — não sobrava o que mostrar sem o
  mecanismo de empréstimo ativo (§6.1); `app_frota_movimentacoes_listar` (as duas sobrecargas, a
  antiga sem filtro e a com filtro de pp13) foram **apagadas**. **Abastecimentos também saiu da lista
  em 2026-10-14** (removido por completo, §6.5). Os submódulos com filtro
  (lavagens/manutenções) têm filtro de **veículo** (dropdown) e **período**
  (`p_data_ini`/`p_data_fim`) numa rodada anterior; o filtro de **colaborador** virou **dropdown de
  todos os colaboradores** na 4ª rodada (`frotasCarregarColaboradores()`, manda o `id` direto como
  `p_condutor_id` — antes era campo de e-mail livre + `app_perfil_por_email`). `PAINEL_CFG` (const)
  só descreve `{rpc,titulo,row}` por tipo; `frotasRenderPainelLista` monta o formulário de filtro +
  chama `carregar()`.
  **"Tempo real" aqui significa só "sempre atualizado quando busca"** — sem Supabase Realtime.
- **Custos por veículo** (`app_frota_custos_por_veiculo()`/`app_frota_veiculo_relatorio()`, **sem
  filtro** — visão agregada por veículo, dentro de Relatório): soma
  `frota_lavagem` **só `status='realizada'`** (lavagem), `frota_manutencao` **só
  `status='concluido'`** (**simplificado na 5ª rodada** — antes incluía `agendado` também, mas
  `orcamento_valor` nunca é preenchido nesse estágio desde que o custo virou parte da conclusão, ver
  acima; manter `agendado` no filtro não somava nada a mais, só confundia) + `valor_devolucao` do
  próprio veículo. `custo_total` é a soma de tudo. Read-only. **Galerias de fotos (2026-09-28):**
  além da seção 5 já existente (`v.fotos`, fotos do cadastro do veículo), o relatório ganhou seção 6
  "Fotos de vinculação" (`vinculos_fotos` — uma galeria por vínculo que teve foto, com nome do
  condutor e período) e seção 7 "Fotos de checklists" (`checklists_fotos` — uma galeria por
  checklist que teve foto, com data/km/status). Mesma assinatura de `app_frota_veiculo_relatorio`
  (só `p_veiculo_id`), só o retorno cresceu — sem risco de overload.
- **Relatório do condutor (novo, 2026-09-28):** não existia — só a tela de cadastro/CNH mostrava a
  foto da CNH sozinha. Botão "📄 Relatório do condutor" em `frotasRenderCondutorCadastro` (só quando
  `c.tem_condutor`) → `frotasRelatorioCondutor(condutorId)` → RPC nova `app_frota_condutor_relatorio
  (p_condutor_id)`, mesmo overlay `#relatorio`/`REL_CSS` do relatório de veículo. Mostra CNH (com
  foto), termo de responsabilidade, veículos vinculados (com fotos de entrega, se houver) e galerias
  de fotos de cada checklist que esse condutor registrou.
- **Estado:** `frotasSub, frotasVeiculoSel, frVeicFiltroTipo, frVeicFiltroCond, frHistVeiculoSel,
  frHistCondutorSel, frHistBackTo, frLavagemSel, frManutSel, frManutRepSel, frManutCluirSel,
  frotasCondutores, frCondBusca, frCondFiltro, frCondSel, frotasPainelCache, frPnlFiltro`.
  **`frManutRepSel`/`frManutCluirSel` são novos (6ª rodada)** — guardam o id da manutenção entre a
  lista e a tela de Reprovar/Marcar-como-concluída, mesmo papel que `frLavagemSel`/`frManutSel` já
  faziam pra Agendar. **`frotasCondutores` virou compartilhado
  entre 4 telas (4ª rodada)** — Condutores (busca/cadastro, uso original), Vincular/desvincular,
  Histórico e Relatório (filtro por colaborador) todas chamam `frotasCarregarColaboradores()`
  (wrapper de `app_frota_usuarios_completo`) pra popular a mesma variável antes de montar seu
  dropdown — `frotasColaboradoresOrdenados()` devolve a lista por ordem de nome (a ordem "sem CNH
  primeiro" do `app_frota_usuarios_completo` só faz sentido na tela Condutores).

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

### 6.5 Equipamentos (novo, 2026-09-28; abastecimento removido 2026-10-14)
**Não é o mesmo conceito de `sup_equipamento`** (schema `9 - suprimentos` — bombas/geradores
emprestados por termo de responsabilidade). Isso aqui é um cadastro de acervo de equipamentos
(gerador, compressor, motobomba etc.) dentro de `"10 - Frotas"`, **sem vínculo pessoa↔equipamento**
(não existe "meu equipamento" — qualquer um da Equipe administrativa vê/gerencia todos).
- **Abastecimento removido por completo (2026-10-14):** a pedido do usuário, todo o controle de
  combustível saiu do módulo de Frotas — **veículo e equipamento**, e todos os relatórios de
  abastecimento. A tabela `frota_equipamento_abastecimento` e as RPCs `app_frota_equipamento_
  abastecimento_salvar`/`app_frota_equipamento_abastecimentos_listar` foram **dropadas** (backup em
  `"_bkp_frota_abastec_20261013"`), junto com a tela `frotasRenderEquipamentoAbastecimento` e o
  botão/histórico de abastecimento no detalhe do equipamento. Sobrou só o cadastro de equipamento.
- **Tabela:** `frota_equipamento` (nome, tipo, identificação/nº série, status,
  ativo, obs, consorcio, fotos array). O campo `tipo_combustivel` segue na tabela (sem uso na UI).
- **Acesso:** hub Frota → "Equipe administrativa" → **Equipamentos** (`frotaOpen('equipamentos')` →
  `frotasTarget='equipamentos'` → `irPara('frotas')`), mesmo gate de sempre em Frotas (`funcao in
  ('frotas','admin') or frota_admin`) — cadastro, edição e inativação são admin/frotas-only.
- **RPCs:** `app_frota_equipamentos_listar()`, `app_frota_equipamento_salvar(p_id,...)` (cria ou
  atualiza — `p_id null` cria; fotos são opcionais, `coalesce(p_fotos, fotos)` no update preserva as
  antigas se não mandar novas, mesmo padrão de `frotasSalvarVeiculo`), `app_frota_equipamento_
  ativo_set(p_id,p_ativo)` (inativar/reativar — zera pra `status='inativo'`/`'disponivel'`).
- **Frontend:** `frotasRenderEquipamentos` (lista + ➕ Novo) → `frotasRenderEquipamentoEdit`
  (cadastro/edição, até 3 fotos, reaproveitando `COMBUSTIVEIS_VEICULO` e o mesmo par de opções de
  consórcio usado em `frotasRenderVeiculoEdit`) → `frotasRenderEquipamentoDetalhe` (fotos, botão
  Editar). Tudo direto via `sb.rpc(...)`, sem fila offline (tela admin/online-only).

### 6.6 Fluxos pedidos pela Amanda (2026-10-16, sw v269) — migração `docs/migracao_frota_fluxos_2026-10.sql`
- **Equipe de frotas = `"10 - Frotas".frota_responsaveis()`** (ativo e `frota_admin` OU `funcao in ('frotas','admin')`).
  ⚠️ Antes o aviso "lavagem solicitada" usava `sup_uuids_por_funcao(['frotas','admin'])` e **não chegava a quem só tem a
  engrenagem** (o responsável de frotas, Lucas, é `funcao='campo'` + `frota_admin`). Avisos pra "a equipe de frotas" devem
  usar `frota_responsaveis()`.
- **Gestor direto = `"10 - Frotas".frota_gestores_de(uid)`** (aprovador 1/2 do perfil, **sem** o fallback "todos os
  aprovadores" do `sup_aprovadores_de`) — usado onde o pedido é avisar **só** o gestor da pessoa.
- **Multas, ocorrências e avarias** — tabela `frota_registro` (tipo `multa|ocorrencia|avaria`, veículo, colaborador,
  data do fato, local, nº do auto, valor, descrição, anexos; RLS ligada, só RPC). Cadastro **só pela equipe de frotas**
  (`app_frota_registro_salvar`); `app_frota_condutor_na_data(veiculo,data)` sugere quem estava com o veículo no dia.
  Trigger `trg_frota_registro` avisa **apenas** o colaborador + `frota_gestores_de` (link `frota_registros`).
  Tela `registros` (`frotasRenderRegistros`/`frotasRenderRegistroNovo`) é a mesma pra todos: `app_frota_registros_listar`
  devolve `{adm, rows}` com escopo (frotas/admin = tudo; gestor = equipe pelo aprovador 1/2; colaborador = os próprios).
  Botões: Colaborador › "Multas e ocorrências" e Equipe administrativa › "Multas, ocorrências e avarias".
  O **fluxo externo** (termo de compromisso por e-mail etc.) ainda não foi definido — fora do app por ora.
- **Manutenção preventiva** — `tipo_problema='preventiva'` (adicionado ao CHECK). `app_frota_preventiva_agendar(veiculo,
  data,descricao)` (frotas/admin) grava já `agendado`, `aprovado_por`=quem agendou e **`reportado_por`= colaborador vinculado
  hoje** (assim aparece em "Manutenção" dele e ele mesmo dá baixa com o custo; sem vínculo fica no nome de quem agendou).
  **Não** muda `frota_veiculo.status` (a data pode ser futura e travaria o checklist). INSERT preventiva → aviso ao
  colaborador + `frota_gestores_de` com a data (`frota_manutencao`). Tela `preventiva` (`frotasRenderPreventiva`, Equipe
  administrativa › "Manutenção preventiva") com o formulário + lista das preventivas.
  **Horário/local/obs (2026-10-23, `docs/migracao_frota_preventiva_local.sql`):** igual ao agendamento de lavagem — colunas
  `frota_manutencao.horario_agendado`/`local_agendado`/`obs_agendamento`; `app_frota_preventiva_agendar` ganhou
  `p_horario,p_local,p_obs` (assinatura antiga **dropada**, §0.6; local obrigatório só na tela). O aviso da preventiva leva
  data/horário/local/serviço/obs; `app_frota_manutencoes_listar`/`app_frota_minhas_manutencoes` devolvem os 3 campos
  (`frManutAgendaInfo` mostra na lista da Frotas e na Manutenção do colaborador).
- **Checklist** — INSERT de `frota_manutencao` com `tipo_problema='checklist'` agora avisa também `frota_responsaveis()`
  (link `frota_chk_equipe` → tela Checklists da equipe), além do gestor. **Corretiva aprovada** pelo gestor avisa
  `frota_responsaveis()` que há manutenção a agendar (link `frota_manutencao_fila`).
- Rótulos: `TIPO_PROBLEMA_ALL` (= `TIPO_PROBLEMA` + checklist/preventiva) é o usado em `labelOf` p/ exibir; o formulário
  do colaborador continua com `TIPO_PROBLEMA` (ele não escolhe preventiva/checklist).

### Tabelas (`"10 - Frotas"`)
`frota_veiculo` (cadastro/combustível/consórcio/contrato — §6.2; **`uso_tipo`/`equipe_id`/
`condutor_exclusivo_id` ficaram sem uso**, ninguém mais escreve neles, não foram dropados; **`status`
é escrito automaticamente por 4 RPCs**: `app_frota_veiculo_vincular(_me)`/`app_frota_veiculo_
desvincular(_me)` fazem `disponivel⇄em_uso` (3ª rodada); `app_frota_manutencao_agendar`/`_concluir`
fazem `disponivel|em_uso→manutencao→(em_uso|disponivel)` (**5ª rodada** — o rótulo `manutencao` já
existia em `STATUS_VEICULO_LABEL` desde muito antes, mas nenhuma RPC realmente escrevia esse valor
até agora; `baixado` continua só manual, via `app_frota_veiculo_devolver`),
`frota_veiculo_aluguel_historico` (**sem interface própria desde 2026-09** — 1 linha real de reajuste
preservada, não apagada), `frota_veiculo_vinculo` (**nova 2026-09, regra apertada na 3ª rodada:
2 índices únicos parciais (`where desvinculado_em is null`) garantem no máximo 1 vínculo aberto por
veículo E no máximo 1 por pessoa** — antes permitia vários simultâneos por veículo; nenhuma linha
existente violava a regra nova, então a migração foi direta, sem necessidade de fechar vínculos
manualmente), `frota_condutor` (PK = `perfil.id`, status/CNH), `frota_condutor_cnh_historico`
(append-only, + `atualizado_por` desde 2026-09 — §6.1), `frota_termo` (1 linha por termo emitido,
`status` pendente/assinado/cancelado, `assinatura_path` — §6.1), `frota_checklist_situacao`,
`frota_lavagem` (ganhou `status`/`solicitado_em`/`agendado_por`/`data_agendada`/`horario_agendado`/
`local_agendado`/`realizado_em` — §6.1/§6.2), `frota_emprestimo` (**sem interface própria desde
2026-09, 3ª rodada** — mesmo tratamento do histórico de aluguel: RPCs e trigger apagados, 1 linha
real preservada, virou só leitura via Histórico, §6.2), `frota_manutencao` (ganhou
`tipo_problema`/`data_agendada`, ciclo `pendente→aprovado/reprovado→agendado→concluido` — §6.1/§6.2).
`frota_equipamento` (**nova, 2026-09-28** — §6.5, cadastro de equipamento; `tipo_combustivel` sem uso
na UI desde 2026-10-14).
`public.perfil` ganhou `frota_isento` (não é tabela de Frotas mas é usada só por ela).
**Apagadas** (estavam vazias ou já totalmente substituídas, sem dado real a perder):
`frota_equipe`/`frota_equipe_membro` (substituída por `frota_veiculo_vinculo`), `frota_ocorrencia`
(substituída por `frota_manutencao` direto), `frota_treinamento`/`frota_treinamento_condutor`
(substituída pelo termo assinado, §6.3). **Dropadas em 2026-10-14** (backup em
`"_bkp_frota_abastec_20261013"`): `frota_checklist_abastecimento`, `frota_equipamento_abastecimento`.

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
- **Overload órfão de RPC — a regra já estava certa em §0.6, mas foi violada duas vezes neste
  módulo antes de alguém notar (2026-09, 5ª rodada):** §0.6 já dizia "adicionar/retirar parâmetro
  cria outra função (overload) — use `drop function` + `create`, só use `create or replace` quando a
  assinatura é idêntica". Mesmo assim, ao adicionar filtros nas RPCs do Painel (rodada anterior) e ao
  adicionar `p_orcamento_valor` em `app_frota_manutencao_concluir` (esta rodada), o parâmetro foi
  acrescentado via `create or replace` direto — o Postgres aceita sem erro, só que o resultado é uma
  função **nova** em paralelo, não uma substituição: a versão antiga (sem o parâmetro, com a lógica
  velha) **continua existindo e chamável**. No caso de `app_frota_manutencao_concluir` isso era um
  risco real, não só estético — a versão de 3 parâmetros tinha a permissão antiga (só `frotas`/admin,
  sem o colaborador que reportou) e nenhum dos efeitos novos (custo, restaurar status do veículo).
  Achado numa auditoria de overloads (`select proname, count(*) from pg_proc ... group by proname
  having count(*)>1`) que também achou o mesmo problema, já esquecido, em
  `app_frota_abastecimentos_listar`/`_lavagens_listar`/`_manutencoes_listar` — os 3 overloads de
  0-parâmetro (sem chamador no frontend) foram dropados nesta rodada. **A lição não é uma regra
  nova, é rodar essa auditoria de overloads sempre que uma assinatura mudar** — a regra escrita já
  bastava, só não estava sendo checada na prática.
- **Mensagens de notificação/erro sem acentuação corrigidas (2026-09, 4ª rodada):** todo texto das
  triggers (`trg_frota_condutor`/`trg_frota_lavagem`/`trg_frota_manutencao`) e todo `raise exception`
  das RPCs `app_frota_*`/`app_condutor_*` (~45 funções) foi reescrito com acentuação correta — texto
  vinha sem acento desde que foi escrito (ex.: "Voce esta ATIVO para direcao" → "Você está ATIVO para
  direção", "nao autenticado" → "não autenticado"). Puramente textual — nenhuma lógica/assinatura
  mudou. **Cuidado ao adicionar mensagem nova:** escrever com acentuação correta desde o início (não
  repetir o problema).
- **`.relBadge` (badge de status nos relatórios em PDF/overlay, `REL_CSS`) não tinha `color` próprio
  — herdava branco de `.relTop` e ficava branco-em-branco (2026-09, 6ª rodada):** achado no Relatório
  do Veículo (§6.2), mas o mesmo `.relBadge` é reaproveitado por Loggers, VRP e pelos termos de
  responsabilidade — a badge só ficava legível quando algo mais dava um `color` explícito (inline nos
  reports de Logger/Suprimentos, ou via `.termoWrap.pend .relBadge{color:...}` nos termos, só pro
  estado "pendente"). Faltava um **default**: qualquer badge sem override específico (Relatório do
  Veículo, Relatório de Visita · VRP, e o termo no estado "assinado/ok") ficava invisível. Corrigido
  com `color:#0a7d5e` na regra base de `.relBadge` — os overrides existentes continuam funcionando
  (maior especificidade/inline sempre vence). **Junto veio outro bug**: o badge do Relatório do
  Veículo mostrava `r.status` cru ("em_uso") — agora passa por `STATUS_VEICULO_LABEL` como em toda
  outra tela.
- **Rótulos amigáveis centralizados (2026-09, 6ª rodada)** — `labelOf(lista, valor)` substitui a
  repetição de `(LISTA.find(t=>t[0]===v)||[,v])[1]||'—'` em ~10 pontos (`TIPOS_VEICULO`,
  `TIPO_PROBLEMA`, `COMBUSTIVEIS_VEICULO`, `CENTROS_CUSTO_FROTA`); `statusBadge(mapa, status)` gera
  o mesmo pill colorido do card de veículo (`background/color: var(--xx-bg)/var(--xx)`) a partir de
  `MANUT_STATUS_LABEL`/`LAVAGEM_STATUS_LABEL` (agora no formato `{l,bg,fg}`, igual
  `STATUS_VEICULO_LABEL`/`FRCOND_STATUS_LABEL` — antes eram mapas `status→string`, sem cor). Isso
  corrigiu dois bugs reais: o Histórico (`frotasRenderHistorico`) e a lista de Manutenções do
  Relatório mostravam `tipo_problema`/`status` **crus** do banco ("motor", "concluido") porque a
  descrição ali nunca tinha passado por lookup nenhum — não era só falta de cor, faltava o rótulo.
  **Cuidado ao adicionar um novo tipo/status em Frota:** se não usar `labelOf`/`statusBadge`, o bug
  volta a se espalhar.
- **`prompt()`/`confirm()` nativos trocados por tela própria em 3 fluxos (2026-09, 6ª rodada):**
  Reprovar manutenção (`frotasRenderManutencaoReprovar`, motivo em textarea),
  Devolver à locadora (`frotasRenderVeiculoDevolver`, valor em input) e "Marcar como concluída" do
  admin em Relatório › Manutenções (`frotasRenderManutencaoConcluirAdmin`, data+custo em inputs).
  Motivo duplo: diálogo nativo destoa do resto do app **e** não dá pra automatizar em teste de
  navegador (`window.prompt` levanta "not supported" em ambiente de automação — foi assim que a
  limitação foi descoberta, numa rodada de QA manual). Outros `confirm()` simples de Frota
  (desvincular veículo/colaborador) **não** foram trocados — só os 3 fluxos que pediam texto/número
  livre, que são os que a automação não conseguia completar.
- **Checklist recusado com o veículo em `manutencao` (2026-09, 6ª rodada; abastecimento removido 2026-10-14):**
  `app_frota_situacao_salvar` checa
  `frota_veiculo.status` antes de gravar — se `='manutencao'`, recusa (o veículo não está fisicamente
  com o colaborador). O hub (`frotaBlocks`/`frotaHome`) também desabilita o botão nesse caso
  (`bloqueiaManutencao:true` nos itens do array) — front é só UX, quem garante é a RPC. **Lavagem e
  Manutenção continuam liberados** mesmo com o veículo em manutenção (reportar um 2º problema, ou
  acompanhar/solicitar lavagem, fazem sentido independente de onde o veículo está fisicamente).
- **`qa/smoke_test_frota.sql` (novo, 6ª rodada):** 6 blocos `do $$ ... end $$` com rollback garantido
  (sempre termina em `raise exception 'ROLLBACK_OK...'`), cobrindo overloads órfãos, grants, vínculo/
  desvínculo (+ status do veículo), ciclo completo de manutenção (com o teste de permissão do
  reportante × terceiro), o bloqueio de checklist em manutenção, e o ciclo completo de
  lavagem. Rode depois de qualquer mudança nas RPCs de Frota. **Roda contra produção**, não contra
  uma branch isolada — tentei criar uma branch de teste no Supabase (`create_branch`), mas a
  ferramenta exige um `confirm_cost_id` de uma chamada `confirm_cost` que não está disponível nas
  ferramentas desta sessão (branch tem custo real, exige confirmação própria). É seguro rodar contra
  produção só porque cada bloco é 100% rollback — não é o ideal a longo prazo; se um dia branch
  virar viável, apontar o script pra lá em vez de produção.
- **9 botões "‹ Voltar" levando pra tela errada (2026-09, 7ª rodada) — exposto pela própria correção
  da 5ª rodada:** esconder a barra fixa `#condBar`/`#frotasBar` fora da home (5ª rodada, acima) tirou
  o "atalho" que mascarava um problema mais antigo: várias subtelas são abertas **direto** a partir do
  hub (`frotaOpen`→`condGoTarget`/`frotasInit` pulando a home), mas o "‹ Voltar" delas estava
  hardcoded pra `condSub='home'`/`frotasSub='home'` — uma tela **diferente** de onde o usuário veio
  (ex.: Checklist diário, aberto direto do hub, voltava pra "Minha CNH" em vez do hub). Com a barra
  fixa sempre visível isso não incomodava (dava pra voltar ao hub por ela); sem a barra, virou "botão
  de voltar quebrado". Corrigidos os 9 casos reais (`condRenderVeiculos`/`Situacao`/
  `Lavagem`/`Manutencao` e `frotasRenderCondutores`/`LavagemFila`/`ManutencaoFila` → `irPara('frota')`
  direto; ver §6.0 pra essa função). **Caso especial — "Registrar problema" tem 2 entradas**
  (Checklist › "Encontrou um problema?" **e** Manutenção › "Reportar problema"): não dava pra
  hardcodar um destino só, então ganhou uma variável de contexto nova, **`condOcorrenciaBackTo`**
  (`'situacao'`|`'manutencao'`, setada por quem abre a tela), igual ao padrão já existente de
  `frHistBackTo` pro Histórico (§6.2). **Detalhe deliberado:** só o botão "‹ Voltar" (desistir) respeita
  `condOcorrenciaBackTo` — depois de **salvar com sucesso** um problema, a tela sempre manda pra
  Manutenção (pra ver a ocorrência nova na lista), não importa se a entrada foi pelo Checklist.
  **Cuidado ao adicionar uma nova subtela aberta direto do hub:** o "‹ Voltar" dela deve chamar
  `irPara('frota')`, nunca `condSub`/`frotasSub='home'` — "home" (Minha CNH / lista de Veículos) só é
  o destino certo pra telas que só se abrem **de dentro** da home de cada módulo.

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
**Pressão:** `app_pressao_filtros`, `app_pressao_produtividade`, `app_estanqueidade_listar`, `app_estanq_poligonos` (camadas ZP/DMC COPASA).
**Loggers:** `app_loggers_listar`, `app_logger_criar/instalar/remover/finalizar/editar`,
`logger_pressao_importar/stats`.
**Pesquisa/Ocorrência:** `app_pesquisa_filtros`, `app_pesquisa_produtividade`,
`app_ocorrencia_fila`, `app_ocorrencia_os` (registro via `app_ocorrencia_registrar`).
**VRP:** `app_vrp_listar`, `app_vrp_visita_registrar`, `app_vrp_visita_ver`.
**Cadastro:** `app_cadastro_geojson`, `app_cadastro_buscar`.
**Roteiro:** `app_roteiro_percursos/pontos/linhas/matricula`.
**Entrevistadores/Retaguarda:** `app_abertura_fila`, `app_abertura_os`,
`app_abertura_servico_minhas`, `app_captacao_fila`, `app_captacao_matricula`
(registro via `app_abertura_servico_registrar`, `app_captacao_registrar`),
`app_entrevista_ocorrencia_registrar`, `app_entrevista_ocorrencia_listar`.
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
`app_frota_lavagens_listar`, `app_frota_manutencoes_listar` (com
filtro de veículo/condutor/data), `app_frota_custos_por_veiculo` (Relatório, §6.2),
`app_frota_situacao_salvar`,
`app_frota_lavagem_solicitar/fila_agendar/agendar/realizar`, `app_frota_minhas_lavagens` (ciclo
solicitar→agendar→confirmar, §6.1/§6.2),
`app_frota_manutencao_solicitar/pendentes/aprovar/agendar(p_id,p_data_agendada)/concluir(p_id,
p_data_liberacao,p_fotos_conclusao,p_orcamento_valor)`, `app_frota_manutencoes_agendar_fila`,
`app_frota_minhas_manutencoes` (**nova 5ª rodada** — histórico próprio do colaborador; sem ela não
havia como ver as próprias manutenções fora do papel frotas/admin) — ciclo
solicitar→aprovar→agendar(**sem custo**)→**concluir com custo, pelo próprio colaborador ou por
Frotas** (substitui "ocorrência" pra qualquer problema mecânico, §6.1/§6.2),
`app_perfil_por_email` (helper genérico: busca `perfil` por e-mail — **desde a 4ª rodada de 2026-09,
Frota não chama mais essa RPC em lugar nenhum**, todo campo de "e-mail do colaborador" virou dropdown
de nome; a função continua no banco pra qualquer outro módulo que precise resolver destinatário por
e-mail, mas hoje não tem chamador em nenhum lugar do frontend).
**Removidas por completo** (não há mais linha no banco): `app_frota_veiculo_aluguel_
reajustar/aluguel_historico`, `app_frota_equipes_listar/equipe_salvar`, `app_frota_ocorrencia_
reportar/pendentes/aprovar`, `app_frota_ocorrencias_listar`, `app_qsms_*` (condutores_aptos,
treinamento_agendar/baixar, treinamentos_listar), e, **nesta rodada (2026-09, 3ª)**:
`app_frota_emprestimo_criar/devolver/solicitar_devolucao`, `app_frota_meus_emprestimos`,
`app_frota_movimentacoes_listar` (as duas sobrecargas). **Legado, ainda no banco mas sem chamador no
frontend:** `app_condutor_solicitar/pendentes/aprovar`, `app_frota_condutores_listar` (substituídas
pelo fluxo de cadastro-pelo-gestor).
**Biblioteca:** `biblioteca_*`. **Notificações/Push:** `app_notif_*`, `app_push_*`.
**Segurança do Trabalho / QSMS (§18):** `app_seg_registrar`, `app_seg_local`, `app_seg_minhas`, `app_seg_ver`,
`app_seg_pessoas`, `app_qsms_listar`, `app_qsms_atividade_ver`, `app_qsms_verificar`, `app_qsms_acesso_listar/_set`, `app_qsms_epi_painel`.

> Assinaturas completas: `select proname, pg_get_function_identity_arguments(oid) from pg_proc p
> join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 1;` (via MCP).

---

## 11. Perdas / NRW — cockpit em **página dedicada** `public/perdas.html`

> **Menu do cockpit (2026-10-22):** `#nav` voltou a exibir **Análise do micromedido** (`mm`) e **Análise de
> macromedição** (`macro`) em *2 · Dados & diagnóstico*, e **Priorização de troca de HD** (`hdpri`) +
> **Fiscalização de irregularidades** em *4 · Execução — comercial* (os deep-links `?s=` e o Auxiliar seguem
> funcionando). **Removidos do menu:** Painel de Perdas, Componentes IWA, Gestão de OS/reparos, Parque de
> hidrômetros, Recuperação de faturamento, Grandes consumidores e Performance contratual (as `<section>`s
> continuam no arquivo, só sem entrada). Tela inicial = `resultado` (`go('resultado')` no fim do script principal).
> Botão "Componentes IWA →" do Balanço removido. Isso substitui o que a nota de reorg abaixo diz sobre `hdpri`/`mm`
> estarem fora do menu.

> **Reorg 2026-10:** **Priorização de troca de HD** (`s-hdpri`) e **Análise do micromedido** (`s-mm`) foram
> **removidas do menu `#nav`** do cockpit e agora são acessadas pelo **Auxiliar de Programação** (cards que
> abrem `perdas.html?s=hdpri` / `?s=mm`). O gate do `perdas.html` (script module no fim) passou a liberar essas
> duas para **aprovador/admin mesmo sem `dev_acesso`**, e nesse caso adiciona **`body.aux-solo`** (CSS
> `body.aux-solo #nav{display:none}`) → o usuário vê só a ferramenta + "Voltar ao AcquaHub". Deep-link lido de
> `?s=` e roteado por `window.go(s)`. As telas/RPCs (`app_nrw_hd_*`/`app_nrw_mm_*`) **não mudaram** — só a porta.

Cockpit de acompanhamento de perdas (NRW) por DMC. **Não é uma tela `<main>` do `index.html`** — é
uma **página HTML separada** (`public/perdas.html`, autocontida: CSS/JS próprios, SVG nativo, sem
Leaflet). Por isso **não entra no `SCREENS`** nem no `irPara`. Acesso pelo card do hub que faz
`location.href='perdas.html'`.

- **Entrada (hub):** card `#cardPerdas` ("Perdas (NRW)") na categoria **🚧 Em desenvolvimento** do `#home`
  (junto do `#cardProj`). Nasce `class="mod soon"` (opaco). O gate roda em **`homeGate()`** (§1): libera por
  **`ME.dev_acesso`** (tira `soon`/🔒 e liga `onclick`); quem não tem fica opaco e o clique dá `toast('Acesso
  restrito')`. **Controle de acesso (2026-09):** engrenagem ⚙️ `#homeDevAcesso` na categoria (só admin) → tela
  `dev_acesso` (`devAcessoInit`/`devAcessoRender`, espelha `supAreaGate`) que lista usuários com toggle; backend
  `perfil.dev_acesso` + RPCs `app_dev_acesso_listar`/`app_dev_acesso_set` (admin-only) + `app_me` repassa
  `dev_acesso` (admin sempre). Substituiu o gate por e-mail hardcoded. A mesma engrenagem governa a **Vitrine (TV)**
  (`#homeVitrine`, §17).
- **Guarda na própria página:** ao final de `perdas.html`, um `<script type="module">` cria um cliente
  supabase-js (mesma `SB_URL`/anon key do app; exposto em **`window.sbg`** p/ o script principal usar nos RPCs),
  lê `auth.getSession()` e, **se `app_me().dev_acesso` for falso** (ou sem sessão), mantém o overlay `#nrwGate`
  (🔒). **Gate unificado por `dev_acesso`** (2026-09, mesmo controle "Em desenvolvimento" da home — antes era
  e-mail do Sander hardcoded). Funciona offline (sessão do `localStorage` do mesmo domínio). O enforcement real
  é **server-side** nas RPCs (checam `dev_acesso`/admin).
- **Análise do micromedido (2026-09, tela REAL — `s-mm`/nav "Análise do micromedido"):** dados de verdade da
  `"5 - info_copasa".micromedicao_historico`. Motor: tabela **`"11 - perdas_nrw".mm_matricula_stats`** (1 linha
  por matrícula, 134.879, recomputada pela função `app_nrw_mm_stats_rebuild` — ver "Recompor" abaixo):
  média/mediana/mín/máx/desvio/**CV**, **slope** (regr sobre índice de mês uniforme), n_zeros, **classificação**
  (fraude_potencial/estável/nulo_recorrente/pico_isolado/queda_continua/crescimento_continuo/instável) e
  **`score_anomalia` 0–100** (Índice de Anomalia = 3·pico + 2·tendência + 2·CV + 1·zeros + **3·fraude**; denom 11).
  RPCs `app_nrw_mm_resumo`/`_ranking`/`_serie` (definer, admin **ou** `dev_acesso`; anon revogado).
  - **Recompor (dinâmico, 2026-10-13):** função **`public.app_nrw_mm_stats_rebuild(p_consorcio text default null)`**
    (definer; gate admin/dev p/ chamador autenticado — serviço/cron com `auth.uid()` nulo passa) recomputa **do
    zero** `mm_mensal` + `mm_matricula_stats` a partir do histórico — rodar **todo mês após inserir micromedição**.
    Como o motor ad-hoc original (buckets `mod(nu_matricu,4)`) **se perdeu** (não havia função/migração que
    populasse), o Índice de Anomalia foi **canonizado** aqui, validado contra o ZA0200 (inalterado): determinísticas
    **idênticas** (100%), `fraude_potencial` **idêntica** (regra `meses_irregular≥2`), classificação **~93%** e
    `score_anomalia` **Pearson ~0,77** (motor antigo não reproduzível exatamente). Fórmula canônica:
    `score = max(5,5 ; min(100 ; (3·pico + 2·tend + 2·CV + 1·zeros + 3·fraude)/11))` com sub-scores 0–100
    (pico = nº meses > média+3σ ×25 · tend = |slope|·n_meses/média·100 · CV = CV·100 · zeros = % meses zerados ·
    fraude = meses_irregular×50); classes por precedência fraude→factível→nulo_recorrente(zeros≥40%)→
    crescimento/queda(slope_rel ≷ ±0,05)→pico_isolado(≥1 pico 3σ)→instável(CV≥0,6)→estável. `ultimo_vol`/`n_picos`
    seguem **nulos** (como no original). ⚠️ Pesada (~2,4M linhas, ~15 min) — o `statement_timeout` do pooler/MCP a
    mata; rodar por **`pg_cron`** (background, sem timeout) ou fatiando por consórcio/faixa de matrícula. Carga
    histórica completada 2026-10-13: **ZA1004 202503** (74.715) que faltava no banco.
  - **Reforma da tela (2026-09-24):** removidos os KPIs técnicos (score elevado/CV médio/score médio). Nova
    disposição em 4 painéis: **(1) Indicador do mês** — **só micromedição, o volume faturado não entra**
    (redesenhado 2026-09-28). **Seletor de competência** (default = **último mês**) + **6 cards uniformes** (`.mmcard`; o 6º, **Factível**, desde 2026-10-07 — ver nota abaixo),
    cada um com o valor no topo e **MoM/YoY no rodapé em letras menores** (calculados sobre o próprio indicador do card):
    **L/lig·dia** (= volume micromedido total ÷ nº ligações ÷ **30 dias** × 1000; destacado em accent), **Volume
    micromedido (total)** = `volume_total`, **(lido)** = `volume_medido`, **(estimado)** = `volume_naomedido`,
    **(factível)** = `volume_factivel` (2026-10-07) e **Ligações** = `n_faturadas`. Removidos o card "Volume faturado",
    o "% não medido", o "Fraude potencial" e os cards
    isolados de MoM/YoY (agora embutidos). Tudo client-side sobre o `mmMensal`; popup ⓘ explica o cálculo.
    **(2) Sazonalidade & tendência** — default **sobre L/lig·dia** (empata as variáveis): **heatmap** ano×mês +
    linha "Sazonal" (desvio de cada mês-calendário vs média) e **gráfico** com o último ano em linha + faixa mín–máx
    dos anos anteriores como **sombra** (hover por mês corrigido — antes o tooltip não batia com a data).
    **Chips de composição (2026-09-28):** o painel inteiro (heatmap + célula + tooltip + gráfico + eixo) alterna entre
    **L/lig·dia · Vol. micromedido (total) · Vol. lido (medido) · Vol. estimado (não medido) · Vol. factível (2026-10-07) · Ligações** —
    decompor ajuda a achar *o que* causa uma flutuação (caiu o lido? subiu o estimado? só entraram mais ligações?). Tudo
    client-side sobre o `mmMensal` já carregado (o `_mensal` já traz `volume_medido`/`volume_naomedido`, sem RPC nova).
    Estado `mmSeasMet` (`MM_SEAS_MET`/`MM_SEAS_ORDER`); `mmSeasNum` escreve os **volumes por extenso, sem k/M**
    (2026-09-28, a pedido) e `mmSeasFmt` os tooltips; a linha "Sazonal" é sempre **desvio %** (dimensão-livre).
    **Alinhamento do gráfico (fix 2026-09-28):** o eixo-Y saiu para uma coluna própria de **58px** (= largura do rótulo
    do heatmap) e o plot ocupa exatamente a faixa dos 12 meses (`X(m)=((m-0.5)/12)·W`), então a linha inferior casa
    coluna a coluna com o heatmap. **Fix 2026-09-28:** os chips de composição (`.mmchip`+`data-seas`) não clicavam
    porque o handler das chips de comportamento (`.mmchip`) sobrescrevia o `onclick` de todas; escopado a
    `.mmchip[data-cls]`. **(3) DMCs mais sensíveis** — L/lig·dia por DMC (último mês) + MoM/YoY + % estimado + suspeita
    de fraude. **Ordenação livre por coluna (2026-09-28):** `MM_DMC_COLS` + estado `mmDmcSort{k,dir}`, clique no
    cabeçalho ordena/inverte (▲▼). Removidos a **cor de fundo do L/lig·dia** e a coluna **Score**; renomeados
    "Lig. fat."→**Ligações**, "% não med."→**% estimado**, "Fraude"→**Suspeita de fraude**. **(4) Análise por
    matrícula** — **relayout 2026-09-28** em 3 blocos com borda (`.mmblock`, grid-areas `faixas`/`lista`/`detalhe`):
    **faixas** no topo-esquerdo, **ranking** ocupando a coluna direita inteira, **detalhe** no rodapé-esquerdo (fluxo:
    ver cards → escolher na lista → visualizar embaixo). Removido o parágrafo explicativo; detalhe com `.mmstats` em 2
    colunas. Detalhe da matrícula mantém série 18m + meses irregulares em
    vermelho. RPCs novas **`app_nrw_mm_mensal`** (série mensal enriquecida) e **`app_nrw_mm_dmc`** (sensibilidade por
    DMC). `app_nrw_mm_sazonalidade` **aposentada** (sazonalidade agora sai do `_mensal`).
  - **Filtros SÓ no cabeçalho (barra do topo) — 2026-09-28:** removido o painel-cabeçalho duplicado dentro do card
    (`mmHeadPanel`); os filtros do micromedido vivem só na **barra do topo** (à direita de "Análise do micromedido"):
    **consórcio = `#zaseg`** (global, já existente), **mês = `#mes`** e **DMC = `#mesDmc`** (novo). `mmSyncHeader()`
    (chamado no fim do `mmRenderAll`) popula `#mes`/`#mesDmc` com os meses reais e os DMCs (`mmDmcList()`) e liga
    `onchange`→`mmSetMes`/`mmSetDmc`; `mmHeaderReset()` (no `go()` p/ telas ≠ mm) esconde o `#mesDmc` e restaura o `#mes`
    mock. Estado `mmDmcSel={cons,num}`. **Filtro de mês** → Indicador + Abertura por DMC (recarrega `app_nrw_mm_dmc` com
    `p_competencia`, via `mmReloadDmc`). **Filtro de DMC** → Indicador + Sazonalidade + Análise por matrícula
    (recarrega resumo/ranking/mensal com `p_dmc`; consórcio efetivo = o do DMC). As 4 RPCs ganharam parâmetro:
    `app_nrw_mm_mensal(p_consorcio,p_dmc)` (usa `mm_dmc_mensal` quando filtrado, `mm_mensal` p/ total exato),
    `app_nrw_mm_resumo(p_consorcio,p_dmc)` e `app_nrw_mm_ranking(...,p_dmc)` (filtram matrículas via `mm_dmc_map`),
    `app_nrw_mm_dmc(p_consorcio,p_competencia)` (+ colunas `volume_total/medido/naomedido`). **DROP+CREATE** (assinatura
    nova). Removidos os textos "Prévia…", "Composição da micromedição…", "Exibindo Vol…" e o parágrafo da análise.
    **Indicador do mês** só micromedição, cards com rótulo **"Vol."** em 1 linha (`.mmcard .lab` nowrap+ellipsis).
    **Sazonalidade:** volumes por extenso; heatmap com **fundo sólido claro→azul** (`mmHeat` deixou de usar alpha) +
    **texto escuro** (`#0d1418`) — corrige branco-em-azul-claro no valor baixo. **Abertura por DMC** (ex-"DMCs mais
    sensíveis"): sem coluna Cons., **+ Micro total/lido/estimado**, sem Score, ordenação livre. **Análise por
    matrícula:** removida a busca por matrícula.
  - **⚠️ Tela reformulada — Indicadores de micromedição (2026-10-26, sw v274):** saíram da tela `s-mm` os blocos **Abertura por DMC** e **Análise por matrícula** (distribuição por comportamento, ranking, detalhe da matrícula, export CSV do ranking — `mmDmcPanel`/`mmAnalysisPanel`/`mmDetail*`/`mmExport`/`MM_CLASS`/`MM_SIT` removidos do front; as RPCs `app_nrw_mm_resumo/_ranking/_serie/_dmc` e `mm_matricula_stats` **continuam** no banco — alimentam Fiscalização e HD). A tela agora tem **Indicador do mês** + **Sazonalidade** + novo bloco **Indicadores de micromedição** (`mmIndPanel`), que espelha o item 7.2 e o Anexo E do **relatório de linha de base** (ZA1004/ZA0200 R01): quadro-resumo (colunas **Média LB** × mês selecionado, por ZA; base = ligações, ativas, volume total/lido/estimado/factível, mais os indicadores) + **detalhamento mensal** por ZA só com os indicadores (= **Anexo E.1** do relatório; janela da LB destacada, 05/2025 como lacuna "sem dado") + **⭳ Exportar CSV** (`mmIndExport`). Indicadores (numeração **final do relatório, I1–I10**): **I1** ativas com leitura estimada, **I2** volume estimado, **I3** volume medido, **I4** ativas com volume zero, **I5** ligações não ativas, **I6** consumo por ligação (L/lig·dia), **I7** consumo por economia ativa (m³/economia/mês = (volume total − volume das não ativas) ÷ economias ativas), **I8** não ativas com volume lido/estimado, **I9** volume factível (I2 + I3 + I9 = 100%), **I10** não ativas com volume factível (definições no ⓘ). Critério = do módulo (volume total = lido + estimado + factível; faturada = volume>0 ou factível>0; estimado = `qt_volume_` das linhas com `qt_vol_est>0`). **Sempre ZA inteira** (não responde ao filtro de DMC). Backend: tabela **`"11 - perdas_nrw".mm_indicadores`** (consorcio, competencia, contagens/volumes; RLS deny-all; **202505 excluído**) refeita por `app_nrw_mm_indicadores_rebuild(p_consorcio)` — **chamada automaticamente no fim de `app_nrw_mm_stats_rebuild`** — e lida por **`app_nrw_mm_indicadores(p_consorcio)`** (definer, admin|`dev_acesso`) que devolve `{serie, janela}`; a janela de cada ZA vem do `linha_base` (`fonte='previa'`: ZA1004 03/2025–03/2026, ZA0200 04/2025–04/2026, sem 05/2025). Médias da janela = média dos valores mensais (bate com o relatório: ZA1004 I1 18,6% / I2 15,8% / L/lig·dia 628; ZA0200 14,1% / 10,3% / 493). DDL em `docs/migracao_mm_indicadores_2026-10.sql`. Cortados pelo usuário e **não implementados**: ligações faturadas, faixa 1–10 m³, taxa de faturamento, zero persistente e estimativa persistente. Tabela `mm_indicadores` também guarda `n_economias_ativas` e `volume_nao_ativas` (p/ o I7).
  - **Cruzamento matrícula→DMC (2026-09-24):** `"11 - perdas_nrw".mm_dmc_map` (spatial join `ligacoes.geom` ×
    `"7 - setorizacao".dmc.geom` vigente, `distinct on` p/ dedup de borda; 134.867 lig, ZA0200 6 DMCs / ZA1004 9) +
    `"11 - perdas_nrw".mm_dmc_mensal` (por DMC×mês: n_faturadas/volume_total/medido/não medido, populada em loop por
    competência p/ não estourar o timeout; 261 linhas). **Reconcilia 100% com `mm_mensal`.** Recompor = recriar
    `mm_dmc_map` (após editar limites de DMC) + repopular `mm_dmc_mensal`.
  - **Dimensão de fraude (2026-09-24):** colunas **`situacao_atual`** (`cd_situaca` da última competência: R=Ativa,
    I=Inativa/cortada, F=Factível, P=Potencial) e **`meses_irregular`** (nº de meses com a ligação em I/F/P **porém
    faturando volume** `qt_volume_>0` — "cortado mas com água") em `mm_matricula_stats`. Classe **`fraude_potencial`**
    (precedência máxima) quando `meses_irregular >= 2`; **2.485** matrículas (score médio 67,3). Detecta religação
    clandestina / by-pass. `_serie` devolve `sit_lig`+`irregular` por mês; `_ranking` devolve `situacao_atual`+
    `meses_irregular`; `_resumo` tem KPI `n_fraude`. Recomputar a dimensão = re-rodar o UPDATE de `meses_irregular`
    (buckets `mod(nu_matricu,4)`, `count(*) filter (where cd_situaca in ('I','F','P') and coalesce(qt_volume_,0)>0)`)
    + `situacao_atual` (join `competencia=ultimo_competencia`) antes do UPDATE de classificação/score.
  - **Base mensal:** tabela leve **`"11 - perdas_nrw".mm_mensal`** (agregado por consórcio×competência, 35 linhas —
    1 INSERT simples, sem bucket): n_faturadas, volume_total/medido/não medido, media_matricula. É a base do painel
    de **Indicador do mês** e da **Sazonalidade** (ambos hoje sobre **L/lig·dia**, não mais o consumo médio por
    matrícula — a reforma de 2026-09-24 acima substituiu essa métrica). ⚠️ Base = 18 meses (2025‑03→2026‑08), então
    a sombra/YoY hoje refletem só 2025 e alguns meses ainda sem sobreposição. Recomputar = re-rodar o INSERT do
    `mm_mensal`.
  - **⚠️ Semântica de volume — só micromedição, faturado FORA (2026-09-30):** `mm_mensal` e `mm_dmc_mensal` foram
    repopuladas para refletir **apenas o micromedido** (o que foi de fato lido + o que foi estimado). O `qt_vol_fac`
    (faturado mínimo — tarifa de consumo zero, aditivo quando `qt_volume_=0`) **saiu de tudo**:
    `volume_total = Σ qt_volume_`; `volume_medido = Σ qt_volume_ where qt_vol_est=0` (leitura real);
    `volume_naomedido = Σ qt_volume_ where qt_vol_est>0` (imputado) — agora `medido + estimado = total` exato.
    `n_faturadas = count(distinct nu_matricu) where qt_volume_>0` (ligações com micromedição; deixa de contar as
    só‑mínimo). As RPCs `app_nrw_mm_*` **não mudaram** (leem esses campos e derivam L/lig·dia e % na hora). O
    `qt_vol_fac` continua **só** na `consumo_dmc` (balanço NRW, onde o faturado é o consumo autorizado). Repopular =
    os dois `INSERT ... SELECT` diretos de `"5 - info_copasa".micromedicao_historico` (o do DMC via join `mm_dmc_map`),
    sem termo de `qt_vol_fac`.
  - **⚠️ FACTÍVEL — `qt_vol_fac` reinterpretado e REINCLUÍDO (2026-10-07, SUPERA a nota 2026-09-30 acima):** a coluna
    `qt_vol_fac` **não é** "faturado mínimo / tarifa de consumo zero" (interpretação anterior, errada) — é o **volume
    FACTÍVEL**: consumo de água **lido** em imóvel **sem situação ativa** (`cd_situaca <> 'R'` — inativo/cortado),
    forte **indício de fraude/religação clandestina**. Por decisão do usuário, o **micromedido total passa a ser
    `lido + estimado + factível`**. Repopulação de `mm_mensal` e `mm_dmc_mensal`: nova coluna **`volume_factivel =
    Σ qt_vol_fac`**; `volume_total = volume_medido + volume_naomedido + volume_factivel`; `n_faturadas =
    count(distinct nu_matricu) where qt_volume_>0 OR qt_vol_fac>0`. RPCs atualizadas (migração
    `app_nrw_mm_rpcs_factivel`): `app_nrw_mm_mensal` devolve `volume_factivel`; `app_nrw_mm_serie` devolve
    `factivel`(=qt_vol_fac) + `is_factivel`(=`cd_situaca<>'R' and qt_vol_fac>0`) por mês; `app_nrw_mm_resumo` ganha
    `n_factivel`. **Impacto no resultado/IRVP:** `app_nrw_resultado` lê `VC = Σ volume_total`, então o factível já
    entra como consumo e **baixa o VP em ~20–25 mil m³/mês** (ZA1004 202608: VP 759.976→**736.037**); as baselines
    **prévia** foram recalculadas (ZA1004 VPBL **1.008.719**/meta 244.110; ZA0200 **830.781**/meta 203.541 —
    contratual intacta). O `qt_vol_fac` **continua fora da `consumo_dmc`** (lá o consumo autorizado é só o faturado).
  - **Classe `factivel` na análise por matrícula (2026-10-07):** coluna **`meses_factivel`** em `mm_matricula_stats`
    (`count(*) filter (where qt_vol_fac>0 and cd_situaca<>'R')`) + classe **`factivel`** (precedência logo após
    `fraude_potencial`: `UPDATE classificacao='factivel' where meses_factivel>0 and classificacao<>'fraude_potencial'`,
    com bump de `score_anomalia`). **5.458** matrículas `factivel` / 1.219 mantidas `fraude_potencial`. Diferença:
    `fraude_potencial` usa o **volume medido** (ligação I/F/P faturando `qt_volume_>0`); `factivel` pega o caso em que
    o volume medido é **zero** mas há leitura no **campo factível** (`qt_vol_fac`). `app_nrw_mm_ranking` devolve
    `meses_factivel` (selo "N× factível" roxo `#b5179e`); `mmDetailRender` marca os meses factíveis em magenta +
    stat "Meses factível" + nota. `MM_CLASS.factivel` / `MM_SEAS_MET.volume_factivel`. Recomputar = re-rodar o UPDATE
    de `meses_factivel` (filtrando `qt_vol_fac>0 and cd_situaca<>'R'` p/ não estourar timeout) + o UPDATE de classe.
- **Análise de macromedição (2026-10-05, tela REAL — `s-macro`/nav "Análise de macromedição"):** espelha a
  do micromedido, sobre os volumes mensais dos macromedidores do **fechamento de volume da ZA** (fonte **GMOA**,
  planilhas por ZA). Carga em **`"11 - perdas_nrw".macro_mensal`** (493 linhas = 27 macros × 17 meses, abr/2025–
  ago/2026; por `competencia` YYYYMM, `funcao` entrada/saída, `sentido` N/I, vazão média + volume medido/estimado/
  total m³; único por consórcio+cd_no_agua+competência+sentido). Cadastro dos macros em **`"2 - infra_agua".macro_fechamento`**
  (cd_no_agua pk, consorcio, funcao, sistema — ex. ELDORADO CONTAGEM/CENTRO BETIM). RPCs `app_nrw_macro_mensal`
  (série por ZA: entrada/saída/**disponibilizado**=entrada−saída + L/lig·dia) / `app_nrw_macro_macros` (abertura por
  medidor no mês, MoM/YoY) / `app_nrw_macro_serie` (série+stats de 1 medidor) — definer, admin **ou** `dev_acesso`.
  **L/lig·dia = disponibilizado ÷ ligações ÷ 30 × 1000, MESMA premissa do micromedido** (reusa o denominador
  `"11 - perdas_nrw".mm_mensal.n_faturadas` por consórcio×competência) → disponibilizado − consumido(micro) ≈ perda
  por ligação. 4 painéis (Indicador do mês · Sazonalidade/tendência heatmap+linha · Abertura por macromedidor ·
  Detalhe do medidor), reaproveitando CSS/helpers do `mm` (`mmcard`/`mmheat`/`mmHeat`/`mmDiv`/`br1`/`mmCmp`...).
  Recarregar = refazer o INSERT em `macro_mensal` a partir das planilhas GMOA.
  - **Medido × estimado na Abertura por macromedidor (2026-10-28):** a tabela mostra o volume **segregado** como o
    GMOA informa — **Medido** + **Estimado** (laranja, com % do total do macro) = **Total** — e o cabeçalho soma o
    estimado do mês ("estimado X m³ em N macros"). `app_nrw_macro_macros` passou a devolver `volume_medido` e
    `volume_estimado` (`coalesce(...,0)`; com fator, o mesmo multiplicador do total — o fator ainda vale sobre o total,
    não só sobre a parcela medida). No GMOA medido + estimado = total (1 linha difere 0,22 m³ por arredondamento da
    fonte); `volume_estimado` vem **vazio** nos macros de telemetria e **0** nos de leitura — os dois contam como 0.
    Demais painéis e o resultado seguem lendo só o total. Na tela de macromedição o conteúdo ocupa a largura toda
    (`body:has(#s-macro.on) .wrap{max-width:none}`, como HD/Fiscalização); a barra lateral do cockpit passou de
    224 → **248 px** (nome "Análise de macromedição" numa linha; no celular a barra fechada fica inteira fora da tela).
  - **Bloco "Macromedidores × meses" + nova ordem (2026-10-28):** ordem dos blocos = Indicador do mês · Abertura por
    macromedidor · Sazonalidade & tendência · **Macromedidores × meses** · Fator de correção. O bloco novo é uma matriz
    **macro (linha) × competência (coluna)** com todos os meses e todos os macros que já apareceram no GMOA da ZA
    (total em mil m³; cor = medido / medido+estimado / só estimado / zerado / sem registro no arquivo do mês). Coluna
    **Situação** vs o último mês da ZA: *Medindo* · *Parou* (já mediu; no último mês saiu do GMOA, veio só estimado ou
    zerado — mostra o último mês medido) · *Nunca medido* (só estimado); "entrou em MM/AAAA" p/ quem começou depois do
    início da série. Filtros: Todos / Deixaram de medir / Com estimado / Entraram depois. Agrupado por ZA+função, os que
    pararam primeiro; clique na linha abre a série no detalhe da Abertura; em tela estreita abre rolado nos meses
    recentes (coluna do macro fixa). RPC **`app_nrw_macro_matriz(p_consorcio, p_com_fator)`** (definer, admin|`dev_acesso`,
    execute só `authenticated`): 1 linha por consórcio×macro×competência com `vm`/`ve`/`vt` (soma dos sentidos; com
    fator, mesmo multiplicador). Status calculado no front (`macroMatModel`). Ex. (09/2026): 4 saídas da ZA1004
    (EMM0000383/0556535/0556538/0559170) saem do GMOA após 07/2026 e a EMM0000131 entra em 08/2026 com volume ≈ soma
    delas; EMM0613252 (ZA0200) sai após 07/2026; EMM1697373 nunca medido.
  - **Camada `unidades_macromedicao` (view, schema 2):** ganhou 3 colunas via left join com `macro_fechamento` —
    **`fechamento_za`** (bool), **`funcao_medicao`** (entrada/saída) e **`sistema_macro`**. Marca 24 dos 37 macros
    da camada; **3 macros do fechamento não têm ponto no cadastro** (`EMM0000131`/`EMM1689916` ZA1004, `EMM1697373`
    ZA0200) — estão em `macro_fechamento`/`macro_mensal` mas não aparecem na camada até serem inseridos em
    `unidades_operacionais`. No QGIS, recarregar a fonte da camada para ver os campos novos.
- **Acompanhamento do resultado / IRVP (2026-10-06, tela REAL — `s-resultado`/nav "Acompanhamento do resultado"):**
  fecha a conta de perdas com macro+micro. **VP = VD (macromedido disponibilizado = entrada − saída) − VC
  (micromedido)**; **IRVP = (VPBL − VP) ÷ meta** (% de atingimento; só volume). Baselines **congeladas** em
  `"11 - perdas_nrw".linha_base` (`indicador='VP_BL'`, 4 linhas = 2 ZAs × fonte): **contratual** (TR 8.3 — ZA1004
  VPBL 977.337 / meta 236.516 · 24,2%; ZA0200 829.385 / 203.199 · 24,5%) e **prévia** (média de VP nos 12 meses
  pré-assinatura dos nossos dados, **já com factível no VC desde 2026-10-07**: ZA1004 1.008.719; ZA0200 830.781 —
  ~0–3% da contratual, validação). Janelas:
  ZA1004 mar/25–mar/26, ZA0200 abr/25–abr/26 (ambas exceto mai/25). RPC **`app_nrw_resultado(p_consorcio)`** (definer, admin|dev_acesso):
  devolve `baselines{contratual,previa}` + `serie` mensal (VD/VC/VP/IP%/L·lig·dia); "Ambos" (p_consorcio null)
  soma as 2 ZAs. **O IRVP é calculado no front** (`resIRVP`). A tela usa só a VPBL dos **dados existentes** (`previa`) — o
  toggle Contratual×Prévia foi **removido** em 2026-10-15 (ver abaixo); o `contratual` ainda vem na RPC, mas o front ignora.
  Painéis: linha de base · VP × baseline × meta (gráfico com corredor baseline→VP alvo) · tabela mês a mês. ⚠️ **bruto, sem
  fator sazonal** (FS é pleito, não aplicado — ver [[copasa-irvp-metodo]]). Está em `NRW_REAL` (destaque, não opaca).
  Recarregar baseline = re-rodar o INSERT em `linha_base` (prévia recalcula de `macro_mensal` − `mm_mensal`).
  - **Refino (2026-10-06):** RPC devolve `janela_de`/`janela_ate` nas baselines. Linha de base enxugada (3 cards:
    VPBL/Meta/VP alvo, com subtítulo explicativo; **removidos IP_BL e VD_BL**) + **colapsável `<details>`**
    (estado `resDerivOpen`) que mostra os 12 meses da janela (VD/VC/VP) → média = VPBL → VP alvo, para contratual e
    prévia. **Toggle contratual↔prévia replicado nos 3 blocos** (`resToggle`). Tabela: colunas Competência · VD · VC ·
    VP · **VP meta · Δ (VP−meta)** · IRVP (removidos IP%/L·lig·dia/Status). **Sem seletor de mês** (`#mes` escondido
    na tela; KPI usa o último mês). Popups (`RES_INFO`) robustos (siglas VD/VC/VP/VPBL + fórmula + gatilhos ≥50%/≥75%).
  - **Refino 2 (2026-10-06):** **"Indicador do mês" removido** (redundante com o mês a mês — `resKpiPanel` apagado).
    **VP alvo segregado em 100% e 120%** (VPBL − meta / VPBL − 1,2×meta, o teto do IRVP pois VC = RB×1,2): 4º card na
    linha de base, 2 linhas de referência no gráfico (verde 100% / azul 120%) e 2 colunas na tabela (VP meta 100%/120%,
    substituindo o Δ; célula pinta quando o VP do mês atinge o alvo). **Detalhamento colapsável agora é anchor-aware**
    (`resDerivHtml` usa `resB()`) — reage ao toggle (antes mostrava os dois fixos). `resStatus` ganhou faixa **≥120% (teto)**.
  - **Janela da VPBL ajustável + rebuild dinâmico (2026-10-13):** a **prévia** VP_BL passou a excluir **202505** e
    estender 1 mês pra trás, por consórcio (**ZA0200** abr/25–abr/26; **ZA1004** mar/25–mar/26) — guardado em
    `premissas` (`janela_de/ate` + **`excluir:[202505]`**). Função dinâmica **`public.app_nrw_baseline_rebuild(p_consorcio?)`**
    (definer, admin/dev; serviço/cron passa) recomputa a prévia (VP_BL/VD_BL/nlig/meta_m3/ip_bl) sobre a janela menos os
    excluídos, usando só meses com macro, e marca **`incompleto`/`meses_faltando`/`meses_no_calculo`** quando falta macro.
    **ZA1004 está provisória** (VP_BL 995.858, 11/12 — falta o **macro 202503**); re-rodar quando o dado entrar fecha os
    12 sozinho. **Contratual intocada** (número do TR). `app_nrw_resultado` agora expõe `excluir`/`incompleto`/
    `meses_faltando`/`meses_no_calculo`/`meses_esperados` (união correta no modo "Ambos"). **Front:** `resDerivHtml`
    tira os meses excluídos da **média** (bate com a VPBL do backend), pinta o 202505 e os meses sem macro de **vermelho**
    com selo "não entra"/"sem macro", e o painel da linha de base mostra **aviso de VPBL provisória** quando incompleto.
    A exclusão do 202505 é **só na VPBL** — a série ao vivo e o IRVP seguem mostrando o mês.
  - **Visibilidade do mês excluído (2026-10-14):** o vermelho só aparecia dentro do accordion "Como o VP alvo é
    calculado", que nascia **fechado**, na âncora **prévia** e com **uma** ZA — por isso passava despercebido na
    visão que abre por padrão (Ambos + Contratual + fechado). Agora o accordion **abre por padrão** (`resDerivOpen=true`)
    e o **painel da Linha de base exibe um aviso vermelho no topo** (`⛔ <meses> não entra(m) no cálculo da VPBL`)
    sempre que a âncora atual tiver meses em `excluir` (ou seja, na prévia) — fora do accordion, sem precisar expandir.
    A marcação segue sendo conceito da **prévia**; na **contratual** (VPBL = número do TR) nenhum mês é excluído, então
    o aviso não aparece (comportamento correto).
  - **Macro 202503 inserida + VPBL único, sem contratual×prévia (2026-10-15):** carregada a macromedição GMOA de
    **202503** (ZA1004 e ZA0200) em `macro_mensal` — os meses sobrepostos (202504→202608) já batiam com o banco, então só
    **202503** era novo (29 linhas). `app_nrw_baseline_rebuild(null)` fechou a janela: **ZA1004 VPBL = 1.003.269 m³/mês**
    (meta 242.791; era provisória 11/12, agora 12/12) e **ZA0200 = 836.312** (inalterada — 202503 fora da janela 202504→202604);
    ambas excluem 202505. **Front simplificado:** removido o toggle **Contratual (TR) × Prévia** — a tela usa só a VPBL dos
    **dados existentes** (fonte `previa`, relabelada apenas "VPBL"); `resAnchor` virou constante interna `'previa'`, `resToggle`/
    `resSetAnchor`/`data-anchor` removidos. Em lugar do toggle, o painel da Linha de base mostra **uma nota de aferição**
    (`resAferNote`): *VPBL preliminar — falta aferir os macromedidores para achar o fator de correção por macro e chegar ao
    VPBL final*. A linha `contratual` do `linha_base` continua no banco (referência do TR), apenas não é mais exibida.
  - **Coluna de Remuneração por Performance na tabela "Mês a mês" (2026-10-15):** removido o banner vermelho redundante
    "⛔ 05/2025 não entra…" do painel da Linha de base (o selo "não entra" na linha + o aviso no accordion bastam). Nova
    coluna **Remuneração** na `resTablePanel` com a **fórmula do TR §8.5**: `RP = (IRVP/120) × (1/42) × (54% × Valor do
    Contrato)`, paga só com **IRVP ≥ gatilho da fase** (≥50% nos 18 meses de implantação, ≥75% nos 42 de apuração, contados
    da **OS 06/2026**; abaixo = R$ 0) e **IRVP limitado a 120%**. Os 46% restantes do VC são a Remuneração Mínima do Ativo
    (por obra executada, fora do IRVP). Helpers `RES_VC`/`resVCtot`/`resGatilho`/`resRemun`; VC assinado ZA0200
    R$ 101.044.138 / ZA1004 R$ 101.248.034. Fica **vazio** (—) nos meses anteriores ao início do contrato (OS 06/2026, `RES_CONTRATO_INI`). Fonte da
    fórmula: `_extracted/TR ZA1004.txt` §8.5 (idem ZA0200). Meta de redução confirmada: **24,5% (ZA0200) / 24,2% (ZA1004)**.
  - **Fator de correção por macromedidor + toggle com/sem fator (2026-10-15):** multiplicador por macro (aferição) que corrige a
    volumetria. Tabela **`"11 - perdas_nrw".fator_correcao_macro`** (consorcio, cd_no_agua, **competencia_vigencia**, fator) — versionada
    por vigência com **carry-forward** (o fator vale do mês lançado em diante até o próximo lançamento). Função `"11 - perdas_nrw".nrw_fator(cons,cd,comp)`
    = LOCF (último lançamento ≤ comp, senão 1,0). **Todos os RPCs de macro e o resultado ganharam `p_com_fator`** (default false):
    `app_nrw_resultado(text,bool)` recomputa **a prévia inteira** (VD → VPBL → meta → IRVP → remuneração) com o fator; `app_nrw_macro_mensal/_macros/_serie(...,bool)`
    aplicam na volumetria (⚠️ **foram dropados os overloads antigos** sem o bool — §0.6). Novos RPCs **`app_nrw_fatores(text)`** (ler: macros `distinct on (cd)`,
    competências, lançamentos, `pode_editar`=admin) e **`app_nrw_fatores_salvar(jsonb)`** (upsert em lote, admin-only). **Front:** toggle **Sem/Com fator**
    no painel da Linha de base (resultado, `resComFator`→refetch) com nota que troca de cor; e na *Análise do macromedido* um toggle **Volume sem/com fator**
    + painel **editor "Fator de correção (aferição)"** (`macroFatorPanel`): seletor de vigência + tabela de macros com fator efetivo e input por macro,
    "Salvar fatores" (admin). `sem fator` = idêntico ao anterior (validado: ZA1004 1.003.269 / ZA0200 836.312). Sistema do 202503 normalizado (rtrim).
  - **Engrenagem de Premissas → Valor do Contrato mês a mês (2026-10-15, tela `config` "Parâmetros & Metas"):** a tela `s-config` (antes mock)
    virou real. Tabela **`"11 - perdas_nrw".premissa_contrato`** (consorcio, **competencia_vigencia**, valor_contrato) versionada por vigência com
    **carry-forward** (p/ reajustes), seed 202606 = VC assinado. Função `"11 - perdas_nrw".nrw_vc(cons,comp)` = LOCF (último lançamento ≤ comp,
    senão o VC assinado). `app_nrw_resultado` passou a devolver **`vcontrato`** por competência na série (soma por ZA no "Ambos"); `resRemun(irvp,comp,vc)`
    usa o VC do mês (fallback na constante `RES_VC`). RPCs novos **`app_nrw_premissas`** (ler; default_vc, competências, lançamentos, pode_editar) e
    **`app_nrw_premissa_vc_salvar(jsonb)`** (upsert lote, admin-only). **Front:** `cfgInit`/`cfgRender` no `#cfgBody` — seletor de vigência (60 meses do
    contrato), VC por ZA (efetivo + input), "Salvar VC" (admin), linha do tempo dos lançamentos, + painel "Outras premissas (referência)" (metas 24,5/24,2%,
    gatilhos 50/75%). `go('config')` chama `cfgInit`. Validado: reajuste vig. 202701 propaga via LOCF.
  - **Ajustes 2026-10-15:** `config` entrou em **`NRW_REAL`** → sai a opacidade/selo "exemplo" da sidebar e o banner "Em construção" (só nessa tela; as demais seguem exemplo). **VC corrigido** p/ os valores sem centavos definidos pelo usuário: **ZA1004 101.248.033 / ZA0200 101.044.138** (seed + fallback `nrw_vc` + `default_vc` + `RES_VC`). **Bloco do VC** deixou de estourar: o `.formrow` é grid com coluna de 90px; escopei `#cfgcss` (`#cfgBody .formrow{grid-template-columns:1fr minmax(160px,210px)}` + inputs `width:100%;box-sizing`) e removi o `width:160px` inline. **IRVP% (resStatus):** removidas as cores laranja/vermelho/rosa dos tiers abaixo de 75% (viram `var(--muted)`) — ficam só **azul** (≥120 teto, ≥75 Fase 2) e **verde** (≥100 meta).
- **Priorização de troca de HD (2026-10-08, tela REAL — `s-hdpri`/nav "Priorização de troca de HD" na seção 4·Execução-comercial):**
  ferramenta que gera a **lista operacional priorizada de substituição de hidrômetros**, seguindo o estudo (metodologia multifator,
  NÃO "medidor velho = troca"). Funções `hd*` em `perdas.html` (bloco clássico); em `NRW_REAL` (destaque, não opaca).
  - **Schema `"11 - perdas_nrw"` (app-only, RLS deny-all, acesso só via RPC definer):** `hd_calibre` (dimensão CAP→Q3/Q4/DN/
    aplicação/**código_servico SIENGE**/in_contrato/faixa típica de consumo), `hd_cadastro` (medidor por matrícula: num_hidr,
    cap, modelo_fam, ano_cod, idade_medidor, interno_externo — ETL dos xlsx), `hd_modelo` (dimensão fabricante/classe, preenchível),
    `hd_config` (singleton: pesos IPS, classe default, limiares idade/faixas P1–P5), `hd_priorizacao` (saída 1/matrícula, padrão
    `mm_matricula_stats`).
  - **Decodificação do nº do hidrômetro (validada em 247.749 nºs):** 1º char = **CAP = calibre** → vazão nominal + **código de
    serviço SIENGE** (Y=0,75→117 79 00 · A=1,5→117 78 00 · B=2,5→117 48 00 · C=3,5→117 49 00 · D=5→117 58 00 · E=6→117 59 00 ·
    F=10→117 68 00 · G=15→117 69 00; J–M macro/industrial = fora do contrato). 2 dígitos = ano fab; letras seguintes = família modelo.
  - **Motor `app_nrw_hd_rebuild()`** (definer, admin|dev; TRUNCATE+INSERT, reusa `mm_matricula_stats` + `micromedicao_historico`):
    Bloco A perfil (percentis P10–P90, faixa predominante, meses zero/baixo/alto), B mudança (média 1ºs×últimos 6m + migração de
    faixa + slope), C idade×utilização (volume registrado no período vs capacidade do calibre), D dimensionamento (perfil vs Q3/faixa
    típica → adequado/sub/super/mudança/indeterminado). **IPS** = média ponderada de sub-scores (pesos em `hd_config`, **editáveis na tela ⚙️ Premissas** — atuais: anomalia 15 · idade 21 · mudança 21 · utilização 22 · dimensionamento 21 · modelo 0; dimensões indeterminadas redistribuem o peso). Categoria
    **P1–P5** por faixa de IPS; `motivos[]` + `justificativa`; `codigo_servico` do calibre; **`remanejamento_sugerido`** = interno + ativa.
    **Interno/externo e situação da ligação são FILTROS, não entram no score** (decisão do usuário).
  - **⚠️ Rebuild mensal (teto de 120s do ambiente, 2026-10-13):** `app_nrw_hd_rebuild()` é **monolítico (~15 min / 132k)** e
    **NÃO passa** no `statement_timeout` de **120s** imposto pelo pooler/MCP **e também pelo pg_cron** deste ambiente (nem
    `SET` na sessão nem `SET statement_timeout=0` no corpo da função levantam — testado; o cron fica relançando e falhando a
    cada 2 min). **Para rodar o rebuild completo use o chunking:** função **`app_nrw_hd_rebuild_chunk(p_mod int, p_k int)`**
    (mesma lógica, **sem truncate**, filtra `matricula % p_mod = p_k`). Receita: `truncate "11 - perdas_nrw".hd_priorizacao;`
    e então rodar **`select app_nrw_hd_rebuild_chunk(20, k)`** para `k = 0..19` (chunks de ~6k matrículas cabem bem em 120s;
    2 chunks por chamada no MCP é seguro, 3 estoura). Alternativa definitiva (não feita): reescrever como **procedure** com
    `COMMIT` entre chunks pra rodar via cron. O gate permite `auth.uid()` nulo (serviço/cron). Reusa `mm_matricula_stats` +
    `micromedicao_historico` — então **rode o `app_nrw_mm_stats_rebuild` ANTES** (ver §micromedido) para o HD refletir o mês novo.
  - **RPCs de leitura** (definer, gate admin|dev_acesso): `app_nrw_hd_resumo(p_consorcio,p_situacao,p_interno)` ·
    `app_nrw_hd_ranking(...filtros...,p_limit,p_offset)` · `app_nrw_hd_mapa(...)` (GeoJSON lon/lat 4326 via join `ligacoes.geom`, top por IPS) ·
    `app_nrw_hd_detalhe(p_matricula)` (blocos + série 18m + calibre). Filtro de situação default **só ativa (R)**.
  - **⚠️ Situação da ligação pela micromedição atual (2026-10-22):** o `situacao_lig` (filtro ativa/inativa + `remanejamento_sugerido`=interno+ativa) **deixou de vir do cadastro estático `"3 - comercial".ligacoes.situacao_lig`** e passa a vir de **`"0 - vitrine_gis".vw_gis_micromedicao_atual.situacao_ligacao`** (R/I/F/P do **último mês da micromedição**; `ligacoes` fica só de fallback via `coalesce`). Motivo: o cadastro estava **desatualizado em 28.660 matrículas (22%)** — 19.806 "ativas" no cadastro estavam **inativas** no último mês faturado. `app_nrw_hd_rebuild`/`_rebuild_chunk` patcheados (CTE `lig`→view + `ligcad` fallback); dados atuais atualizados in-place (UPDATE `situacao_lig`+`remanejamento_sugerido` a partir da view). A view atualiza junto com cada carga mensal de micromedição → sempre a última situação.
  - **Frontend:** 4 painéis — **Resumo** (cards P1–P5 + remanejamentos + IPS médio + barras de motivos e de códigos SIENGE),
    **Lista operacional** (filtros categoria/motivo/calibre/situação/interno/busca + tabela ordenável + **export .xlsx**), **Mapa
    logístico** (Leaflet + markercluster, pontos coloridos por prioridade) e **Detalhe** por matrícula (stats + mini-gráfico + justificativa +
    ação/código). Novas libs via cdnjs `<script>`/`<link>` no `<head>`: **Leaflet 1.9.4 + Leaflet.markercluster 1.5.3 + SheetJS (xlsx) 0.18.5**.
  - **⚠️ Carga de dados:** o `hd_cadastro` foi populado só com uma **AMOSTRA (~700 matrículas)** para validar o motor/tela
    (carga completa via MCP é inviável — limite de leitura; e a rota via service key foi bloqueada pelo classificador). A **carga
    completa (132k)** é feita por um **script Python local** (`importar_hd_cadastro.py`, psycopg2 + `DATABASE_URL`) que o usuário
    roda com a credencial de banco → UPSERT em `hd_cadastro` + `app_nrw_hd_rebuild()`.
  - **⚠️ Calibrar:** faixas típicas de consumo por calibre (`hd_calibre.cons_tip_*`), classe metrológica default (`hd_config.classe_default='B'`)
    e pesos/limiares são **defaults iniciais** — refinar com ensaios/histórico de trocas. Tabela de vazão E/F adotada = a completa do usuário
    (E=6, F=10, G=15; divergia da 1ª tabela de designação em E=10/F=15). Bloco E (modelo) fica neutro até haver histórico de substituições.
  - **Refino (2026-10-08):** **filtros movidos para o cabeçalho** (categoria/motivo/calibre/situação/posição do padrão, junto do município — `.hdhf` + `hdSyncHeader`/`hdHeaderReset`). **Calibre recomendado** por consumo: função `"11 - perdas_nrw".hd_cal_recomendado(ref)` (menor calibre **in_contrato** cuja faixa cobre o consumo; J–M = fora do contrato) → colunas `cal_recomendado`/`q3_recomendado`/`codigo_recomendado`/`desc_recomendado` + `media_m3h`; o **código de serviço aberto = o do calibre RECOMENDADO** (o que será instalado), com atual→recomendado explícito. `hd_calibre.descricao_servico` (texto SIENGE). **Justificativa virou narrativa** (frase composta) — distinta da lista de `motivos` (tags). **Layout p/ uso diário:** KPIs compactos (P1–P5 clicáveis) + lista à esquerda + painel com **abas Detalhe / Mapa / Visão geral** (`hdTab`/`hdSetTab`); lista de códigos SIENGE com contexto calibre+vazão. `.xlsx` inclui atual+recomendado+código+descrição.
  - **Redesenho (2026-10-08b):** layout reformulado p/ operação — **sem cards de KPI no topo**; **3 distribuições no topo** (Serviço a abrir · Motivos · Adequação) que são **cross-filter** (clicar numa barra filtra a tela inteira em série — `hdF.codigo`/`motivo`/`adequacao`); **mapa + lista embaixo**; **detalhe da matrícula virou POPUP** (modal `mmModal`) ao clicar na linha/ponto, com **visualização da faixa de consumo** (`hdBandViz`: barras do calibre atual × recomendado + marcador do consumo → mostra por que sub/superdimensionado, já que m³/h médio confunde). **Mapa sem cluster** (`L.layerGroup`, pontos individuais) + **seleção por polígono** (desenho manual de vértices → GeoJSON) que filtra espacialmente lista/mapa/distribuições. RPCs de leitura ganharam `p_adequacao`/`p_codigo`/`p_poligono` (filtro espacial `st_contains` sobre `ligacoes.geom`); `app_nrw_hd_detalhe` retorna `calibre_rec` (faixa do recomendado).
  - **Ajustes de layout (2026-10-09):** **4 distribuições no topo** (Serviço a abrir · **Prioridades** P1–P5 · Motivos · Adequação; `hdDistCat`, `hdBars` com `keepOrder`); `.wrap` sem `max-width` na tela de HD (`body:has(#s-hdpri.on) .wrap{max-width:none}` — preenche a lateral); distribuições sem rolagem (`hddistwrap` 340px); mapa e lista do mesmo tamanho (`hdbottom` 1fr 1fr); **popup branco** — `--card` passou a ser definido (#fff claro / #152a31 escuro; antes caía no fallback navy #0f1a1f). sw v220.
  - **Premissas editáveis (2026-10-09b):** **tela escondida de premissas internas** acessível pelo botão **⚙️ Premissas** no cabeçalho (ao lado de Ambos/Betim/Contagem; `#hdPrem`, `.hdhf`, só na tela de HD). Abre em **popup** (`mmModal`) com **visualização OU edição** (`hdPremissas`/`hdPremRender`/`hdPremSave`): pesos do IPS, cortes P1–P4, idade-alta/classe default e as **faixas de consumo por calibre** (`cons_tip_min/max`) — cada premissa com uma **descrição de onde entra no cálculo** da substituição, soma dos pesos ao vivo. Backend: RPCs `app_nrw_hd_premissas()` (lê config+calibre, gate admin|dev) e `app_nrw_hd_premissas_salvar(p_config jsonb,p_calibre jsonb)` (grava e **chama `app_nrw_hd_rebuild()`** → o ranking/tela recalcula na hora; `hdReload()` + invalida `hdDetCache`). **Pesos revisados pelo gestor:** anomalia 15 · idade 21 · mudança 21 · utilização 22 · dimensionamento 21 · modelo 0 (antes 26/21/16/16/16/5). DN alinhados à referência Qn/Inmetro 246 (D=DN30/40 etc.; `dn_rec` é só exibição). sw v221.
  - **Códigos SIGOS editáveis (2026-10-09c):** no modo edição das Premissas, a tabela de calibres também edita **`codigo_servico`**, **`descricao_servico`** e a marca **`in_contrato`** por calibre — permite adicionar/alterar códigos de serviço SIGOS quando são criados/mudados (ex.: trazer J–M pro contrato). `app_nrw_hd_premissas_salvar` grava esses campos (`r ? 'codigo_servico'` → `nullif(btrim(...),'')`, `in_contrato::boolean`) e o rebuild/`hd_cal_recomendado` passam a considerá-los. O rótulo do gráfico **"Serviço a abrir"** usa um **mapa código→CAP dinâmico** (`hdCodMap`, carregado em `hdLoadCodMap` no `hdInit` e atualizado ao salvar) em vez do `HD_COD2CAL` fixo, então não fica "fora" quando um código novo é cadastrado. Popup alargado p/ 720px. sw v222.
  - **Metodologia + cabeçalho enxuto (2026-10-09d):** novo botão **📘 Metodologia** no cabeçalho (`#hdMetodo`, `.hdhf`) → popup `hdMetodologia()` explicando **como a nota IPS é calculada** (passo a passo + os 6 componentes detalhados com fórmula/cortes + exemplo real da matrícula 2212803). **Filtros de calibre/categoria/motivo removidos do cabeçalho** (`hdfCap`/`hdfCat`/`hdfMot`) — o cross-filter por categoria/motivo continua pelos gráficos; restam situação da ligação (`hdfSit`) e situação do padrão (`hdfInt`, antes "posição do padrão"). **Ordem no cabeçalho (tela HD):** Metodologia · Premissas · Ambos/Betim/Contagem (`#zaseg`) · Situação da ligação · Situação do padrão · busca (os 2 botões vêm **antes** do `zaseg` no DOM, escondidos nas demais telas). `#mes`/`#mesDmc` já ficam ocultos no HD. sw v223.
  - **Metodologia dinâmica + exemplo congelado (2026-10-09e):** no popup `hdMetodologia`/`hdRenderMetodologia`, os **pesos** dos componentes, o rótulo **"(maior peso)"**, os **cortes P1–P4** e o **limiar de idade alta** passaram a ser lidos **ao vivo de `hd_config`** (via `hdPremData`, carregado no `hdInit`/`hdLoadCodMap`; se faltar, o popup busca `app_nrw_hd_premissas` antes de renderizar). O **exemplo** (matrícula 2212803) virou um **snapshot congelado** (`const HD_EXEMPLO`) — fixo, com selo "❄ Snapshot fixo" e os pesos de referência que usou; **não muda** se as premissas forem alteradas (evita número incoerente). sw v224.
  - **Seleção do mapa por leaflet-draw + endereço no export (2026-10-15, sw v245):** o **seletor de área do mapa** deixou de ser o desenho manual de vértices (clique-a-clique) e passou a usar o **controle padrão `L.Control.Draw`** (polígono **e** retângulo), **igual ao da programação de pesquisa de vazamento** (`index.html` `ppInit`). Libs novas no `<head>` do perdas.html: **Leaflet.draw 1.0.4** (CSS+JS). As ferramentas moram no canto superior direito do mapa; `L.Draw.Event.CREATED` → `hdSelecionarGeom(geom)` (seta `hdF.poligono` com o GeoJSON cru do shape e `hdReload()`); botão **✕ Limpar seleção** (`hdDrawReset`) zera a área. Saíram `hdDrawClick`/`hdDrawAdd` e o estado `hdDraw`; entraram `hdDrawnLayer`/`hdDrawCtl`. **Export .xlsx** da priorização ganhou **Bairro** e **Endereço** (logo após a Matrícula) — **só no arquivo**, não na lista operacional: `app_nrw_hd_ranking` recebeu `p_incluir_endereco boolean default false` (⚠️ §0.6: a assinatura de 12 args foi **dropada** antes de recriar a de 13) que faz um `left join lateral` em `"0 - vitrine_gis".vw_gis_cadastro_comercial` (por `matricula`+`consorcio`) só quando `true`; `hdExport` chama com `p_incluir_endereco:true`, as telas (lista/mapa) chamam sem o flag → sem custo do join. ⚠️ **rua 99,99% em Contagem/0% em Betim** (a `logradouros` só tem Contagem) — em Betim o `endereco` traz só o número; `bairro` cobre as duas ZAs.
  - **Export CSV do ranking de matrículas (micromedido, 2026-10-15, sw v245):** a **Análise por matrícula** (tela `mm`) ganhou botão **⭳ Exportar CSV** no cabeçalho do bloco "Ranking de matrículas" (`#mmExport`, `mmExport`) — espelha o export da priorização de HD, exporta a **lista filtrada** (consórcio/DMC via `mmDmcSel`, classificação `mmClass`, busca `mmBusca`) paginando `app_nrw_mm_ranking` (`p_limit:500`). CSV com BOM UTF-8, separador `;` e decimais com vírgula (Excel-PT); colunas: Matrícula, Consórcio, Comportamento, Situação, Score, Meses, Média, Mediana, CV, Tendência (slope), Nº zeros, Mín, Máx, Meses irregular, Meses factível. Sem RPC nova.
  - **⚠️ Recomendação por p90+média-4m e filtro "troca efetiva" (2026-10-20d — só DB, sem sw):** corrige o caso em que o motor recomendava **trocar o HD por um calibre IGUAL** (ex.: Y→Y) — descoberto na matrícula 113902859. Eram **84,3k/132k (64%)** recomendando o mesmo calibre, **77,5k deles em medidor novo** (<10 anos) = "trocas fantasma" sem motivo (nem calibre, nem idade); já causaram trocas desnecessárias em campo.
    - **Nova referência de dimensionamento** `ref_dim = greatest(mediana, least(p90, média_4m))` usada em `adequacao` (a `utilizacao` e os demais sub-scores seguem na `ref`=mediana). O `least(p90, média_4m)` **exige que o p90 E a média dos últimos 4 meses concordem** para escalar → **robusto a pico isolado** (1 mês alto não move o p90). Nova coluna `"11 - perdas_nrw".hd_priorizacao.media_4m` (a antiga `media_3m` foi dropada).
    - **⚠️ Recomendação só com margem:** `cal_recomendado` **só muda de calibre quando `adequacao in ('subdimensionado','superdimensionado')`** — i.e. consumo **> 1,5× o máx da faixa** (subdim) ou **< mín** (superdim). **Migração de faixa que ainda cabe no calibre atual (`mudanca`) → mantém o calibre** (não é troca). Antes, qualquer migração marginal gerava upsize. Ex.: 113902859 tem `ref_dim=15`, Y cobre até 10 (1,5×=15) → `15 > 15` é falso → **permanece Y**.
    - **Coluna/flag `troca_efetiva`** = `(cal_recomendado ≠ cap) OU (idade ≥ idade_alta)`. **Os 3 RPCs de leitura filtram por `troca_efetiva` por padrão** (`app_nrw_hd_resumo`/`_mapa` sempre; `app_nrw_hd_ranking` ganhou `p_incluir_sem_troca boolean default false` — ⚠️ §0.6: assinatura de 13 args dropada e recriada com 14) → **saem do radar de quem programa**; o ranking devolve `media_4m`/`p90`/`troca_efetiva` nas linhas. Swaps por idade (mesmo calibre, HD velho) **continuam** no radar.
    - **Efeito:** radar caiu de 132k → **35,9k** itens efetivos (27%); só **28,5k trocas de calibre reais** (24,2k subdim + 4,3k superdim) + 7,4k por idade; **30,8k "mudança de faixa que cabe no calibre"** não geram mais troca. 113902859 → **Y→Y, `troca_efetiva=false`** (fora do radar). **Patches:** `app_nrw_hd_rebuild` e `app_nrw_hd_rebuild_chunk` (computam `media_4m`, `ref_dim`, cal_rec com margem, `troca_efetiva`); dados atuais recomputados por UPDATE in-place + `justificativa` regenerada. **Nenhuma mudança de frontend** (filtro server-side).
- **Fiscalização de irregularidades / fraudes (2026-10-20, tela REAL — `s-fraudepri`, sw v257):** tela operacional p/ o **time de programação** montar a **rota de fiscalização** (export p/ o SIGOS), modelada na Priorização de troca de HD. **Dois caminhos de acesso:** (1) item de menu no **cockpit NRW** — seção "4 · Execução — comercial", `data-s="fraudepri"` (dev_acesso); (2) **Auxiliar de Programação › Serviços comerciais** (`#apFraudePri` em `index.html` → `perdas.html?s=fraudepri`, aux-solo p/ aux_acesso/aprovador/admin). Em `AUX_TOOLS` e `NRW_REAL`. **2026-10-20c (sw v259):** esta tela **substituiu no menu os dois mocks** "Indicativo de fraude" (`fraude`/`s-fraude`) e "Fiscalização de fraudes" (`nrw_fiscalizacao`/`s-nrw_fiscalizacao`) — os dois `<section>` foram **removidos** e o card "Consumo não-autorizado" do mapa de ação (Componentes IWA) repontado p/ `go:"fraudepri"` (as funções mortas `fraude()`/`fiscalizacaoTool()` ficam inacessíveis — `go()` dá no-op em tela inexistente).
  - **Sem motor novo** — reaproveita a classificação de anomalia já pronta em **`"11 - perdas_nrw".mm_matricula_stats`** (score_anomalia/classificação/slope/cv/n_zeros/meses_irregular/meses_factivel). **Universo de suspeitos** = classes `fraude_potencial`, `queda_continua`, `nulo_recorrente`, `factivel`, `instavel` (≈41,4k; exclui estável/crescimento). DMC por matrícula via `mm_dmc_map.codigo_dmc` (join por matrícula **+ consórcio**).
  - **Lentes operacionais** (recortes de priorização, selecionáveis no painel ou no cabeçalho): **grandes consumidores** (média ≥ 50 m³/mês), **consumo com ligação irregular** (`meses_irregular` ≥ 3 = meses faturando volume com a **situação da ligação** `cd_situaca` em Inativo/Factível/Potencial — "cortado mas com água"), **leitura estimada recorrente** (`meses_estimada` ≥ 3 = meses com `qt_vol_est>0`, sem leitura real do hidrômetro), **abaixo da vizinhança** (média < 40% da **mediana do próprio DMC** — CTE `percentile_cont(0.5)` por DMC×consórcio). A coluna **% vizinhança** no ranking = média÷mediana_DMC×100.
  - **⚠️ Correção 2026-10-20b (sw v258):** o `cd_situaca` (R/I/F/P) e o `cd_situa_3` (AA/IA/FA/PA) são a **SITUAÇÃO DA LIGAÇÃO de água** (Real/Inativo/Factível/Potencial — conforme os slides comerciais da COPASA), **não** a situação da leitura. A 1ª versão rotulava `meses_irregular` como "leituras impedidas/estimadas" — **errado**: ele conta consumo em ligação não-Real (sinal de fraude, renomeado p/ "consumo com ligação irregular"). A **leitura estimada** de verdade = `qt_vol_est>0`; criei a coluna **`"11 - perdas_nrw".mm_matricula_stats.meses_estimada`** (backfill em buckets `nu_matricu%4`; **`app_nrw_mm_stats_rebuild` patcheado** p/ computá-la: `count(*) filter (where qt_vol_est>0)`). Duas lentes/colunas distintas agora: **Lig.irreg** e **Estim.**. FR_SIT corrigido (R=Real/Ativa, I=Inativo, F=Factível, P=Potencial). Assinatura: pontos ● coloridos = situação da ligação (I/F/P), ◯ azul = mês com leitura estimada.
  - **RPCs** (definer, gate **admin | dev_acesso | aux_acesso** via helper `_nrw_fraude_gate()` — mais permissivo que o HD p/ cobrir o acesso pelo Auxiliar): `app_nrw_fraude_resumo(...,p_poligono,p_est_min)` (total + por_classe + por_consorcio + contagens grandes/ligirreg/estimada/vizinhança) · `app_nrw_fraude_ranking(...,p_poligono,p_incluir_endereco,p_est_min)` (bairro/endereço via `left join lateral vw_gis_cadastro_comercial` só no export) · `app_nrw_fraude_mapa(...,p_limit,p_est_min)` (lon/lat 4326 via `ligacoes.geom`, top por score, máx 8.000) · `app_nrw_fraude_detalhe(p_matricula)` (stats + **série de 18m da micromedição com `cd_situaca` e flag `est`=`qt_vol_est>0`** + endereço/perfil). Filtro espacial = `st_contains` sobre `ligacoes.geom` (31983), mesmo padrão do HD.
  - **⚠️ Situação da ligação pela micromedição atual (2026-10-22):** a **"situação atual" exibida** (ranking + detalhe) passou a vir de **`"0 - vitrine_gis".vw_gis_micromedicao_atual.situacao_ligacao`** (último mês) via `coalesce(mv.situacao_ligacao, s.situacao_atual)` — ancorando na view a fonte canônica. Na prática **0 divergências** hoje (o `mm_matricula_stats.situacao_atual` já era o cd_situaca do último mês), mas garante robustez se a última competência da matrícula for < o mês global da base. (O mesmo ajuste foi feito, com impacto real, no HD — ver §1 troca de HD.)
  - **Frontend** (`fr*` em `perdas.html`, bloco clássico): 3 distribuições no topo (**Classes de suspeita** · **Lentes** · **Por consórcio**), cross-filter por clique; **mapa Leaflet + L.Control.Draw** (polígono/retângulo, cor #d6336c) que filtra espacialmente a **fila operacional** e o mapa; **export .xlsx** p/ SIGOS (matrícula, consórcio, bairro, endereço, DMC, classe, score, média, último vol, slope, zeros, meses s/ ligação ativa, meses leitura estimada, % vizinhança, situação da ligação). **Assinatura de fraude** no popup (`frDetailHtml`): sparkline de 18m com ● por situação da ligação (I/F/P) e ◯ nos meses de leitura estimada + bloco de estatísticas. Reusa libs já carregadas (Leaflet/Leaflet.draw/SheetJS). **Não há** priorização por DMC nem estimativa de recuperação de volume (fora de escopo por decisão do usuário).
  - **Gate do `perdas.html` alinhado:** a liberação das ferramentas aux (`AUX_TOOLS`) passou a aceitar também **`me.aux_acesso`** (além de `is_admin`/`pode_aprovar`) — consistente com o controle de acesso do próprio Auxiliar de Programação (a ⚙️ geral).
- **Balanço hídrico — rastreio dos dados (2026-10-22, tela REAL — `s-nrw_balanco`, sw v270):** a antiga folha mock (proxy do cadastro, `balancoSheet()` removida) virou o **checklist dinâmico de dados do Balanço Hídrico IWA**, escopo **ZA inteira** (sem DMC, sem benchmarking, sem valor/cenários — decisão do usuário). Plano completo: Artifact "Balanço Hídrico IWA" + memória `copasa-nrw-balanco-iwa-plano`.
  - **Tabelas** (`"11 - perdas_nrw"`, RLS sem policy, app-only): `bh_checklist_item` (34 itens A1–F1: grupo, item, `componentes text[]` = células IWA que alimenta, fase, fornecedor, necessidade, **origem** (tabela de origem), **tela** do cockpit, `status_base`/`nota_base` de partida, `status_manual`/`nota`/`atualizado_por`/`atualizado_em` do ajuste) + `bh_checklist_log` (histórico append-only de ajustes). Helpers `"11 - perdas_nrw".bh_fmt(numeric)` (número BR) e `bh_comp(int)` (AAAAMM→MM/AAAA).
  - **RPCs:** `app_nrw_checklist()` (definer, gate admin|dev_acesso) **verifica cada item ao vivo** na tabela de origem (macro_mensal, macro_fechamento, fator_correcao_macro, mm_mensal, hd_cadastro, hd_modelo, mm_matricula_stats, rede, ligacoes, vrps, vw_loggers, mapeamento_pressao, curvas_nivel, ordens_servico [148xxxx/149xxxx], ocorrencia, pesquisa_trecho, linha_base, premissa_contrato) e devolve `status_auto` + `evidencia` (+ `frescor`) por item; **status final = ajuste manual > verificação automática > status de partida**. `app_nrw_checklist_salvar(p_id,p_status,p_nota)` (admin; `p_status null` = volta ao automático; **nota obrigatória**; grava no log). Para incluir verificação automática num item novo: acrescente o bloco no `app_nrw_checklist` e semeie o item.
  - **Frontend** (`bh*` em `perdas.html`): KPIs (temos/em parte/não temos) + "Verificar de novo"; **quadro IWA clicável** (`BH_CELLS`: folhas + células calculadas em tracejado; `BH_EXTRA`: Infraestrutura/UARL e Contrato) colorido pelo agregado dos itens; clicar uma célula abre o **rastreio** (de quais folhas depende) e filtra o checklist; cada item expande com necessidade, fornecedor, origem no banco, botão **"Abrir <tela de origem>"** (`go(it.tela)`), verificação automática, contexto, situação final (com aviso se o ajuste manual difere do automático), formulário de ajuste (admin) e histórico do item. `#zaseg` e `#mes` ficam ocultos nesta tela. Em `NRW_REAL`.
- **Desativação visual do que não é real (2026-10-05):** só **`mm`** (micromedido) e **`macro`** (macromedição)
  têm dados ao vivo via RPC. As outras **11 telas** restantes (após a remoção abaixo) ficam **opacas + selo "exemplo"** no menu
  (`.navi.mock`) e com **banner "🚧 dados de exemplo"** no topo da tela (`.mockbanner`) — **nada apagado, só
  sinalizado/rastreável**. Controle num só ponto: `const NRW_REAL=new Set(['mm','macro','resultado','hdpri','fraudepri','config','nrw_balanco'])` + `nrwMarkMocks()`
  (marca o menu no load) + `nrwMockBanner(s)` (injeta o banner por tela dentro do `go()`). **Para promover uma
  tela a "real", adicione o `data-s` dela ao `NRW_REAL`** (sai da opacidade e perde o banner automaticamente).
- **Dados (resto):** ainda **snapshot estático** embutido no HTML (15 DMCs, VRPs projetadas, OS por causa,
  auditoria cadastral, reincidência de ramais — extraídos de `"7 - setorizacao".dmc`).
  Indicadores de perda (IPD/%NRW/ILI/MNF) ficam "aguardando Qin/faturamento".
  **Próximo passo:** trocar o snapshot por RPCs `app_nrw_*` (a criar) sobre `"7 - setorizacao"` (geometria/
  cadastro DMC) e `"11 - perdas_nrw"` (`parametros_nrw`, `linha_base`, `medicao_entrada`, `consumo_dmc`).
  Reorg de 2026-09: `dmc` foi de `"6 - analises"` (aposentado) → `"7 - setorizacao"`; as tabelas de
  cálculo/config → `"11 - perdas_nrw"` (*app-only*, sem `USAGE` pra GIS).
- **Estrutura (2026-10-05, enxugada p/ 13 itens; +Acompanhamento do resultado em 2026-10-06 = 14):** 1 Visão (Painel, **Acompanhamento do resultado**) · 2 Dados & diagnóstico (Análise do
  micromedido, Análise de macromedição, Balanço) · 3 Ação (Componentes IWA, Fraude) · 4 Execução (OS;
  Parque, Fiscalização, Recuperação, Grandes) · 5 Gestão & decisão (Contrato) · 6 Configuração (Parâmetros).
  **21 telas removidas de vez** (não só opacas): DMCs, Ficha, Medições, Consumo, Vazão mínima noturna,
  Eventos, Plano por DMC, HD, Auditoria, Rede, Ramais, Pressão, Renovação, VRPs, Reservatórios, Setorização,
  Leitura, Simulador, ELL, Indicadores, Governança — botões + seções + dispatch do `go()` + entradas de
  `TITLES`/`COMPET` apagados; `go()` ganhou guarda `if(!document.getElementById('s-'+s))return` p/ links órfãos;
  limpos o wiring top-level do simulador (`sp/sh/sk`) e as refs à `dmcs` em `indToggles`/`renderMaps`. As
  **funções de render** das telas removidas ficaram como código morto (não referenciado) — poda futura.
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

---

## 8. Projetos · Intervenções — `// MÓDULO PROJETOS / INTERVENÇÕES` · telas `projetos`(hub) / `projeto_campo` / `projeto_det` / `projeto_sup` / `projeto_cfg` / `projeto_acesso` / `projeto_resumo` / `projeto_rel`

Acompanhamento diário de obra das intervenções (macromedidores, VRPs, redes VCA/HDD, **válvulas**).

- **⭐ Reground nos dados reais (2026-09-25):** `PJ_IVS` deixou de ser mock — agora é **carregado do banco** por
  **`pjLoad()`** (RPC **`app_proj_intervencoes`**, gated admin/`dev_acesso`) a partir das tabelas-base
  **`"7 - setorizacao".intervencoes_pontuais`** (21: VRP 16, Valvula 5) e **`intervencoes_lineares`** (1 rede),
  importadas do GeoPackage `CRONOGRAMA_MG`. `pjLoad` roda no dispatch de cada tela do módulo (`pjLoad().then(...)`),
  mapeia o **`tipo`** real → tipo do módulo (`PJ_TIPO_MAP`: VRP→`vrp_impl`, Valvula→`valvula`) e
  instancia a **árvore-modelo** do tipo (`PJ_ARV[tipo]()`, zerada). As coords reais (GeoJSON 4326) são
  **normalizadas** no mapa esquemático (viewBox 100×62, bbox→[8..92]×[8..54], y invertido). Toda intervenção
  recém-importada entra **`locked=false`** (em configuração no Suporte). O mock antigo de 6 IVs vira só fallback
  (mostrado se a RPC falhar/offline).
- **Mapa Leaflet real (2026-09-25):** `pjRenderMap` deixou de ser o SVG esquemático — agora é **Leaflet**
  (`mapAddCamadaBase`, um mapa por contexto em `pjMaps[ctx]`, `L.layerGroup` recriado a cada refresh). Pontos =
  `circleMarker` coloridos por tipo (`PJ_TIPO_COR`, hex que espelha as CSS `--t-*`, porque Leaflet não aceita
  `var()`), linhas = `polyline`; tooltip com código+tipo, clique abre a intervenção. `iv.ll`=[lat,lon] / `iv.lls`
  (do GeoJSON 4326). ⚠️ **Cuidado:** `fitBounds` roda **dentro** do `setTimeout` do `invalidateSize` (senão, com o
  container ainda sem tamanho, o zoom trava no `maxZoom` centrado no meio). `pjSetView('mapa')` também dá
  `invalidateSize`. Containers `#pjMapaL`/`#pjSupMapaL` (46vh).
- **Persistência por snapshot (2026-09-25):** schema **app-only `13 - projetos_obra`** + tabela
  **`intervencao_estado`** (`kind`,`gid`, **`arv jsonb`** = snapshot da árvore, `locked`, `status`, quem/quando;
  RLS deny-all, acesso só por RPC). RPCs **`app_proj_estados`** (lê todos) e **`app_proj_estado_set`** (upsert),
  definer, gated admin/`dev_acesso`. No `pjLoad`, após instanciar os templates, **sobrepõe** o estado salvo
  (arv/locked/status). Salva (debounce 500 ms — `pjSave`/`pjSaveNow`, chave `kind|gid`) em **toda mutação**:
  toggle "No escopo?", quantidade (±), tipo de peça, registro, **cadeado** (liberar/reabrir) e **lançamento de
  avanço** no campo — o "Lançar avanço" agora é **real** (lê o input `.pjinp` e soma ao `%`/`exec` da folha) e
  persiste. `pjLeafHist` (histórico fabricado) foi zerado e `hasAdv` usa `pjHasAdv` (avanço real).
- **⭐ Log de avanço REAL (2026-09-25):** cada "Lançar avanço" grava um registro **append-only** em
  **`"13 - projetos_obra".intervencao_avanco`** (kind,gid, iv_cod/iv_local/consorcio/tipo denormalizados,
  **caminho** "Atividade › … › Sub", atividade, sub, valor, unidade %/m, obs, **fotos[]** no bucket `fotos-campo`
  prefixo `projetos/avanco/`, ts, autor/autor_nome, equipe). RPCs **`app_proj_avanco_registrar`** (devolve a linha),
  **`app_proj_avancos_iv(kind,gid)`** (histórico de uma intervenção) e **`app_proj_avancos(de,ate)`** (feed do
  Resumo) — definer, gated `dev_acesso`. Front: `pjAvancosLoad`/`pjAvancosCur` (por `caminho`), **`pjNodePath`**
  (identidade do nó por referência → caminho único por folha, validado), `pjDDMM`. O **painel de campo** mostra os
  **lançamentos reais** da etapa (data/valor/autor/obs + link da foto) + acumulado; o **Resumo por período**
  (`pjRsFeed`/`pjResumoLoad`) e o **mini-Gantt** do relatório usam as **datas reais** do log. `pjOpen`/`pjRel`
  viraram async (carregam avanços). Lançar = upload fotos → `registrar` → aplica no snapshot → atualiza histórico.
- **Diferenciação HDD × VCA nas linhas (2026-09-28):** `intervencoes_lineares.tipo` já traz **`'HDD'`** (trechos AL13/AL14,
  gid 2–16) ou nulo/`'VCA'` (rede a céu aberto, gid 1); a RPC `app_proj_intervencoes` **já devolve `tipo`** nas
  properties das linhas. Antes o front **fixava toda linha em `rede_vca`** (`pjMapTipo(...,isLine)` hardcoded) — bug.
  Agora `pjLoad` decide por regex `/HDD/i` sobre `tipo`+`layer_dwg` → **`rede_hdd`** (senão `rede_vca`), com árvore
  própria **`PJ_ARV.rede_hdd`** (perfuração direcional trenchless: locação/sondagem → mobilização do equipamento HDD →
  valas de entrada/saída → **furo piloto** (m) → alargamento → **puxamento/pullback** (m) → peças → **ramais**
  (2026-09-28, igual à VCA) → interligação → teste → as-built; sem escavação de vala longa/reaterro/pavimento). Cores
  `--t-rede_hdd` (verde) × `--t-rede_vca` (roxo).
- **Filtro de consórcio (2026-09-28):** select **Ambos/Betim(ZA0200)/Contagem(ZA1004)** nas barras `pjfilt` de Campo
  (`#pjCons`) e Suporte (`#pjSupCons`); estado compartilhado `pjFcons`, entra no `pjOk` (`iv.za` = `p.consorcio` gravado
  em cada iv no `pjLoad`). Filtra mapa+lista+contador. (Consórcio derivado da cidade na RPC: Betim→ZA0200, Contagem→ZA1004.)
- **Status DERIVADO (2026-09-28):** o status deixou de ser campo fixo (todo import entrava `new`) — agora
  **`pjStatusDe(iv)`** deriva do estado real: **`cfg` "Em configuração"** quando `!iv.locked` (travada no Suporte, campo
  bloqueado); depois de liberada, **`new` "Não iniciada"** (0%), **`run` "Em andamento"** (0–100%), **`done`
  "Finalizada"** (≥100%, via `pjIvPct`). Usado em `pjOk` (filtro), nas listas, no as-built e salvo em `p_status`
  (`pjSaveNow`). Pill `.pjpill.cfg` (âmbar). Isso responde "como o status é atribuído": antes não era — ficava tudo
  "Não iniciada". **"Em configuração" só no Suporte (2026-09-28):** `pjStatusView(iv,ctx)` mapeia `cfg`→`new` fora do
  Suporte, então o **Campo** (usuário final) só vê **Não iniciada/Em andamento/Finalizada**; a opção "Em configuração"
  saiu do `#pjStatus` (fica só no `#pjSupStatus`) e o chip "⏳ Em config." agora aparece **só na lista do Suporte** (o
  Campo mostra apenas a pill de status). `pjOk`/`pjInit` recebem `ctx`; `pjFst='cfg'` é limpo ao entrar no Campo.
  **2026-09-29 — Campo esconde de vez o cfg:** `pjOk` filtra `pjStatusDe(iv)!=='cfg'` fora do Suporte, então
  intervenções em configuração **não aparecem no mapa/lista do Campo** (nem contam no total) — só surgem no Suporte
  (configuração das intervenções). Ao liberar o cadeado, entram no Campo.
- **Reconciliação de snapshot — bloco Ramais (2026-09-29):** snapshots de rede (`app_proj_estados`) salvos **antes** da
  adição do bloco **Ramais** ao template não o tinham (ex.: a AL14/F05 tinha 11 nós, 0 ramais). O `pjLoad`, após
  sobrepor o snapshot, **insere o bloco Ramais** (do `PJ_ARV[tipo]()`) logo após "Peças e acessórios" nas árvores
  `rede_vca`/`rede_hdd` que não o tiverem — preserva o resto da config e some sozinho quando o snapshot for regravado.
- **Valas HDD configuráveis + rename (2026-10-06):** a atividade do `PJ_ARV.rede_hdd` **"Valas de entrada e saída" →
  "Valas de perfuração"** (o nome antigo dava a entender que eram exatamente 2) virou **bloco replicável**
  (`pjValas`/`pjVala`, espelha `pjPecas`/`pjPeca`): quantidade setável no Suporte (stepper `rep`), **mínimo 2**
  (`min:2` — entrada + saída, podendo haver mais); cada vala = `pjSel` (Tipo entrada/saída) + obra civil (`pjOc`).
  `pjRepDel` e o stepper (`delDis`) respeitam `node.min`. **Avanços já lançados** (nome/caminho antigos, 2 níveis,
  ex. `Valas de entrada e saída › Escavação`) são preservados **sem mexer no banco** por: (1) `pjLoad` reconcilia
  snapshots antigos — regex `/^valas de (entrada|perfura)/i`, envolve as subs planas em **Vala 1** (preserva o %
  lançado) + **Vala 2 (Saída)** vazia (só HDD, `jaNovo`=algum filho `k==='g'`; já-replicável com nome antigo é só
  renomeado; some ao regravar, igual ao bloco Ramais); (2) `pjAvancosLoad` **normaliza** o avanço legado em memória
  (`atividade`/`caminho` antigos → `Valas de perfuração › Vala 1 › …`) — faz o histórico, o bloco de avanços e o
  **Gantt** (que casa por `atividade`) baterem com a árvore renomeada. Forward-compatible com migração futura do banco.
- **Mapa — traçados distinguíveis (2026-09-28):** cada linha recebe uma **cor distinta** de `PJ_LINE_PAL` (indexada por
  `gid`) p/ separar traçados sobrepostos — o tipo (VCA/HDD) fica no tooltip, não mais na cor da linha. (Tentativa
  anterior de marcadores início/fim "I"/"F" foi descartada: sobrepunham nas pontas.) **Removidos** a legenda de cores
  (`#pjLeg`/`#pjSupLeg`) e os textos de dica sob os dois mapas ("Toque num pino…"/"Toque numa intervenção…").
- **Contorno das ZAs no mapa (2026-09-28):** `app_proj_intervencoes` ganhou a chave **`limites`** (GeoJSON das 2 ZAs
  de `"1 - suporte_geografico".limite_za`, `ST_SimplifyPreserveTopology(geom,30)`→4326, ~15 KB; mesma assinatura, só
  `CREATE OR REPLACE`). `pjLoad` guarda em `PJ_LIMITES`; `pjRenderMap` desenha o contorno tracejado (Betim vermelho /
  Contagem azul, `fillOpacity .04`) **embaixo** dos marcadores, **respeitando o filtro de consórcio** (`pjFcons`) e
  **fora do `fitBounds`** (não afasta o zoom das intervenções). **Marcadores pontuais reduzidos** (`radius` 8→6).
- **⚠️ `sw.js` ASSETS:** restaurados `logo-aguas-integradas.png`/`logo-eficiencia-hidrica.png` no precache (tinham
  caído da lista na resolução de conflito ao empilhar os PRs da Geovana; os arquivos sempre estiveram no repo).
- **Projetos → 🛠️ Execução + política de acesso (2026-09-29):** o card saiu de "Em desenvolvimento" p/ **Execução**
  (`data-go="projetos"`, sem gate). **Gate das RPCs revisto:** leitura/campo (`app_proj_intervencoes`/`_estados`/
  `_avancos`/`_avancos_iv`/`_docs_listar`/`_avanco_registrar`/`_estado_set`) agora só exigem **autenticação** (saiu o
  `dev_acesso`); config de documento (`_doc_set`/`_doc_remover`) e acesso (`app_proj_acesso_*`) migraram p/ o gate
  **Suporte** (admin **ou** `proj_sup_acesso`). `homeGate` não gerencia mais `#cardProj`; a engrenagem ⚙️ de "Em
  desenvolvimento" perdeu a borda (só Perdas/Pessoas seguem lá). E2E: usuário de campo comum lê tudo e **não** consegue
  `doc_set`. **Filtro de DMC (2026-09-29):** `#pjDmc`/`#pjSupDmc` (estado `pjFdmc`, opções = DMCs distintos das
  intervenções carregadas) entra no `pjOk` das duas telas. **Camada de DMCs no mapa:** `app_proj_intervencoes` ganhou
  a chave **`dmcs`** (`"7 - setorizacao".dmc`, simplificada 15 m, `codigo`/`numero`/`consorcio`); `PJ_DMCS` desenhado
  por baixo (tracejado fino, o DMC filtrado em destaque). **Borda da ZA mais forte** (`weight` 1.5→3.5, sólida, sem
  fill). **Cabeçalho por tipo (`pjSpecs`):** nas telas de intervenção (`pjRenderDet`/`pjRenderCfg`) mostra info-chave —
  rede VCA/HDD: **Extensão (m) + DN**; VRP/Válvula/macro: **DN**; + tubulação e DMC quando houver (`ext`/`tubulacao`
  agora guardados no iv das linhas).
- **Loggers `-3` (2026-09-29):** inseridos `J-4971-3`/`J-5048-3`/`J-6499-3`/`J-6635-3` em
  `"8 - coleta_campo".instalacao_logger_calibracao` (ZA0200, pendentes, copiando ponto planejado + modelo dos `-2`).
- **Atividade fora do escopo some no Campo (2026-09-29):** `pjNodeHtml` retorna `''` para nó `ativo===false` quando
  `pjMode==='campo'` — o usuário do Campo não vê mais a atividade **opaca** (no Suporte/config ela continua visível com
  o toggle "No escopo?"). Já era coerente com o %: `pjPct` retorna `null` e `pjLeaves` pula `ativo===false`.
- **3 fotos por avanço (2026-09-29):** o painel de lançamento (`.pjlaunch`) passou de 2 para **3** `.pjph2` (Foto 1/2/3);
  o handler `[data-launch]` já coletava todas via `.pjph2 input[type=file]` e o `app_proj_avanco_registrar.p_fotos text[]`
  aceita qualquer nº — sem mudança de backend. `.pjfotos` ganhou `flex-wrap` + `min-width` p/ caber no celular.
- **Resumo por período → Campo (2026-09-29):** o card "Resumo por período" saiu da categoria **Suporte** para **Campo**
  no `pjHub` e `pjResumoEnter` perdeu o gate `pjPodeSup()` (aberto a todos, como Intervenções). Título "Suporte ·
  Resumo por período" → "Resumo por período". Só **Configuração de intervenções** segue no Suporte (pjPodeSup).
- **Visão 3D nos documentos da config (2026-09-29):** em `projeto_cfg`, para intervenções de **VRP** (`vrp_impl`/
  `vrp_subst`), a seção Documentos ganha a linha **🧊 Visão 3D** → `pjOpen3d(iv)` abre um overlay (`#pj3d`) com
  `<iframe src="https://vrps-3d-aguas-mg.vercel.app/?embed=1" allow="fullscreen; xr-spatial-tracking">` (visor externo
  das 16 VRPs, projeto Vercel independente). **Deep-link por peça (2026-09-29):** o `projeto`/`id` da intervenção de
  VRP já traz o nº (`"VRP-07"`, `"BET-02-VRP-29"`) e essas **16 = exatamente as 16 do visor**, únicas por número — o
  `pjLoad` extrai (`iv.vrp`, regex `/VRP-?(\d+)/i`, mantém o zero à esquerda) e o `pjOpen3d` abre direto em
  `?embed=1&vrp=NN`. Consórcio/DMC não são necessários p/ desambiguar (números não se repetem entre ZAs).
- **"Projeto 3D" na lista de documentos (2026-10-01):** a linha **🧊 Visão 3D** virou **🧊 Projeto 3D** e foi
  **reposicionada para logo após "Projeto executivo"** (antes de "Licença ambiental"); além da `pjRenderCfg`, agora
  aparece também no **relatório** (`pjRel`) para o usuário. Helpers `pj3dIsVrp(iv)`/`pj3dRow()` (botão `data-open3d`
  → `pjOpen3d(iv)`); só intervenções de VRP (`vrp_impl`/`vrp_subst`). Overlay `#pj3d` inalterado.
- **Árvore de Válvula (`PJ_ARV.valvula`, nova):** Locação → Obra civil (vala/caixa) → Retirada (se substituição,
  off) → Instalação da válvula + acessórios → Interligação/religação → Teste/manobra → Cadastro. As demais árvores
  (vrp_impl, rede_vca) seguem o padrão do protótipo. Cor `--t-valvula`.
- **Trava do editor GIS (`gis_editor_2s`):** nas tabelas-base ele tem **SELECT/INSERT/UPDATE, sem DELETE/TRUNCATE**
  (revogados) + auditoria append-only (`intervencoes_audit` via trigger) → alimenta as camadas sem nunca apagar.
  Ver [[copasa-projetos-intervencoes]] na memória.

**Estado anterior (preview):** dados de exemplo no HTML (`PJ_IVS` mock), sem backend. Gate hoje é por
`ME.dev_acesso` (categoria "Em desenvolvimento"), não mais o e-mail hardcoded.

- **Gate:** card `#cardProj` na home. Em `homeGate()` espelha o `cardPerdas`: se
  `ME.email==='sander.sirio@aguasmg.com.br'` vira botão ativo → `irPara('projetos')`, senão fica `.soon` +
  🔒 e `toast('Acesso restrito')`.
- **Hub (`projetos`, `pjHub()`) — 2 categorias, espelha o Almoxarifado:** **🏗️ Campo** → `projeto_campo`
  (dia a dia) e **🧰 Suporte** → `projeto_sup` (configuração/cadeado, card com ícone **⚙️** — engrenagem, distinto
  do cadeado). A categoria Suporte é gateada por **`pjPodeSup()`** = admin **ou** `ME.proj_sup`. O grant é
  definido no **mini-cadeado 🔐** ao lado do título "🧰 Suporte" (só admin, `pjPodeSetSup()`) → tela `projeto_acesso`.
  **Grant persistido no banco (2026-09-25, espelha o `dev_acesso`):** coluna **`perfil.proj_sup_acesso`**, RPCs
  **`app_proj_acesso_listar`** / **`app_proj_acesso_set`** (admin-only) + `app_me` devolve **`proj_sup`**
  (admin **ou** flag). Vale **em qualquer dispositivo** (o localStorage antigo `pj_sup_acesso` foi aposentado).
  ⚠️ **Bug corrigido:** o campo de busca (`#pjAcessoBusca`) recriava o próprio input a cada tecla (`oninput` →
  render total) → cursor/foco pulava e o texto virava minúsculo. Agora o input é fixo e só a **lista**
  (`#pjAcessoList`) re-renderiza (`pjSupAcesso`/`pjSupAcessoRender`).
- **Cadeado (1 por intervenção):** `iv.locked`. **Liberada** (`locked`) = configuração **congelada**, o campo
  lança avanços. **Em configuração** (`!locked`) = só o Suporte edita escopo/quantidade; **avanços bloqueados**
  (evita desativar atividade que já tem avanço). Default: liberada, exceto `status==='new'` (segue em config).
  Chip de estado na lista/Suporte (`.pjlockchip` lib/cfg). **2026-09-28:** removidos os textos de ajuda da tela de
  configuração — a descrição do card "Em configuração" (mantido só o rótulo + botão Liberar) e o parágrafo `.pjhint`
  "Ative/desative atividades…" acima do escopo.
- **Congelamento por item (`pjHasAdv`):** mesmo com o cadeado **aberto**, um item que já tem **lançamento**
  (folha %/m com avanço >0, ou grupo com descendente lançado) **não pode sair do escopo** — o toggle vira 🔒
  e o `−` da Quantidade não remove um bloco com lançamento. "O que foi lançado não pode ser desativado."
- **Telas de campo:**
  - `projeto_campo` — filtros **dropdown** (`#pjTipo`/`#pjStatus`), toggle **Mapa/Lista** (`.pjseg`). Mapa é
    **SVG esquemático** (a versão integrada usa geometrias reais do GIS). `pjInit`/`pjRefresh`/`pjRenderMap`/`pjRenderList`.
  - `projeto_det` — **lançar avanços** (`pjRenderDet()`, `pjMode='campo'`, `pjLocked=iv.locked`). Banner de estado
    (liberada/em config). **Só lança se liberada:** `＋ Lançar` e os inputs de registro (OS SIGOS etc.) só aparecem/
    editam com `pjLocked`. Árvore robusta (`pjNodeHtml()`): cada bloco nível-1 é card separado, grupos colapsáveis
    com **Detalhes** (`data-detbtn`→`.pjdetpanel`) e linha-resumo (`X/Y etapas ✓ · Z%`). Registros viram **inputs
    editáveis** no campo (`data-reg`→`node.v`); tipo de peça (`sel`) fica só-leitura. `＋ Lançar` → painel com
    **histórico real da etapa** (`pjAvancosCur`, do log) + acumulado + **2 fotos + observação**. **Nenhum controle de config aqui** (foi p/ Suporte).
    Botão **📄 Relatório e documentos** no fim da rolagem.
- **Suporte (config + cadeado):**
  - `projeto_sup` (`pjSupEnter()`→`pjInit('sup')`) — **mesma visualização de mapa + filtros do campo** (SVG,
    dropdowns, toggle Mapa/Lista), via **`PJ_CTX`** (mapa de ids campo×sup + ação de toque `pjOpen`×`pjOpenCfg`);
    `pjInit`/`pjSetView`/`pjRefresh`/`pjRenderMap`/`pjRenderList` recebem `ctx`. Toca numa intervenção → `projeto_cfg`.
    Mini-cadeado 🔐 no cabeçalho (`#pjSupAcessoBtn`, só admin) → `projeto_acesso`.
  - `projeto_cfg` (`pjRenderCfg()`, `pjMode='cfg'`) — **cartão do cadeado** no topo (`pjLockcard`): **Liberar para
    execução** (`#pjLock`→`iv.locked=true`) / **Reabrir configuração** (`#pjUnlock`; se já há avanços, exige
    **2 cliques** com aviso, sem `confirm()` nativo). Árvore em **modo config**: **toggle "No escopo?"** (`.pjsw.sm`,
    `data-toggle`→`node.ativo`) em **toda atividade E subatividade mensurável** (grupos + folhas %/m; item lançado
    congela — ver `pjHasAdv` acima); **stepper Quantidade** (`data-repadd/repdel`); **select de tipo** (`sel`,
    `data-sel`) nas peças. Tudo **desabilitado quando `pjLocked`** (frozen). Abaixo do escopo, **📎 Documentos**
    — **é AQUI que se anexa/abre/remove** projeto executivo/autorização de via/relatórios (furo/solda [HDD])/as-built/RTQ. Wiring da árvore compartilhado
    com o campo via **`pjWireTree(d,rerender)`** + `pjSnapOpen`/`pjReopen`.
    - **Documentos REAIS (2026-09-25):** 1 arquivo (PDF) por tipo (`PJ_DOCS`: executivo/licenca/alvara/as_built).
      Upload no bucket **`fotos-campo`** (reaproveitado, prefixo `projetos/<kind>/<gid>/`), registro em
      **`"13 - projetos_obra".intervencao_documento`** (PK `kind,gid,tipo`; RLS deny-all). RPCs **`app_proj_docs_listar`**
      / **`app_proj_doc_set`** (upsert, devolve o path antigo p/ apagar do Storage) / **`app_proj_doc_remover`**
      (devolve o path removido), definer/gated `dev_acesso`. Front: `pjDocsLoad`/`pjDocAnexar`/`pjDocRemover`;
      **Anexar** (input file PDF → upload + `_set`, substitui e apaga o antigo), **Abrir** (`SBASE+path`, nova aba),
      **Remover** (`_remover` + `storage.remove`). `pjOpenCfg` e `pjRel` viraram **async** (carregam docs antes de
      renderizar). No `projeto_rel` os documentos são **só Abrir** (real). O mock `pjMakePdfUrl`/`pjOpenPdf` deixou
      de ser usado pelos docs.
    - **Atividades de encerramento (As-Built + RTQ) (2026-10-15, sw v247):** toda intervenção termina com **duas
      atividades-documento** fixas — **Cadastro do As Built** e **Relatório Técnico de Qualidade** — adicionadas ao fim de
      cada árvore (`PJ_ARV`) e garantidas por reconciliação no `pjLoad` (converte o antigo `pjP('Cadastro / as-built')`;
      insere/reordena como as 2 últimas; some sozinho ao regravar o snapshot). Novo tipo de nó **`k:'doc'`** (`pjDoc(n,doc)`,
      `doc` = `as_built`|`rtq`): **registro único via anexo de PDF (não foto)**, sem % — `pjPct` devolve `null` p/ `doc` (não
      entra no agregado, evita leitura do `pjDocsCur` global entre intervenções na lista/mapa); render próprio em `pjNodeHtml`
      (chip anexado/pendente + 📎 Anexar/Substituir PDF + 👁 Abrir); wiring `data-docattach`/`data-docfile`/`data-docopen` no
      `pjWireTree`. O PDF é gravado pelo **mesmo mecanismo de documentos** (`pjDocAnexar`→`app_proj_doc_set`), então entra
      automaticamente na **lista de Documentos** e no **relatório final/PDF consolidado** (`PJ_DOCS` ganhou `rtq`; `as_built`
      renomeado p/ "Cadastro do As-Built"). No campo o anexo aparece só com a intervenção **liberada** (`pjLocked`); no Suporte
      o anexo segue pela seção Documentos. `pjOpen` virou a carregar docs (`pjDocsLoad`) além dos avanços; `pjDocAnexar`/
      `_remover` re-renderizam a tela corrente via `pjRerender()` (campo×config). Gantt do relatório exclui nós `doc`.
      **Backend:** `app_proj_doc_set` passou a aceitar `rtq` e a **permitir o campo** (qualquer autenticado, mesmo gate do
      `app_proj_avanco_registrar`) a anexar **só** os 2 docs de encerramento (`as_built`/`rtq`); os demais tipos seguem
      restritos ao Suporte (admin/`proj_sup_acesso`). Sem mudança de tabela (whitelist só na RPC; sem CHECK em `tipo`).
    - **As-Built/RTQ contam como 100% (2026-10-15, sw v248):** as 2 atividades de encerramento passaram a **entrar no
      progresso** — `pjPct(doc)` = `node.done?100:0` (antes `null`), `pjLeaves` inclui `doc`, então o **anel/%** da intervenção
      e o **concluídas/total** só fecham 100% com os **dois PDFs anexados** (a intervenção não fica "Finalizada" sem eles).
      Para os **cards da lista/mapa** ficarem corretos sem abrir cada intervenção, nova RPC leve **`app_proj_docs_presenca()`**
      (authenticated; devolve `kind,gid,tipo` dos docs as_built/rtq existentes) → `pjDocsPresLoad`/`pjStampDoc` marcam
      `node.done` em todas as intervenções no `pjLoad`. `pjDocsLoad` (abrir intervenção) re-marca pelo `pjDocsCur`; anexar/
      remover chamam `pjSetDocDone(iv,tipo,bool)` (atualiza `pjDocsPres` + `node.done`) antes do `pjRerender`. O chip do nó
      mostra **"anexado · 100%" / "pendente · 0%"** e o Gantt do relatório volta a listar os nós `doc` com status (anexado/pendente).
    - **OS SIGOS + Relatório de Furo (2026-10-22, sw v268):** (1) **OS SIGOS** é a **1ª atividade de TODA árvore** (`pjOS()`:
      nó `k:'reg'` com flag `os:true`) — **só número** (input `inputmode=numeric`, `oninput` tira não-dígitos, `data-osigos`),
      salvo no snapshot (`pjSave`) e editável no Campo e no Suporte. Por ser `reg`: **não conta no avanço** (`pjPct`→`null`),
      **sem toggle "No escopo?"** nem cadeado (só `isG/%/m` têm toggle) e fora do Gantt/progresso do relatório (filtro `k!=='reg'`).
      O valor sai nos "Dados da intervenção" do PDF (`pjOsVal`). Snapshots antigos ganham o nó no `pjLoad` (reconciliação:
      `unshift` se faltar, move p/ o início se estiver fora de lugar). (2) **Relatório de Furo** (`rel_furo`) = atividade-documento
      **exclusiva de `rede_hdd`**, **antes** do As Built (ordem HDD: … teste › Relatório de Furo › As Built › RTQ). Mesmo mecanismo
      do As-Built/RTQ (PDF, conta 100% quando anexado, campo anexa com a intervenção liberada). `PJ_DOCS` ganhou `{t:'rel_furo',hdd:true}`
      e **`pjDocsFor(iv)`** filtra os docs aplicáveis — usada na lista de Documentos (cfg e relatório), na seção 4 do PDF e nos
      **anexos mesclados** do PDF consolidado (ordem de `PJ_DOCS`: furo antes do as-built). **Backend (migração `proj_doc_rel_furo`):**
      `app_proj_doc_set` aceita `rel_furo` e o libera ao campo (junto de `as_built`/`rtq`); `app_proj_docs_presenca` inclui `rel_furo`.
    - **Autorização de Intervenção de Via + Relatório de Solda + sai a Licença (2026-10-28, sw v281):** (1) **Licença ambiental
      saiu** de `PJ_DOCS` (cfg, relatório, PDF consolidado) e da whitelist do `app_proj_doc_set` — os anexos antigos (`tipo='licenca'`,
      1 na linha 16) **ficam no banco**, só não aparecem. (2) O antigo **"Alvará de execução" virou "Autorização de Intervenção de
      Via"** — **mesmo tipo `alvara`** (anexos existentes migram sozinhos), constante `PJ_AIV_N`/`pjAIV()`. Agora é **atividade-documento
      obrigatória de TODA intervenção**, **logo após a OS SIGOS** (2ª atividade): anexada pelo **campo na tela de lançamento**, igual
      ao As-Built/RTQ, e conta **100% quando anexada** → a intervenção **não chega a 100% sem ela** (não trava o lançamento de avanço).
      Snapshots antigos ganham o nó no `pjLoad` (reconciliação: insere/move para o índice 1, renomeia). (3) **Relatório de Solda**
      (`rel_solda`, `hdd:true`) = atividade-documento **só de `rede_hdd`**, entre Furo e As-Built (ordem HDD: … › Furo › Solda ›
      As Built › RTQ). Os três entram no relatório consolidado e nos anexos mesclados do PDF via `pjDocsFor(iv)` (ordem de `PJ_DOCS`).
      **Backend (migração `proj_excluir_intervencao_e_docs_aiv_solda`):** `app_proj_doc_set` aceita `rel_solda` e libera ao campo
      `alvara`/`as_built`/`rtq`/`rel_furo`/`rel_solda`; `app_proj_docs_presenca` inclui `alvara` e `rel_solda`.
    - **Excluir intervenção (2026-10-28, sw v281):** botão **🗑️ Excluir intervenção** no canto superior direito do `projeto_cfg`
      (`#pjCfgDel`, na `.bar` ao lado do "‹ Suporte"; visível p/ `pjPodeSup()`). Só exclui **sem lançamento**: bloqueado (opaco, toast
      com o motivo) se houver avanço em qualquer item (`pjHasAdv`) **ou** documento da tela de lançamento anexado (`pjIvDocLanc` —
      nó-doc 100%; remova o anexo antes). Confirmação no modal global `vmModal` (`pjExcluirConfirm`) → RPC
      **`app_proj_intervencao_excluir(p_kind,p_gid)`** (definer, gate admin/`proj_sup_acesso`) que **revalida** (log `intervencao_avanco`,
      `%`/`m` > 0 no snapshot via `jsonb_path_exists`, docs `alvara/rel_furo/rel_solda/as_built/rtq`) e apaga **de forma definitiva**:
      a linha em `"7 - setorizacao".intervencoes_pontuais|lineares` (o trigger `a_audit` grava a geometria), `intervencao_estado` e
      `intervencao_documento`. Rastro extra em `intervencoes_audit` (`operacao='EXCLUSAO_APP'`, estado + documentos + `excluido_por`,
      `alterado_por`=e-mail). Devolve `paths` dos arquivos → o app apaga no Storage (`storage.remove`; delete direto em `storage.objects`
      é bloqueado pelo Supabase). **Policy nova** `fotos_campo_projetos_sup_delete` (DELETE em `fotos-campo`, prefixo `projetos/`, só
      admin/`proj_sup_acesso`) — antes **nenhum** `storage.remove` do módulo apagava de fato (sem policy de DELETE, falhava em silêncio;
      no campo, sem acesso ao Suporte, a troca de PDF continua deixando o arquivo antigo órfão). ⚠️ Se a camada de intervenções for
      **reimportada do gpkg de origem**, a intervenção excluída pode voltar.
  - `projeto_acesso` (`pjSupAcesso()`) — **mini-cadeado da categoria Suporte**: lista de usuários (via
    `app_proj_acesso_listar`) com toggle de acesso (admin sempre ligado). Persiste no banco
    (`perfil.proj_sup_acesso` via `app_proj_acesso_set`); busca com input fixo + `#pjAcessoList`.
  - `projeto_resumo` (`pjResumoEnter`→`pjResumo()`) — **resumo por período** p/ o gestor. Filtro de período
    (atalhos Hoje/7 dias/Este mês/Tudo + `de`/`até` custom) + consórcio + tipo. **KPIs** (nº avanços, intervenções
    com movimento, subatividades, metros executados), **timeline por dia**, **por intervenção** e **por atividade**,
    + **Exportar CSV**. Fonte de dados: **`pjRsFeed`** (RPC `app_proj_avancos`, log **real**), carregado por
    `pjResumoLoad`; `pjRsRange()` resolve o período (filtro cliente por consórcio/tipo/data). (O `pjAllAvancos()`
    antigo, sobre `pjLeafHist`, ficou obsoleto.)
    - **Metros = rede instalada (2026-10-02):** todo total de metros (KPI "metros exec.", Por dia, Por intervenção,
      Por atividade) soma **só Puxamento** (`rede_hdd`) e **Assentamento de tubulação** (`rede_vca`) via
      `pjRsEhMetroRede`/`mNum` — evita dupla contagem (piloto, escavação etc. não entram). O **Por dia** passou a
      agrupar **dia → intervenção → avanços**; cada avanço individual segue mostrando seu valor real (+N m/%).
  - `projeto_rel` — **gestão, tela à parte**. **Documentos** = `pjDocsFor(iv)` (projeto executivo, autorização de intervenção de via, relatórios de furo/solda [HDD], as-built, RTQ),
    **só com botão Abrir** (arquivo real do Storage) — **anexar/remover ficam na configuração** (`projeto_cfg`).
    **Progresso por atividade (2026-10-06, era "mini-Gantt"):** AUDITORIA — o Gantt antigo plotava a barra por
    `ts` (data de **registro** do avanço), não por data de obra; sem cronograma planejado e com lançamento em
    lote (ex. AL13/F02 = 6 avanços em 8 min, 02/10) a linha do tempo colapsava e o eixo repetia a mesma data.
    Trocado por **barra de progresso (0–100%)** por atividade + a janela de registro como rótulo honesto (`gfmt`).
    **Avanços por atividade·subatividade (reescrito):** `pjRelGrupos(iv)` agrupa por atividade (nível 1) →
    subatividade, **só o que tem lançamento de fato** (`pjAvancosCur`), em ordem de execução (árvore); cada sub
    abre por avanço em **ordem de envio** (`ts` asc), com **observação + nome de quem enviou** (`autor_nome`, cai
    p/ `equipe`) + **fotos reais** (miniaturas, `pjRelAvRow`). **Removidos** o toggle `#pjAdvSeg` e o uso do stub
    `pjLeafHist` (deixava o bloco sempre vazio). **PDF consolidado (2026-10-07, merge real):** `pjRelPdf(iv)`
    (async) → overlay `#relatorio` com `pjRelDocHtml(iv)` (REL_CSS): dados + progresso + avanços (c/ autor/obs/
    fotos) + documentos. Os anexos (PDFs do executivo etc.) são **renderizados página a página** via **PDF.js**
    (`pjLoadPdfJs`/`pjRelRenderAnexos`, cdnjs 3.11.174, igual ao Leaflet) como imagens embutidas ao fim (`#relAnexos`,
    cada página `break-before:page`), então o "Salvar PDF" (window.print) sai como **um único documento mesclado** —
    não mais só a nota de "anexado". O botão de imprimir fica **desabilitado até os anexos renderizarem**; anexo que
    falhar (CORS/sem internet) cai numa nota `.relPend` com link p/ abrir. Anexo não anexado segue com nota explicativa.
- **Fotos obrigatórias no avanço (2026-10-07):** o `app_proj_avanco_registrar` só é chamado se houver **≥1 foto**
  (`if(!files.length){ toast(...); return; }` no handler de lançar); antes dava pra lançar sem nenhuma foto.
- **Modelo de dados (nós da árvore):** construtores `pjP` (%), `pjM` (metros meta/exec, % automático),
  `pjR` (registro), `pjSel` (**seleção de tipo**, `k:'sel'` — não mensurável), `pjG` (grupo); helpers `pjOc`
  (obra civil), `pjIL` (interligação), `pjILrep` (container replicável), `pjRamal`/`pjRamais` e
  `pjPeca`/`pjPecas`. **Ramal** (`pjRamal`) traz, nesta ordem: **OS SIGOS** e **Nº do Hidrômetro** (primeiro),
  **Nº do imóvel**, as-built **A1/A2/A3/P1** (registros), depois execução **Escavação/Assentamento/Ligação à
  rede** (% ativáveis). **Peça** (`pjPeca`) traz **Especificação (tipo de componente)** primeiro (`pjSel`, opções
  em `PJ_PECA_TIPOS`: **válvula de manobra, ventosa, descarga** (2026-09-28 — reduzido a essas 3; saíram registro/
  redução/tê/cap/luva/outro); o tipo
  escolhido aparece no cabeçalho do bloco), depois **Escavação/Escoramento/Montagem hidráulica/Reaterro/
  Recomposição de pavimento** (% ativáveis). `pjReg[rid]=node` mapeia elemento→nó p/ os handlers.
  `pjPct()` agrega: % = média das folhas ativas; `m` = exec/meta; grupo = média dos filhos. `ativo:false`,
  `k:'reg'` e `k:'sel'` não entram na média (nem viram `null%`). Meta **não** é limitador (passa de 100%).
- **Render dual (`pjNodeHtml`):** módulo-global `pjMode` (`'campo'`|`'cfg'`) + `pjLocked` decidem o que
  aparece: campo = `＋Lançar`/inputs de registro (só se liberada); cfg = toggles/steppers/selects (só se
  destravada). `pjZero` reseta `sel`→'' ao replicar bloco.
- **Idioma do app:** script é `type="module"` → funções **não** são globais; handlers via `.onclick=`
  (não `onclick=` inline), exceto `toast()` que está em `window`. Telas em `SCREENS` +
  `irPara()`: `projetos`→`pjHub()`, `projeto_campo`→`pjInit()`, `projeto_sup`→`pjSupEnter()`,
  `projeto_acesso`→`pjSupAcesso()`, `projeto_resumo`→`pjResumoEnter()` (det/cfg abrem via `pjOpen`/`pjOpenCfg`).
  Back buttons das telas ligados uma vez no load.
- **✅ Resolvido (2026-09-25):** reground nos dados reais; **persistência por snapshot** (`intervencao_estado`);
  **lançamento de avanço real** (grava no `%`/`exec`); **grant do Suporte no banco** (`proj_sup_acesso`/`ME.proj_sup`,
  vale entre dispositivos); histórico fabricado **removido**; **documentos reais**; **log de avanço real**
  (`intervencao_avanco` — autor/equipe/hora/fotos/obs; Resumo e Gantt reais); schema `13 - projetos_obra` **criado**.
- **⚠️ Ainda pendente:** (a) `status` (run/new/done) é **fixo**, não deriva do progresso; (b) **prazos/planejado ×
  realizado** — o Gantt mostra a janela real mas **não detecta atraso** (falta o cronograma planejado); (c) toggles
  são `<span>` (sem teclado). Datas do log são reais (ts); o parse legado DD/MM só aparece na exibição.
- **Schema `13 - projetos_obra` (2026-09-25):** **`intervencao_estado`** (snapshot da árvore),
  **`intervencao_documento`** (docs por tipo) e **`intervencao_avanco`** (log de lançamentos, append-only).
  Cadastro georref das intervenções vem de **`7 - setorizacao.intervencoes_pontuais`/`intervencoes_lineares`**
  (importadas do gpkg CRONOGRAMA_MG).
- **Próximos passos sugeridos:** controle de atividades = **prazos & atraso** (planejado × realizado, farol) +
  **log de avanço real** (com fotos/equipe), depois impedimentos, painel e alertas.

## 12. Meus colaboradores — tela `meus_colab` (substitui a Gestão de Pessoas, 2026-10)

A antiga **Gestão de Pessoas** (schema `"14 - pessoas"`: candidatos, aprovação de vaga, carta proposta, ativação,
checklist de setup, desligamento, premissas de benefícios, RH/`pessoas_admin`) **foi removida do app**. A
admissão/desligamento voltam a ser pela planilha de usuários (`Usuarios_AcquaHub.xlsx` → `public.perfil`).

- **Quem vê:** card **📇 Meus colaboradores** na home › 🧰 Suporte (`#homeMeusColab`, `homeGate()` → só
  `ME.pode_aprovar`). **Aprovador** vê os colaboradores **ativos** que o têm como Aprovador 1 ou 2; **admin** vê
  todos os ativos. O próprio usuário não aparece na lista dele.
- **Tela:** busca (nome/e-mail/cargo), chips de consórcio (com contagem), select de área; total + quantitativos
  **por área, consórcio, projeto, cargo, modalidade e direto/indireto** (barras simples, `mcBloco`), e a lista —
  tocar num colaborador abre a ficha (`mcFicha`): e-mail, cargo, consórcio, código+área, frente, projeto,
  direto/indireto, modalidade, matrícula, admissão, aprovador 1 e 2. **CPF não é exibido.**
  Estado `mcData, mcCons, mcArea, mcSel`; tudo filtrado no cliente sobre uma única chamada.
- **RPC:** `app_meus_colaboradores()` (`SECURITY DEFINER`; devolve `[]` se o chamador não for aprovador/admin).
- **Aviso de novo colaborador:** trigger `trg_perfil_novo_colaborador` (`AFTER INSERT OR UPDATE OF aprovador_uuid,
  aprovador2_uuid, ativo ON public.perfil`) → `sup_notificar` (notificação **pessoal**, sem `p_exceto`) para o
  Aprovador 1/2 que **acabou de ser vinculado** (ou quando o colaborador é reativado), `link='meus_colaboradores'`
  (`supGoAct` → `irPara('meus_colab')`; os links antigos `pessoas_*` também caem aqui). Na prática dispara quando
  o admin/a sincronização da planilha preenche os aprovadores de um usuário novo.
- **Migrações:** `docs/migracao_meus_colaboradores.sql` (RPC + trigger). A limpeza do banco antigo é **opcional e
  destrutiva**: `docs/migracao_remove_gestao_pessoas.sql` (dropa `app_pessoas_*` e o schema `"14 - pessoas"`
  inteiro, com dados de candidatos) — só rodar depois de exportar/backup. `perfil.pessoas_admin` foi mantida
  (o `app_me` ainda a devolve; não é mais lida pelo front). Os logos `logo-aguas-integradas.png`/
  `logo-eficiencia-hidrica.png` (usados só pela carta proposta) ficaram em `public/` e no `ASSETS` do `sw.js`.

## 15. Gestão de VRPs (`vrpman`, schema `8 - coleta_campo`)

> **Reorg 2026-10:** o card da home virou **"VRPs – Campo"** e o hub `vrpman` (`vmHub`) ficou **só com 🏗️ Campo**
> (Minhas OS / Visita primária). As 3 telas de **gestão — `vrpman_serv` (Gestão de serviços), `vrpman_fichas`
> (Ficha cadastral), `vrpman_prev` (Cronograma preventivo)** — **migraram para o Auxiliar de Programação ›
> categoria "Gestão de VRPs"** (renderizadas por `apInit()`, gate `ME.vrp_gestao`, ⚙️ `vrpman_cfg` admin). As
> telas em si não mudaram; seus back-buttons e os redirects de gate agora apontam para `auxiliar_programacao`.
>
> **Melhorias 2026-10 (UX):** (1) **Ficha cadastral** (`vmFichasRender`) ganhou **busca pesquisável de VRP**
> (input + `datalist`, filtra os cards ao digitar); (2) na **ficha aberta** (`vmFichaOpen`) há botão **＋ Abrir OS**
> (gest.) que reusa `vmProgramar(vrp,num)` → escolhe tipo (corretiva/preventiva/substituição) + usuário + data;
> (3) o **select de VRP ao Programar** (`vmProgramar`) virou **input+`datalist` pesquisável** (resolve o texto
> digitado → `vrp_id` via `elig`); (4) **Execução** (`vmPhoto`/`vmPhotoMulti`) — removido `capture="environment"`
> para o usuário **escolher foto da galeria** (não força a câmera); (5) **Gerar OS a partir de pendência**
> (`vmGerarCorr`, usado na ficha, na OS e na gestão › Pendências) agora tem **seletor de tipo de OS**
> (corretiva/preventiva/substituição) — RPC `app_vrp_pendencia_gerar_os` ganhou `p_origem` (drop+create, §0.6;
> deixou de bloquear pendência de substituição); pendências de substituição também viraram acionáveis.

Vertente de **gestão de serviços de manutenção** sobre as VRPs (separada do módulo `vrp`, que é só
levantamento/inventário). Card **🔧 Manutenção de VRPs** na categoria **🚧 Em desenvolvimento** da home
(gate `ME.dev_acesso` via `homeGate` — opaco `.mod soon` + 🔒 p/ quem não tem, como Perdas/Pessoas; quando
maduro, promover para 🛠️ Execução como foi feito com Projetos). Hub (`vmHub`) com 2 categorias: **🏗️ Campo**
(executar OS — qualquer autenticado) e **🧰 Gestão** (backoffice, gate `ME.vrp_gestao`). Campo + Gestão entregues.

**Modelo de dados (app-only, RLS on, acesso só via RPC definer):**
- **`vrp_os`** — ordem de serviço de manutenção. `os_numero` interno `VRP-OS-AAAA-NNNN` (contador por
  ano em `vrp_os_contador`) + **`os_sigos`** (OS da COPASA, opcional, preenchida no backoffice).
  `origem` (preventiva/corretiva/programada/avulsa), `status`
  (programada→em_execucao→concluida/concluida_pendencia/retorno/improdutiva), `atribuido_uuid` (quem
  recebe — **só usuário, não há equipe**), `programada_para`, `dmc` (spatial VRP→DMC via `vrp_dmc_de`),
  geom/gps, campos-ficha reaproveitados da última OS (`modelo`/`tem_controlador`/`controlador_modelo`/
  `ponto_critico_ref`), pressões encontradas/finais, estabilizada/vazamento_pos/liberada, `respostas`/
  `fotos` jsonb, **`pendencia_id`** (quando é uma corretiva que resolve uma pendência).
- **`vrp_pendencia`** — pendência técnica gerada na OS (`os_id`). Ciclo: **aberta → em_andamento**
  (quando o backoffice gera a corretiva, `os_correcao_id`) **→ resolvida** (ao concluir a corretiva,
  `resolvida_os_id`). Regra do usuário: **toda pendência se resolve por uma OS corretiva derivada** —
  nunca fecha manual nem "dentro" de outra visita.
  **Consolidação (2026-10-15):** o encerramento gera **uma única pendência** por OS — `app_vrp_os_concluir`
  consolida todos os problemas relatados num só registro (descrição em lista ` • `; `tipo='multiplos'` se
  houver mais de um, `lado` só se único) em vez de 1 linha por item. E **`app_vrp_pendencia_gerar_os` gera
  UMA OS corretiva que cobre todas as pendências abertas da mesma VRP** (vincula todas via `os_correcao_id`,
  obs lista todas) — uma visita resolve tudo, evita ir ao local mais de uma vez. **Front:** na tela da OS
  (gestão, `vmOsView`), quando há pendência aberta sem corretiva, botão **"Programar correção (OS única)"**
  → abre o diálogo e gera a OS; `vmGerarCorr(pendId, after)` ganhou callback e texto novo. As 2 pendências
  legadas da VRP-OS-2026-0009 foram **mescladas em 1**. **Na ficha da VRP (`vmFichaOpen`, 2026-10-15):** a
  seção "Pendências abertas" ficou **clicável** — uma pendência `aberta` (só p/ gestão `vrp_gestao`/admin) vira
  botão "programar ›" que chama `vmGerarCorr` e gera a OS corretiva única; `#vmModal` subiu p/ z-index 10001
  (abre sobre a ficha).
  **Form de execução (2026-10-15):** campos manuais que abrem condicionalmente agora são **obrigatórios**
  (`vmValid`): descrição do "Intervir" (passo 3·Condição), pressão encontrada quando conecta o manômetro
  (passo 2), "Descreva Outro" (passo 4). E **cada serviço marcado** no passo 4 abre um bloco próprio com
  **descrição + fotos obrigatórias** (`vmSlug(serviço)` → `servd_<slug>` em `respostas`, fotos `serv_<slug>_N`),
  no lugar do campo único de fotos. `vmReport` (PDF) mostra descrição e fotos por serviço (compat. OSs antigas
  com prefixo `servico`). **Gatilhos de status** (sugerido, ajustável no fim): **improdutiva** = na Chegada,
  "VRP localizada? Não" ou "Caixa acessível? Não" (botão "Encerrar como improdutivo" + foto do ponto);
  **concluida_pendencia** = `vmPendencias()` ≥1 (tomada mont/jus não resolvida, adequação civil/acesso não
  resolvidos, vazamento após=Sim, liberada=Não); senão **concluida**.
  **Status 100% automático (2026-10-15):** o executor **não escolhe mais** o status — removido o seletor da tela
  de resultado (`vmScrResult`/`vmstatuspick` e o handler `[data-status]`); `S.status=vmSugere()` sempre. Logo,
  **improdutiva só ocorre pelo caminho da Chegada** (não localizada/inacessível); com visita completa nunca é
  forçável. **Nova regra de pendência:** condição **"Intervir" sem serviço executável mapeado** (corrosão,
  ruído, **condição geral** — fora de `VM_INT_SERV`) **gera pendência** com a descrição (ex.: "precisa trocar a
  VRP"). **"O que aconteceu" visível:** as descrições (`d_<cond>`, `servd_<serviço>`, `serv_outro`) agora
  aparecem na **tela de resultado** (bloco "O que aconteceu"), no **relatório PDF** (`vmReport` §3/§4) e na
  **tela da OS da gestão** (`vmOsView` §3/§4) — antes só os rótulos "Intervir/OK" iam pro PDF.
  **Substituição — parte 1 (2026-10-15):** 3º tipo de OS. **`origem`** aceita **`substituicao`** (programável no diálogo:
  segmento Preventiva/Corretiva/**Substituição**). Na **finalização** o executor responde **"Necessita substituição da VRP?"**
  (`nec_subst`); se Sim + descrição → `vmPendencias` gera uma pendência **`tipo='substituicao'`** própria. No `app_vrp_os_concluir`
  essa pendência **NÃO é consolidada** com as demais (fica separada e evidente); `app_vrp_pendencia_gerar_os` **recusa** gerar
  corretiva para ela e a **exclui** da cobertura (uma substituição não se resolve por corretiva). `app_vrp_os_programar` permite
  **programar substituição mesmo com pendência aberta** e vincula/resolve a pendência de substituição. Displays (ficha, OS, lista de
  pendências) mostram badge **⚠ SUBSTITUIÇÃO** em vermelho.
  **Substituição — parte 2 (2026-10-15, form próprio):** quando a OS é `substituicao`, o wizard usa um **fluxo próprio**
  (`vmExecRender`/`vmStepbar`/`vmValid` ramificam por `hdr.origem`): **Chegada → VRP anterior → VRP nova → Pressões →
  Finalização**. `vmScrSubAnt` mostra o cadastro atual (read-only) + foto da VRP removida + motivo; `vmScrSubNova` captura os
  **dados cadastrais/técnicos da nova VRP** (diâmetro, modelo, atuação, controlador, pressões de projeto, ponto crítico, obs) +
  foto da nova. `app_vrp_os_header` agora devolve `origem` e `atuacao`. Na conclusão, `app_vrp_os_concluir` **recadastra
  `"2 - infra_agua".vrps`** (diametro/pres_max/pres_saida/pres_min/atuacao/observacao) a partir de `p_campos.cad_*`; o **nó de
  água é mantido**. `respostas.vrp_anterior`/`vrp_nova` guardam o antes×depois, exibido no **relatório PDF** e na **tela da OS**
  ("🔁 Substituição — anterior → nova"). `nec_subst` fica oculto no fluxo de substituição. Validado E2E: DN 50→200, 58→55 mca.
- **`vrp_prev_config`** (intervalo padrão por consórcio + `aviso_dias`) + **`vrp_prev_vrp`** (override
  por VRP). Próxima preventiva = última OS concluída + intervalo efetivo (override→consórcio→180).

**RPCs (`public`, definer):** campo (authenticated) — `app_vrp_os_header`/`app_vrp_os_abrir` (gera nº;
assume a programada da VRP se houver)/`app_vrp_os_concluir` (grava tudo, materializa pendências, e se
a OS tem `pendencia_id` e foi concluída, **fecha a pendência**)/`app_vrp_os_minhas`/`app_vrp_os_ver`/
`app_vrp_ficha` (cadastro+última OS+histórico+pendências+próxima preventiva)/`app_vrp_dmc_listar`.
Gestão (admin **ou** `perfil.vrp_gestao_acesso`, via `vrp_pode_gestao`) — `app_vrp_os_listar`
(filtros consórcio/DMC/status/origem/período + lat/lon p/ mapa)/`app_vrp_os_kpis`/`app_vrp_os_programar`
(cria programada e notifica)/`app_vrp_os_set_sigos`/`app_vrp_pendencias_listar`/
`app_vrp_pendencia_gerar_os` (corretiva derivada)/`app_vrp_pendencia_atualizar`/`app_vrp_prev_config_get`
/`_set`/`app_vrp_prev_vrp_set`/`app_vrp_prev_farol`. **Trigger** `trg_vrp_os` → `sup_notificar` (programada
→ o usuário atribuído; retorno/pendência → a gestão). `app_me` expõe `vrp_gestao`.

**Frontend Campo (`index.html`, funções `vm*`):** hub `vmHub`; `vmCampoInit` (Minhas OS via
`app_vrp_os_minhas` + "Nova OS corretiva" → `vmNovaPicker` reusa `app_vrp_listar`); wizard de 5 telas
(`vmExecRender`/`vmScr1..5`: Chegada→Pressões→Condição→Serviço→Finalização) sobre o cabeçalho autofill,
com botões OK/Intervir/Não verificado, campos condicionais, pendências automáticas e sugestão de status;
fotos via `comprimir`+`vmUpload` (bucket `fotos-campo` prefixo `vrp-os/`), GPS global `gps`; conclusão
`vmEnviar`→`app_vrp_os_concluir`. **Ficha da VRP** (`vmFichaOpen`, overlay `#vmFicha`) e **relatório PDF**
(`vmReport`, reusa `#relatorio`+`REL_CSS`+`window.print`). Telas: `vrpman`/`vrpman_campo`/`vrpman_exec`.
**Setpoint em campo (2026-10-23):** o cabeçalho da OS (`vmHeaderHtml`) mostra sempre, fora do "dados do cadastro", o
**🎯 Setpoint da VRP (jusante)** = `vmAlvoJus()` (= `proj_jus`; na substituição, o `cad_pres_saida` digitado p/ a VRP
nova) + o montante de projeto como referência. Na tela Pressões o card de jusante rotula o valor como "Setpoint
(projeto)" (mesma fonte `vmAlvoJus()`) e a tela 5 mostra "Deixe a jusante no setpoint: X mca". Se a **Jus. final**
(`fim_jus`) ficar fora do setpoint (`vmJusForaProjeto()`, diferença ≥ `VM_JUS_TOL` = 0,1 mca), pede justificativa
obrigatória `fim_jus_motivo` (vai no `respostas` jsonb, sem mudança de banco; é descartada no envio se a jusante
voltou p/ dentro da tolerância) e ela aparece no resumo. O `onchange` de `fim_jus` só re-renderiza quando o aviso
aparece/some (não perde o foco ao tocar no próximo campo). O setpoint é a **pressão de projeto** (decisão confirmada em 2026-10-23); `pres_saida_campo` ("Jusante em campo") não é usada aqui.
⚠️ **Cuidados:** funções `vm*` vivem no `<script type="module">` (não globais); a OS é criada no
`app_vrp_os_abrir` (abandonar o wizard deixa uma OS `em_execucao` — o backoffice enxerga). Base de VRPs
= `"2 - infra_agua".vrps` (148; `atuacao` é código, ex. "AL"; `pres_max`≈montante, `pres_saida`≈jusante).

**Frontend Gestão (`index.html`, funções `vm*`, gate `ME.vrp_gestao`):** `vmGestaoInit`/`vmGRender` com 3
subtabs + barra de filtros (consórcio + DMC): **Gestão de OS** (`vmGLoadOs`: KPIs + chips de status +
alternador Lista/Mapa Leaflet colorido por status + `＋ Programar`), **detalhe da OS** (`vmOsView`, tela
`vrpman_os`: 5 seções + pendências + **OS SIGOS** editável `vmSigos`→`app_vrp_os_set_sigos` + relatório +
ficha), **Pendências** (`vmGLoadPend`: tabela + `＋ Gerar corretiva` `vmGerarCorr`→`app_vrp_pendencia_gerar_os`),
**Preventivas** (`vmGLoadPrev`: farol Lista/Mapa colorido + config de intervalos `vmCfgSalvar` + `Programar`
`vmProgramar`→`app_vrp_os_programar`). ⚙️ **Acesso** (`vrpman_cfg`, admin) concede `vrp_gestao_acesso`
(`vmCfgInit`/`app_vrp_acesso_*`). Modais reaproveitáveis (`vmModal`). Colaboradores p/ atribuição via
`app_vrp_colaboradores_listar`. Telas `vrpman_gestao`/`vrpman_os`/`vrpman_cfg`. Mapas via `mapAddCamadaBase`
(tiles reais); marcadores `circleMarker` por status/farol. **Backend testado E2E** (abrir→concluir c/
pendência→gerar corretiva→resolver; listar/kpis/farol/programar).

**Reorg (2026-09-30, "Gestão de VRPs"):** módulo renomeado de "Manutenção de VRPs" → **Gestão de VRPs**.
- **Campo** ganhou o card **Visita primária** (`data-go="vrp"` — abre o módulo `vrp`/levantamento antigo), ao
  lado de "Minhas OS / Executar".
- **Gestão** = **3 cards diretos no hub do módulo** (`vmHub`, sem tela intermediária): **1) Gestão de serviços**
  (`vrpman_serv`, `vmServInit`/`vmServRender`: subtabs OS + Pendências); **2) Ficha cadastral** (`vrpman_fichas`,
  `vmFichasInit`: **lista/mapa de TODAS as VRPs** via `app_vrp_ficha_listar`, por VRP abre o overlay `#vmFicha`);
  **3) Cronograma preventivo** (`vrpman_prev`, `vmPrevInit`→`vmGLoadPrev`: farol + resumo de contadores). A ⚙️ de
  acesso (`vrpman_cfg`, admin) fica no cabeçalho da seção **Gestão** do hub. ⚠️ **Cards do hub são renderizados
  dinamicamente** → o handler global de `[data-go]` (ligado no load) NÃO os cobre; `vmHub` liga cada card
  explicitamente (`data-go` p/ Campo, `data-g` gateado p/ Gestão).

**Home (2026-10-01):** o card **"Gestão de VRPs"** foi **promovido** de 🚧 Em desenvolvimento para a seção **🛠️ Execução**
(mantém o nome; virou card simples `data-go="vrpman"` **sem gate `dev_acesso`** — removidos o `#cardVrpMan` e sua lógica no
`homeGate`; Campo p/ qualquer autenticado, Gestão por `vrp_gestao`). O card **"VRPs"** (`data-go="vrp"`) da seção Execução
foi **removido** — o módulo antigo já está dentro de Campo como **Visita primária**.
- **Gestão de serviços — OS:** filtro por **colaborador** (`p_atribuido`), cartão mostra **para quem está
  programado** e botão **Desprogramar** (`app_vrp_os_desprogramar` — só `programada`; se era corretiva de
  pendência, reabre a pendência).
- **Ficha da VRP (`vmFichaOpen`, `app_vrp_ficha`):** histórico **mescla OS novas + visitas primárias antigas**
  (`vrp_visita`) em ordem cronológica; cada item abre em popup — OS via `vmReport`, visita via `vmVisitaReport`
  (reusa `vrpRespPairs`/`vrpFotoPairs`/`REL_CSS`). Mantém as duas fontes até desativar o módulo `vrp` antigo.
- Novas RPCs: `app_vrp_os_desprogramar`, `app_vrp_ficha_listar`, `app_vrp_ficha` (+`visitas`),
  `app_vrp_acesso_listar`/`_set` (admin concede `vrp_gestao_acesso`), `app_vrp_colaboradores_listar`.

**Fluxo de serviços revisado (2026-10-02):**
- **Status = início→fim:** removidos `em_execucao` e `retorno`. Estados: `programada` (aberta) → `concluida` /
  `concluida_pendencia` / `improdutiva`. `app_vrp_os_abrir` não cria mais `em_execucao` (OS fica `programada` até
  concluir); `app_vrp_os_concluir` aceita só os 3 finais (coage `retorno`→`concluida_pendencia` p/ cliente antigo).
  Migração de dados aplicada (`em_execucao`→`programada`, `retorno`→`concluida_pendencia`).
- **"Não liberada" / "vazou após"** agora **geram pendência** (`vmPendencias`: tipos `nao_liberada`/`vazamento`) → a
  conclusão vira `concluida_pendencia` (antes era `retorno`), rastreável por OS corretiva.
- **Gestão de serviços — OS:** sem cards de KPI; só os **chips** com quantitativo entre parênteses —
  Todas/Programadas/Concluídas/C-pendência/Improdutivas (contagem via `app_vrp_os_kpis`).
- **Programar OS:** o dropdown carrega `app_vrp_os_programaveis` (VRPs **sem OS aberta e sem pendência aberta**).
  **Bloqueio** no `app_vrp_os_programar`: recusa VRP com OS `programada`/`em_execucao` ou pendência `aberta`/`em_andamento`.
- **Pendências ↔ OS:** `app_vrp_pendencias_listar` e `app_vrp_os_ver` expõem **OS pai** (`os_id`/`os_numero`),
  **corretiva** (`os_correcao_id`/`_numero`) e **resolvida** (`resolvida_os_id`). A tabela de pendências ganhou a coluna
  **Vínculo (OS)** clicável; na OS concluída c/ pendência cada pendência tem link **"abrir corretiva"**; a OS corretiva
  mostra o banner **"é corretiva de"** → OS pai. Nova RPC: `app_vrp_os_programaveis` (gestão; definer).
- Telas: +`vrpman_serv`/`vrpman_fichas`/`vrpman_prev`. sw `coleta-v197`→`v198`.

**Ajustes de UX (2026-10-01, sw v199→v200):**
- **Campo não abre mais OS avulsa** — removido "Nova OS corretiva"; o colaborador só executa o que o backoffice
  programou (`vmNovaPicker` removido). **Minhas OS** ganhou **Lista/Mapa** (`vmCampoMapRender`, marcadores dos
  serviços programados; popup com **Navegar** no Google Maps + **Preencher OS** `vmAbrir`). `app_vrp_os_minhas`
  passou a devolver `lat/lon`.
- **Wizard — Condição → Serviço:** marcar **"Intervir"** em Filtro/Piloto/Vazamento **pré-seleciona** o serviço
  correspondente na Tela 4 (`VM_INT_SERV`); corrosão/ruído/geral seguem só como anotação.
- **Wizard — "Resolveu agora?"**: tomada (Tela 2) e adequação civil / acesso (Tela 4) só geram pendência se o
  operador responder **Não**; **Sim = executado em campo, sem pendência** (`vmPendencias` passou a exigir
  `tomres_*`/`res_*` = Não). Atende "ele mesmo executa ao invés de gerar pendência".
- **Wizard — múltiplas fotos de serviço** (`vmPhotoMulti`, chaves `servico_N`); validação e relatório ajustados.
- **Filtros compactos** (`.vmfbar2`/`.vmff`): Consórcio virou **dropdown**, Consórcio + DMC **lado a lado**,
  Colaborador abaixo (ocupa menos espaço horizontal).
- **Tooltip de etapa** nos cards de OS (`title`, `VM_STAGE` + selo ⓘ): explica o status e em que etapa do
  processo a OS vive.

## 16. Telemetria (CCO COPASA) — `// MÓDULO TELEMETRIA (CCO COPASA)` · tela `telemetria` (admin-only)

Importa os **CSVs horários/sub-horários exportados do sistema CCO da COPASA** (telemetria de macro,
reservatório e booster) e alimenta o banco, já cruzando com o cadastro técnico. **Não há API da COPASA**
(em desenvolvimento) → a extração é manual (o usuário baixa os CSVs) e a ingestão é por **upload no app**.
Card **📡 Telemetria (CCO)** na home › 🚧 Em desenvolvimento (movido em 2026-10), **hidden**, mostrado por `homeGate()` só para **admin**
(`ME.is_admin`); `telemetriaInit()` também barra não-admin.

**Os dados (3 esquemas, detectados pelo cabeçalho):** separador `;`, decimal `.`, timestamp
`DD/MM/YYYY HH:MM`, granularidade **5 min**, `Sinal`=1 (telemetria viva). Nome do arquivo =
`CODIGO - CODIGOCOPASA.csv` (o `CODIGOCOPASA` = `cd_no_agua`, chave de cruzamento).
- `Momento;Vazao;Volume;Sinal` → **macro** (`vazao_volume`): vazão L/s + volume acumulado m³.
- `Momento;B01;B02;B03;B04;Nivel_Suc;Pressao_Suc;Pressao_Rec;Sinal` → **booster** (`bombas_pressao`).
- `Momento;Nivel;Sinal` → **reservatório** (`nivel`).

**Banco — schema `"15 - telemetria"` (app-only):**
- `tele_unidade` — dimensão (1 linha/unidade): código CCO, código COPASA, za/cidade, tipo, esquema +
  cruzamento com o cadastro (`cadastro_tabela`/`cadastro_id`/`nome`; **`null` = unidade fora do nosso
  cadastro**). Match por `cd_no_agua` contra `"2 - infra_agua".unidades_{macromedicao,reservatorio,elevatoria,booster_bomba,poco}`.
- `tele_leitura` — fatos em **formato longo** `(unidade_id, momento, grandeza, valor)`, PK nas 3 primeiras
  (reprocessar não duplica). Um formato serve os 3 esquemas e qualquer grandeza futura. Índices btree
  `(unidade_id,momento)`, BRIN `momento`, btree `grandeza`. Momento = `timestamptz` local −03.
- `tele_carga` — log de ingestão por arquivo.
- Views `vw_cobertura` (unidade × cadastro × estatística de leituras) e `vw_cadastro_sem_tele` (inverso:
  pontos do cadastro sem telemetria).

**RPCs públicas (SECURITY DEFINER, grant `authenticated`+`service_role`):**
- `app_tele_unidade_upsert(p_codigo_unidade,p_codigo_copasa,p_za,p_cidade,p_tipo,p_esquema)` → upsert da
  unidade, resolve o match com o cadastro, retorna `id`.
- `app_tele_ingest(p_codigo_unidade,p_rows jsonb,p_arquivo,p_hash)` → insere o lote `[{m,g,v}]` com
  `on conflict do update`, loga a carga. Exige a unidade já cadastrada.
- `app_tele_cobertura()` → `setof vw_cobertura` para o painel.

**Frontend (`telemetria`):** dropzone (vários CSVs), prévia (arquivo→unidade/tipo/esquema/linhas/cadastro),
**Processar** com barra de progresso, resumo e painel **Cobertura × cadastro** (KPIs + tabela). Parsing é
client-side (mesma lógica do schema); grava **pela sessão do usuário via RPC — sem service key no front**.
Opção **"Enviar só leituras novas"** (incremental): usa `momento_max` da cobertura por unidade e só manda
`momento > último`. Consórcio por `webkitRelativePath` (pasta) → seletor → `null` (upsert faz `coalesce`,
não sobrescreve za bom já gravado). Lotes de 5000 leituras por chamada.

**Cuidados:**
- **Ingestão é online** (grava direto no banco; não passa pela fila offline). É tarefa de mesa/admin.
- **Carga histórica** (meses de 5 min = dezenas de milhões de linhas) é pesada numa aba — o módulo faz com
  progresso e retomada (reprocessar é idempotente; incremental pula o que já entrou), mas para o backfill
  inicial há também o script `scripts/telemetria/ingest_telemetria.py` (mesmas RPCs, via `service_role`,
  mais rápido). Dia a dia = só o módulo.
- Schema **15** (não 14 — "14 - pessoas" é legado). App-only: sem `USAGE` para papéis `gis_*`.
- **Estado atual (2026-10-16):** dimensão com **101 unidades** carregada; **25 no cadastro, 76 fora**
  (candidatas a inclusão — ver `vw_cadastro_sem_tele`/`vw_cobertura`). Série temporal entra pelo
  módulo/script.

## 17. Vitrine (TV) — `// VITRINE (TV)` · tela `vitrine` (🚧 Em desenvolvimento, gate `dev_acesso` — 2026-10-27)

Painel para a TV da sala: **apresentação em loop** com as atividades de campo (fotos + mapas) e indicadores,
**ao vivo** — a cada volta completa busca os dados de novo (`vtCarregar`) e recomeça.
- **Acesso:** card `#homeVitrine` na categoria **🚧 Em desenvolvimento** (mesmo padrão do `#cardPerdas`): nasce
  `mod soon` + 🔒; `homeGate()` libera por **`ME.dev_acesso`** (admin sempre) — tira `soon`/🔒 e liga `onclick` →
  `irPara('vitrine')`; sem acesso, o clique dá `toast('Acesso restrito')`. `vtInit` repete o check (`vtPode()`).
  A RPC **`app_vitrine_dados(p_desde date default null)`** (SECURITY DEFINER, `docs/migracao_vitrine.sql`) usa o
  mesmo gate das `app_nrw_*` (`funcao='admin' or dev_acesso`). **Liberar alguém = engrenagem ⚙️ da categoria**
  (`dev_acesso`), sem código. (Até 2026-10-27 era uma lista de e-mails fixa no app e na RPC — removida.)
- **Período:** padrão = desde a última sexta-feira (`p_desde` nulo). Atividades: instalação/remoção de logger, OS de VRP
  executadas (≠ programada), ocorrências da pesquisa, recomposição de pavimento, mapeamento de pressão, avanços de obra
  (sem GPS) e solicitações de serviço. Indicadores: "Situação agora" (loggers em campo, frota, manutenções, pendências
  VRP, solicitações/ocorrências sem OS, checklists do dia, usuários) e "No mês até agora". "Loggers em campo" = instalados
  e não removidos (`data_instalacao` preenchida — o planejado ainda não instalado não conta).
- **Tela:** `<main id="vitrine">` é overlay `position:fixed` com tema escuro próprio (`.vt-*`), botões ⛶ Tela cheia e
  ✕ Sair (canto sup. dir., semitransparentes). Teclado: ←/→ navega, espaço pausa, Esc sai. Mapas Leaflet com base
  **Esri Dark Gray** (o CARTO passou a exigir chave). `irPara` chama `vtParar()` ao sair (limpa timers).
- Estado em `var`/lista dentro da função de propósito: `homeGate`/`irPara` podem rodar antes do fim da avaliação do módulo.
- **Cuidados:** a TV roda o dia todo — todo mapa criado vai para `vtMapas` e `vtSoltarMapas()` faz `m.remove()` antes
  de remontar o deck (o Leaflet prende o mapa no `resize` do window; sem isso cada volta vaza ~1 mapa por slide). Não
  chamar `vtSoltarMapas` em `vtParar` (roda em todo `irPara`, possivelmente antes de `vtMapas` existir). A linha do
  tempo do slide do dia é ajustada ao mostrar (`vtAjustaTl`): se não cabe, esconde as mais antigas com "+N mais cedo".

## 18. Segurança do Trabalho (APR · PT · PET) + QSMS — `// SEGURANÇA DO TRABALHO` · telas `seg` / `seg_form` / `qsms` (hub) / `qsms_ind` / `qsms_form` / `qsms_epi_painel` / `qsms_cesta` / `qsms_epi_col` / `qsms_acesso` (2026-10-28)

Substitui os formulários de papel **APR** (modelo COPASA PRT-CSMG-2023_003), **PT de trabalho em altura**
(FOR_PG_22 rev 00, do consórcio — o mesmo modelo serve as duas ZAs, o PDF troca o nome do consórcio) e **PET de
espaço confinado** (COPASA FOR-PES_131-CSMG). **Formulário é só preenchimento**: sai *emitido* (ou *impedido*) e
pronto — **nada fica "aberto"** (sem acompanhamento, encerramento, interrupção ou tratativas; ajuste de 28/10/2026).

**Campo — `seg` (Home › 🛠️ Execução, card ⛑️, sem gate):**
- **Atividade** = cabeçalho comum: tipo de intervenção (`SEG_TIPOS`: VRP separado em instalação/substituição/
  manutenção; válvula limítrofe no lugar de DMC — `dmc`/`vrp` antigos só têm rótulo em `SEG_TIPO_LEGADO`), OS SIGOS
  (texto livre, **sem busca** — a OS ainda não está na base quando o campo preenche), serviço, GPS travado, data/hora,
  usuário. **Endereço (rua mais próxima), bairro, município e consórcio vêm da coordenada** — prévia online por
  `app_seg_local` (card `#segLocal`), valor oficial gravado pelo servidor no registro (`qsms_local`). Sem unidade
  organizacional no formulário (o servidor guarda `perfil.area` em `qsms_atividade.unidade`).
- **APR** (`segAprHtml`): sugestões por tipo (`SEG_TEMPLATE`: fases, riscos marcados "Sim", EPIs — editáveis);
  13 riscos (`SEG_RISCOS`) — risco "Sim" exige "Medida de controle aplicada"; `r2`/`r6` invertidas ("Não"
  bloqueia); EPIs; requer PT/PET; **foto obrigatória da sinalização**. **Assinaturas:** o **responsável é quem
  preenche** (`segEu()`: nome/matrícula/cargo do cadastro, travados — só assina); **executantes = só o nome,
  escolhido da lista** (`app_seg_pessoas`, datalist; nome fora da lista não passa) + assinatura.
- **PT/PET só saem de uma APR** com requer=Sim (botões "+ PT"/"+ PET" na atividade) e **reaproveitam a equipe e as
  assinaturas da APR** (`segNovo` lê a APR por `segDocCarregar` — local ou `app_seg_ver`; sem a APR no aparelho e sem
  sinal, não abre). Participante com `apr:true` vai com `assinatura_apr:true` e o servidor copia a assinatura da APR
  (`qsms_participante.assinatura_apr`).
  - **PT** (`segPtHtml`): descrição, altura, meio de acesso + sistema anti-queda, checklist de **42 itens** em 13
    blocos (`SEG_PT_BLOCOS`; blocos de outro meio de acesso viram NA e somem; p7 já vem Sim; **um "Não" impede**).
    Participantes = executantes da APR (só leitura, "✓ assinatura dada na APR"); emissor = quem preenche (assinatura da
    APR); **liberador da área = escolhido da lista + assina** (única assinatura nova). Sem "mão de obra".
  - **PET** (`segPetHtml`): cada executante da APR recebe um papel (**Entra / Vigia / Não participa** — um vigia só,
    `segPetEquipe`); supervisor de entrada = quem preenche (assinatura da APR); 11 ações preliminares (item 1 já Sim;
    **um "Não" impede**); bloqueios; detector (identificação + **foto obrigatória**); insuflação ≥ 10 min; gases P1–P3
    vertical (+ H1/H2) com semáforo (`SEG_GAS`); leitura fora → "↻" nova leitura (a antiga vira ocorrência).
- Com bloqueio de segurança e tudo preenchido aparece **"Registrar PT/PET impedida"** (2 toques) — avisa o QSMS.
- **Validação ao vivo** (`segPendencias`); botão "Emitir X" só habilita sem pendência. **Rascunho** em IndexedDB
  `seg_local.draft`. **Offline:** fila (`segEnviar`, ids `seg-<timestamp>` mantêm APR antes de PT/PET), anexos em
  `item.anexos` (§1 Envio) → `p_anexos`, pasta `seg/`; cópia local em `seg_local.docs`. Limpeza da cópia local em
  `segListar` (só quando a lista do servidor carregou): sai o que já está no servidor há >1 dia, tudo com >5 dias e **o que
  não está mais no servidor** (apagado lá), desde que não esteja na fila e tenha >15 min — assim uma limpeza feita no
  banco some também do celular.
- **Minhas atividades = um bloco por atividade** (APR + PT/PET que saíram dela): chips de status (não clicáveis),
  selo da verificação QSMS quando houver, botões **"📄 PDF da atividade"**, "+ PT", "+ PET".
- **PDF único da atividade** (`segPdfAtividade(ids)`, overlay `#relatorio` + `REL_CSS` + `SEG_REL_CSS`): **capa**
  (`segCapaHtml`: serviço, OS, local, responsável, tabela dos formulários com situação/alertas, equipe consolidada com
  os papéis de cada pessoa em cada formulário, verificação QSMS + histórico) e depois cada formulário em página própria
  (`.segPag`) no layout do papel (`segDocHtml`). Atividade só com APR = sem capa (a verificação vai no fim). Online lê
  cada formulário por `app_seg_ver`; sem sinal usa a cópia local (avisa se faltar algum). Assinaturas reaproveitadas
  aparecem como "assinatura dada na APR".

**Gestão — `qsms` (Home › 🧰 Suporte, card 🦺, gate `ME.qsms`):** `ME.qsms` = admin **ou** engrenagem
`perfil.qsms_acesso` **ou** cargo Téc. Segurança do Trabalho / Téc. Qualidade / Coord. QSMSS
(`"16 - qsms".qsms_pode`). ⚙️ (admin, no hub) → `qsms_acesso` (`app_qsms_acesso_listar/_set`).
**Hub `qsms` em categorias (espelha o Almoxarifado, 2026-10-28):** **⛑️ APR e derivados** → `qsms_ind` (Indicadores) e
`qsms_form` (Formulários); **🦺 EPI** → `qsms_epi_painel` (Painel de EPI), `qsms_cesta` (Cesta de EPI) e `qsms_epi_col` (EPI
por colaborador), nessa ordem. Cada
tela tem cabeçalho e filtros próprios (período + consórcio com prefixos `qi`/`qf`/`qe`; `qsmsPeriodo`/`qsmsFiltros`/
`qsmsArgs`). Em APR e derivados **a unidade é a atividade** (APR + PT/PET), com **uma verificação por atividade**.
- **Indicadores** (`qsms_ind`, `qsmsIndInit`/`qsmsPainel`): KPIs (atividades, com PT, com PET, com PT/PET impedida,
  leituras de gás fora, com alertas) e verificação (a verificar, conformes, com ressalva, não conformes — **tocar num tile
  abre Formulários já filtrado no mesmo período/consórcio**); atividades por dia, por tipo, por responsável; riscos.
- **Formulários** (`qsms_form`, `qsmsFormInit`/`qsmsLista`/`qsmsCardHtml`; filtros guardados em `qsmsFF`, sobrevivem ao
  trocar período/consórcio): segmento **A verificar / Não conformes / Verificadas / Todas** (contagens
  respeitam os demais filtros); filtros tipo de intervenção, responsável (quem preencheu), formulários (com PT / com PET
  / só APR), "só com alerta ou impedimento", busca (OS, endereço, bairro, pessoa); **Lista / Mapa** (cor = verificação)
  / **XLSX** (1 linha por atividade). Detalhe (`qsmsDetalhe` + `app_qsms_atividade_ver`): dados, formulários com
  situação/alertas/leituras, **equipe consolidada** (papéis por formulário), **PDF da atividade** e **verificação**
  Conforme/Com ressalva/Não conforme (`app_qsms_verificar(p_atividade,…)`; obs obrigatória fora de "conforme"; histórico).
- **EPI por colaborador** (`qsms_epi_col`, `qsmsEpiColInit`): **a mesma tela do Almoxarifado** — `supVEpiPainel(root,pre)`
  desenha em `#qcView` (no Almoxarifado continua em `#supView`); `pre={uuid,nome}` pré-seleciona (vindo do painel, inclusive
  quem nunca recebeu EPI) e o "‹ Voltar" (`#qcBack`) volta ao Painel de EPI. Ficha e comprovantes iguais.
- **Cesta de EPI** (`qsms_cesta`, `qsmsCestaInit`): **a mesma tela da engrenagem ⚙️ "Cargos e cesta de EPI" do
  Almoxarifado** — `supCestaEm(root)` desenha em `#qkView` (no Almoxarifado em `#supView`; `cfgCestaRoot` escopa
  `.cfgCargos`/`#cesta-<id>`). `sup_cargos_admin` e `sup_cesta_set` passaram a aceitar `qsms_pode` além de admin
  (migração `qsms_cesta_epi_acesso`); a engrenagem do Almoxarifado segue visível só p/ admin.
- **Painel de EPI** (`qsms_epi_painel`, `qsmsEpiInit`/`qsmsEpiRender`, RPC `app_qsms_epi_painel(p_de,p_ate,p_consorcio)`;
  colaboradores = perfis ativos, consórcio pelo perfil): situação agora (ativos, com EPI em posse, nunca receberam, itens
  em posse/vencidos/vencem em 30 d), cesta do cargo (com cesta, completa, cargo sem cesta — **referência**, porque a cesta
  lista alternativas e quase ninguém a tem completa), fluxo pendente (aguardando aprovação/separação/retirada, em falta,
  trocas e devoluções pendentes), movimentação no período (entregas/trocas/devoluções + por dia), EPIs mais entregues,
  itens da cesta mais faltantes, tabela por área (vencido / vence 30 d / nunca receberam) e **lista de colaboradores**
  com chips (vencido / vence 30 d / nunca receberam / cesta faltando / todos) + busca + XLSX — tocar abre o EPI por
  colaborador. As RPCs de leitura de EPI (`sup_epi_gestao_colaboradores`, `sup_epi_gestao_colaborador`, `sup_epi_ficha`)
  passaram a aceitar também `qsms_pode` (quem tem a engrenagem do QSMS).

**Backend — schema `"16 - qsms"` (app-only, RLS deny-all, só RPC definer, nada pode ser apagado — trigger
`qsms_sem_delete`):** `qsms_atividade` (geom 31983, `endereco`/`bairro`/`municipio`/`consorcio` pela coordenada,
**`verif_status/obs/por/em`**) · `qsms_formulario` (status **`emitida|impedida`**, `respostas jsonb`, `fotos`, `alertas` +
`n_alertas`) · `qsms_participante` (papel, `pessoa_uuid`, `documento`/`funcao` do cadastro, `assinatura`,
`assinatura_apr`) · `qsms_medicao` · `qsms_evento` (trilha das verificações, por `atividade_id`). Helpers: `qsms_pode`, `qsms_uuids`, `qsms_consorcio`,
`qsms_local` (rua ≤ 80 m + bairro + município + ZA), `qsms_gas_fora`, `qsms_pode_form`. `perfil.qsms_acesso`;
`app_me` devolve `qsms`.
RPCs: `app_seg_registrar(p_id, p_dados, p_anexos)` (idempotente; cria a atividade se não existe; local pela
coordenada; matrícula/cargo do perfil; assinatura da APR quando `assinatura_apr`; **recalcula status e alertas** —
conteúdo inválido vira alerta, não erro, porque a fila descartaria em silêncio), `app_seg_local`, `app_seg_minhas`,
`app_seg_ver` (traz `verificacoes` da atividade), `app_seg_pessoas`, `app_qsms_listar` (`{atividades:[…, forms:[…]]}`),
`app_qsms_atividade_ver`, `app_qsms_verificar(p_atividade, p_status, p_obs)`, `app_qsms_acesso_listar/_set`.
**Avisos** (triggers → `sup_notificar`, tipo `qsms`): atividade não conforme → quem preencheu (`seg`, trigger em
`qsms_atividade`); PT/PET impedida → equipe QSMS menos o ator (`qsms`, trigger em `qsms_formulario`).

**Cuidados:**
- Removidos em 28/10/2026 (ajuste do usuário): tela `seg_acomp`, tratativas (tabela `qsms_tratativa` e RPCs),
  `app_seg_evento`, `app_seg_os_info`, status `liberada/encerrada/interrompida`, colunas `encerrado_*`/`encerramento`.
  Registros de teste anteriores foram convertidos (`liberada` → `emitida`). Ainda em 28/10 a verificação saiu do
  formulário para a atividade (migração `qsms_verificacao_por_atividade`: ficou o pior resultado da atividade).
- PT/PET **não existem sem APR** — a APR é a raiz da atividade; o app só oferece "+ PT/+ PET" a partir dela.
- **Uma PT e uma PET por APR** (2026-10-28): "+ PT"/"+ PET" somem quando a atividade já tem uma emitida (`jaTem` em
  `segListar`; `segNovo` confere de novo). Só uma **impedida** (trabalho não aconteceu) libera nova tentativa. Se mesmo
  assim chegar outra emitida (dois aparelhos / lista desatualizada sem sinal), `app_seg_registrar` grava com o alerta
  "Já existia PT/PET emitida nesta APR — duplicada" (não rejeita: a fila descartaria em silêncio). Reentrada em espaço
  confinado depois de a equipe sair = nova APR (a PET vale para uma entrada).
- Tipos de intervenção e sugestões estão **no código** — não há tela de configuração.
- Itens de capacitação/ASO são declarados pela equipe (sem cadastro de aptidão NR-33/NR-35).
- `perfil.funcao='qsms'` (legado de §6.3) **não** dá acesso — o acesso é `ME.qsms`. A tela `<main id="qsms">`
  reaproveita o id da tela de treinamento removida em 2026-09 (§6.3) — são coisas diferentes.
- Teste de UI sem login: servir uma cópia de `public/` com um script que simula GPS e responde às RPCs; as RPCs
  foram testadas com rollback E2E (§4 do CLAUDE.md).

## 19. Avisos (pop-ups) — `// AVISOS (pop-ups)` · tela `avisos` (admin-only, 2026-10-27) — `docs/migracao_avisos.sql`

- **Admin** (Home › 🧰 Suporte › 📢 Avisos, `#homeAvisos`, gate `ME.is_admin` + RPC `aviso_eh_admin()`): cria/edita aviso com
  título, texto (`**negrito**` + quebras), imagem (upload → bucket `fotos-campo/avisos/` via `uploadFoto2`), texto do botão,
  destino do botão (`AV_LINKS` = mesmos links de notificação, roteados por `supGoAct`), público (`todos` |
  `condutores_vinculados`), período (de/até) e ativo; na lista, botão **⏸ Desativar / ▶ Ativar** (mesma RPC, só inverte `ativo`). **Pré-visualizar** mostra o pop-up como o usuário verá.
- **Usuário:** `avPopAbrir()` roda **1x por carregamento do app**, logo após o `app_me` (em `mostrar`), chama
  `app_avisos_ativos()` e exibe os avisos vigentes em sequência (`#avPop`, overlay com ✕; clicar fora fecha).
- **Imagem:** `./...` = arquivo do site (`public/avisos/`), `http...` = URL, senão = caminho no bucket (`avImg`). Na edição, "Remover imagem" manda `p_imagem='-'` (null/'' = manter a atual).
- **Destino "Notificações":** `supGoAct('notificacoes')` abre a tela `notificacoes` (antes caía no hub do Almoxarifado).
- **Lembretes push** (`lembrete='checklist_frota'`): `aviso_lembretes_run(slot)` via **pg_cron** `aviso-lembrete-1..5`
  (08h/10h/12h/14h/16h BRT, seg–sex) — notifica **só quem tem veículo vinculado e não fez o checklist do dia**, com o texto do
  slot (`lembrete_textos[1..5]`), link `frota_checklist`. Independe do público do pop-up. Se houver mais de um aviso de lembrete vigente, vale **só o mais recente** (1 push por horário).
- **Grants:** `aviso_eh_admin()`/`aviso_tem_veiculo(uuid)` são internos (revogados de anon/authenticated); `aviso_lembretes_run` só o cron.
- **Tabela** `public.app_aviso` (RLS ligada, sem policy — só RPC). 1º aviso (seed): "Checklist diário do veículo", até
  30/10/2026, pop-up p/ todos, imagem `./avisos/checklist-frota-2026-10.webp`.
