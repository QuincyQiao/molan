// 页面：取文档 → 渲染 → 补上路径链接、表格、公式样式、流程图、目录、查找、返回。
// 在扩展里跑在 molan:///res/index.html，开发时跑在 test/serve.mjs 起的本地服务上，接口一样。
import { render, slugify } from './render.js';
import { basename, fileURL } from './paths.js';

const $ = (sel, root = document) => root.querySelector(sel);
const doc = $('#doc');
const editor = $('#editor');
const previewPane = $('#preview-pane');
const divider = $('#divider');
const chrome = { back: $('#back'), backName: $('#back-name'), tocBtn: $('#toc-btn'), toc: $('#toc'), find: $('#find'), findInput: $('#find-input'), findCount: $('#find-count') };

const MD_EXT = /\.(md|markdown|mdown|mkd|mdx|mdc|qmd|rmd)$/i;
const BIG = 200_000;

let current = null;          // { path, dir, home, text, ... }
let editing = false;
let viewMode = 'read';
let dirty = false;
let savedScroll = 0;
let savedText = '';
let previewText = null;
let previewTimer = null;
let composing = false;
let saving = null;
let renderRevision = 0;
const history = [];          // [{ payload, scrollY }]
let headingObserver = null;
let tableObserver = null;
let mermaidSources = [];

function post(msg) {
  const h = window.webkit?.messageHandlers?.molan;
  if (h) { h.postMessage(msg); return true; }
  if (msg.type === 'open') window.open(msg.url, '_blank');
  return false;
}

function postAsync(msg) {
  const h = window.webkit?.messageHandlers?.molan;
  if (!h) return Promise.resolve(null);
  try { return Promise.resolve(h.postMessage(msg)); } catch { return Promise.resolve(null); }
}

async function getJSON(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r.json();
}

// ---------- 设置 ----------
function applySettings(s = {}) {
  const root = document.documentElement.style;
  if (s.fontSize) root.setProperty('--font-size', `${s.fontSize}px`);
  const widths = { narrow: '680px', medium: '780px', wide: '960px', full: 'none' };
  root.setProperty('--measure', widths[s.width] || widths.medium);
}

// ---------- 渲染 ----------
async function show(payload, { scrollY = 0, hash = '' } = {}) {
  clearTimeout(previewTimer);
  current = payload;
  editor.value = payload.text;
  editor.readOnly = !!payload.readOnly;
  $('#source-label').textContent = payload.readOnly ? '源码 · 只读' : '源码';
  savedText = editor.value;
  previewText = null;
  dirty = false;
  savedScroll = scrollY;
  setMode(payload.viewMode || viewMode, { focus: false });
  savedScroll = scrollY;
  editor.scrollTop = previewPane.scrollTop = 0;
  editor.setSelectionRange(0, 0);
  updateDirty();
  document.title = payload.name || basename(payload.path || '');
  const t0 = performance.now();
  renderPreview();
  updateBack();
  window.scrollTo(0, scrollY);
  if (hash) scrollToHash(hash, false);
  post({ type: 'location', path: payload.path });
  post({ type: 'rendered', ms: Math.round(performance.now() - t0) });
}

function renderPreview() {
  clearTimeout(previewTimer);
  if (!current || previewText === editor.value) return;
  const revision = ++renderRevision;
  previewText = editor.value;
  const scrollY = previewPane.scrollTop;
  const r = render(previewText, { dir: current.dir, home: current.home });
  doc.classList.toggle('big', r.html.length > BIG);
  doc.innerHTML = r.html;
  if (r.hasMath) loadStyle('katex/katex.min.css');
  enhanceCode();
  enhanceImages();
  watchTables();
  buildToc(r.headings);
  previewPane.scrollTop = scrollY;
  // 下面这些不挡第一屏
  mermaidSources = [];
  if (r.hasMermaid) renderMermaid(revision);
  linkPaths(revision);
}

// ---------- 编辑 ----------
function setMode(mode, { focus = true } = {}) {
  if (!current || !['read', 'edit', 'split'].includes(mode)) return;
  if (viewMode === 'read') savedScroll = window.scrollY;
  viewMode = mode;
  editing = mode !== 'read';
  document.body.classList.toggle('editing', editing);
  document.body.classList.toggle('split', mode === 'split');
  closeToc();
  closeFind();
  if (mode !== 'edit') renderPreview();
  if (mode === 'read') window.scrollTo(0, savedScroll);
  else if (focus) editor.focus({ preventScroll: true });
  doc.querySelectorAll('.table-wrap').forEach(layoutTable);
  post({ type: 'mode', mode, editing });
}

function updateDirty() {
  dirty = editor.value !== savedText;
  post({ type: 'dirty', dirty });
}

async function performSave(force = false) {
  if (!current || editor.readOnly) return false;
  if (!dirty) return true;
  const text = editor.value;
  const res = await postAsync({ type: 'save', text, force });
  if (!res) { window.alert('保存只在墨览 App 里可用。'); return false; }
  if (res.conflict && !force) {
    if (window.confirm('这个文件在磁盘上已经被别的程序改过。仍然保存并覆盖吗？')) return performSave(true);
    return false;
  }
  if (!res.ok) { window.alert(res.error || '保存失败。'); return false; }
  current.text = text;
  savedText = text;
  updateDirty();
  return true;
}

async function save() {
  if (saving) return saving;
  saving = performSave();
  try { return await saving; } finally { saving = null; }
}

async function saveAndRead() {
  if (await save()) setMode('read');
}

editor.addEventListener('input', () => {
  updateDirty();
  clearTimeout(previewTimer);
  if (viewMode === 'split' && !composing) {
    previewTimer = setTimeout(renderPreview, editor.value.length > BIG ? 800 : 250);
  }
});
editor.addEventListener('compositionstart', () => { composing = true; clearTimeout(previewTimer); });
editor.addEventListener('compositionend', () => {
  composing = false;
  editor.dispatchEvent(new Event('input'));
});

// Tab 不要跳走，缩进两个空格
editor.addEventListener('keydown', (e) => {
  if (editor.readOnly || e.isComposing || e.key !== 'Tab' || e.metaKey || e.ctrlKey || e.altKey) return;
  e.preventDefault();
  // execCommand 保留系统撤销栈，Tab 插入也可以用 ⌘Z 撤销。
  document.execCommand('insertText', false, '  ');
});

// 双栏分隔线：拖动调整，双击恢复一半，键盘左右键也可调整。
function resizeSource(percent) {
  const value = Math.max(20, Math.min(80, percent));
  document.documentElement.style.setProperty('--source-width', `${value}%`);
  divider.setAttribute('aria-valuenow', String(Math.round(value)));
  doc.querySelectorAll('.table-wrap').forEach(layoutTable);
}
divider.addEventListener('pointerdown', (e) => {
  divider.setPointerCapture(e.pointerId);
  document.body.classList.add('resizing');
});
divider.addEventListener('pointermove', (e) => {
  if (!divider.hasPointerCapture(e.pointerId)) return;
  resizeSource(e.clientX / document.documentElement.clientWidth * 100);
});
function stopResizing() { document.body.classList.remove('resizing'); }
divider.addEventListener('pointerup', stopResizing);
divider.addEventListener('lostpointercapture', stopResizing);
divider.addEventListener('dblclick', () => resizeSource(50));
divider.addEventListener('keydown', (e) => {
  if (!['ArrowLeft', 'ArrowRight', 'Home'].includes(e.key)) return;
  e.preventDefault();
  resizeSource(e.key === 'Home' ? 50 : Number(divider.getAttribute('aria-valuenow')) + (e.key === 'ArrowLeft' ? -5 : 5));
});

function loadStyle(href) {
  if (document.querySelector(`link[href="${href}"]`)) return;
  const l = document.createElement('link');
  l.rel = 'stylesheet';
  l.href = href;
  document.head.appendChild(l);
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${src}"]`);
    if (existing) { existing.dataset.loaded ? resolve() : existing.addEventListener('load', resolve); return; }
    const s = document.createElement('script');
    s.src = src;
    s.onload = () => { s.dataset.loaded = '1'; resolve(); };
    s.onerror = reject;
    document.head.appendChild(s);
  });
}

// ---------- 代码块 ----------
const COPY_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.25" y="5.25" width="8" height="8.5" rx="1.8"/><path d="M10.75 3.25v-.5a1.5 1.5 0 0 0-1.5-1.5h-5a1.5 1.5 0 0 0-1.5 1.5v6.5a1.5 1.5 0 0 0 1.5 1.5h.5"/></svg>';
const DONE_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>';

function enhanceCode() {
  for (const block of doc.querySelectorAll('.code')) {
    const btn = document.createElement('button');
    btn.className = 'copy';
    btn.innerHTML = COPY_ICON;
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      copyText(block.querySelector('code').innerText);
      btn.innerHTML = DONE_ICON;
      btn.classList.add('done');
      setTimeout(() => { btn.innerHTML = COPY_ICON; btn.classList.remove('done'); }, 1200);
    });
    block.appendChild(btn);
  }
}

function copyText(text) {
  if (post({ type: 'copy', text })) return;
  navigator.clipboard?.writeText(text);
}

// ---------- 图片 ----------
function enhanceImages() {
  for (const img of doc.querySelectorAll('img')) {
    img.addEventListener('error', () => {
      const ph = document.createElement('span');
      ph.className = 'img-missing';
      ph.textContent = img.alt || basename(img.dataset.path || img.src);
      img.replaceWith(ph);
    }, { once: true });
  }
}

// ---------- 表格 ----------
// 正文宽度放得下：表头吸顶。放不下：先撑到窗口宽度、居中；还放不下就在框里横向滚动，两边渐隐提示。
function watchTables() {
  tableObserver?.disconnect();
  tableObserver = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      tableObserver.unobserve(e.target);
      layoutTable(e.target);
    }
  }, { rootMargin: '1200px 0px' });
  doc.querySelectorAll('.table-wrap').forEach((w) => tableObserver.observe(w));
}

function layoutTable(wrap) {
  wrap.classList.remove('fits', 'wide', 'scroll');
  wrap.style.width = wrap.style.marginLeft = '';
  const table = wrap.firstElementChild;
  table.style.width = 'max-content';
  const natural = table.offsetWidth;
  table.style.width = '';
  if (natural <= wrap.clientWidth + 1) { wrap.classList.add('fits'); return; }
  const view = viewMode === 'split' ? previewPane.clientWidth : document.documentElement.clientWidth;
  const origin = viewMode === 'split' ? previewPane.getBoundingClientRect().left : 0;
  const width = Math.min(natural, view - 48);
  wrap.classList.add('wide');
  wrap.style.width = `${width}px`;
  wrap.style.marginLeft = `${origin + (view - width) / 2 - wrap.getBoundingClientRect().left}px`;
  if (viewMode === 'split') table.style.width = 'max-content';
  if (wrap.scrollWidth > wrap.clientWidth + 1) {
    wrap.classList.add('scroll');
    updateTableEdges(wrap);
    if (!wrap.dataset.edges) {
      wrap.dataset.edges = '1';
      wrap.addEventListener('scroll', () => updateTableEdges(wrap), { passive: true });
    }
  } else {
    wrap.classList.add('fits');
  }
}

function updateTableEdges(wrap) {
  wrap.classList.toggle('more-left', wrap.scrollLeft > 2);
  wrap.classList.toggle('more-right', wrap.scrollLeft + wrap.clientWidth < wrap.scrollWidth - 2);
}

let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    doc.querySelectorAll('.table-wrap').forEach((w) => {
      w.style.width = w.style.marginLeft = '';
      tableObserver?.observe(w);
    });
  }, 120);
});

// ---------- 反引号路径、[[维基链接]]：真有这个文件才变成链接 ----------
const PATH_LIKE = /^(~\/|\/|\.{1,2}\/)?[^\s`'"<>|*?:;,，。；、（）()]+$/;
const FILE_EXT = /\.[A-Za-z0-9]{1,8}$/;

function pathCandidate(text) {
  let t = text.trim().replace(/:\d+(:\d+)?$/, '');
  if (t.length < 3 || t.length > 300 || !PATH_LIKE.test(t)) return null;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(t)) return null;
  const hasSlash = t.includes('/');
  if (!hasSlash && !FILE_EXT.test(t)) return null;   // 单个词不是路径
  if (!hasSlash && /^\d/.test(t)) return null;        // 1.5.7 之类的版本号
  return t;
}

async function resolveAll(candidates) {
  const uniq = [...new Set(candidates)];
  const out = new Map();
  for (let i = 0; i < uniq.length; i += 40) {
    const chunk = uniq.slice(i, i + 40);
    const q = `/resolve?base=${encodeURIComponent(current.dir)}&p=${encodeURIComponent(JSON.stringify(chunk))}`;
    try {
      const res = await getJSON(q);
      chunk.forEach((c, k) => res[k] && out.set(c, res[k]));
    } catch { /* 查不到就当普通文字 */ }
  }
  return out;
}

async function linkPaths(revision = renderRevision) {
  const payload = current;
  const codes = [...doc.querySelectorAll('code')].filter((c) => !c.closest('pre, a'));
  const wikis = [...doc.querySelectorAll('[data-wiki]')];
  const cand = [];
  const codeCand = new Map();
  for (const c of codes) {
    const p = pathCandidate(c.textContent);
    if (p) { codeCand.set(c, p); cand.push(p); }
  }
  const wikiCand = new Map();
  for (const w of wikis) {
    const name = w.dataset.wiki.split('#')[0];
    const list = w.tagName === 'IMG' || FILE_EXT.test(name) ? [name] : [`${name}.md`, name];
    wikiCand.set(w, list);
    cand.push(...list);
  }
  if (!cand.length) return;
  const found = await resolveAll(cand);
  if (payload !== current || revision !== renderRevision) return;
  for (const [code, p] of codeCand) {
    const hit = found.get(p);
    if (!hit) continue;
    const a = document.createElement('a');
    a.className = 'path-link';
    a.dataset.local = hit.path;
    if (hit.dir) a.dataset.dir = '1';
    code.replaceWith(a);
    a.appendChild(code);
  }
  for (const [w, list] of wikiCand) {
    const hit = list.map((p) => found.get(p)).find(Boolean);
    if (!hit) { w.classList.add('missing'); continue; }
    if (w.tagName === 'IMG') w.src = fileURL(hit.path);
    else w.dataset.local = hit.path;
    const hash = w.dataset.wiki.split('#')[1];
    if (hash) w.dataset.hash = hash;
  }
}

// ---------- 流程图 ----------
let mermaidQueue = Promise.resolve();
async function renderMermaid(revision = renderRevision) {
  const nodes = [...doc.querySelectorAll('pre.mermaid')];
  mermaidSources = nodes.map((n) => n.textContent);
  try {
    await loadScript('mermaid.min.js');
    if (revision !== renderRevision) return;
    await drawMermaid();
  } catch (e) {
    nodes.forEach((n) => n.classList.add('failed'));
  }
}

async function drawMermaid() {
  const revision = renderRevision;
  const nodes = [...doc.querySelectorAll('pre.mermaid')];
  const sources = [...mermaidSources];
  mermaidQueue = mermaidQueue.catch(() => {}).then(async () => {
  if (revision !== renderRevision) return;
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  window.mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: dark ? 'dark' : 'neutral',
    fontFamily: getComputedStyle(document.body).fontFamily,
  });
  nodes.forEach((n, i) => { n.removeAttribute('data-processed'); n.textContent = sources[i]; });
  await window.mermaid.run({ nodes, suppressErrors: true });
  });
  return mermaidQueue;
}

matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (window.mermaid && mermaidSources.length) drawMermaid();
});

// ---------- 目录 ----------
function buildToc(headings) {
  headingObserver?.disconnect();
  const items = headings.filter((h) => h.level <= 3 && h.id);
  const enough = items.length >= 4;
  chrome.tocBtn.hidden = !enough;
  if (!enough) { closeToc(); chrome.toc.innerHTML = ''; return; }
  const minLevel = Math.min(...items.map((h) => h.level));
  chrome.toc.innerHTML = '<ol>' + items.map((h) =>
    `<li class="l${h.level - minLevel}"><a href="#${encodeURIComponent(h.id)}" data-id="${escAttr(h.id)}">${escHtml(h.title || h.id)}</a></li>`).join('') + '</ol>';
  const byId = new Map([...chrome.toc.querySelectorAll('a')].map((a) => [a.dataset.id, a]));
  let active = null;
  headingObserver = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const a = byId.get(e.target.id);
      if (!a || a === active) continue;
      active?.classList.remove('active');
      active = a;
      a.classList.add('active');
      if (!chrome.toc.hidden) a.scrollIntoView({ block: 'nearest' });
    }
  }, { rootMargin: '0px 0px -75% 0px' });
  for (const h of items) {
    const el = document.getElementById(h.id);
    if (el) headingObserver.observe(el);
  }
}

function openToc() {
  chrome.toc.hidden = false;
  chrome.tocBtn.classList.add('on');
  chrome.toc.querySelector('a.active')?.scrollIntoView({ block: 'center' });
}
function closeToc() {
  chrome.toc.hidden = true;
  chrome.tocBtn.classList.remove('on');
}
chrome.tocBtn.addEventListener('click', (e) => {
  e.stopPropagation();
  chrome.toc.hidden ? openToc() : closeToc();
});

const escHtml = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const escAttr = escHtml;

// ---------- 跳转 ----------
function scrollToHash(hash, smooth = true) {
  let id = hash.replace(/^#/, '');
  try { id = decodeURIComponent(id); } catch { /* 原样用 */ }
  const el = document.getElementById(id) || document.getElementById(slugify(id)) || document.getElementById(`user-content-${id}`);
  if (!el) return;
  const far = Math.abs(el.getBoundingClientRect().top) > innerHeight * 3;
  el.scrollIntoView({ behavior: smooth && !far ? 'smooth' : 'auto', block: 'start' });
}

async function openLocal(path, hash, isDir) {
  if (!isDir && MD_EXT.test(path)) {
    if (!await mayLeave()) return;
    try {
      const payload = await getJSON(`/doc?path=${encodeURIComponent(path)}`);
      history.push({ payload: current, scrollY: window.scrollY });
      closeToc();
      await show(payload, { hash });
      return;
    } catch { /* 读不了就交给访达 */ }
  }
  post({ type: 'reveal', path, dir: !!isDir });
}

async function mayLeave() {
  if (!dirty) return true;
  const res = await postAsync({ type: 'confirmNavigate' });
  return res?.ok === true;
}

async function goBack() {
  if (!await mayLeave()) return;
  const prev = history.pop();
  if (prev) show({ ...prev.payload, viewMode }, { scrollY: prev.scrollY });
}

function updateBack() {
  const prev = history[history.length - 1];
  chrome.back.hidden = !prev;
  if (prev) chrome.backName.textContent = basename(prev.payload.path).replace(MD_EXT, '');
}
chrome.back.addEventListener('click', goBack);

document.addEventListener('click', (e) => {
  if (!e.target.closest('#toc, #toc-btn')) closeToc();
  const a = e.target.closest('a');
  if (!a || e.target.closest('button')) return;
  const href = a.getAttribute('href') || '';
  if (a.dataset.local) {
    e.preventDefault();
    openLocal(a.dataset.local, a.dataset.hash || '', a.dataset.dir === '1');
  } else if (href.startsWith('#')) {
    e.preventDefault();
    if (a.closest('#toc')) closeToc();
    scrollToHash(href);
  } else if (/^(https?|mailto|ftp):/i.test(href)) {
    e.preventDefault();
    post({ type: 'open', url: a.href });
  } else if (href || a.classList.contains('wikilink')) {
    e.preventDefault();
  }
});

// ---------- 查找 ----------
let findTimer = null;
function openFind() {
  chrome.find.hidden = false;
  chrome.findInput.focus();
  chrome.findInput.select();
}
function closeFind() {
  chrome.find.hidden = true;
  chrome.findCount.textContent = '';
  window.getSelection()?.removeAllRanges();
}
function countMatches(q) {
  if (!q) return 0;
  const text = doc.innerText.toLowerCase();
  const needle = q.toLowerCase();
  let n = 0, i = 0;
  while ((i = text.indexOf(needle, i)) !== -1) { n++; i += needle.length; }
  return n;
}
function findNext(backwards = false) {
  const q = chrome.findInput.value;
  if (!q) return;
  const ok = window.find(q, false, backwards, true, false, false, false);
  chrome.find.classList.toggle('none', !ok);
  chrome.findInput.focus({ preventScroll: true });
}
chrome.findInput.addEventListener('input', () => {
  clearTimeout(findTimer);
  findTimer = setTimeout(() => {
    const q = chrome.findInput.value;
    const n = countMatches(q);
    chrome.findCount.textContent = q ? String(n) : '';
    chrome.find.classList.toggle('none', q && !n);
    window.getSelection()?.removeAllRanges();
    if (n) findNext();
  }, 120);
});
chrome.findInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); findNext(e.shiftKey); }
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFind(); }
});

document.addEventListener('keydown', (e) => {
  const cmd = e.metaKey || e.ctrlKey;
  if (editing) return;
  if (cmd && e.key === 'f') { e.preventDefault(); openFind(); }
  else if (cmd && e.key === 'g') { e.preventDefault(); findNext(e.shiftKey); }
  else if (cmd && (e.key === '[' || e.key === 'ArrowLeft') && history.length) { e.preventDefault(); goBack(); }
  else if (e.key === 'Escape' && !chrome.find.hidden) { e.preventDefault(); closeFind(); }
  else if (e.key === 'Escape' && !chrome.toc.hidden) { e.preventDefault(); closeToc(); }
});

// ---------- 启动 ----------
window.molan = {
  async boot() {
    const payload = await getJSON('/doc' + location.search);
    applySettings(payload.settings);
    await show(payload);
  },
  applySettings,
  find: openFind,
  back: goBack,
  open: (path) => openLocal(path, '', false),
  setMode,
  save,
  saveAndRead,
  editorText: () => editor.value,
};

window.molan.boot().catch((e) => {
  doc.innerHTML = `<p class="boot-error">${escHtml(String(e))}</p>`;
  post({ type: 'rendered', error: String(e) });
});
