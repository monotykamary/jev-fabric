import { test, expect, beforeAll, afterAll } from 'bun:test';
import { rmSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { capture, expectFixture, tempRoot } from './helpers.ts';

const dir = tempRoot('native-tls-');
const keyFile = join(dir, 'key.pem');
const certFile = join(dir, 'cert.pem');
const unreachableProxy = 'http://127.0.0.1:1';
let server: ReturnType<typeof Bun.serve>;
const requests: { path: string; auth: string | null; body: string }[] = [];
const body = JSON.stringify({
  state: 'quotes " slashes \\ newline\n tab\t emoji 🙂; \\nurl = https://invalid.test/',
});

function selfSignedLocalhost() {
  const p = Bun.spawnSync([
    'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', keyFile, '-out', certFile, '-days', '1',
    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
  ], { stdout: 'ignore', stderr: 'pipe' });
  expect(p.exitCode, p.stderr.toString()).toBe(0);
}

async function respond(req: Request) {
  const path = new URL(req.url).pathname;
  requests.push({ path, auth: req.headers.get('authorization'), body: await req.text() });
  if (path === '/redirect') {
    const location = `https://localhost:${server.port}/unexpected`;
    return new Response('', { status: 302, headers: { location } });
  }
  if (path === '/huge') return new Response('x'.repeat(1048577));
  if (path === '/error') return new Response('SYNTHETIC_NOT_A_SECRET', { status: 401 });
  if (path === '/slow') await Bun.sleep(2500);
  return new Response('ok');
}

beforeAll(() => {
  selfSignedLocalhost();
  expectFixture('http');
  server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    tls: { key: Bun.file(keyFile), cert: Bun.file(certFile) },
    fetch: respond,
  });
}, 100000);
afterAll(() => {
  server?.stop(true);
  rmSync(dir, { recursive: true, force: true });
});

async function run(path: string, trust = true, host = 'localhost', input = body) {
  const url = `https://${host}:${server.port}${path}`;
  const env = {
    PATH: '/usr/bin:/bin',
    ...(trust ? { CURL_CA_BUNDLE: certFile } : {}),
    HTTPS_PROXY: unreachableProxy,
    ALL_PROXY: unreachableProxy,
  };
  const { out, err, code } = await capture([resolve('build/test-http'), '--', url, input], { env });
  expect(code, err).toBe(0);
  expect(out + err).not.toContain('SYNTHETIC_NOT_A_SECRET');
  return out.trim();
}

test('native HTTPS verifies trusted TLS and preserves private config/body literally', async () => {
  expect(await run('/ok')).toBe('ok:2');
  const req = requests.at(-1)!;
  expect(req.auth).toBe('Bearer SYNTHETIC_NOT_A_SECRET');
  expect(req.body).toBe(body);
});

test('unknown CA and wrong hostname fail closed', async () => {
  const n = requests.length;
  expect(await run('/untrusted', false)).toBe('error');
  expect(await run('/mismatch', true, '127.0.0.1')).toBe('error');
  expect(requests.length).toBe(n);
});

test('redirect is not followed and status errors never expose body', async () => {
  expect(await run('/redirect')).toBe('error');
  expect(requests.some(r => r.path === '/unexpected')).toBe(false);
  expect(await run('/error')).toBe('error');
});

test('body bounds and network deadline are enforced', async () => {
  expect(await run('/huge')).toBe('error');
  const start = Date.now();
  expect(await run('/slow')).toBe('error');
  expect(Date.now() - start).toBeLessThan(2300);
});

test('curl data-file syntax rejected before network', async () => {
  const n = requests.length;
  expect(await run('/file', true, 'localhost', '@/etc/passwd')).toBe('error');
  expect(requests.length).toBe(n);
});
