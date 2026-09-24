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
- **Camadas COPASA no mapa da estanqueidade (2026-09):** no modo Mapa há chips toggle (`#estCamadas`,
  `EST_CAM`/`estCamRender`/`estCamToggle`) para **Zonas de pressão** (`"5 - info_copasa".zonas_pressao_copasa`,
  137, azul) e **DMCs** (`"5 - info_copasa".dmcs_existentes_copasa`, 23, laranja) — polígonos com **fill 30% +
  borda weight 2** (mesmo padrão de ativar/desativar do Cadastro técnico). GeoJSON (4326, `ST_SimplifyPreserveTopology 1m`)
  via RPC **`app_estanq_poligonos(p_layer)`** (`zonas_pressao`|`dmcs`, definer, só `authenticated`); cache em
  localStorage (`est_cam_zp`/`est_cam_dmc`). Camadas ficam **abaixo** dos pontos (`bringToBack`); começam desligadas.
- **Popup no ponto do mapa (2026-09):** clicar num marcador abre popup (`bindPopup`+`popupopen`) com **🧭 Navegar
  até o local** (link Google Maps, `target=_blank`) e **📝 Preencher informações** (`.estPopFill` → `estSelecionar`
  → tela de pressão). Antes o clique ia direto p/ a tela de pressão; o tooltip de hover foi mantido.

### 2.2 Loggers temporários — `// MÓDULO LOGGERS` (~L782) · telas `loggers` / `logger_det`
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
  **VRPs**, rede, ligações, **rede de gás** (`CAD_DEF`). Camadas `whole:true` baixam a ZA inteira 1x; pesadas usam
  `step` (célula de cache).
  - **Rede de gás (2026-09, `CAD_VER v5→v6`):** camada **`rede_gas`** (GASMIG, `"4 - redes_terceiros".rede_gas`,
    1.271 linhas MULTILINESTRING, âmbar `#f9a825`, `whole:true`, começa desligada). Só leitura/visualização;
    branch `rede_gas` na RPC `app_cadastro_geojson` (props id/material/diametro/municipio) — popup genérico.
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
- **KPIs (5):** km de rede pesquisado · km andado · vazamentos · vaz/km (por km de rede) · velocidade
  média. (Saiu a "cobertura da programação".)
- **Resumo por colaborador:** repete os indicadores de cima por pessoa — km rede pesquisado · km andado ·
  vazamentos · vaz/km · velocidade. (Saíram "km programado" e "%".)
- **RPCs (SECURITY DEFINER, gate aprovador/admin):** `app_pp_acompanhamento(p_consorcio, p_colaborador,
  p_data_ini, p_data_fim)` → `kpis` + `progresso_passadas` (6 buckets 0..5) + `resumo` (agora com km
  rede/andado/vaz/vaz-km/velocidade por colaborador); `app_pp_passadas_bbox(xmin,ymin,xmax,ymax,
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
  filtros redesenham só `#eqInvLista` (a busca não perde foco). Só leitura — nenhuma ação de escrita.
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
- Notificações de aprovação vão só aos aprovadores diretos (`sup_aprovadores_de`).

---

## 6. Frota — schema `"10 - Frotas"` · tela-hub `frota` (+ telas internas `condutor` / `frotas`)

Um público entra por **um só card** na home (🧰 Suporte › **🚗 Frota**, `data-go="frota"`). Fluxo
**(reformulado 2026-09, 3ª rodada)**: **Frotas** (`funcao='frotas'`/admin) cadastra a CNH do
colaborador → colaborador é avisado e **assina o termo de responsabilidade de condução** (assinatura
eletrônica, igual EPI) → ativo → colaborador **se vincula a um veículo disponível sozinho**
(self-service, tela **Veículos** do próprio Colaborador — não é mais o gestor quem faz isso).
Colaborador faz **checklist diário** (com botão de reportar problema embutido), abastece e usa as
telas próprias de **Lavagem** e **Manutenção** — cada uma é histórico + ação, não só um formulário
avulso (ver §6.1). Frotas **agenda** a lavagem (data/horário/local) e o colaborador confirma a
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
    §6.1) · Checklist diário · Abastecimento · **Manutenção** · **Lavagem** — **estes últimos 4
    ficam desabilitados** (`disabled`, opacidade reduzida) **enquanto `frotaMeuVeiculo` é `null`**
    (colaborador sem veículo vinculado não tem o que fazer neles). **Checklist diário e Abastecimento
    também desabilitam (6ª rodada) se `frotaMeuVeiculo.status==='manutencao'`** — flag
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
    depois do load (`condGoTarget`). Ação que precisa de veículo (`situacao`/`abastecimento`/
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
- **Checklist diário, abastecimento, problema (manutenção), lavagem — todos no ÚNICO veículo
  vinculado ao colaborador (reformulado 2026-09, 3ª rodada):** `condMeuVeiculo` =
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
    é preciso marcar item por item pra registrar `p_status='ok'` de verdade.
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
    ver "Vincular/desvincular" abaixo). Checklist continua **sem checagem de vínculo** no backend (só
    o frontend já auto-seleciona `condMeuVeiculo`). `app_frota_manutencao_solicitar`/
    `app_frota_lavagem_solicitar` também aceitam `funcao in ('frotas','admin')` **sem** precisar de
    vínculo (Frotas solicita em qualquer um). **Checklist e abastecimento passaram a recusar se
    `frota_veiculo.status='manutencao'` (6ª rodada)** — o veículo não está fisicamente com o
    colaborador nesse estado; o hub também desabilita os 2 botões nesse caso (ver §6.0), mas quem
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
    reaberto e salvo. (Não confundir com `COMBUSTIVEIS` do abastecimento — Etanol/Diesel/Arla, §6.2 acima.)
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
  `status` que a versão self-service).
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
  ficava em Equipe administrativa)** (`frotasRenderPainel` → grid de 5 submódulos, estilo `.mod`/
  `.grid` igual o hub — antes era uma lista solta de links de texto: `abastecimentos`, `lavagens`,
  `manutencoes`, `custos`, e **`historico`** — que agora é um item **dentro** de Relatório em vez de
  botão próprio no hub, ver §6.0). **`agora mora na categoria Gestor`**, não mais em Equipe
  administrativa — é uma tela de acompanhamento/auditoria, não de operação do cadastro.
  **"Movimentações (empréstimos)" foi removida da lista** — não sobrava o que mostrar sem o
  mecanismo de empréstimo ativo (§6.1); `app_frota_movimentacoes_listar` (as duas sobrecargas, a
  antiga sem filtro e a com filtro de pp13) foram **apagadas**. Os 3 submódulos restantes com filtro
  (abastecimentos/lavagens/manutenções) ganharam filtro de **veículo** (dropdown) e **período**
  (`p_data_ini`/`p_data_fim`) numa rodada anterior; o filtro de **colaborador** virou **dropdown de
  todos os colaboradores** na 4ª rodada (`frotasCarregarColaboradores()`, manda o `id` direto como
  `p_condutor_id` — antes era campo de e-mail livre + `app_perfil_por_email`). `PAINEL_CFG` (const)
  só descreve `{rpc,titulo,row}` por tipo; `frotasRenderPainelLista` monta o formulário de filtro +
  chama `carregar()`.
- **Relatório de abastecimento — centro de custo/modelo/grupo + Lista×Consolidado (2026-09-16):**
  `app_frota_abastecimentos_listar` passou a retornar tb. `centro_custo`/`modelo` do veículo e
  `foto_cupom` do abastecimento (`consorcio` já vinha); a linha da **Lista** mostra placa+modelo, o
  cabeçalho de sempre, e uma linha "CC <descrição> · <grupo econômico> · 🧾 Nota" (grupo econômico =
  **nome do consórcio**, `CONSORCIO_NOME` — Águas Integradas/Eficiência Hídrica; a foto do cupom abre
  via `fotoURL(foto_cupom)`). Só no tipo **abastecimentos** há um **toggle 📋 Lista / 📊 Por centro de
  custo** (`frAbMode`); o **Consolidado** chama a RPC nova `app_frota_abastecimentos_consolidado(p_data_ini,
  p_data_fim)` — uma linha por `centro_custo` do veículo (filtrável só por período), somando
  litros/valor e contando abastecimentos/veículos (`frAbConsolRow`). Grupo econômico na linha
  consolidada só aparece quando o CC é de um único consórcio.
  **"Tempo real" aqui significa só "sempre atualizado quando busca"** — sem Supabase Realtime.
- **Custos por veículo** (`app_frota_custos_por_veiculo()`/`app_frota_veiculo_relatorio()`, **sem
  filtro** — visão agregada por veículo, dentro de Relatório): soma `frota_checklist_abastecimento`
  (abastecimento), `frota_lavagem` **só `status='realizada'`** (lavagem), `frota_manutencao` **só
  `status='concluido'`** (**simplificado na 5ª rodada** — antes incluía `agendado` também, mas
  `orcamento_valor` nunca é preenchido nesse estágio desde que o custo virou parte da conclusão, ver
  acima; manter `agendado` no filtro não somava nada a mais, só confundia) + `valor_devolucao` do
  próprio veículo. `custo_total` é a soma de tudo. Read-only.
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
- **Checklist e abastecimento recusados com o veículo em `manutencao` (2026-09, 6ª rodada):**
  `app_frota_situacao_salvar`/`app_frota_abastecimento_salvar` agora checam
  `frota_veiculo.status` antes de gravar — se `='manutencao'`, recusa (o veículo não está fisicamente
  com o colaborador). O hub (`frotaBlocks`/`frotaHome`) também desabilita os 2 botões nesse caso
  (`bloqueiaManutencao:true` nos itens do array) — front é só UX, quem garante é a RPC. **Lavagem e
  Manutenção continuam liberados** mesmo com o veículo em manutenção (reportar um 2º problema, ou
  acompanhar/solicitar lavagem, fazem sentido independente de onde o veículo está fisicamente).
- **`qa/smoke_test_frota.sql` (novo, 6ª rodada):** 6 blocos `do $$ ... end $$` com rollback garantido
  (sempre termina em `raise exception 'ROLLBACK_OK...'`), cobrindo overloads órfãos, grants, vínculo/
  desvínculo (+ status do veículo), ciclo completo de manutenção (com o teste de permissão do
  reportante × terceiro), o bloqueio de checklist/abastecimento em manutenção, e o ciclo completo de
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
  de voltar quebrado". Corrigidos os 9 casos reais (`condRenderVeiculos`/`Situacao`/`Abastecimento`/
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

> Assinaturas completas: `select proname, pg_get_function_identity_arguments(oid) from pg_proc p
> join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 1;` (via MCP).

---

## 11. Perdas / NRW — cockpit em **página dedicada** `public/perdas.html`

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
  `dev_acesso` (admin sempre). Substituiu o gate por e-mail hardcoded.
- **Guarda na própria página:** ao final de `perdas.html`, um `<script type="module">` cria um cliente
  supabase-js (mesma `SB_URL`/anon key do app; exposto em **`window.sbg`** p/ o script principal usar nos RPCs),
  lê `auth.getSession()` e, **se `app_me().dev_acesso` for falso** (ou sem sessão), mantém o overlay `#nrwGate`
  (🔒). **Gate unificado por `dev_acesso`** (2026-09, mesmo controle "Em desenvolvimento" da home — antes era
  e-mail do Sander hardcoded). Funciona offline (sessão do `localStorage` do mesmo domínio). O enforcement real
  é **server-side** nas RPCs (checam `dev_acesso`/admin).
- **Análise do micromedido (2026-09, tela REAL — `s-mm`/nav "Análise do micromedido"):** dados de verdade da
  `"5 - info_copasa".micromedicao_historico`. Motor: tabela **`"11 - perdas_nrw".mm_matricula_stats`** (1 linha
  por matrícula, 134.868, computada em buckets `mod(nu_matricu,4)` p/ não estourar o statement timeout do MCP):
  média/mediana/mín/máx/desvio/**CV**, **slope** (regr sobre índice de mês uniforme), n_zeros, **classificação**
  (estável/nulo_recorrente/pico_isolado/queda_continua/crescimento_continuo/instável) e **`score_anomalia` 0–100**
  (Índice de Anomalia = 3·pico + 2·tendência + 2·CV + 1·zeros). RPCs `app_nrw_mm_resumo`/`_ranking`/`_serie`
  (definer, admin **ou** `dev_acesso`; anon revogado). A tela: KPIs + distribuição por comportamento + ranking
  filtrável (chip de classe + busca) + detalhe com série de 18 meses (SVG) + ação sugerida. Recomputar =
  re-rodar os INSERTs por bucket + o UPDATE de classificação/score.
  - **Sazonalidade & tendência (mesma tela):** tabela leve **`"11 - perdas_nrw".mm_mensal`** (agregado por
    consórcio×competência, 35 linhas — 1 INSERT simples, sem bucket) + RPC **`app_nrw_mm_sazonalidade`**. Painel
    com evolução mensal do **consumo médio por matrícula** (não o volume total — este só cresce porque entram
    mais matrículas nos meses recentes: 57k→134k), **perfil sazonal** (desvio de cada mês-calendário vs a média)
    e **Δ ano a ano** dos meses sobrepostos (2025 vs 2026). Recomputar = re-rodar o INSERT do `mm_mensal`.
- **Dados (resto):** ainda **snapshot estático** embutido no HTML (15 DMCs, VRPs projetadas, OS por causa,
  auditoria cadastral, reincidência de ramais — extraídos de `"7 - setorizacao".dmc`).
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

---

## 8. Projetos · Intervenções — `// MÓDULO PROJETOS / INTERVENÇÕES` · telas `projetos`(hub) / `projeto_campo` / `projeto_det` / `projeto_sup` / `projeto_cfg` / `projeto_acesso` / `projeto_resumo` / `projeto_rel`

Acompanhamento diário de obra das intervenções (macromedidores, VRPs, redes VCA/HDD).
**Estado: preview embutido, gated só ao meu usuário** (`sander.sirio@aguasmg.com.br`) — dados de exemplo
no HTML (`PJ_IVS`), sem backend ainda. Objetivo desta etapa: validar a UX dentro do app antes de modelar o banco.

- **Gate:** card `#cardProj` na home. Em `homeGate()` espelha o `cardPerdas`: se
  `ME.email==='sander.sirio@aguasmg.com.br'` vira botão ativo → `irPara('projetos')`, senão fica `.soon` +
  🔒 e `toast('Acesso restrito')`.
- **Hub (`projetos`, `pjHub()`) — 2 categorias, espelha o Almoxarifado:** **🏗️ Campo** → `projeto_campo`
  (dia a dia) e **🧰 Suporte** → `projeto_sup` (configuração/cadeado, card com ícone **⚙️** — engrenagem, distinto
  do cadeado). A categoria Suporte é gateada por **`pjPodeSup()`** = admin **ou** grant por pessoa. O grant é
  definido no **mini-cadeado 🔐** ao lado do título "🧰 Suporte" (só admin, `pjPodeSetSup()`) → tela `projeto_acesso`
  (`pjSupAcesso()`, lista real de usuários via `sup_admin_usuarios`, admin sempre ligado). **Protótipo:** o grant
  fica em **localStorage** (`pj_sup_acesso`, `pjSupGrants`/`pjSupSetGrant`) até haver backend (`proj_acesso` → `ME.proj_areas`).
- **Cadeado (1 por intervenção):** `iv.locked`. **Liberada** (`locked`) = configuração **congelada**, o campo
  lança avanços. **Em configuração** (`!locked`) = só o Suporte edita escopo/quantidade; **avanços bloqueados**
  (evita desativar atividade que já tem avanço). Default: liberada, exceto `status==='new'` (segue em config).
  Chip de estado na lista/Suporte (`.pjlockchip` lib/cfg).
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
    histórico (`pjLeafHist`) + acumulado + **2 fotos + observação**. **Nenhum controle de config aqui** (foi p/ Suporte).
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
    (`data-attach`/`data-pdf`/`data-remove`) — **é AQUI que se anexa/abre/remove** projeto executivo/licença/alvará/
    as-built. Wiring da árvore compartilhado com o campo via **`pjWireTree(d,rerender)`** + `pjSnapOpen`/`pjReopen`.
  - `projeto_acesso` (`pjSupAcesso()`) — **mini-cadeado da categoria Suporte**: lista de usuários com toggle de
    acesso (admin sempre ligado). Persiste em localStorage (protótipo).
  - `projeto_resumo` (`pjResumoEnter`→`pjResumo()`) — **resumo por período** p/ o gestor. Filtro de período
    (atalhos Hoje/7 dias/Este mês/Tudo + `de`/`até` custom) + consórcio + tipo. **KPIs** (nº avanços, intervenções
    com movimento, subatividades, metros executados), **timeline por dia**, **por intervenção** e **por atividade**,
    + **Exportar CSV**. Fonte de dados: **`pjAllAvancos()`** achata todos os avanços de `pjLeafHist` (mock) com a
    atividade de nível 1 e metadados da intervenção; `pjRsRange()` resolve o período. ⚠️ **Prévia:** datas/valores
    são os do mock `pjLeafHist` (derivado do % atual) — viram reais quando existir o **log de avanço** (ver abaixo).
  - `projeto_rel` — **gestão, tela à parte**. **Documentos** = projeto executivo, licença, alvará, as-built,
    **só com botão Abrir** (`pjOpenPdf()` gera um PDF-blob mínimo válido e abre em nova aba) — **anexar/remover
    saíram daqui e ficam na configuração** (`projeto_cfg`). **mini-Gantt** (`pjRel()`) — cada barra vai
    do **1º ao último avanço** da atividade (datas reais de `pjLeafHist`; eixo min→méd→máx); atividade sem
    avanço = "não iniciada". **Avanços por atividade·subatividade** com fotos + observação, com toggle de
    ordenação (`#pjAdvSeg`): **Sequência lógica** (árvore atividade›subatividade) × **Ordem de envio** (feed
    cronológico de todos os lançamentos, mais recente primeiro, fora da sequência). **PDF consolidado**
    = documento único (capa + Gantt + avanços + projeto/licença/alvará/as-built no fim).
    (Sem gradientes nos cards de atividade — removidos a pedido.)
- **Modelo de dados (nós da árvore):** construtores `pjP` (%), `pjM` (metros meta/exec, % automático),
  `pjR` (registro), `pjSel` (**seleção de tipo**, `k:'sel'` — não mensurável), `pjG` (grupo); helpers `pjOc`
  (obra civil), `pjIL` (interligação), `pjILrep` (container replicável), `pjRamal`/`pjRamais` e
  `pjPeca`/`pjPecas`. **Ramal** (`pjRamal`) traz, nesta ordem: **OS SIGOS** e **Nº do Hidrômetro** (primeiro),
  **Nº do imóvel**, as-built **A1/A2/A3/P1** (registros), depois execução **Escavação/Assentamento/Ligação à
  rede** (% ativáveis). **Peça** (`pjPeca`) traz **Especificação (tipo de componente)** primeiro (`pjSel`, opções
  em `PJ_PECA_TIPOS`: válvula de manobra, ventosa, descarga, registro, redução, tê, cap, luva, outro; o tipo
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
- **⚠️ Fragilidades conhecidas (protótipo — corrigir com o backend):** (1) **avanço não é gravado** —
  `data-launch` só dá `toast` e **`pjLeafHist` FABRICA** o histórico a partir do % atual (split 60/40, datas de
  uma lista fixa semeada por `node.n` → subatividades homônimas caem nas mesmas datas); o `projeto_resumo`
  herda esse mock. (2) **Nada persiste** — `PJ_IVS`, toggles de escopo, quantidades, tipos, registros e o
  `iv.locked` são de memória; reload zera. (3) **Grant do Suporte é localStorage por-navegador** → não gateia de
  fato entre usuários. (4) `status` (run/new/done) é **fixo**, não deriva do progresso. (5) `pjHasAdv` = "% > 0"
  (não "avanço real"). (6) Datas só DD/MM com ano fixo 2026 no parse. (7) Avanço sem autor/equipe/hora; sem
  planejado × realizado (Gantt não detecta atraso); fotos do avanço não são guardadas. (8) Toggles são `<span>`
  (sem teclado). Todas se resolvem com o **log de avanço real** + persistência (schema abaixo).
- **Schema-alvo (a criar):** um schema próprio **`13 - projetos_obra`** (segue o padrão 1-módulo-1-schema:
  8 coleta / 9 suprimentos / 10 Frotas / 11 perdas). Cadastro da intervenção **vem de camada georref de
  projetos** — hoje não existe no banco; as georref correlatas são `7 - setorizacao.dmc_projetado`/
  `vrp_projetada` e `2 - infra_agua.vrps`/`unidades_macromedicao`/`rede`. Tabelas previstas: `intervencao`
  (↔ geometria), `no_arvore` (template + instância por intervenção, com unidade/formato/meta/ativo/rep),
  `avanco` (lançamento diário: valor incremental + observação, N fotos em `fotos-campo`), `registro`
  (OS SIGOS/hidrômetro), `documento` (projeto/licença/alvará/as-built). RPCs `app_proj_*`.
- **Próximo passo:** modelar esse schema e trocar `PJ_IVS` por RPCs `app_proj_*`. Depois: resumo diário
  multi-intervenção.

## 12. Gestão de Pessoas — schema `"14 - pessoas"` · tela-hub `pessoas`

**Fase 1** (esta rodada, incluindo o incremento de aprovação por área): fluxo de candidato em
contratação até a ativação, com aprovação de vaga restrita a uma lista fechada de gestores por
área. Orçamento/headcount por área (comparar contratados × previstos no orçamento × em
contratação) fica para uma Fase 2 — não implementado ainda.

**Ciclo de status** (`candidato.status`): `aguardando_gestor` → (o gestor da área aprova **e**
confirma área/empresa/projeto numa única ação — custo é derivado, não escolhido) →
`proposta_pendente` → (RH gera a carta,
depois anexa o PDF assinado fora do sistema) → `proposta_assinada` → (RH ativa, vinculando a um
`perfil` existente) → `ativo`. `reprovado` sai direto de `aguardando_gestor`; `cancelado` é
reservado para uso futuro (não produzido por nenhuma RPC nesta fase). Não existe mais o status
intermediário `aguardando_area` — antes eram dois passos (RH aprova, depois um gestor qualquer
preenche a área); agora é a mesma pessoa (o gestor mapeado da área) que faz as duas coisas de uma
vez, então os passos foram fundidos.

- **Quem aprova vaga não é mais RH genérico — é uma lista fechada de gestores por área**, tabela
  `"14 - pessoas".area_aprovador` (`codigo_area` PK, `area`, `aprovador_uuid → public.perfil`,
  ~18 linhas, 6 pessoas distintas; hoje mantida só por SQL direto, sem tela de edição — muda raro).
  No cadastro (`app_pessoas_candidato_cadastrar`), o RH escolhe o **gestor da área** da vaga a
  partir dessa lista (`p_gestor_uuid` validado contra `area_aprovador` — RH não pode apontar
  qualquer `perfil`, só um dos mapeados). Isso é **separado** do par genérico
  `perfil.aprovador_uuid`/`aprovador2_uuid` usado no resto do app (EPI/insumos/etc.) — aqui esse par
  só entra em cena **depois** que o colaborador já está `ativo` (ver "Visibilidade em camadas"
  abaixo).
- **RH** (flag `perfil.pessoas_admin`, mesmo molde de `frota_admin`; ligado/desligado por
  `app_pessoas_admin_set`, admin-only): cadastra o candidato (`app_pessoas_candidato_cadastrar` —
  `p_id` null cria, preenchido atualiza só enquanto `aguardando_gestor`), acompanha o status (não
  aprova mais — só o gestor mapeado decide), gera a carta proposta (`app_pessoas_carta_gerar` —
  cargo/salário/data de início/benefícios, prévia via o mesmo overlay `#relatorio`/`REL_CSS` usado
  nos outros relatórios do app, `pessoasEmitirCarta`), anexa o PDF final assinado
  (`app_pessoas_carta_anexar`, upload via `uploadFoto2`/`fotoPickHtml(...,{pdf:true})` — bucket
  `fotos-campo`, pasta `pessoas/`), marca como assinada (`app_pessoas_candidato_marcar_assinado`) e
  ativa no primeiro dia (`app_pessoas_candidato_ativar`).
- **Gestor da área** (`candidato.gestor_uuid`, restrito à lista `area_aprovador`): aprova ou
  reprova a vaga numa única RPC (`app_pessoas_candidato_aprovar` — quando `p_aprovado=true`,
  exige/grava `p_codigo_area`/`p_area`/`p_frente_empresa`/`p_projeto` e avança pra
  `proposta_pendente`; quando `false`, grava `p_motivo_reprovacao` e vai pra `reprovado`). Gate:
  `candidato.gestor_uuid = auth.uid() or funcao='admin'` — nem RH comum (`pessoas_admin` sem
  `funcao='admin'`) nem qualquer outro gestor mapeado de outra área consegue aprovar; só o gestor
  exato da vaga (ou o admin de fato, como override). **`custo_direto_indireto` não é mais escolhido
  pelo gestor (2026-09-24)** — a RPC deriva sozinha: `projeto='Ambos'` → `Indireto`, qualquer
  projeto específico (Contagem/Betim) → `Direto`. **Área também não é mais texto livre**: nova RPC
  `app_pessoas_minhas_areas()` (qualquer autenticado, sem exigir `pessoas_admin` — é sobre *ser* o
  gestor mapeado) devolve só as linhas de `area_aprovador` do próprio chamador; se só 1 linha (5 dos
  6 gestores hoje), o frontend mostra a área como texto fixo e nem pede confirmação; se mais de 1
  (só Raulmar, que cobre ~12 áreas), mostra um `<select>` restrito às áreas dele, não as 18 inteiras.
  Depois que o colaborador está `ativo`, o mesmo gestor preenche o checklist de setup
  (`app_pessoas_checklist_setup_salvar` — celular/notebook (se área indireta)/EPIs/usuário
  AcquaHub, todos **desmarcados por padrão**, mesmo padrão do checklist diário de Frotas — colunas
  booleanas individuais, sem jsonb).
- **Visibilidade em camadas (dados confidenciais do candidato — CPF, endereço, formação,
  salário/benefícios, motivo de reprovação):** só o gestor mapeado da área da vaga (via
  `candidato.gestor_uuid`) + RH/admin veem esses campos, e só durante a contratação — as duas RPCs
  devolvem o conjunto completo: `app_pessoas_meus_candidatos` (visão do gestor, filtrado por
  `gestor_uuid = auth.uid()` — isolamento automático por pessoa, não por "equipe") e
  **"Minha equipe" (`pessoasRenderMinhaEquipe`) filtra no frontend quem já terminou o processo
  (2026-09-24)**: some da lista quem está `ativo` **e** já tem checklist de setup preenchido —
  continua aparecendo enquanto `ativo` sem checklist (é assim que o gestor acha o aviso "Checklist
  de setup pendente"), e some de vez só depois de completo; e
  `app_pessoas_candidatos_listar` (visão do RH, gate `app_pessoas_admin_check`); o frontend mostra
  o mesmo bloco "Dados do candidato" pras duas visões. O par genérico
  `aprovador_uuid`/`aprovador2_uuid` de `perfil` **nunca** vê esses campos nem participa da
  aprovação da vaga — ele só passa a enxergar o colaborador **depois** de `ativo`, e só campos
  simples (nome/área/empresa/data de admissão) via `app_pessoas_meus_colaboradores` (`select
  id,nome,area,frente_empresa,admissao from perfil where aprovador_uuid=auth.uid() or
  aprovador2_uuid=auth.uid()` — qualquer autenticado pode chamar, não precisa de `pessoas_admin`,
  porque é sobre *ser* aprovador1/2 de alguém, mecanismo já genérico do app). Tela "Gestor → Meus
  colaboradores" no hub mostra essa lista simples (2026-09-24: a seção "Meu Time" separada foi
  removida — a ação virou uma segunda opção dentro de "Gestor", junto de "Minha equipe").
- **Ativação não cria conta nova.** O RH escolhe, num `<select>`, um `perfil` existente
  (`app_pessoas_usuarios_listar(p_apenas_ativos, p_somente_novos)` — `p_apenas_ativos=true` no
  cadastro/gestor, `false` na ativação, pra permitir vincular a um `perfil` já `ativo=false`, ex.:
  recontratação; **`p_somente_novos=true` na ativação (2026-09-24)** filtra `where codigo_area is
  null` — só aparecem perfis que nunca passaram por `app_pessoas_candidato_ativar` antes, pra não
  misturar candidatos novos com colaboradores que já têm ficha completa). `app_pessoas_candidato_ativar`
  grava `candidato_admissao` (tamanhos de uniforme + matrícula + data de admissão) **e também
  atualiza `public.perfil`** (`cpf`/`matricula`/`admissao`/`codigo_area`/`area`/`frente_empresa`/
  `projeto`/`custo_direto_indireto`/`cargo_id`/`ativo=true`) — essas colunas já existem em `perfil`
  (usadas pela planilha de usuários e por Frotas) e continuam com fonte única de verdade ali, não
  duplicada em Pessoas. **Um `perfil` só pode estar vinculado a um `candidato` por vez** — índice
  único parcial `candidato_perfil_id_uk` (`where perfil_id is not null`) + checagem amigável na RPC,
  e a `UPDATE` final de `candidato` re-checa `status='proposta_assinada'` (com as outras RPCs de
  transição de status fazendo o mesmo: status guard **na própria `UPDATE`**, não só numa `SELECT`
  anterior, pra fechar corrida de duplo clique/dupla aprovação).
- **Notificação** segue o invariante §0.9, nunca chamada inline nas RPCs: trigger
  `"14 - pessoas".trg_candidato()` `AFTER INSERT OR UPDATE on candidato` — cobre **INSERT** (avisa
  só `NEW.gestor_uuid`, o gestor mapeado escolhido no cadastro — não mais o grupo `pessoas_admin`
  inteiro, porque é ele quem precisa agir agora — `link='pessoas_candidato'`), **UPDATE** pra
  `proposta_pendente` (avisa o grupo `pessoas_admin`/admin — área preenchida, hora de gerar a
  carta) e **UPDATE** pra `ativo` (avisa `NEW.gestor_uuid`, `link='pessoas_checklist'`, **e também**
  o `aprovador_uuid`/`aprovador2_uuid` atuais do `NEW.perfil_id`, lookup em `perfil` de dentro do
  trigger — "Você tem um novo colaborador: `<nome>`", `link='pessoas_meus_colaboradores'`) — mesmo
  cuidado já documentado em Frotas de cobrir os dois `TG_OP`, não só `UPDATE`.
- **Cargo do candidato** vem de `sup_cargos_ativos()` (schema `9 - suprimentos`, mesma RPC já usada
  em Suprimentos) — reaproveitada, não duplicada.
- **Premissas de benefícios (2026-09-24):** tabela nova `"14 - pessoas".beneficio_premissa`
  (`codigo` PK texto — `vt`/`vr_va`/`saude`/`odontologico`/`seguro_vida` —, `nome`, `valor`,
  `regra` texto livre), seed com os 5 valores que a Geovana passou. Tela RH "Premissas de
  benefícios" (`pessoasRenderBeneficiosPremissas`, RPCs
  `app_pessoas_beneficios_premissas_listar`/`app_pessoas_beneficio_premissa_salvar`, ambas
  `app_pessoas_admin_check`). **`candidato.beneficios` (texto livre) foi substituído por 5 colunas
  booleanas** (`beneficio_vt`/`beneficio_vr_va`/`beneficio_saude`/`beneficio_odontologico`/
  `beneficio_seguro_vida`, default `false`) — RH marca sim/não por candidato em vez de digitar
  texto; `app_pessoas_carta_gerar` trocou o parâmetro `p_beneficios text` pelos 5
  `p_beneficio_* boolean` (assinatura antiga dropada explicitamente antes de criar a nova, mesmo
  cuidado do bug de overload da 2ª revisão do PR #104). A tela de geração de carta soma os valores
  dos benefícios marcados contra as premissas e mostra "Custo estimado em benefícios" **só pro
  RH**, como referência interna — **os valores não aparecem na carta** que o candidato recebe
  (decisão confirmada: a carta mantém texto descritivo fixo por benefício, sem imprimir R$; isso é
  desenhado na 3ª rodada, que reescreve `pessoasEmitirCarta` pro modelo legal completo). A coluna
  `beneficios` (texto) continua existindo na tabela por enquanto (não é mais escrita nem lida por
  nenhuma RPC/tela) — pode ser dropada quando a 3ª rodada estiver pronta e confirmada.
- **Desligamento** (`app_pessoas_colaborador_desligar(p_perfil_id, p_data_demissao, p_motivo)`,
  `pessoas_admin`/admin-only): tela **Colaboradores** (`app_pessoas_colaboradores_listar`, busca por
  nome/e-mail sobre todo `perfil`, ativos e inativos) → abrir um colaborador ativo mostra o form de
  desligamento. Grava histórico em `"14 - pessoas".desligamento` (append-only, 1 linha por evento —
  permite recontratação futura sem perder o registro) e espelha o estado atual em
  `public.perfil.ativo=false`/`demissao=p_data_demissao`, mesma fonte única de verdade da ativação.
  Sem trigger de notificação nesta fase (RH é quem inicia e confirma na hora). Não muda com o
  incremento de aprovação por área.
- **Tabelas:** `candidato` (dados pessoais + CPF/endereço + status + campos da carta proposta),
  `candidato_admissao` (1:1, tamanhos de uniforme/matrícula/data de admissão),
  `colaborador_checklist_setup` (1:1, checklist de setup), `desligamento` (histórico, N:1 por
  `perfil_id`), `area_aprovador` (mapeamento área → gestor de aprovação de vaga). RLS ligada,
  `revoke all` de `anon`/`authenticated` — acesso só via RPC `SECURITY DEFINER`, mesmo padrão dos
  outros schemas app-only (`9`/`10`/`11`/`12`).
- **`app_me()`** ganhou `pessoas_admin` no retorno (igual `frota_admin`).
- **Acesso de RH** (`perfil.pessoas_admin`) é concedido pela engrenagem ⚙️ na seção RH do hub
  (admin-only) — `pessoasRenderAdminGate`/`pessoasAdmRender`, `app_pessoas_admin_listar`/
  `app_pessoas_admin_set` — mesmo molde de `frotaAdminGate`/`app_frota_admin_*`. `funcao='admin'`
  sempre tem acesso (`acesso_pelo_cargo`, checkbox travado), assim como em Frotas.
- **Cuidados:** o schema é `14`, não `13` — `13 - projetos_obra` já está reservado no roteiro do
  módulo Projetos (§8, ainda não criado) e não podia ser reaproveitado. `SCREENS` ganhou `'pessoas'`
  + `if(id==='pessoas') pessoasInit()` em `irPara()`; roteamento das notificações em `supGoAct`
  (`pessoas_candidato`/`pessoas_checklist`/`pessoas_meus_colaboradores`). O upload de anexo da carta
  proposta (`FOTO2_BLOBS.peCartaAnexo`, via `uploadFoto2`/`fotoPickHtml`) é resetado a cada render
  da tela de detalhe do candidato — sem isso, o blob em memória de um candidato anterior poderia
  vazar e ser anexado ao candidato errado se o RH não escolher um arquivo novo.
- **Card do hub travado** (`#cardPessoas`, na categoria **🚧 Em desenvolvimento**, `homeGate()`, mesmo
  padrão de `cardPerdas`/`cardProj` — gate por **`ME.dev_acesso`**, controlado pela engrenagem ⚙️ da categoria
  `dev_acesso`): só quem tem acesso "Em desenvolvimento" vê/clica o card "Gestão de Pessoas" — pros demais
  aparece com 🔒 e toast de "Acesso restrito". Isso só esconde o módulo do menu geral; não é o controle de
  acesso real (esse continua sendo as RPCs `SECURITY DEFINER` + `pessoas_admin`/`gestor_uuid`/`aprovador_uuid`/`aprovador2_uuid`) — por isso
  um gestor de área que recebe notificação de aprovação de vaga (`supGoAct` → `irPara('pessoas')`)
  continua conseguindo entrar pelo link da notificação mesmo sem estar na lista do card, porque
  `irPara('pessoas')` não tem gate próprio, só o card do home tem.
- **Próximo passo (Fase 2):** tabela de orçamento mensal por vaga (código de área/função/setor/
  modalidade/projeto/custo/headcount por mês — fonte é uma planilha de orçamento existente fora do
  app) + painel do gestor comparando contratados (via `perfil.ativo`+`area`) × orçado × em
  contratação (via `candidato.status`).
