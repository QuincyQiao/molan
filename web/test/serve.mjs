// 开发用：本地起一个和扩展接口一样的服务，在浏览器里调样子。
// node test/serve.mjs [端口] [默认文档]   打开 http://127.0.0.1:端口/res/index.html?path=/绝对路径.md
import { createServer } from 'node:http';
import { readFileSync, statSync, existsSync } from 'node:fs';
import { join, dirname, extname, basename } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const dist = join(here, '..', 'dist');
const port = Number(process.argv[2] || 8792);
const fallbackDoc = process.argv[3] || join(dist, 'sample.md');
const home = homedir();
const settings = JSON.parse(process.env.MOLAN_SETTINGS || '{}');

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.woff2': 'font/woff2', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.md': 'text/plain; charset=utf-8' };

function stat(p) { try { return statSync(p); } catch { return null; } }

function resolveOne(base, c) {
  const tryPath = (p) => { const s = stat(p); return s ? { path: p, dir: s.isDirectory() } : null; };
  if (c.startsWith('/')) return tryPath(c);
  if (c.startsWith('~/')) return tryPath(join(home, c.slice(2)));
  let d = base;
  for (let i = 0; i < 16; i++) {
    const hit = tryPath(join(d, c));
    if (hit) return hit;
    if (d === home || d === '/') break;
    d = dirname(d);
  }
  return null;
}

function payload(path) {
  return { path, name: basename(path), dir: dirname(path), home, text: readFileSync(path, 'utf8'), settings };
}

createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const send = (code, body, type = 'text/plain') => { res.writeHead(code, { 'content-type': type }); res.end(body); };
  try {
    if (url.pathname === '/doc') {
      const p = url.searchParams.get('path') || fallbackDoc;
      if (!existsSync(p)) return send(404, 'not found');
      return send(200, JSON.stringify(payload(p)), 'application/json');
    }
    if (url.pathname === '/resolve') {
      const base = url.searchParams.get('base');
      const list = JSON.parse(url.searchParams.get('p') || '[]');
      return send(200, JSON.stringify(list.map((c) => resolveOne(base, c))), 'application/json');
    }
    const [, kind, ...rest] = url.pathname.split('/');
    const rel = decodeURIComponent(rest.join('/'));
    const file = kind === 'res' ? join(dist, rel) : kind === 'file' ? '/' + rel : null;
    if (!file || !stat(file)?.isFile()) return send(404, 'not found');
    send(200, readFileSync(file), TYPES[extname(file).toLowerCase()] || 'application/octet-stream');
  } catch (e) {
    send(500, String(e));
  }
}).listen(port, '127.0.0.1', () => console.log(`http://127.0.0.1:${port}/res/index.html`));
