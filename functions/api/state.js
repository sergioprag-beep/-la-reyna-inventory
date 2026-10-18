const MAX_STATE_BYTES = 20 * 1024 * 1024;
const CHUNK_CHARS = 400_000;
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }
});

function splitText(text) {
  const chunks = [];
  for (let offset = 0; offset < text.length;) {
    let end = Math.min(offset + CHUNK_CHARS, text.length);
    if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end--;
    chunks.push(text.slice(offset, end));
    offset = end;
  }
  return chunks;
}

async function readSnapshot(env, snapshotId) {
  const rows = await env.LRX_META.prepare(
    'SELECT chunk_data FROM lrx_state_chunks WHERE snapshot_id = ? ORDER BY chunk_index'
  ).bind(snapshotId).all();
  if (!rows.results?.length) return null;
  try { return JSON.parse(rows.results.map(row => row.chunk_data).join('')); }
  catch { return null; }
}

export async function onRequestGet({ env, request }) {
  const meta = await env.LRX_META.prepare('SELECT revision, object_key, updated_at FROM lrx_state_meta WHERE singleton = 1').first();
  if (!meta) return json({ payload: null, revision: 0, updatedAt: null });
  if (new URL(request.url).searchParams.get('revisionOnly') === '1')
    return json({ revision: Number(meta.revision), updatedAt: meta.updated_at });
  const payload = await readSnapshot(env, meta.object_key);
  if (!payload) return json({ error: 'La copia de datos está incompleta; no se modificó nada.' }, 503);
  return json({ payload, revision: Number(meta.revision), updatedAt: meta.updated_at });
}

export async function onRequestPut({ request, env }) {
  if (Number(request.headers.get('Content-Length') || 0) > MAX_STATE_BYTES)
    return json({ error: 'La copia de datos supera el límite de 20 MB.' }, 413);
  let body;
  try { body = await request.json(); } catch { return json({ error: 'El contenido no es JSON válido.' }, 400); }
  const expected = Number(body?.expectedRevision);
  const payload = body?.payload;
  if (!Number.isSafeInteger(expected) || expected < 0 || !payload || typeof payload !== 'object' || Array.isArray(payload))
    return json({ error: 'Falta una copia de datos válida o su revisión.' }, 400);

  const prior = await env.LRX_META.prepare('SELECT revision, object_key FROM lrx_state_meta WHERE singleton = 1').first();
  const current = Number(prior?.revision || 0);
  if (current !== expected) return json({ error: 'La copia compartida cambió. Actualiza antes de guardar.', revision: current }, 409);

  const serialized = JSON.stringify(payload);
  if (new TextEncoder().encode(serialized).byteLength > MAX_STATE_BYTES)
    return json({ error: 'La copia de datos supera el límite de 20 MB.' }, 413);
  const next = current + 1;
  const now = new Date().toISOString();
  const snapshotId = `${next}-${crypto.randomUUID()}`;
  const chunks = splitText(serialized);
  await env.LRX_META.batch(chunks.map((chunk, index) => env.LRX_META.prepare(
    'INSERT INTO lrx_state_chunks (snapshot_id, chunk_index, chunk_data) VALUES (?, ?, ?)'
  ).bind(snapshotId, index, chunk)));

  const result = await env.LRX_META.prepare(`
    INSERT INTO lrx_state_meta (singleton, revision, object_key, updated_at) VALUES (1, ?, ?, ?)
    ON CONFLICT(singleton) DO UPDATE SET revision = excluded.revision, object_key = excluded.object_key, updated_at = excluded.updated_at
    WHERE lrx_state_meta.revision = ?
  `).bind(next, snapshotId, now, expected).run();
  if (!result.meta?.changes) {
    await env.LRX_META.prepare('DELETE FROM lrx_state_chunks WHERE snapshot_id = ?').bind(snapshotId).run();
    const latest = await env.LRX_META.prepare('SELECT revision FROM lrx_state_meta WHERE singleton = 1').first();
    return json({ error: 'Otro usuario guardó cambios primero. Actualiza antes de volver a guardar.', revision: Number(latest?.revision || 0) }, 409);
  }
  if (prior?.object_key) {
    try { await env.LRX_META.prepare('DELETE FROM lrx_state_chunks WHERE snapshot_id = ?').bind(prior.object_key).run(); }
    catch (error) { console.warn('LRX old snapshot cleanup deferred', error); }
  }
  return json({ revision: next, updatedAt: now });
}
