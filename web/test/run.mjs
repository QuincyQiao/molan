// 渲染自测：几条写法逐条核对；设了 MOLAN_TEST_ROOT 再抽那个文件夹里的真文件跑一遍不报错。node test/run.mjs
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { render } from '../src/render.js';

const home = homedir();
const r = (t, dir = '/Users/x/notes') => render(t, { dir, home: '/Users/x' }).html;
const cases = [
  ['中文粗体', r('**目前能回答“哪些”。**公开资料'), '<strong>目前能回答“哪些”。</strong>公开资料'],
  ['中文斜体', r('中文*斜体*中文'), '<em>斜体</em>'],
  ['中文软换行不留空格', r('第一行\n第二行'), '第一行第二行'],
  ['表格包一层', r('| a | b |\n|--|--|\n| 1 | 2 |'), '<div class="table-wrap"><table>'],
  ['YAML 头成卡片', r('---\ntitle: 测试\ntags: [甲, 乙]\n---\n# 正文'), '<dl class="front-matter"><dt>title</dt><dd>测试</dd>'],
  ['提示框中文标题', r('> [!NOTE]\n> 内容'), '说明'],
  ['高亮', r('==重点=='), '<mark>重点</mark>'],
  ['任务列表', r('- [x] 完成'), 'task-list-item-checkbox'],
  ['维基链接', r('见 [[写稿|写稿规范]]'), 'data-wiki="写稿">写稿规范</a>'],
  ['图片换成本地地址', r('![图](../img/a.png)'), 'src="/file/Users/x/img/a.png"'],
  ['家目录图片', r('![图](~/p/a.png)'), 'src="/file/Users/x/p/a.png"'],
  ['相对 md 链接', r('[另一篇](sub/b.md#第二节)'), 'data-local="/Users/x/notes/sub/b.md" data-hash="第二节"'],
  ['文件名不当网址', r('看 README.md 和 写稿.md'), '<p>看 README.md 和 写稿.md</p>'],
  ['网址照样变链接', r('见 https://example.com/a'), '<a href="https://example.com/a">'],
  ['行内公式', r('比例 $c = m/V$。'), 'class="katex"'],
  ['块公式', r('$$\n\\int_0^1 x\\,dx\n$$'), 'katex-display'],
  ['货币不当公式', r('售价 $5，后来 $10'), '售价 $5，后来 $10'],
  ['流程图', r('```mermaid\ngraph LR\nA-->B\n```'), '<pre class="mermaid">graph LR'],
  ['代码高亮和别名', r('```sh\necho hi\n```'), 'class="hljs-built_in">echo</span>'],
  ['缩进代码块', r('正文\n\n    栏目/  立了项的期\n'), '<div class="code"><pre><code>栏目/'],
  ['标题锚点', r('## 两种 墨'), 'id="两种-墨"'],
  ['脚注', r('正文[^1]\n\n[^1]: 注'), 'footnote-ref'],
];

let failed = 0;
for (const [name, html, want] of cases) {
  if (!html.includes(want)) {
    failed++;
    console.log(`✗ ${name}\n  想要：${want}\n  实际：${html.slice(0, 300)}`);
  }
}

// 真文件：抽一批跑，不能抛错
const root = process.env.MOLAN_TEST_ROOT;
let real = 0, slowest = [0, ''];
if (root && existsSync(root)) {
  const files = [];
  const walk = (d, depth) => {
    if (depth > 7 || files.length > 4000) return;
    let entries;
    try { entries = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.name.startsWith('.') || e.name === 'node_modules' || e.name.endsWith('.noindex')) continue;
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p, depth + 1);
      else if (e.name.endsWith('.md')) files.push(p);
    }
  };
  walk(root, 0);
  const step = Math.max(1, Math.floor(files.length / 400));
  for (let i = 0; i < files.length; i += step) {
    const f = files[i];
    try {
      if (statSync(f).size > 3_000_000) continue;
      const t0 = performance.now();
      render(readFileSync(f, 'utf8'), { dir: dirname(f), home });
      const ms = performance.now() - t0;
      if (ms > slowest[0]) slowest = [ms, f];
      real++;
    } catch (e) {
      failed++;
      console.log(`✗ 渲染出错 ${f}\n  ${e.stack?.split('\n').slice(0, 3).join('\n  ')}`);
    }
  }
}

if (failed) {
  console.log(`渲染自测：${failed} 条没过`);
  process.exit(1);
}
console.log(`渲染自测通过：${cases.length} 条写法${real ? `，${real} 份真文件（最慢 ${slowest[0].toFixed(0)} ms）` : ''}`);
