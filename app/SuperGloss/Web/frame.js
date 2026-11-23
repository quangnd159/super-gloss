// Injected into every article iframe (not the main page). Reports its height,
// routes link clicks to the app, and supports looking up a word by double-click or
// right-click.
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

  // ---------- direction ----------
  // Arabic, Hebrew and Persian read right to left. An entry takes the direction most of
  // its letters have; inside it, a paragraph of some length in the other direction turns,
  // a lone word (a headword, a gloss) keeps the entry's. Where a dictionary says (dir),
  // it is left alone.
  const RTL_SCRIPT = /[\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Syriac}\p{Script=Thaana}\p{Script=Nko}]/gu;
  const orient = () => {
    const letters = new Map(); // block → [right-to-left, other]
    const add = (map, k, [r, o]) => {
      const c = map.get(k) || map.set(k, [0, 0]).get(k);
      c[0] += r;
      c[1] += o;
    };
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      const p = n.parentElement;
      const block = p && !SKIP.has(p.tagName) && p.closest(BLOCKS);
      if (!block) continue;
      const all = (n.data.match(/\p{L}/gu) || []).length;
      if (!all) continue;
      const rtl = (n.data.match(RTL_SCRIPT) || []).length;
      add(letters, block, [rtl, all - rtl]);
    }
    const ruled = (b) => b.closest('[dir]');
    const entries = new Map();
    for (const [b, c] of letters) add(entries, b.closest('.sg-entry') || document.body, c);
    const dir = new Map();
    for (const [e, [r, o]] of entries) if (!ruled(e)) dir.set(e, r > o ? 'rtl' : 'ltr');
    // Ancestors before descendants, so each block knows the direction it inherits.
    const blocks = [...letters.keys()].filter((b) => !dir.has(b) && !ruled(b))
      .sort((x, y) => (x.compareDocumentPosition(y) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
    for (const [e, d] of dir) if (d === 'rtl') e.dir = d;
    for (const b of blocks) {
      const [r, o] = letters.get(b);
      let up = b.parentElement;
      while (up && !dir.has(up)) up = up.parentElement;
      const inherited = up ? dir.get(up) : 'ltr';
      const own = r + o >= 16 ? (r > o ? 'rtl' : 'ltr') : inherited;
      dir.set(b, own);
      if (own !== inherited) b.dir = own;
    }
  };
  if (document.body && new RegExp(RTL_SCRIPT.source, 'u').test(document.body.textContent)) orient();

  // ---------- viewport units ----------
  // The frame is as tall as its content, so a height in vh is measured against the content
  // that holds it: each height reported grows the next, without end. And vw spans the
  // gutters on both sides of the column (article.css). Where either shows, the
  // dictionary's viewport units are rewritten to the window's height and the column's
  // width, what they meant where it was made. Nothing is walked until then.
  const UNITS = /(-?(?:\d+\.?\d*|\.\d+))(?:s|l|d)?(vh|vw|vmin|vmax|vb|vi)\b/g;
  const HAS_UNITS = /\d(?:s|l|d)?(?:vh|vw|vmin|vmax|vb|vi)\b/;
  const AXIS = { vb: 'vh', vi: 'vw' };
  const pinned = new WeakSet();
  let pinnedInline = false;
  let unitsPinned = false;
  const pinStyle = (style) => {
    const props = [];
    for (let i = 0; i < style.length; i++) if (HAS_UNITS.test(style.getPropertyValue(style[i]))) props.push(style[i]);
    for (const p of props) {
      const v = style.getPropertyValue(p).replace(UNITS, (_, n, u) => `calc(${n} * var(--sg-${AXIS[u] || u}))`);
      style.setProperty(p, v, style.getPropertyPriority(p));
    }
    return props.length;
  };
  const pinRules = (rules) => {
    let n = 0;
    for (const r of rules) {
      if (r.style) n += pinStyle(r.style);
      if (r.cssRules) n += pinRules(r.cssRules);
      if (r.styleSheet) n += pinSheet(r.styleSheet); // @import
    }
    return n;
  };
  const pinSheet = (s) => {
    if (pinned.has(s)) return 0;
    pinned.add(s);
    try { return pinRules(s.cssRules); } catch (_) { return 0; } // another origin's, or ours
  };
  const sizeUnits = () => {
    const b = document.body;
    const cs = getComputedStyle(b);
    const vw = (b.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)) / 100;
    const vh = (window.outerHeight || screen.availHeight) / 100;
    const root = document.documentElement.style;
    root.setProperty('--sg-vw', vw + 'px');
    root.setProperty('--sg-vh', vh + 'px');
    root.setProperty('--sg-vmin', Math.min(vw, vh) + 'px');
    root.setProperty('--sg-vmax', Math.max(vw, vh) + 'px');
  };
  // Whether anything was rewritten.
  const pinUnits = () => {
    let n = 0;
    for (const s of document.styleSheets) n += pinSheet(s);
    if (!pinnedInline) {
      pinnedInline = true;
      for (const e of document.querySelectorAll('[style]')) n += pinStyle(e.style);
    }
    if (n) unitsPinned = true;
    if (unitsPinned) sizeUnits();
    return n > 0;
  };

  const height = () => Math.ceil(Math.max(document.documentElement.getBoundingClientRect().height,
    document.body ? document.body.scrollHeight : 0));
  let last = -1;
  // Times in a row the content outgrew the height it was just fitted to. Past two,
  // something other than a style follows the viewport (a script sizing to it): hold.
  let feedback = 0;
  let frameW = window.innerWidth;
  window.addEventListener('resize', () => {
    if (window.innerWidth !== frameW) {
      frameW = window.innerWidth;
      if (unitsPinned) sizeUnits();
    } else if (window.innerHeight === last) {
      if (height() > last) {
        pinUnits();
        if (height() > last) feedback++;
      } else {
        feedback = 0;
      }
    }
  });

  const measure = () => {
    const b = document.body;
    if (b && b.scrollWidth > b.clientWidth) pinUnits();
    let h = height();
    if (feedback > 2) h = Math.min(h, window.innerHeight);
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
        // The page scrolls, keeping the target clear of the entry's pinned name.
        if (t) {
          const sy = window.scrollY;
          const l = firstLine(t);
          post({ type: 'goto', y: Math.round(t.getBoundingClientRect().top + sy),
            mark: l && { x: l.l, y: l.t + sy, w: l.r - l.l, h: l.b - l.t } });
        }
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

  // A word or short phrase worth looking up, without the punctuation around it.
  const lookable = (s) => {
    const w = String(s || '').trim().replace(/^[\s"'“‘(\[]+|[\s"'”’)\].,;:!?]+$/g, '');
    return w && w.length <= 48 && w.split(/\s+/).length <= 3 ? w : '';
  };

  document.addEventListener('dblclick', (e) => {
    if (e.target.closest && e.target.closest('a, button, input, textarea, select')) return;
    const w = lookable(window.getSelection());
    if (w) post({ type: 'lookup', word: w });
  });

  // The word under the pointer, selected; null off the text.
  const wordAt = (x, y) => {
    const r = document.caretRangeFromPoint(x, y);
    const node = r && r.startContainer;
    if (!node || node.nodeType !== Node.TEXT_NODE) return null;
    const at = r.startOffset;
    for (const s of new Intl.Segmenter(undefined, { granularity: 'word' }).segment(node.data)) {
      if (!s.isWordLike || at < s.index || at > s.index + s.segment.length) continue;
      const range = document.createRange();
      range.setStart(node, s.index);
      range.setEnd(node, s.index + s.segment.length);
      const hit = Array.from(range.getClientRects()).some((b) =>
        x >= b.left - 1 && x <= b.right + 1 && y >= b.top - 1 && y <= b.bottom + 1);
      if (!hit) return null;
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      return s.segment;
    }
    return null;
  };

  // A right-click offers the selection, or else the word under the pointer, to look up:
  // the menu's first item (ArticleView). Told to the app directly, so it is there
  // before the menu opens.
  document.addEventListener('contextmenu', (e) => {
    const selected = lookable(window.getSelection());
    const word = selected || lookable(wordAt(e.clientX, e.clientY));
    try { window.webkit.messageHandlers.sg.postMessage({ type: 'menu', word }); } catch (_) {}
  });

  // A press anywhere in an article: the page closes what floats over it.
  document.addEventListener('mousedown', (e) => {
    if (e.button === 0) post({ type: 'press' });
  }, true);
  // The wheel over an article scrolls the page, which then stops holding a position.
  let wheeled = 0;
  window.addEventListener('wheel', () => {
    const t = performance.now();
    if (t - wheeled > 150) { wheeled = t; post({ type: 'wheel' }); }
  }, { passive: true });

  // Typing while an article has focus goes back to the search field (or the find
  // line, which also takes Return and ⇧Return to step through matches). ↑↓ and Space
  // scroll, as in any document; ⌥↑↓ keep their meaning, along the related words.
  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey) return;
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !e.shiftKey && e.altKey) {
      post({ type: 'key', key: 'Alt' + e.key });
      e.preventDefault();
      return;
    }
    if (e.altKey) return;
    if ((e.key.length === 1 && e.key !== ' ') || e.key === 'Escape' || e.key === 'Enter') {
      post({ type: 'key', key: e.key === 'Enter' && e.shiftKey ? 'ShiftEnter' : e.key });
      e.preventDefault();
    }
  });
})();
