/**
 * URL privacy sanitizer & sensitive-domain blocklist.
 * Mirrors Context Hub v2 `anchors.py` + `privacy.py` rules so tracking parameters,
 * auth tokens, and banking/password-manager sites are never captured.
 */

const STRIP_PARAM_EXACT = new Set([
  'fbclid',
  'gclid',
  'dclid',
  'msclkid',
  'mc_cid',
  'mc_eid',
  'yclid',
  'spm',
  'from',
  'isappinstalled',
  'ref',
  'ref_src',
  'ref_url',
  'token',
  'access_token',
  'refresh_token',
  'id_token',
  'auth',
  'code',
  'state',
  'session',
  'session_id',
  'sig',
  'signature',
  'key',
  'api_key',
  'apikey',
  'secret',
  'password',
  'pwd',
]);

const DEFAULT_BLOCKED_DOMAINS = [
  'localhost',
  '127.0.0.1',
  '::1',
  'accounts.google.com',
  'login.microsoftonline.com',
  'login.live.com',
  'appleid.apple.com',
  'idmsa.apple.com',
  '1password.com',
  'bitwarden.com',
  'vault.bitwarden.com',
  'lastpass.com',
  'dashlane.com',
  'paypal.com',
  'alipay.com',
  'tenpay.com',
  'chase.com',
  'bankofamerica.com',
  'icbc.com.cn',
  'cmbchina.com',
  'ccb.com',
  'abchina.com',
  'boc.cn',
];

const SECRET_RE =
  /(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{25,}|gho_[A-Za-z0-9]{25,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/g;

export function canonicalizeUrl(rawUrl: string): string {
  const parsed = new URL(rawUrl);
  const host = parsed.hostname.toLowerCase();
  const kept: Array<[string, string]> = [];
  for (const [k, v] of parsed.searchParams.entries()) {
    const kl = k.toLowerCase();
    if (kl.startsWith('utm_') || STRIP_PARAM_EXACT.has(kl)) {
      continue;
    }
    kept.push([k, v]);
  }
  kept.sort((a, b) => (a[0] === b[0] ? a[1].localeCompare(b[1]) : a[0].localeCompare(b[0])));
  const search = new URLSearchParams(kept).toString();
  let pathname = parsed.pathname || '/';
  if (pathname.length > 1 && pathname.endsWith('/')) {
    pathname = pathname.slice(0, -1);
  }
  const port = parsed.port ? `:${parsed.port}` : '';
  return `${parsed.protocol}//${host}${port}${pathname}${search ? `?${search}` : ''}`;
}

export function isDomainBlocked(rawUrl: string, userBlocked: string[] = []): boolean {
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return true;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return true;
  }
  const host = parsed.hostname.toLowerCase();
  if (!host || host.endsWith('.local')) {
    return true;
  }
  if (/(?:^|\.)(?:bank|ebank|onlinebanking|sso|oauth|auth|signin|login)\./.test(host)) {
    return true;
  }
  const combined = [...DEFAULT_BLOCKED_DOMAINS, ...userBlocked.map((d) => d.trim().toLowerCase())];
  for (const rule of combined) {
    if (!rule) continue;
    if (host === rule || host.endsWith(`.${rule}`)) {
      return true;
    }
  }
  return false;
}

export function redactInlineSecrets(text: string): string {
  return text.replace(SECRET_RE, '[REDACTED_SECRET]');
}
