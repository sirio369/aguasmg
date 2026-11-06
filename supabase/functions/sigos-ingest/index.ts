// sigos-ingest — Carga SIGOS do AcquaHub (Auxiliar de Programação › Carga SIGOS).
// Recebe { arquivo_id } de um arquivo já enviado ao bucket privado `sigos-relatorios` e registrado por
// app_sigos_registrar. Baixa, decodifica (o SIGOS exporta UTF-16 LE sem BOM), separa o CSV (';') e manda
// cabeçalho + linhas cruas para a RPC public.sigos_processar, que valida contra o campo e aplica a regra
// (Relação = substitui a carteira da ZA; Encerradas = acumula). Toda a regra de negócio fica no SQL
// (docs/migracao_sigos_carga.sql); aqui só leitura do arquivo.
// Roda com o JWT do próprio usuário (verify_jwt=true): sem service role — storage e RPCs respeitam as policies/gates.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// UTF-16 LE/BE (com ou sem BOM) → UTF-8 → Windows-1252.
function decodificar(buf: Uint8Array): string {
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) return new TextDecoder("utf-16le").decode(buf.subarray(2));
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) return new TextDecoder("utf-16be").decode(buf.subarray(2));
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) return new TextDecoder("utf-8").decode(buf.subarray(3));
  const n = Math.min(buf.length, 400);
  let zImpar = 0, zPar = 0;
  for (let i = 0; i < n; i++) if (buf[i] === 0) (i % 2 ? zImpar++ : zPar++);
  if (zImpar > n / 6) return new TextDecoder("utf-16le").decode(buf);
  if (zPar > n / 6) return new TextDecoder("utf-16be").decode(buf);
  try { return new TextDecoder("utf-8", { fatal: true }).decode(buf); }
  catch { return new TextDecoder("windows-1252").decode(buf); }
}

// CSV com ';' e aspas RFC 4180 (o SIGOS manda coordenadas como "=""-19.93"""), quebra de linha \n ou \r\n.
function lerCsv(t: string, sep = ";"): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], f = "", q = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) {
      if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; }
      else f += c;
    } else if (c === '"' && f === "") q = true;
    else if (c === sep) { row.push(f); f = ""; }
    else if (c === "\n") { row.push(f); rows.push(row); row = []; f = ""; }
    else if (c !== "\r") f += c;
  }
  if (f !== "" || row.length) { row.push(f); rows.push(row); }
  return rows.filter((r) => r.some((c) => c.trim() !== ""));
}

async function sha256(buf: Uint8Array): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", buf);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
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

  let id = "";
  try { id = (await req.json())?.arquivo_id ?? ""; } catch { /* corpo inválido */ }
  if (!id) return json({ ok: false, erro: "arquivo_id ausente" }, 400);

  const falhar = async (msg: string) => {
    await sb.rpc("app_sigos_falha", { p_id: id, p_erro: msg });
    return json({ ok: false, id, erro: msg });
  };

  const { data: info, error: e1 } = await sb.rpc("app_sigos_arquivo_info", { p_id: id });
  if (e1 || !info) return json({ ok: false, erro: e1?.message ?? "arquivo não encontrado" }, 403);

  const { data: blob, error: e2 } = await sb.storage.from("sigos-relatorios").download(info.storage_path);
  if (e2 || !blob) return await falhar("Não consegui ler o arquivo no bucket: " + (e2?.message ?? "vazio"));

  const buf = new Uint8Array(await blob.arrayBuffer());
  let rows: string[][];
  try { rows = lerCsv(decodificar(buf)); }
  catch (e) { return await falhar("Não consegui ler o CSV: " + (e as Error).message); }
  if (rows.length < 2) return await falhar("Arquivo sem nenhuma OS.");

  const [cab, ...linhas] = rows;
  const { data, error: e3 } = await sb.rpc("sigos_processar", {
    p_arquivo: id, p_cabecalho: cab, p_linhas: linhas, p_sha256: await sha256(buf), p_tamanho: buf.length,
  });
  if (e3) return await falhar("Falha ao processar: " + e3.message);
  return json(data);
});
