// 路径工具：页面里的相对路径都换成绝对路径，再交给 /file、/doc 去读
export function hasScheme(s) {
  return /^[a-z][a-z0-9+.-]*:/i.test(s);
}

export function normalize(p) {
  const out = [];
  for (const part of p.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') out.pop();
    else out.push(part);
  }
  return '/' + out.join('/');
}

export function resolvePath(dir, p, home) {
  if (p.startsWith('/')) return normalize(p);
  if (p === '~' || p.startsWith('~/')) return normalize(home + p.slice(1));
  return normalize(dir + '/' + p);
}

export function dirname(p) {
  const i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.slice(0, i);
}

export function basename(p) {
  return p.slice(p.lastIndexOf('/') + 1);
}

export function fileURL(abs) {
  return '/file' + abs.split('/').map(encodeURIComponent).join('/');
}
