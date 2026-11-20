// Injected into every article iframe (not the main page). Reports its height,
// routes link clicks to the app, and supports double-click lookup.
(() => {
  if (window.top === window) return;
  if (!/^sgloss:$/.test(location.protocol)) return;
  const post = (m) => { try { parent.postMessage({ sg: m }, '*'); } catch (_) {} };
  const decode = (s) => { try { return decodeURIComponent(s); } catch (_) { return s; } };
  const byId = (id) => document.getElementById(id) || document.getElementsByName(id)[0];

  const norm = (s) => s.replace(/\s+/g, ' ').trim().toLowerCase();

  // `#{"id","find"}` in the frame's URL: where a followed link lands. The element
  // `id` (or the whole article), narrowed to the one whose text is exactly the
  // link's text ("above yourself" inside the entry `above_1`). Its position is
  // reported, again as late content shifts it, so the page can scroll there.
  let want = null;
  try { want = location.hash.length > 1 ? JSON.parse(decode(location.hash.slice(1))) : null; } catch (_) {}
  let target;
  let anchorY = null;

  // The smallest visible element under `root` whose text reads `hint`. Walks text
  // nodes and climbs only while the text still prefixes the hint, so it is linear.
  const findText = (root, hint) => {
    const w = norm(hint);
    if (!w) return null;
    const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      const d = norm(n.data);
      if (!d || !w.startsWith(d)) continue;
      for (let el = n.parentElement; el && root.contains(el); el = el.parentElement) {
        const t = norm(el.textContent);
        if (t === w) {
          if (el.getClientRects().length) return el;
          break;
        }
        if (!w.startsWith(t)) break;
      }
    }
    return null;
  };

  const locate = () => {
    if (target === undefined && want) {
      const root = want.id ? byId(want.id) : document.body;
      target = root ? (want.find && findText(root, want.find)) || root : null;
    }
    return target;
  };

  // The first rendered line of text inside `t`, in document coordinates.
  const firstLine = (t) => {
    const walk = document.createTreeWalker(t, NodeFilter.SHOW_TEXT,
      { acceptNode: (n) => (/\S/.test(n.data) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP) });
    const r = document.createRange();
    let line = null;
    for (let n = walk.nextNode(), k = 0; n && k < 64; n = walk.nextNode(), k++) {
      r.selectNodeContents(n);
      for (const b of r.getClientRects()) {
        if (!b.width || !b.height) continue;
        if (line && b.top >= line.t + (line.b - line.t) * 0.6) return line;
        line = line
          ? { l: Math.min(line.l, b.left), t: Math.min(line.t, b.top), r: Math.max(line.r, b.right), b: Math.max(line.b, b.bottom) }
          : { l: b.left, t: b.top, r: b.right, b: b.bottom };
      }
    }
    return line;
  };

  // ---------- find in entries ----------
  // The page's visible text is flattened once into a folded string (case, accents,
  // quote styles, soft hyphens and syllable dots folded away; whitespace collapsed;
  // a space between blocks) with a map back to text-node offsets. Each query is then
  // a plain indexOf over that string, and matches are painted with the CSS Custom
  // Highlight API: no DOM changes, no reflow of the dictionary's own markup.

  const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TITLE', 'HEAD']);
  const BLOCKS = 'address,article,aside,blockquote,dd,div,dl,dt,figcaption,figure,footer,form,'
    + 'h1,h2,h3,h4,h5,h6,header,hr,li,main,nav,ol,p,pre,section,table,td,th,tr,ul';
  const IGNORED = /[­​-‍⁠﻿·‧ˈˌ]/;
  const foldCache = new Map();
  const fold = (cp) => {
    if (cp < 128) {
      if (cp <= 32) return ' ';
      if (cp >= 65 && cp <= 90) return String.fromCharCode(cp + 32);
      return cp === 96 ? "'" : String.fromCharCode(cp);
    }
    let f = foldCache.get(cp);
    if (f === undefined) {
      const ch = String.fromCodePoint(cp);
      if (IGNORED.test(ch)) f = '';
      else if (/\s/.test(ch)) f = ' ';
      else {
        f = ch.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase()
          .replace(/[‘’‚‛ʼ′]/g, "'").replace(/[“”„‟″]/g, '"').replace(/[‐‑‒–—―−]/g, '-');
      }
      foldCache.set(cp, f);
    }
    return f;
  };
  const foldQuery = (q) => {
    let out = '';
    for (const ch of q) out += fold(ch.codePointAt(0));
    return out.replace(/ {2,}/g, ' ').replace(/^ /, '');
  };

  // One letter would light up most of a page: searching starts at two, except
  // for scripts where a single character is a word (CJK and the like).
  const searchable = (fq) => fq.length >= 2 || (fq.length === 1 && fq.codePointAt(0) >= 0x2e80);

  let index = null;
  const buildIndex = () => {
    const nodes = [];
    const parts = [];
    const nodeOf = [];
    const startOf = [];
    const endOf = [];
    let space = true;
    let block;
    let br = false;
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.nodeType === 1 && SKIP.has(n.tagName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      if (n.nodeType === 1) {
        if (n.tagName === 'BR') br = true;
        continue;
      }
      const data = n.data;
      if (!data) continue;
      const b = n.parentElement.closest(BLOCKS);
      if (b !== block || br) {
        if (!space) { parts.push(' '); nodeOf.push(-1); startOf.push(0); endOf.push(0); space = true; }
        block = b;
        br = false;
      }
      const ni = nodes.push(n) - 1;
      for (let i = 0; i < data.length;) {
        const cp = data.codePointAt(i);
        const w = cp > 0xffff ? 2 : 1;
        const f = fold(cp);
        if (f === ' ') {
          if (!space) { parts.push(' '); nodeOf.push(ni); startOf.push(i); endOf.push(i + w); space = true; }
        } else if (f) {
          parts.push(f);
          for (let k = 0; k < f.length; k++) { nodeOf.push(ni); startOf.push(i); endOf.push(i + w); }
          space = false;
        }
        i += w;
      }
    }
    return { text: parts.join(''), nodes, nodeOf, startOf, endOf };
  };
  try {
    // Text changes made by the dictionary's own scripts; our <style> in <head> is not one.
    new MutationObserver(() => { index = null; })
      .observe(document.body, { childList: true, subtree: true, characterData: true });
  } catch (_) {}

  const LIMIT = 2000;
  let matches = [];
  let ys = [];
  let findGen = -1;
  let current = -1;
  let hlAll = null;
  let hlCur = null;

  const ensureHighlights = () => {
    if (hlAll || !window.Highlight || !window.CSS || !CSS.highlights) return !!hlAll;
    hlAll = new Highlight();
    hlCur = new Highlight();
    hlCur.priority = 1;
    CSS.highlights.set('sg-find', hlAll);
    CSS.highlights.set('sg-find-current', hlCur);
    // The app's accent. Dictionaries that keep their own design are colour-inverted
    // in dark mode (invert .882, hue-rotate 180°), so they get the colours that
    // invert to the same accent.
    const foreign = document.body && document.body.classList.contains('sg-foreign');
    const s = document.createElement('style');
    s.textContent = `
      html { transition: opacity 160ms ease-out; }
      html.sg-nofind { opacity: 0.3; }
      ::highlight(sg-find) { background-color: rgba(196, 71, 27, 0.17); }
      ::highlight(sg-find-current) { background-color: #c4471b; color: #fff; }
      @media (prefers-color-scheme: dark) {
        ::highlight(sg-find) { background-color: ${foreign ? 'rgba(210, 57, 0, 0.3)' : 'rgba(255, 138, 92, 0.26)'}; }
        ::highlight(sg-find-current) { background-color: ${foreign ? 'rgb(210, 57, 0)' : '#ff8a5c'}; color: ${foreign ? '#fff' : '#1e1e1e'}; }
      }`;
    (document.head || document.documentElement).append(s);
    return true;
  };

  const reportFound = (fresh) => {
    if (!fresh) {
      const sy = window.scrollY;
      ys = matches.map((r) => Math.round(r.getBoundingClientRect().top + sy));
    }
    post({ type: 'found', gen: findGen, ys });
  };

  const runFind = (q, gen) => {
    findGen = gen;
    current = -1;
    matches = [];
    ys = [];
    if (hlAll) { hlAll.clear(); hlCur.clear(); }
    const fq = foldQuery(q || '');
    if (searchable(fq) && ensureHighlights()) {
      if (!index) index = buildIndex();
      const { text, nodes, nodeOf, startOf, endOf } = index;
      const sy = window.scrollY;
      for (let from = 0; matches.length < LIMIT;) {
        const s = text.indexOf(fq, from);
        if (s < 0) break;
        from = s + fq.length;
        let a = s;
        let b = s + fq.length - 1;
        while (a <= b && nodeOf[a] < 0) a++;
        while (b >= a && nodeOf[b] < 0) b--;
        if (a > b) continue;
        const r = new Range();
        r.setStart(nodes[nodeOf[a]], startOf[a]);
        r.setEnd(nodes[nodeOf[b]], endOf[b]);
        // One layout query per match: its position, and an empty box means hidden
        // text (a collapsed box), which is left out.
        const box = r.getBoundingClientRect();
        if (!box.width && !box.height) continue;
        matches.push(r);
        ys.push(Math.round(box.top + sy));
        hlAll.add(r);
      }
    }
    // Without a match this source recedes while finding.
    document.documentElement.classList.toggle('sg-nofind', searchable(fq) && hlAll !== null && matches.length === 0);
    reportFound(true);
  };

  const setCurrent = (i) => {
    current = i;
    if (!hlCur) return;
    hlCur.clear();
    if (i >= 0 && matches[i]) hlCur.add(matches[i]);
  };

  window.addEventListener('message', (e) => {
    if (e.source !== parent) return;
    const m = e.data && e.data.sg;
    if (!m) return;
    if (m.type === 'find') runFind(String(m.q || ''), m.gen);
    // The find line just opened: flatten the text now, while the first letters are typed.
    else if (m.type === 'prepare') { if (!index) index = buildIndex(); }
    else if (m.type === 'findCurrent') setCurrent(m.i);
  });

  let last = -1;
  const measure = () => {
    const de = document.documentElement;
    const b = document.body;
    const h = Math.ceil(Math.max(de.getBoundingClientRect().height, b ? b.scrollHeight : 0));
    if (h !== last) {
      last = h;
      post({ type: 'height', h });
      if (matches.length) reportFound(); // late images move the matches
    }
    const t = locate();
    if (t) {
      const y = Math.round(t.getBoundingClientRect().top + window.scrollY);
      if (y !== anchorY) {
        anchorY = y;
        const l = firstLine(t);
        const sy = window.scrollY;
        post({ type: 'anchor', y, mark: l && { x: l.l, y: l.t + sy, w: l.r - l.l, h: l.b - l.t } });
      }
    }
  };
  try { new ResizeObserver(measure).observe(document.documentElement); } catch (_) {}
  if (document.body) {
    try { new ResizeObserver(measure).observe(document.body); } catch (_) {}
  }
  window.addEventListener('load', measure);
  document.addEventListener('load', measure, true); // images
  measure();

  const soundOf = (a) => {
    const href = a.getAttribute('href') || '';
    return href.slice('sound://'.length);
  };
  const first = document.querySelector('a[href^="sound://"]');
  post({ type: 'ready', sound: first ? soundOf(first) : null });

  document.addEventListener('click', (e) => {
    if (e.defaultPrevented && !e.target.closest('a[href^="sound://"]')) return;
    const a = e.target.closest && e.target.closest('a[href]');
    if (!a) return;
    const href = a.getAttribute('href') || '';
    const lower = href.toLowerCase();
    if (lower.startsWith('sound://')) {
      e.preventDefault();
      post({ type: 'sound', path: soundOf(a) });
    } else if (lower.startsWith('entry://') || lower.startsWith('bword://')) {
      e.preventDefault();
      const target = href.slice(8);
      const hash = target.indexOf('#');
      const id = hash >= 0 ? decode(target.slice(hash + 1)) : '';
      // Anchors into this very article ("call_2#call_idmg_19" while reading "call").
      const t = id && byId(id);
      if (t || hash === 0) {
        if (t) t.scrollIntoView({ behavior: 'smooth' });
        return;
      }
      const word = decode(hash >= 0 ? target.slice(0, hash) : target).replace(/\/+$/, '');
      // What the reader clicked, to land on it ("↑Above and over" → "Above and over").
      const text = (a.textContent || '').replace(/\s+/g, ' ').trim().replace(/^[^\p{L}\p{N}(]+/u, '').slice(0, 120);
      if (word) post({ type: 'link', target: id ? word + '#' + id : word, text });
    } else if (/^(https?:|mailto:)/.test(lower)) {
      e.preventDefault();
      post({ type: 'open', url: a.href });
    } else if (href.startsWith('#') || href === '' || lower.startsWith('javascript:')) {
      // in-page anchors and script handlers behave normally
    } else {
      // Relative links to other files and unknown schemes would navigate away.
      e.preventDefault();
    }
  }, true);

  document.addEventListener('dblclick', (e) => {
    if (e.target.closest && e.target.closest('a, button, input, textarea, select')) return;
    const sel = String(window.getSelection() || '').trim().replace(/^[\s"'“‘(\[]+|[\s"'”’)\].,;:!?]+$/g, '');
    if (sel && sel.length <= 48 && sel.split(/\s+/).length <= 3) post({ type: 'lookup', word: sel });
  });

  // A press anywhere in an article: the page closes what floats over it.
  document.addEventListener('mousedown', (e) => {
    if (e.button === 0) post({ type: 'press' });
  }, true);

  // Typing while an article has focus goes back to the search field (or the find
  // line, which also takes Return and ⇧Return to step through matches). The arrows
  // keep their meaning there: ↑↓ between dictionaries, ⌥↑↓ along the related words.
  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey) return;
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !e.shiftKey) {
      post({ type: 'key', key: (e.altKey ? 'Alt' : '') + e.key });
      e.preventDefault();
      return;
    }
    if (e.altKey) return;
    if (e.key.length === 1 || e.key === 'Escape' || e.key === 'Enter') {
      post({ type: 'key', key: e.key === 'Enter' && e.shiftKey ? 'ShiftEnter' : e.key });
      e.preventDefault();
    }
  });
})();
