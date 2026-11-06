// sigos-geocode — localização das OS abertas do SIGOS sem ponto no cadastro (tela "OS não executadas").
// Pega um lote de endereços pendentes (public.app_sigos_geo_pendentes), consulta o Nominatim do
// OpenStreetMap (1 requisição/s, conforme a política de uso) e grava em "17 - sigos".geo_endereco
// (public.app_sigos_geo_gravar). Só o ENDEREÇO sai do banco: sem matrícula, nome ou nº da OS.
// O app chama em laço enquanto houver pendentes (cada chamada ≤ ~45 s). Cache por endereço: um endereço
// localizado nunca é consultado de novo; "não achou" tenta de novo após 7 dias (máx. 3 vezes).
// Aceita o resultado só se a cidade bater (Contagem/Betim) — evita cair em rua homônima de outra cidade.
// Roda com o JWT do usuário (verify_jwt=true); gate = public.sigos_pode_ver (aux/admin).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const UA = "AcquaHub-SIGOS/1.0 (programacao de servicos; geocodificacao de enderecos de OS)";
const TIPO: Record<string, string> = {
  R: "Rua", AV: "Avenida", AL: "Alameda", TV: "Travessa", PC: "Praça", PCA: "Praça", ROD: "Rodovia",
  EST: "Estrada", BC: "Beco", LG: "Largo", VIA: "Via", PRQ: "Parque", ANEL: "Anel",
};
const LIMITE_MS = 45_000;
const sono = (ms: number) => new Promise((r) => setTimeout(r, ms));
const norm = (s?: string) =>
  (s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase().replace(/[^A-Z0-9 ]/g, " ")
    .replace(/\s+/g, " ").trim();

type Partes = { tipo?: string; rua?: string; num?: string | null; bairro?: string; cidade?: string };
type Pend = { chave: string; za: string; endereco: string; partes: Partes | null };

let ultimo = 0;
async function nominatim(params: Record<string, string>): Promise<any[]> {
  const espera = 1100 - (Date.now() - ultimo);
  if (espera > 0) await sono(espera);
  ultimo = Date.now();
  const u = "https://nominatim.openstreetmap.org/search?" + new URLSearchParams({
    ...params, format: "jsonv2", addressdetails: "1", limit: "5", countrycodes: "br",
  });
  const r = await fetch(u, { headers: { "User-Agent": UA, "Accept-Language": "pt-BR" } });
  if (r.status === 429 || r.status === 403) throw new Error("nominatim bloqueou (" + r.status + ")");
  if (!r.ok) return [];
  return await r.json();
}

function escolher(res: any[], p: Partes): any | null {
  const cid = norm(p.cidade), bai = norm(p.bairro);
  const ok = res.filter((x) => {
    const a = x.address ?? {};
    return norm(a.city ?? a.town ?? a.municipality ?? a.village) === cid && /MINAS/.test(norm(a.state));
  });
  if (!ok.length) return null;
  // prefere o que cita o bairro (ajuda nas "Rua Um/Dois…" que se repetem na cidade)
  const comBairro = ok.find((x) => {
    const a = x.address ?? {};
    return [a.suburb, a.neighbourhood, a.quarter, a.city_district].some((v) => v && (norm(v).includes(bai) || bai.includes(norm(v))));
  });
  return comBairro ?? ok[0];
}

async function localizar(p: Partes) {
  const tipo = TIPO[p.tipo ?? ""] ?? p.tipo ?? "";
  const rua = `${tipo} ${p.rua ?? ""}`.trim();
  const base = { city: p.cidade ?? "", state: "Minas Gerais" };
  let r = p.num ? escolher(await nominatim({ ...base, street: `${p.num} ${rua}` }), p) : null;
  if (!r) r = escolher(await nominatim({ ...base, street: rua }), p);
  if (!r) return null;
  const a = r.address ?? {};
  return {
    lat: Number(r.lat), lon: Number(r.lon),
    precisao: a.house_number ? "numero" : "rua",
    detalhe: String(r.display_name ?? "").slice(0, 300),
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "método não permitido" }, 405);
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ ok: false, erro: "não autenticado" }, 401);
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY")!,
    { global: { headers: { Authorization: auth } }, auth: { persistSession: false } },
  );
  const t0 = Date.now();
  const { data: pend, error } = await sb.rpc("app_sigos_geo_pendentes", { p_limite: 20 });
  if (error) return json({ ok: false, erro: error.message }, 400);
  const itens: Pend[] = pend?.itens ?? [];
  const out: any[] = [];
  let achados = 0, bloqueado = "";
  for (const it of itens) {
    if (Date.now() - t0 > LIMITE_MS) break;
    if (!it.partes?.rua || !it.partes?.cidade) {
      out.push({ chave: it.chave, za: it.za, endereco: it.endereco, nao_achou: true });
      continue;
    }
    try {
      const g = await localizar(it.partes);
      if (g) { achados++; out.push({ chave: it.chave, za: it.za, endereco: it.endereco, ...g }); }
      else out.push({ chave: it.chave, za: it.za, endereco: it.endereco, nao_achou: true });
    } catch (e) {
      bloqueado = String((e as Error).message ?? e);
      break; // não insiste se o Nominatim recusar
    }
  }
  if (out.length) {
    const { error: e2 } = await sb.rpc("app_sigos_geo_gravar", { p_itens: out });
    if (e2) return json({ ok: false, erro: e2.message }, 400);
  }
  const restantes = Math.max(0, (pend?.total ?? 0) - out.length);
  return json({ ok: !bloqueado, feitos: out.length, achados, restantes, erro: bloqueado || undefined });
});
