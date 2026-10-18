const MAX_FILE_BYTES = 20 * 1024 * 1024;
const CHUNK_BYTES = 1_500_000;
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }
});

function safePath(path) {
  const value = (Array.isArray(path) ? path.join('/') : String(path || '')).replace(/^\/+|\/+$/g, '');
  if (!value || value.split('/').some(part => !part || part === '.' || part === '..')) return '';
  return value;
}

export async function onRequestPost({ request, env, params }) {
  const path = safePath(params.path);
  if (!path) return json({ error: 'Ruta de archivo inválida.' }, 400);
  if (Number(request.headers.get('Content-Length') || 0) > MAX_FILE_BYTES)
    return json({ error: 'El archivo supera el límite de 20 MB.' }, 413);
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_FILE_BYTES) return json({ error: 'El archivo supera el límite de 20 MB.' }, 413);
  const contentType = request.headers.get('Content-Type') || 'application/octet-stream';
  const chunks = [];
  for (let offset = 0; offset < bytes.byteLength; offset += CHUNK_BYTES)
    chunks.push(bytes.slice(offset, Math.min(offset + CHUNK_BYTES, bytes.byteLength)));
  if (!chunks.length) chunks.push(new Uint8Array());
  await env.LRX_META.batch([
    env.LRX_META.prepare('DELETE FROM lrx_resources WHERE resource_path = ?').bind(path),
    ...chunks.map((chunk, index) => env.LRX_META.prepare(
      'INSERT INTO lrx_resources (resource_path, chunk_index, content_type, chunk_data) VALUES (?, ?, ?, ?)'
    ).bind(path, index, contentType, chunk.buffer))
  ]);
  return json({ path, size: bytes.byteLength });
}

export async function onRequestGet({ env, params }) {
  const path = safePath(params.path);
  if (!path) return json({ error: 'Ruta de archivo inválida.' }, 400);
  const first = await env.LRX_META.prepare(
    'SELECT content_type, chunk_data FROM lrx_resources WHERE resource_path = ? AND chunk_index = 0'
  ).bind(path).first();
  if (!first) return json({ error: 'No se encontró el archivo.' }, 404);
  let index = 0;
  const body = new ReadableStream({
    async pull(controller) {
      const row = index === 0 ? first : await env.LRX_META.prepare(
        'SELECT chunk_data FROM lrx_resources WHERE resource_path = ? AND chunk_index = ?'
      ).bind(path, index).first();
      if (!row) { controller.close(); return; }
      index++;
      controller.enqueue(new Uint8Array(row.chunk_data));
    }
  });
  const headers = new Headers({
    'Content-Type': first.content_type || 'application/octet-stream',
    'Cache-Control': 'private, no-store',
    'Content-Disposition': 'attachment'
  });
  return new Response(body, { headers });
}

export async function onRequestDelete({ env, params }) {
  const path = safePath(params.path);
  if (!path) return json({ error: 'Ruta de archivo inválida.' }, 400);
  await env.LRX_META.prepare('DELETE FROM lrx_resources WHERE resource_path = ?').bind(path).run();
  return new Response(null, { status: 204 });
}
