const ACCESS_KEYS = new Map();

function base64UrlToBytes(value) {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '='));
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function decodePart(value) {
  return JSON.parse(new TextDecoder().decode(base64UrlToBytes(value)));
}

async function accessKeySet(teamDomain) {
  const cached = ACCESS_KEYS.get(teamDomain);
  if (cached && cached.expiresAt > Date.now()) return cached.keys;
  const response = await fetch(`https://${teamDomain}/cdn-cgi/access/certs`, { cf: { cacheTtl: 300 } });
  if (!response.ok) throw new Error('No se pudieron consultar las llaves de acceso de Cloudflare.');
  const body = await response.json();
  const keys = new Map((body.keys || []).map(key => [key.kid, key]));
  ACCESS_KEYS.set(teamDomain, { keys, expiresAt: Date.now() + 5 * 60_000 });
  return keys;
}

async function verifyAccessToken(token, env) {
  if (!env.LRX_ACCESS_TEAM_DOMAIN || !env.LRX_ACCESS_AUD)
    throw new Error('Falta configurar la protección de acceso de LRX.');
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return false;
  const header = decodePart(parts[0]);
  const claims = decodePart(parts[1]);
  const teamDomain = String(env.LRX_ACCESS_TEAM_DOMAIN).replace(/^https:\/\//, '').replace(/\/$/, '');
  const issuer = `https://${teamDomain}`;
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  const now = Math.floor(Date.now() / 1000);
  if (claims.iss !== issuer || !audiences.includes(env.LRX_ACCESS_AUD) || !claims.exp || claims.exp <= now || (claims.nbf && claims.nbf > now)) return false;
  const jwk = (await accessKeySet(teamDomain)).get(header.kid);
  if (!jwk || header.alg !== 'RS256') return false;
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  return crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, base64UrlToBytes(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
}

export async function onRequest(context) {
  try {
    const token = context.request.headers.get('Cf-Access-Jwt-Assertion');
    if (!await verifyAccessToken(token, context.env))
      return new Response('Se requiere una sesión de acceso autorizada para LRX.', { status: 401, headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    console.error('LRX Access verification failed', error);
    return new Response('No se pudo verificar el acceso a LRX.', { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
  return context.next();
}
