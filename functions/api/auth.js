import { hasSession, signature } from '../_middleware.js';

const COOKIE = 'lrx_session';
const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), {
  status,
  headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers }
});

function secureCookie(value, maxAge) {
  return `${COOKIE}=${encodeURIComponent(value)}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`;
}

function sameOrigin(request) {
  const origin = request.headers.get('Origin');
  return !origin || origin === new URL(request.url).origin;
}

function equalSecret(left, right) {
  const a = new TextEncoder().encode(String(left));
  const b = new TextEncoder().encode(String(right));
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let index = 0; index < a.length; index++) diff |= a[index] ^ b[index];
  return diff === 0;
}

export async function onRequest({ request, env }) {
  const action = new URL(request.url).searchParams.get('action');
  if (action === 'session' && request.method === 'GET') return json({ authenticated: await hasSession(request, env) });
  if (!sameOrigin(request)) return json({ error: 'Solicitud no válida.' }, 403);
  if (action === 'logout' && request.method === 'POST') return json({ authenticated: false }, 200, { 'Set-Cookie': secureCookie('', 0) });
  if (action !== 'login' || request.method !== 'POST') return json({ error: 'Ruta no encontrada.' }, 404);
  let body;
  try { body = await request.json(); } catch { return json({ error: 'Solicitud no válida.' }, 400); }
  if (typeof body?.password !== 'string' || !equalSecret(body.password, env.LRX_APP_PASSWORD))
    return json({ error: 'La contraseña no coincide.' }, 401);
  const expiresAt = Math.floor(Date.now() / 1000) + 12 * 60 * 60;
  const token = `${expiresAt}.${await signature(env.LRX_APP_PASSWORD, expiresAt)}`;
  return json({ authenticated: true }, 200, { 'Set-Cookie': secureCookie(token, 12 * 60 * 60) });
}
