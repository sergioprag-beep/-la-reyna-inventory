const COOKIE_NAME = 'lrx_session';

function fromBase64Url(value) {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '='));
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function toBase64Url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

async function signature(secret, expiresAt) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return toBase64Url(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`lrx-session:${expiresAt}`))));
}

function cookieValue(request) {
  const header = request.headers.get('Cookie') || '';
  const pair = header.split(';').map(item => item.trim()).find(item => item.startsWith(`${COOKIE_NAME}=`));
  return pair ? decodeURIComponent(pair.slice(COOKIE_NAME.length + 1)) : '';
}

async function hasSession(request, env) {
  const secret = env.LRX_APP_PASSWORD;
  if (!secret) return false;
  const [expiresAtText, supplied] = cookieValue(request).split('.');
  const expiresAt = Number(expiresAtText);
  if (!Number.isSafeInteger(expiresAt) || expiresAt <= Math.floor(Date.now() / 1000) || !supplied) return false;
  const expected = await signature(secret, expiresAt);
  const left = new TextEncoder().encode(supplied);
  const right = new TextEncoder().encode(expected);
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index++) diff |= left[index] ^ right[index];
  return diff === 0;
}

export async function onRequest(context) {
  const { request, env } = context;
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/api/')) return context.next();

  if (!env.LRX_APP_PASSWORD)
    return new Response(JSON.stringify({ error: 'El acceso seguro aún no está configurado.' }), { status: 503, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } });

  const authPath = url.pathname === '/api/auth';
  if (authPath && ((request.method === 'POST' && url.searchParams.get('action') === 'login') ||
      (request.method === 'GET' && url.searchParams.get('action') === 'session') ||
      (request.method === 'POST' && url.searchParams.get('action') === 'logout'))) return context.next();

  if (!await hasSession(request, env))
    return new Response(JSON.stringify({ error: 'La sesión terminó. Inicia sesión de nuevo.' }), { status: 401, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } });
  return context.next();
}

export { signature, hasSession };
