// 打包页面：src/ → dist/（index.html、molan.js、molan.css、katex/、mermaid.min.js）
// 用法：node build.mjs [--dev]   --dev 不压缩，方便调试
import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync, copyFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, 'src');
const dist = join(here, 'dist');
const nm = join(here, 'node_modules');
const dev = process.argv.includes('--dev');

rmSync(dist, { recursive: true, force: true });
mkdirSync(join(dist, 'katex', 'fonts'), { recursive: true });

await build({
  entryPoints: [join(src, 'main.js')],
  bundle: true,
  format: 'iife',
  target: 'safari16',
  minify: !dev,
  legalComments: 'none',
  outfile: join(dist, 'molan.js'),
  logLevel: 'warning',
});
await build({
  entryPoints: [join(src, 'style.css')],
  bundle: true,
  minify: !dev,
  target: 'safari16',
  outfile: join(dist, 'molan.css'),
  logLevel: 'warning',
});
copyFileSync(join(src, 'index.html'), join(dist, 'index.html'));
// mermaid 只用它打包好的这一个文件（12.2.0），单独存在 vendor/，免得装整个包（连依赖 200 多 MB）
copyFileSync(join(here, 'vendor', 'mermaid.min.js'), join(dist, 'mermaid.min.js'));
copyFileSync(join(nm, 'katex', 'dist', 'katex.min.css'), join(dist, 'katex', 'katex.min.css'));
for (const f of readdirSync(join(nm, 'katex', 'dist', 'fonts'))) {
  if (f.endsWith('.woff2')) copyFileSync(join(nm, 'katex', 'dist', 'fonts', f), join(dist, 'katex', 'fonts', f));
}
cpSync(join(here, 'sample.md'), join(dist, 'sample.md'));
console.log('页面已打包到 dist/');
