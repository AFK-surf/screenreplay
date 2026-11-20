// Downloads from the R2 bucket `screenreplay` (bound as BUCKET in wrangler.toml):
// /dl/ScreenReplay-Setup.exe (latest), /dl/v0.1.7/ScreenReplay-Setup-0.1.7.exe, /dl/latest.json
export async function onRequestGet({ params, env }) {
  const raw = params.path;
  const key = Array.isArray(raw) ? raw.join("/") : String(raw || "");
  if (!key || key.includes("..")) return new Response("Not found", { status: 404 });
  if (!env || !env.BUCKET) return new Response("R2 binding missing", { status: 503 });
  const obj = await env.BUCKET.get(key);
  if (!obj) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("content-length", String(obj.size));
  if (key.endsWith(".json")) {
    headers.set("content-type", "application/json; charset=utf-8");
    headers.set("cache-control", "no-cache");
  } else {
    headers.set("content-type", "application/octet-stream");
    headers.set("content-disposition", `attachment; filename="${key.split("/").pop()}"`);
    headers.set("cache-control", key.includes("/") ? "public, max-age=31536000, immutable" : "public, max-age=300");
  }
  return new Response(obj.body, { headers });
}

export async function onRequestHead({ params, env }) {
  const raw = params.path;
  const key = Array.isArray(raw) ? raw.join("/") : String(raw || "");
  if (!key || key.includes("..")) return new Response(null, { status: 404 });
  if (!env || !env.BUCKET) return new Response(null, { status: 503 });
  const obj = await env.BUCKET.head(key);
  if (!obj) return new Response(null, { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("content-length", String(obj.size));
  headers.set("content-type", key.endsWith(".json") ? "application/json; charset=utf-8" : "application/octet-stream");
  if (!key.endsWith(".json")) {
    headers.set("content-disposition", `attachment; filename="${key.split("/").pop()}"`);
  }
  return new Response(null, { status: 200, headers });
}
