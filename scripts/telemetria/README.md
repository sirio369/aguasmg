# Telemetria CCO COPASA → AcquaHub

Pipeline para receber diariamente os CSVs de telemetria exportados do sistema CCO da
COPASA e alimentar o banco (Supabase, schema `"15 - telemetria"`), já cruzando com o
nosso cadastro técnico.

## O que os dados são

Cada unidade com telemetria exporta um CSV. O nome do arquivo é `CODIGO - CODIGOCOPASA.csv`
(ex.: `EMM209 - EMM0000002.csv`). São **3 esquemas de medição**, detectados pelo cabeçalho:

| Esquema | Cabeçalho | Tipo | Grandezas |
|---|---|---|---|
| `vazao_volume` | `Momento;Vazao;Volume;Sinal` | macromedidor | vazão (L/s), volume acumulado (m³) |
| `bombas_pressao` | `Momento;B01;B02;B03;B04;Nivel_Suc;Pressao_Suc;Pressao_Rec;Sinal` | booster/elevatória | 4 bombas (on/off), nível e pressões sucção/recalque |
| `nivel` | `Momento;Nivel;Sinal` | reservatório | nível (m) |

- Separador `;`, decimal `.`, timestamp `DD/MM/YYYY HH:MM`, granularidade **5 min**.
- `Sinal` = 1 quando a telemetria está viva (guardamos como grandeza `sinal`).
- Horário local de Brasília (−03:00, sem horário de verão).

## Modelo no banco (`"15 - telemetria"`)

- **`tele_unidade`** — dimensão: 1 linha por unidade (código CCO, código COPASA, ZA, cidade,
  tipo, esquema) + o cruzamento com o cadastro (`cadastro_tabela`/`cadastro_id`/`nome`;
  `null` = unidade **não existe** no nosso cadastro).
- **`tele_leitura`** — fatos em **formato longo**: `(unidade_id, momento, grandeza, valor)`.
  Um único formato serve os 3 esquemas e qualquer grandeza futura. PK evita duplicata →
  reprocessar é seguro (upsert).
- **`tele_carga`** — log de ingestão por arquivo.
- **`vw_cobertura`** — cada unidade × presença no cadastro × estatística de leituras.
- **`vw_cadastro_sem_tele`** — inverso: pontos do cadastro sem feed de telemetria.
- RPCs públicas (SECURITY DEFINER): `app_tele_unidade_upsert`, `app_tele_ingest`, `app_tele_cobertura`.

## Setup (uma vez)

```bash
pip install -r requirements.txt
cp .env.example .env      # e preencha SUPABASE_SERVICE_KEY
```

A `service_role key` está em: Supabase → Project Settings → API → `service_role` (secret).

## Uso diário (input fácil)

A COPASA exporta os CSVs atualizados → jogue todos numa pasta → rode:

```bash
python ingest_telemetria.py "C:\caminho\para\os\CSVs"
```

- É **incremental**: envia só as leituras novas (momento > último já carregado), controlado
  pelo arquivo local `.ingest_state.json`. Reprocessar a pasta inteira não duplica nada.
- A ZA/cidade é inferida pelo nome da pasta (`contagem`/`betim`); force com `--za` / `--cidade`.
- `--full` reenvia o arquivo inteiro; `--dry-run` só mostra o que faria.

Sugestão: manter uma pasta fixa (ex. `telemetria\_inbox\`) onde a extração diária deposita
os CSVs, e agendar este comando no Agendador de Tarefas do Windows.

## Cruzamento com o cadastro

Das 101 unidades com telemetria, apenas ~25 existem hoje no cadastro técnico
(`"2 - infra_agua"`). As demais são pontos telemetrados **fora** do nosso banco — candidatas
a inclusão no cadastro. Veja `vw_cobertura` (o que temos e com dados) e `vw_cadastro_sem_tele`
(cadastro sem telemetria).
