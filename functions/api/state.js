const MAX_STATE_BYTES = 40 * 1024 * 1024;
const CHUNK_CHARS = 400_000;
const INSERT_BATCH_SIZE = 8;
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

async function readSnapshot(env) {
  // Read the active revision pointer and chunks in one D1 statement. Separate
  // reads can race a PUT that switches the pointer and removes the old chunks.
  const rows = await env.LRX_META.prepare(`
    SELECT meta.revision, meta.updated_at, meta.object_key,
           chunks.chunk_index, chunks.chunk_data
    FROM lrx_state_meta AS meta
    LEFT JOIN lrx_state_chunks AS chunks ON chunks.snapshot_id = meta.object_key
    WHERE meta.singleton = 1
    ORDER BY chunks.chunk_index
  `).all();
  if (!rows.results?.length) return { meta: null, chunks: null };
  const first = rows.results[0];
  const meta = { revision: Number(first.revision), updated_at: first.updated_at, object_key: first.object_key };
  if (!first.chunk_data || first.chunk_index === null) return { meta, chunks: null };
  if (rows.results.some((row, index) => Number(row.chunk_index) !== index || typeof row.chunk_data !== 'string'))
    return { meta, chunks: null };
  return { meta, chunks: rows.results };
}

function streamSnapshot(chunks, meta) {
  const encoder = new TextEncoder();
  let index = 0;
  const suffix = `,"revision":${Number(meta.revision)},"updatedAt":${JSON.stringify(meta.updated_at)}}`;
  const body = new ReadableStream({
    pull(controller) {
      if (index === 0) {
        controller.enqueue(encoder.encode('{"payload":'));
        index++;
        return;
      }
      const chunkIndex = index - 1;
      if (chunkIndex < chunks.length) {
        controller.enqueue(encoder.encode(chunks[chunkIndex].chunk_data));
        index++;
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
  // Large snapshots exceeded Pages Functions' per-request resource budget when
  // D1 returned every 400 KB row in one query. Read one row at a time instead.
  if (url.searchParams.get('manifest') === '1') {
    const meta = await env.LRX_META.prepare(`
      SELECT meta.revision, meta.updated_at, meta.object_key,
             (SELECT COUNT(*) FROM lrx_state_chunks AS chunks WHERE chunks.snapshot_id = meta.object_key) AS chunk_count
      FROM lrx_state_meta AS meta
      WHERE meta.singleton = 1
    `).first();
    if (!meta) return json({ snapshotId: null, revision: 0, updatedAt: null, chunkCount: 0 });
    if (!Number(meta.chunk_count)) return json({ error: 'La copia compartida está incompleta; no se modificó nada.' }, 503);
    return json({ snapshotId: meta.object_key, revision: Number(meta.revision), updatedAt: meta.updated_at, chunkCount: Number(meta.chunk_count || 0) });
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
  const { meta, chunks } = await readSnapshot(env);
  if (!meta) return json({ payload: null, revision: 0, updatedAt: null });
  if (!chunks) return json({ error: 'La copia de datos está incompleta; no se modificó nada.' }, 503);
  return streamSnapshot(chunks, meta);
}

export async function onRequestPut({ request, env }) {
  const contentLength = Number(request.headers.get('Content-Length') || 0);
  if (contentLength > MAX_STATE_BYTES)
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
  if (!contentLength && new TextEncoder().encode(serialized).byteLength > MAX_STATE_BYTES)
    return json({ error: 'La copia de datos supera el límite de 40 MB.' }, 413);

  const prior = await env.LRX_META.prepare('SELECT revision, object_key FROM lrx_state_meta WHERE singleton = 1').first();
  const current = Number(prior?.revision || 0);
  if (current !== expected) return json({ error: 'La copia compartida cambió. Actualiza antes de guardar.', revision: current }, 409);

  const next = current + 1;
  const now = new Date().toISOString();
  const snapshotId = `${next}-${crypto.randomUUID()}`;
  const chunks = splitText(serialized);
  try {
    // Keep each D1 batch small. Large phone/laptop merges can contain dozens
    // of chunks; stage them in groups and publish the pointer only after all
    // groups have been written successfully.
    for (let offset = 0; offset < chunks.length; offset += INSERT_BATCH_SIZE) {
      const batch = chunks.slice(offset, offset + INSERT_BATCH_SIZE);
      await env.LRX_META.batch(batch.map((chunk, index) => env.LRX_META.prepare(
        'INSERT INTO lrx_state_chunks (snapshot_id, chunk_index, chunk_data) VALUES (?, ?, ?)'
      ).bind(snapshotId, offset + index, chunk)));
    }
  } catch (error) {
    try { await env.LRX_META.prepare('DELETE FROM lrx_state_chunks WHERE snapshot_id = ?').bind(snapshotId).run(); }
    catch (cleanupError) { console.error('LRX incomplete snapshot cleanup failed', cleanupError); }
    console.error('LRX snapshot staging failed', error);
    return json({ error: 'No se pudo completar la copia. La versión compartida anterior sigue intacta; vuelve a intentarlo.' }, 503);
  }

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
