// Markdown → HTML。浏览器和 Node 自测共用这一份，不碰 DOM。
import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import taskLists from 'markdown-it-task-lists';
import mark from 'markdown-it-mark';
import alerts from 'markdown-it-github-alerts';
import frontMatter from 'markdown-it-front-matter';
import anchor from 'markdown-it-anchor';
import cjkBreaks from 'markdown-it-cjk-breaks';
import cjkFriendly from 'markdown-it-cjk-friendly';
import mathPluginModule from '@vscode/markdown-it-katex';
import hljs from 'highlight.js/lib/common';
import { load as loadYaml } from 'js-yaml';
import { resolvePath, fileURL, hasScheme } from './paths.js';

const esc = MarkdownIt().utils.escapeHtml;
const mathPlugin = mathPluginModule.default || mathPluginModule;

const LANG_ALIAS = { sh: 'bash', zsh: 'bash', shell: 'bash', console: 'bash', command: 'bash', py: 'python', js: 'javascript', mjs: 'javascript', ts: 'typescript', yml: 'yaml', md: 'markdown', jsonl: 'json', plist: 'xml', html: 'xml', svg: 'xml' };
const PLAIN = new Set(['', 'text', 'txt', 'plain', 'plaintext', 'srt', 'log', 'output']);

export function slugify(s) {
  return s.trim().toLowerCase()
    .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, '')
    .replace(/\s+/g, '-');
}

function build() {
  const md = MarkdownIt({ html: true, linkify: true, typographer: false, breaks: false });
  md.linkify.set({ fuzzyLink: false, fuzzyEmail: false, fuzzyIP: false });

  md.use(frontMatter, (raw) => { md.__frontMatter = raw; });
  md.use(footnote);
  md.use(taskLists, { enabled: false, label: true });
  md.use(mark);
  md.use(alerts, { titles: { note: '说明', tip: '提示', important: '重要', warning: '注意', caution: '警告' } });
  md.use(anchor, { slugify, tabIndex: false });
  md.use(cjkBreaks);
  md.use(cjkFriendly);
  md.use(mathPlugin, { enableFencedBlocks: true, throwOnError: false, strict: 'ignore' });
  md.use(wikiLinks);

  const rules = md.renderer.rules;
  const mathFence = rules.fence;
  rules.fence = (tokens, idx, options, env, self) => {
    const t = tokens[idx];
    const info = (t.info || '').trim();
    let lang = info.split(/\s+/)[0].toLowerCase();
    if (lang === 'math') { env.hasMath = true; return mathFence(tokens, idx, options, env, self); }
    if (lang === 'mermaid') {
      env.hasMermaid = true;
      return `<figure class="mermaid-wrap"><pre class="mermaid">${esc(t.content)}</pre></figure>\n`;
    }
    lang = LANG_ALIAS[lang] || lang;
    let body;
    if (!PLAIN.has(lang) && hljs.getLanguage(lang)) {
      try { body = hljs.highlight(t.content, { language: lang, ignoreIllegals: true }).value; } catch { body = esc(t.content); }
    } else {
      body = esc(t.content);
    }
    const label = info.split(/\s+/)[0];
    return `<div class="code"${label ? ` data-lang="${esc(label)}"` : ''}><pre><code>${body}</code></pre></div>\n`;
  };

  // 缩进四格的代码块，和围栏代码块一个样子
  rules.code_block = (tokens, idx) => `<div class="code"><pre><code>${esc(tokens[idx].content)}</code></pre></div>\n`;

  rules.table_open = () => '<div class="table-wrap"><table>\n';
  rules.table_close = () => '</table></div>\n';

  rules.image = (tokens, idx, options, env, self) => {
    const t = tokens[idx];
    const src = t.attrGet('src') || '';
    if (src && !hasScheme(src) && !src.startsWith('//')) {
      const abs = resolvePath(env.dir, safeDecode(src.split(/[?#]/)[0]), env.home);
      t.attrSet('src', fileURL(abs));
      t.attrSet('data-path', abs);
    }
    t.attrSet('loading', 'lazy');
    t.attrSet('alt', self.renderInlineAsText(t.children, options, env));
    return self.renderToken(tokens, idx, options);
  };

  const linkOpen = rules.link_open || ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));
  rules.link_open = (tokens, idx, options, env, self) => {
    const t = tokens[idx];
    const href = t.attrGet('href') || '';
    if (href && !href.startsWith('#') && !hasScheme(href)) {
      const [p, hash] = splitHash(href);
      if (p) {
        t.attrSet('data-local', resolvePath(env.dir, safeDecode(p), env.home));
        if (hash) t.attrSet('data-hash', safeDecode(hash));
      }
    }
    return linkOpen(tokens, idx, options, env, self);
  };

  // KaTeX 的样式和字体按需加载，这里只记一下用没用到
  const mathInline = rules.math_inline, mathBlock = rules.math_block;
  if (mathInline) rules.math_inline = (...a) => { a[3].hasMath = true; return mathInline(...a); };
  if (mathBlock) rules.math_block = (...a) => { a[3].hasMath = true; return mathBlock(...a); };

  return md;
}

// [[名字]]、[[名字|显示文字]]、![[图片.png]]：先画成待解析的链接，交给页面去找文件
function wikiLinks(md) {
  md.inline.ruler.before('link', 'wikilink', (state, silent) => {
    const src = state.src;
    let pos = state.pos;
    const embed = src.charCodeAt(pos) === 0x21;
    if (embed) pos++;
    if (src.charCodeAt(pos) !== 0x5B || src.charCodeAt(pos + 1) !== 0x5B) return false;
    const end = src.indexOf(']]', pos + 2);
    if (end < 0) return false;
    const inner = src.slice(pos + 2, end);
    if (!inner.trim() || /[\n[\]]/.test(inner)) return false;
    if (!silent) {
      const [target, alias] = inner.split('|');
      const t = state.push('html_inline', '', 0);
      t.content = embed
        ? `<img class="wiki-embed" data-wiki="${esc(target.trim())}" alt="${esc((alias || target).trim())}">`
        : `<a class="wikilink" data-wiki="${esc(target.trim())}">${esc((alias || target).trim())}</a>`;
    }
    state.pos = end + 2;
    return true;
  });
}

function splitHash(href) {
  const i = href.indexOf('#');
  return i < 0 ? [href, ''] : [href.slice(0, i), href.slice(i + 1)];
}

function safeDecode(s) {
  try { return decodeURIComponent(s); } catch { return s; }
}

function frontMatterCard(raw) {
  let data;
  try { data = loadYaml(raw); } catch { data = null; }
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return `<div class="front-matter"><pre>${esc(raw)}</pre></div>\n`;
  }
  const rows = Object.entries(data).map(([k, v]) => {
    let val;
    if (Array.isArray(v)) val = v.map((x) => `<span class="fm-tag">${esc(fmText(x))}</span>`).join('');
    else val = esc(fmText(v));
    return `<dt>${esc(k)}</dt><dd>${val}</dd>`;
  }).join('');
  return `<dl class="front-matter">${rows}</dl>\n`;
}

function fmText(v) {
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (v && typeof v === 'object') return JSON.stringify(v);
  return String(v ?? '');
}

let shared;
// 返回 { html, hasMath, hasMermaid, headings }
export function render(text, { dir = '/', home = '/' } = {}) {
  shared ||= build();
  shared.__frontMatter = null;
  const env = { dir, home, hasMath: false, hasMermaid: false };
  const tokens = shared.parse(text, env);
  const headings = [];
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type === 'heading_open') {
      const level = Number(t.tag.slice(1));
      const title = tokens[i + 1].children.filter((c) => c.type === 'text' || c.type === 'code_inline').map((c) => c.content).join('');
      headings.push({ level, id: t.attrGet('id'), title });
    }
  }
  let html = shared.renderer.render(tokens, shared.options, env);
  if (shared.__frontMatter) html = frontMatterCard(shared.__frontMatter) + html;
  return { html, hasMath: env.hasMath, hasMermaid: env.hasMermaid, headings };
}

