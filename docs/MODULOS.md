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
   `aprovador2_uuid` (configurados em Suprimentos ⚙️ Configurações) + `"9 - suprimentos".sup_aprovadores_de(uid)`
   (fallback: todo `aprovador`/`admin` ativo) + `"9 - suprimentos".sup_notificar(...)` **disparado por
   trigger** `AFTER INSERT/UPDATE` na tabela de negócio — nunca inline na RPC. Regra de ouro:
   notificação **pessoal** (ao próprio interessado) nunca leva `p_exceto`; notificação de **grupo**
   sempre leva `p_exceto = auth.uid()` (ator). **Módulo novo que precisa de aprovação/notificação →
   reaproveite isso, não crie hierarquia paralela.** Ver §5.5 (origem) e §6.4 (segundo uso, Frotas).

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
  - `item = {id, tipo, rpc, pasta, fotos:{p_x:Blob}, fields:{...}}`.
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
  Usado por loggers (§Loggers), VRP e comprovantes de suprimentos.

---

## 2. Coleta de campo (schema `"8 - obras & servicos"`)

### 2.1 Mapeamento de pressão — `// UI módulo pressão` (~L592) · tela `pressao`
- Leitura de manômetro + foto + GPS. Salva via `app_registrar_pressao` (fila).
- Alvo opcional vindo do Teste de estanqueidade (`prAlvo`). Botões: `#prEst` (estanqueidade), `#prProd`.
- Subtelas: **Estanqueidade** (`estanqueidade`, `// TESTE DE ESTANQUEIDADE` ~L649, RPC
  `app_estanqueidade_listar`, filtro por consórcio) e **Produtividade de pressão** (`pr_prod`,
  `// PRODUTIVIDADE DE PRESSÃO` ~L4093, RPCs `app_pressao_filtros`/`app_pressao_produtividade`).

### 2.2 Loggers temporários — `// MÓDULO LOGGERS` (~L782) · telas `loggers` / `logger_det`
- **Ciclo (situação DERIVADA, não há coluna):** `pendente → instalado → removido ("dados pendentes")
  → concluido`. **Não existe mais** promoção automática após 7 dias.
- **Tabela base:** `"8 - obras & servicos".instalacao_logger_calibracao`. **View:** `vw_loggers`
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
- **PDF:** `emitirRelatorio(p)` / `relDocHtml(p)` (`// Relatório do ponto` ~L1039) — seções
  Localização (mapa sugerido×instalado), Instalação, Remoção, Finalização, Pressão (SVG de
  `logger_pressao_stats`) + bloco **OS COPASA** sempre visível.
- **Cuidado:** ao adicionar param de foto/campo a `criar`/`instalar`/`editar`, respeite a regra do
  **drop+create** (invariante §0.6) e re-`grant`. E a chave em `item.fotos` = nome do param.

### 2.3 Pesquisa — `// MÓDULO PESQUISA` (~L2067) · telas `pesquisa` / `ocorrencia` / `produtividade`
- Trechos retos (GPS início→fim) + **ocorrências** + produtividade.
- **Ocorrência** (`ocRegistrar`): `app_ocorrencia_registrar` (fila, pasta `ocorrencia`), tabela
  `"8 - obras & servicos".ocorrencia` (campos `tipo`, `local_ref`, `observacao`, `foto`, `lat/lon`,
  `consorcio`, `usuario` texto, `pesquisa_id`, `origem`). Foto obrigatória.
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

### 2.5 Cadastro técnico — `// CADASTRO TÉCNICO` (~L1821) · tela `cadastro`
- Camadas PostGIS no mapa por bbox: reservatório, booster/bomba, elevatória, poço, macromedição,
  **VRPs**, rede, ligações (`CAD_DEF`). Camadas `whole:true` baixam a ZA inteira 1x; pesadas usam
  `step` (célula de cache).
- **RPCs:** `app_cadastro_geojson` (bbox→GeoJSON, param `p_layer`), `app_cadastro_buscar`,
  `app_limites_zas`. Cache em **IndexedDB** (`cadcache`) versionado por **`CAD_VER`** (`'vN|'`) —
  **mudou dado/camada do cadastro? Suba `CAD_VER` também**, senão o usuário fica com cache velho.
- Marcador **"Você"** (GPS): `cadOnGps()` cria/atualiza `cadVoce` (não é apagado nos redraws de
  `cadAtualizar`, que só mexe em `cadCamadas`).
- **Estado:** `cadMap, cadCamadas, cadOn (visibilidade por camada), cadRendered, cadMem, cadVoce`.

---

## 3. Entrevistadores — tela `entrevistadores`

Reúne funções de campo + a subdivisão **🛟 Suporte**. (A antiga "Retaguarda" foi movida para o
**Auxiliar de Programação**, §4.)

### 3.1 Captação de clientes — `// MÓDULO CAPTAÇÃO` (~L2266) · tela `captacao`
- Questionário schema-driven (~70 perguntas, condicionais). Salva via `app_captacao_registrar`
  (fila, pasta `captacao`; fotos termo/fachada/doc/comprovante). View achatada `vw_captacao`.

### 3.2 Solicitação de serviços (campo) — `// ABERTURA DE SERVIÇOS` (~L1394) · tela `abertura_servicos`
- Entrevistador pede abertura de OS (tipo, matrícula, HD, foto do HD, GPS). RPC
  `app_abertura_servico_registrar` (fila, pasta `abertura`). "Minhas solicitações":
  `app_abertura_servico_minhas`. Tabela `"8 - obras & servicos".abertura_servico`.

### 3.3 Roteiro de leitura (Suporte) — `// SUPORTE › ROTEIRO DE LEITURA` (~L1926) · tela `roteiro`
- Mapa por **percurso/trecho** sobre `"8 - obras & servicos".vw_roteiro_leitura` (pontos, 133k) e
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

---

## 5. Suprimentos / Almoxarifado — `// MÓDULO SUPRIMENTOS` (~L2403) · tela `suprimentos` (schema `"9 - suprimentos"`)

Home própria com áreas **Insumos**, **Equipamentos**, **EPI/Uniforme** e **Baixas/Conferência**.
`SUP_ACTS` mapeia act→função; `supBlocks*` montam os menus por papel (`ME`). Navegação interna por
`supArea`/`supHome`/`supGoAct`; back inteligente em `#supBack`. Helpers de papel no banco:
`sup_funcao(uuid)`, `sup_e_almox(uuid)`, `sup_pode_aprovar(uuid)`.

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

### 5.4 Baixas / Conferência (almoxarife)
- Consolida entregas por período p/ baixa no **SIENGE**, **por consórcio** (do perfil de quem retirou).
  RPCs: `sup_baixas_relatorio` (5 args, com `p_consorcio`), `sup_baixas_marcar`,
  `sup_epi_baixa_fila`/`_solicitar`/`_cancelar`, `sup_epi_minhas_baixas`.

### 5.5 Configurações (admin) — `// tela: Configurações` (~L3824)
- Cadastro de usuários: acesso (`sup_admin_set_funcao`), cargo (`sup_admin_set_cargo`), **2 aprovadores
  diretos** (`sup_admin_set_aprovadores(uuid,uuid,uuid)`), **consórcio** (`sup_admin_set_consorcio`);
  equipes (`sup_admin_equipe_*`, `sup_admin_membro_*`); cestas por cargo (`sup_cesta_*`,
  `sup_cargos_*`). Notificações de aprovação vão só aos aprovadores diretos (`sup_aprovadores_de`).

---

## 6. Frotas / Condutor / QSMS — schema `"10 - Frotas"` · telas `condutor` / `frotas` / `qsms`

Três telas, três públicos, um fluxo só: colaborador vira **condutor** (auto-cadastro de CNH →
aprovação do gestor → treinamento de direção defensiva → ativo), **Frotas** (`funcao='frotas'`/admin)
cadastra veículos e aprova ocorrências, **QSMS** (`funcao='qsms'`/admin) agenda e dá baixa nos
treinamentos. Cards na home (🧰 Suporte): 🚗 Frotas, 🪪 Condutor (todo mundo vê), 🦺 QSMS
(`#cardQsms`, nasce `hidden`, revelado por `homeGate()` — mesmo padrão do §1/§4).

### 6.1 Condutor — `// condutor/frotas/qsms` (~L4275) · tela `condutor`
- **Ciclo de status** (`frota_condutor.status`): `pendente` → (gestor aprova) → `apto` (banner com
  prazo de **10 dias**, `prazo_treinamento`) → (QSMS agenda + dá baixa no treinamento) → `ativo`.
  Reprovação → `reprovado` (`motivo_reprovacao`), pode reenviar.
- **Auto-cadastro:** `condRenderCadastro`/`condSalvarCnh` → `app_condutor_solicitar` (1º envio) ou
  `app_condutor_atualizar_cnh` (já `apto`/`ativo`, ex.: CNH renovada) — mesma assinatura
  `(p_cnh_numero, p_cnh_categoria, p_cnh_validade, p_cnh_foto)`. Foto via `uploadFoto2(...,'cnh')`
  → bucket `fotos-campo` (**mesmo bucket público das fotos de campo** — sem storage dedicado/privado
  para CNH; se isso virar problema de privacidade, é o primeiro lugar a mexer).
- **Alerta de vencimento:** `app_condutor_meu` retorna `cnh_vencendo` (validade ≤ hoje+30). Exibido
  como banner em `condRenderHome` quando `status` é `apto`/`ativo`.
- **Aprovação (gestor):** `condPendentes` vem de `app_condutor_pendentes()` — só quem está em
  `sup_aprovadores_de(condutor.id)` (ou admin) vê a lista. Botão liga a `condAprovar` →
  `app_condutor_aprovar(p_condutor_id, p_aprovado, p_motivo)`.
- **Meu veículo / situação / abastecimento / empréstimo:** `condVeiculos` = `app_frota_veiculos_listar()`
  (retorno enxuto p/ não-`frotas`: `id,placa,modelo,tipo,km_atual,status`, filtrado a exclusivo-meu ou
  da minha equipe). Sub-telas `condRenderSituacao`/`condRenderAbastecimento` salvam via
  `app_frota_situacao_salvar`/`app_frota_abastecimento_salvar` (tabelas `frota_checklist_situacao` /
  `frota_checklist_abastecimento`; ambas levam `p_consorcio` **ZA1004/ZA0200** e foto opcional).
- **Empréstimo:** `condRenderEmprestimo`/`condSalvarEmprestimo` — condutor busca o destinatário por
  e-mail (`app_perfil_por_email`) e chama `app_frota_emprestimo_criar(p_veiculo_id,
  p_para_condutor_id, p_data_inicio, p_data_fim_prevista)`. **Não valida se o destino é condutor
  cadastrado** — qualquer `perfil` serve. Lista "Meus empréstimos" (`app_frota_meus_emprestimos`,
  campo `sou_recebedor`) mostra "Devolver veículo" só pra quem recebeu e está `ativo`; devolução via
  `app_frota_emprestimo_devolver(p_id)`.
- **Estado:** `condSub, condVeiculoSel, condData, condPendentes, condVeiculos, condEmprestimos`.

### 6.2 Frotas — `// condutor/frotas/qsms` (~L4446) · tela `frotas`
- **Gate de tela vs. gate de conteúdo:** todo mundo entra na tela (pra ver ocorrências pendentes se
  for aprovador, ou os próprios veículos se for condutor comum); `frotasRenderHome` decide o conteúdo
  completo (`const full = ME.funcao==='frotas'||ME.is_admin`) — CRUD de veículo/equipe só aparece pra
  `full`. **O backend também gateia** (`app_frota_veiculos_listar` já filtra por função — ver §6.4).
- **Veículo** (`frotasRenderVeiculoEdit`/`frotasSalvarVeiculo` → `app_frota_veiculo_salvar`, 16 params
  incl. dados de locação `fornecedor/contrato_numero/data_inicio/data_fim_prevista` e uso
  `uso_tipo ∈ {equipe,exclusivo}` com `equipe_id` **xor** `condutor_exclusivo_id`). Devolução à
  locadora: `app_frota_veiculo_devolver(p_id, p_data_fim_real)` (botão só aparece se `!data_fim_real`).
- **Equipe** (`frotasRenderEquipes`/`feqCarregar` → `app_frota_equipe_salvar(p_id,p_nome,p_membros[])`,
  `app_frota_equipes_listar`; tabelas `frota_equipe`/`frota_equipe_membro`). **Não confundir com** a
  seção "Equipes" de Suprimentos ⚙️ Configurações (`sup_admin_equipe_*`) — aquilo é código morto (RPC
  não existe no banco); esta aqui, de Frotas, é real e funcional.
- **Ocorrências** (manutenção/sinistro/multa/lavagem): `frotasRenderOcorrencia` → 
  `app_frota_ocorrencia_reportar(p_veiculo_id,p_tipo,p_descricao,p_valor,p_data_ocorrencia,p_fotos[])`
  (tabela `frota_ocorrencia`). Fila de aprovação `frotasOcorPend` = `app_frota_ocorrencia_pendentes()`
  — só quem está em `sup_aprovadores_de(condutor_exclusivo_do_veiculo || reportado_por)` (ou admin) vê,
  **e é aí que o valor fica visível** — o card de "veículos designados a você" (não-`full`) nunca lista
  ocorrências nem valor. Aprovação: `frotasOcorAprovar` → `app_frota_ocorrencia_aprovar(p_id,
  p_aprovado,p_motivo)`.
- **Estado:** `frotasSub, frotasVeiculoSel, frotasVeiculos, frotasEquipes, frotasOcorPend`.

### 6.3 QSMS — `// condutor/frotas/qsms` (~L4577) · tela `qsms`
- Tela só pra `funcao='qsms'`/admin (RPCs recusam com `raise exception 'sem permissao'` pra quem não é
  — testado, ver §6.4). `qsmsAptos` = `app_qsms_condutores_aptos()` (condutores `apto` **sem**
  treinamento `agendado` em aberto). Seleciona vários (`qsmsSelCondutores`) → **Agendar treinamento**
  (`qsmsRenderAgendar` → `app_qsms_treinamento_agendar(p_data,p_horario,p_local,p_instrutor,
  p_condutor_ids[])`, cria `frota_treinamento` + 1 linha por condutor em `frota_treinamento_condutor`).
- **Baixa:** `qsmsRenderBaixa` lista os participantes do treinamento selecionado (`qsmsTreinoSel`),
  QSMS marca presença + anexa foto da lista → `app_qsms_treinamento_baixar(p_treinamento_id,
  p_lista_presenca,p_presentes[])`. Isso **atualiza `frota_condutor.status='ativo'`** pra quem está em
  `p_presentes` — é essa `UPDATE` que dispara a notificação de "condutor ativo" (via trigger, não é
  a própria RPC que notifica — ver §6.4). Quem faltou continua `apto` (pode ser reagendado).
- **Estado:** `qsmsSub, qsmsSelCondutores, qsmsTreinoSel, qsmsAptos, qsmsTreinos`.

### 6.4 Notificação/aprovação — reaproveita Suprimentos (não é hierarquia própria)
Frotas **não tem** tabela de aprovadores/setor própria — usa exatamente o mecanismo do invariante
§0.9. Todo disparo é por **trigger**, nunca inline nas RPCs `app_*` (que só gravam):
- `"10 - Frotas".trg_frota_condutor()` (`AFTER INSERT/UPDATE` em `frota_condutor`): cadastro novo/reenvio
  → grupo `sup_aprovadores_de(condutor)`; `apto` → pessoal ao condutor + grupo `qsms`/admin; `reprovado`
  → pessoal; `ativo` → pessoal ao condutor + grupo `sup_aprovadores_de(condutor)`.
- `"10 - Frotas".trg_frota_ocorrencia()` (`frota_ocorrencia`): INSERT → grupo
  `sup_aprovadores_de(condutor_exclusivo_do_veiculo ?? reportado_por)` + pessoal a esse mesmo alvo
  (se não foi ele quem reportou); UPDATE de status → pessoal ao alvo.
- `"10 - Frotas".trg_frota_emprestimo()` (`frota_emprestimo`, só INSERT): pessoal a `para_condutor_id`.
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
`frota_veiculo` (locação, uso exclusivo/equipe), `frota_condutor` (PK = `perfil.id`, status/CNH),
`frota_equipe` + `frota_equipe_membro`, `frota_checklist_situacao`, `frota_checklist_abastecimento`,
`frota_emprestimo`, `frota_ocorrencia`, `frota_treinamento` + `frota_treinamento_condutor`.

### Cuidados
- **Sem veículos cadastrados ainda em produção** — quem tem `funcao='frotas'` precisa cadastrar os
  reais antes das telas de condutor mostrarem algo.
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
**Condutor/Frotas/QSMS (ver §6):** `app_condutor_solicitar/meu/pendentes/aprovar/atualizar_cnh`,
`app_frota_veiculos_listar/veiculo_salvar/veiculo_devolver`, `app_frota_equipes_listar/equipe_salvar`,
`app_frota_situacao_salvar`, `app_frota_abastecimento_salvar`,
`app_frota_emprestimo_criar/devolver`, `app_frota_meus_emprestimos`,
`app_frota_ocorrencia_reportar/pendentes/aprovar`,
`app_qsms_condutores_aptos`, `app_qsms_treinamento_agendar/baixar`, `app_qsms_treinamentos_listar`,
`app_perfil_por_email` (helper genérico: busca `perfil` por e-mail, usado por Frotas e por qualquer
módulo que precise resolver destinatário por e-mail).
**Biblioteca:** `biblioteca_*`. **Notificações/Push:** `app_notif_*`, `app_push_*`.

> Assinaturas completas: `select proname, pg_get_function_identity_arguments(oid) from pg_proc p
> join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' order by 1;` (via MCP).
