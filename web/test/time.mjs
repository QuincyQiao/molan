// 用真文件量渲染时间：node test/time.mjs 文件…
import { readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { render } from '../src/render.js';
for (const f of process.argv.slice(2)) {
  const text = readFileSync(f, 'utf8');
  const t0 = performance.now();
  const r = render(text, { dir: dirname(f), home: process.env.HOME });
  const ms = performance.now() - t0;
  console.log(`${(text.length / 1024).toFixed(0).padStart(6)} K字符  ${ms.toFixed(0).padStart(5)} ms  html ${(r.html.length / 1024).toFixed(0)}K  标题 ${r.headings.length}  公式 ${r.hasMath}  ${f.split('/').slice(-2).join('/')}`);
}
