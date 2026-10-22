#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Ingestor de telemetria do CCO COPASA -> Supabase (schema "15 - telemetria").

Uso tipico (diario):
    python ingest_telemetria.py "C:\\caminho\\para\\CSVs"

Le todos os .csv da pasta (recursivo), identifica a unidade pelo nome do
arquivo ("CODIGO - CODIGOCOPASA.csv"), detecta o esquema pelo cabecalho,
faz upsert da unidade e envia as leituras em lote via RPC. E idempotente:
reprocessar a mesma pasta nao duplica nada, e por padrao envia apenas as
leituras novas (momento maior que o ultimo ja carregado), controlado por um
arquivo local de estado (.ingest_state.json).

Configuracao (variaveis de ambiente OU arquivo .env ao lado do script):
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_SERVICE_KEY=<service_role key>   # chave de servico do projeto

Flags:
    --za ZA1004|ZA0200     forca a ZA (senao infere pelo nome da pasta)
    --cidade NOME          forca a cidade
    --batch 8000           leituras por requisicao (default 8000)
    --full                 reenvia o arquivo inteiro (ignora o incremental)
    --dry-run              apenas analisa e mostra o que faria, sem gravar
"""
import os, sys, csv, re, json, hashlib, argparse, datetime as dt
from collections import OrderedDict

try:
    import requests
except ImportError:
    sys.exit("Faltou a dependencia 'requests'. Rode:  pip install -r requirements.txt")

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.path.join(HERE, ".ingest_state.json")
TZ = "-03:00"  # horario de Brasilia (sem horario de verao desde 2019)

# cabecalho -> (esquema, tipo)
ESQUEMAS = {
    "momento;vazao;volume;sinal": ("vazao_volume", "macro"),
    "momento;b01;b02;b03;b04;nivel_suc;pressao_suc;pressao_rec;sinal": ("bombas_pressao", "booster"),
    "momento;nivel;sinal": ("nivel", "reservatorio"),
}
# nome da coluna do CSV -> nome da grandeza no banco
GRANDEZA = {
    "vazao": "vazao", "volume": "volume", "nivel": "nivel",
    "b01": "b01", "b02": "b02", "b03": "b03", "b04": "b04",
    "nivel_suc": "nivel_suc", "pressao_suc": "pressao_suc",
    "pressao_rec": "pressao_rec", "sinal": "sinal",
}


def load_env():
    envp = os.path.join(HERE, ".env")
    if os.path.exists(envp):
        for line in open(envp, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_KEY", "")
    if not url or not key:
        sys.exit("Defina SUPABASE_URL e SUPABASE_SERVICE_KEY (em variaveis de ambiente ou .env).")
    return url, key


def load_state():
    if os.path.exists(STATE_PATH):
        try:
            return json.load(open(STATE_PATH, encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_state(st):
    json.dump(st, open(STATE_PATH, "w", encoding="utf-8"), ensure_ascii=False, indent=0)


def parse_name(fn):
    """CODIGO - CODIGOCOPASA.csv  ->  (codigo_unidade, codigo_copasa|None)"""
    bn = os.path.splitext(fn)[0]
    parts = re.split(r"\s*[-_]\s*", bn, maxsplit=1)
    uc = parts[0].strip()
    cc = parts[1].strip() if len(parts) > 1 else None
    if cc:
        m = re.match(r"^[A-Za-z]+[0-9]+", cc)  # limpa sufixos ("RSV0001172-15" -> "RSV0001172")
        cc = m.group(0) if m else None
        if cc and cc.lower() == "none":
            cc = None
    if not cc and re.match(r"^[A-Za-z]{2,4}\d{6,}$", uc):  # arquivo nomeado so pelo codigo COPASA
        cc = uc
    return uc, cc


def infer_za_cidade(path, cli_za, cli_cidade):
    low = path.lower()
    za = cli_za or ("ZA1004" if "contagem" in low else "ZA0200" if "betim" in low else None)
    cidade = cli_cidade or ("CONTAGEM" if za == "ZA1004" else "BETIM" if za == "ZA0200" else None)
    return za, cidade


def to_iso(momento):
    """ '23/03/2026 14:03' -> '2026-03-23T14:03:00-03:00' """
    d = dt.datetime.strptime(momento.strip(), "%d/%m/%Y %H:%M")
    return d.strftime("%Y-%m-%dT%H:%M:00") + TZ


class Client:
    def __init__(self, url, key):
        self.rpc = url + "/rest/v1/rpc/"
        self.s = requests.Session()
        self.s.headers.update({
            "apikey": key, "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        })

    def call(self, fn, payload):
        r = self.s.post(self.rpc + fn, data=json.dumps(payload), timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"{fn} -> HTTP {r.status_code}: {r.text[:300]}")
        return r.json() if r.text else None


def process_file(cli, path, za, cidade, batch, incremental, last_momento, dry):
    fn = os.path.basename(path)
    with open(path, encoding="utf-8", errors="replace") as f:
        header = f.readline().strip()
        hkey = header.lower().replace(" ", "")
        esq_tipo = ESQUEMAS.get(hkey)
        if not esq_tipo:
            return ("skip", f"cabecalho desconhecido: {header}", None, 0)
        esquema, tipo = esq_tipo
        cols = [c.strip() for c in header.split(";")]
        measure_cols = [c for c in cols if c.lower() != "momento"]

        uc, cc = parse_name(fn)
        if dry:
            # conta linhas rapidamente
            n = sum(1 for _ in f)
            return ("dry", f"{uc} [{esquema}] copasa={cc} za={za}", cc, n)

        uid = cli.call("app_tele_unidade_upsert", {
            "p_codigo_unidade": uc, "p_codigo_copasa": cc,
            "p_za": za, "p_cidade": cidade, "p_tipo": tipo, "p_esquema": esquema,
        })

        # monta leituras (deduplicadas por unidade+momento+grandeza, mantem a ultima)
        rows = OrderedDict()
        maxmom = last_momento
        rdr = csv.reader(f, delimiter=";")
        for rec in rdr:
            if not rec or len(rec) < len(cols):
                continue
            mraw = rec[0].strip()
            try:
                iso = to_iso(mraw)
            except Exception:
                continue
            if incremental and last_momento and iso <= last_momento:
                continue
            if iso > (maxmom or ""):
                maxmom = iso
            for i, c in enumerate(cols):
                lc = c.lower()
                if lc == "momento":
                    continue
                g = GRANDEZA.get(lc)
                if not g:
                    continue
                v = rec[i].strip().replace(",", ".")
                rows[(iso, g)] = {"m": iso, "g": g, "v": (v if v != "" else None)}

        leituras = list(rows.values())
        total = 0
        fhash = hashlib.md5(open(path, "rb").read()).hexdigest()
        for i in range(0, len(leituras), batch):
            chunk = leituras[i:i + batch]
            arq = fn if i == 0 else None
            n = cli.call("app_tele_ingest", {
                "p_codigo_unidade": uc, "p_rows": chunk,
                "p_arquivo": arq, "p_hash": (fhash if i == 0 else None),
            })
            total += (n or 0)
        return ("ok", f"{uc} [{esquema}] +{total} leituras", maxmom, total)


def main():
    ap = argparse.ArgumentParser(description="Ingestor de telemetria CCO -> Supabase")
    ap.add_argument("pasta", help="pasta com os CSVs (recursivo)")
    ap.add_argument("--za")
    ap.add_argument("--cidade")
    ap.add_argument("--batch", type=int, default=8000)
    ap.add_argument("--full", action="store_true", help="reenvia arquivo inteiro (ignora incremental)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    url, key = load_env()
    cli = Client(url, key)
    state = load_state()

    files = []
    for root, _, fs in os.walk(a.pasta):
        for fn in fs:
            if fn.lower().endswith(".csv"):
                files.append(os.path.join(root, fn))
    files.sort()
    if not files:
        sys.exit("Nenhum .csv encontrado em " + a.pasta)

    print(f"{len(files)} arquivos | destino {url} | {'DRY-RUN' if a.dry_run else 'GRAVANDO'}")
    ok = skip = err = 0
    tot_leituras = 0
    for p in files:
        key_st = os.path.relpath(p, a.pasta).replace("\\", "/")
        last = None if a.full else (state.get(key_st, {}) or {}).get("last_momento")
        try:
            status, msg, maxmom, n = process_file(
                cli, p, *infer_za_cidade(p, a.za, a.cidade),
                a.batch, incremental=not a.full, last_momento=last, dry=a.dry_run)
            tag = {"ok": "OK ", "skip": "SKIP", "dry": "DRY", "err": "ERR"}.get(status, "?")
            print(f"  [{tag}] {os.path.basename(p):40s} {msg}")
            if status == "ok":
                ok += 1; tot_leituras += n
                if maxmom:
                    state[key_st] = {"last_momento": maxmom}
                    save_state(state)
            elif status == "dry":
                ok += 1
            else:
                skip += 1
        except Exception as e:
            err += 1
            print(f"  [ERR] {os.path.basename(p):40s} {e}")
    print(f"\nResumo: {ok} processados, {skip} ignorados, {err} erros, {tot_leituras} leituras gravadas.")


if __name__ == "__main__":
    main()
