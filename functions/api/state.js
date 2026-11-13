// The full restaurant dataset, including recipe utensil and cost histories,
// can exceed 20 MiB. Keep headroom for a reconciled snapshot while staying
// below D1's 50 MB query-result limit and Cloudflare's 100 MB request limit.
const MAX_STATE_BYTES = 40 * 1024 * 1024;
const CHUNK_CHARS = 400_000;
// Fetch only a few D1 rows at a time. Large restaurant snapshots can approach
// the D1 result limit, and buffering every chunk in a Worker is wasteful on
// mobile clients.
const READ_BATCH_SIZE = 8;
// Keep recent immutable snapshots so a device that is midway through a
// streamed download can finish even after another device publishes a change.
// A multi-megabyte snapshot can take a while to download on a phone. Keep
// enough previous revisions that ordinary edits on other devices cannot
// prune the snapshot while that response is still streaming.
const RETAIN_RECENT_SNAPSHOTS = 16;
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

async function readSnapshotInfo(env, snapshotId) {
  const info = await env.LRX_META.prepare(
    'SELECT COUNT(*) AS chunk_count, MIN(chunk_index) AS first_index, MAX(chunk_index) AS last_index FROM lrx_state_chunks WHERE snapshot_id = ?'
  ).bind(snapshotId).first();
  const count = Number(info?.chunk_count || 0);
  if (!count || Number(info.first_index) !== 0 || Number(info.last_index) !== count - 1) return null;
  return count;
}

async function readSnapshotBatch(env, snapshotId, startIndex) {
  const rows = await env.LRX_META.prepare(
    'SELECT chunk_index, chunk_data FROM lrx_state_chunks WHERE snapshot_id = ? AND chunk_index >= ? ORDER BY chunk_index LIMIT ?'
  ).bind(snapshotId, startIndex, READ_BATCH_SIZE).all();
  const chunks = rows.results || [];
  if (chunks.some((row, index) => Number(row.chunk_index) !== startIndex + index || typeof row.chunk_data !== 'string'))
    throw new Error('La copia compartida está incompleta.');
  return chunks;
}

async function pruneOldSnapshots(env, latestRevision) {
  const oldestRevisionToKeep = latestRevision - RETAIN_RECENT_SNAPSHOTS + 1;
  if (oldestRevisionToKeep <= 1) return;
  const snapshots = await env.LRX_META.prepare(
    'SELECT DISTINCT snapshot_id FROM lrx_state_chunks'
  ).all();
  for (const row of snapshots.results || []) {
    const snapshotId = String(row.snapshot_id || '');
    const revision = Number(snapshotId.slice(0, snapshotId.indexOf('-')));
    if (Number.isSafeInteger(revision) && revision > 0 && revision < oldestRevisionToKeep) {
      await env.LRX_META.prepare('DELETE FROM lrx_state_chunks WHERE snapshot_id = ?').bind(snapshotId).run();
    }
  }
}

function streamSnapshot(env, snapshotId, firstBatch, chunkCount, meta) {
  const encoder = new TextEncoder();
  let chunkIndex = 0;
  let batch = firstBatch;
  let batchOffset = 0;
  let started = false;
  const suffix = `,"revision":${Number(meta.revision)},"updatedAt":${JSON.stringify(meta.updated_at)}}`;
  const body = new ReadableStream({
    async pull(controller) {
      if (!started) {
        controller.enqueue(encoder.encode('{"payload":'));
        started = true;
        return;
      }
      if (batchOffset >= batch.length && chunkIndex < chunkCount) {
        batch = await readSnapshotBatch(env, snapshotId, chunkIndex);
        batchOffset = 0;
        if (!batch.length) throw new Error('La copia compartida está incompleta.');
      }
      if (chunkIndex < chunkCount) {
        const chunk = batch[batchOffset++];
        if (Number(chunk.chunk_index) !== chunkIndex || typeof chunk.chunk_data !== 'string')
          throw new Error('La copia compartida está incompleta.');
        controller.enqueue(encoder.encode(chunk.chunk_data));
        chunkIndex++;
        return;
      }
      controller.enqueue(encoder.encode(suffix));
      controller.close();
    }
  });
  return new Response(body, { headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } });
}

export async function onRequestGet({ env, request }) {
  const url = new URL(request.url);
  if (url.searchParams.get('revisionOnly') === '1') {
    const meta = await env.LRX_META.prepare(
      'SELECT revision, updated_at FROM lrx_state_meta WHERE singleton = 1'
    ).first();
    if (!meta) return json({ revision: 0, updatedAt: null });
    return json({ revision: Number(meta.revision), updatedAt: meta.updated_at });
  }
  // Keep large snapshots out of one Worker response. The browser fetches a
  // small manifest followed by bounded chunks, avoiding the 1102 resource
  // limit that a single 35 MB D1 read can trigger.
  if (url.searchParams.get('manifest') === '1') {
    const meta = await env.LRX_META.prepare(`
      SELECT meta.revision, meta.updated_at, meta.object_key,
             (SELECT COUNT(*) FROM lrx_state_chunks AS chunks WHERE chunks.snapshot_id = meta.object_key) AS chunk_count
      FROM lrx_state_meta AS meta
      WHERE meta.singleton = 1
    `).first();
    if (!meta) return json({ snapshotId: null, revision: 0, updatedAt: null, chunkCount: 0 });
    if (!Number(meta.chunk_count)) return json({ error: 'La copia compartida está incompleta; no se modificó nada.' }, 503);
    return json({ snapshotId: meta.object_key, revision: Number(meta.revision), updatedAt: meta.updated_at, chunkCount: Number(meta.chunk_count) });
  }
  if (url.searchParams.has('chunk')) {
    const index = Number(url.searchParams.get('chunk'));
    const snapshotId = url.searchParams.get('snapshot') || '';
    if (!Number.isSafeInteger(index) || index < 0 || !snapshotId)
      return json({ error: 'La solicitud de sincronización no es válida.' }, 400);
    const row = await env.LRX_META.prepare(`
      SELECT meta.revision, meta.updated_at, meta.object_key,
             chunks.chunk_index, chunks.chunk_data
      FROM lrx_state_meta AS meta
      LEFT JOIN lrx_state_chunks AS chunks
        ON chunks.snapshot_id = meta.object_key AND chunks.chunk_index = ?
      WHERE meta.singleton = 1 AND meta.object_key = ?
    `).bind(index, snapshotId).first();
    if (!row) return json({ error: 'La copia cambió mientras se descargaba; vuelve a sincronizar.' }, 409);
    if (row.chunk_index === null || typeof row.chunk_data !== 'string')
      return json({ error: 'La copia compartida está incompleta; no se modificó nada.' }, 503);
    return json({ snapshotId: row.object_key, revision: Number(row.revision), updatedAt: row.updated_at, index: Number(row.chunk_index), data: row.chunk_data });
  }
  const meta = await env.LRX_META.prepare('SELECT revision, object_key, updated_at FROM lrx_state_meta WHERE singleton = 1').first();
  if (!meta) return json({ payload: null, revision: 0, updatedAt: null });
  try {
    const chunkCount = await readSnapshotInfo(env, meta.object_key);
    if (!chunkCount) return json({ error: 'La copia de datos está incompleta; no se modificó nada.' }, 503);
    // Read the first small page before returning headers so setup errors become
    // a useful HTTP error instead of a generic network failure in Safari.
    const firstBatch = await readSnapshotBatch(env, meta.object_key, 0);
    if (!firstBatch.length) return json({ error: 'La copia de datos está incompleta; no se modificó nada.' }, 503);
    return streamSnapshot(env, meta.object_key, firstBatch, chunkCount, meta);
  } catch (error) {
    console.error('LRX snapshot read failed', error);
    return json({ error: 'No se pudo cargar la copia compartida. No se modificó ningún dato; vuelve a intentarlo con conexión estable.' }, 503);
  }
}

export async function onRequestPut({ request, env }) {
  if (Number(request.headers.get('Content-Length') || 0) > MAX_STATE_BYTES)
    return json({ error: 'La copia de datos supera el límite de 40 MB.' }, 413);
  let serialized;
  const revisionHeader = request.headers.get('X-LRX-Expected-Revision');
  let expected = revisionHeader === null ? Number.NaN : Number(revisionHeader);
  try { serialized = await request.text(); } catch { return json({ error: 'No se pudo leer la copia de datos.' }, 400); }

  // Accept older clients that send {expectedRevision, payload}, but unwrap the
  // JSON text without parsing or re-stringifying the entire multi-megabyte state.
  if (!Number.isSafeInteger(expected) || expected < 0) {
    const legacy = serialized.match(/^\{"expectedRevision":(\d+),"payload":/);
    if (!legacy || !serialized.endsWith('}')) return json({ error: 'Falta una copia de datos válida o su revisión.' }, 400);
    expected = Number(legacy[1]);
    serialized = serialized.slice(legacy[0].length, -1);
  }
  if (!Number.isSafeInteger(expected) || expected < 0 || serialized.length < 2 || serialized[0] !== '{' || serialized.at(-1) !== '}')
    return json({ error: 'Falta una copia de datos válida o su revisión.' }, 400);
  if (new TextEncoder().encode(serialized).byteLength > MAX_STATE_BYTES)
    return json({ error: 'La copia de datos supera el límite de 40 MB.' }, 413);

  const prior = await env.LRX_META.prepare('SELECT revision, object_key FROM lrx_state_meta WHERE singleton = 1').first();
  const current = Number(prior?.revision || 0);
  if (current !== expected) return json({ error: 'La copia compartida cambió. Actualiza antes de guardar.', revision: current }, 409);

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
  // Never delete the immediately previous snapshot here. A GET may already
  // have read its metadata and still be streaming later chunks to a phone or
  // tablet; deleting them mid-response makes Safari report a generic
  // "Load failed" / HTTP 503 and can trigger a false local-copy conflict.
  try { await pruneOldSnapshots(env, next); }
  catch (error) { console.warn('LRX old snapshot cleanup deferred', error); }
  return json({ revision: next, updatedAt: now });
}
