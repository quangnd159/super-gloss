// Share as Image: the passage a reader chose, marked where it stands on the dictionary's
// own page, under the word set large. Served on the entry's origin
// (sgloss://<dict>/__card/card.html) so it can read and measure the entry (ShareCard).
// Cards are text only: the entry's pictures are neither loaded (ArticleView) nor shown.
//
// Query: e (the entries, as the reading page has them), word, name (the dictionary's short
// name), and the selection: start and end ("2.0.1:14", a path of child indices from the
// entry's <body>, then an offset), and text, what that range reads (Range.toString).
//
// Ends with <html data-state="ready | too-long | error">, and the same as a message to
// webkit.messageHandlers.card. Nothing waits on an animation frame: none comes in a view
// that is never on screen.
(() => {
  const P = Object.fromEntries(new URLSearchParams(location.search));
  const html = document.documentElement;
  const finish = (state, info) => {
    html.dataset.state = state;
    try { window.webkit.messageHandlers.card.postMessage({ state, ...info }); } catch (_) {}
  };
  card().catch((err) => finish('error', { reason: String(err) }));

  async function card() {
    // CSS px, captured at 2x: 1080×1350.
    const W = 540, H = 675, side = 48, colW = W - 2 * side;
    const inset = 46; // byline top, mark bottom
    const pad = 34; // at least this between byline or mark and the passage
    const lo = inset + 18 + pad, hi = H - inset - 16 - pad; // the byline's line is 18 tall, the mark's 16
    const room = hi - lo;
    // Body text, CSS px on the card. Whole blocks around the passage while they fit at
    // FBLOCKS or larger; below that, the passage's own rows take the room.
    const FMIN = 17, FMAX = 30, FBLOCKS = 22;
    for (const [k, v] of Object.entries({ W, H, side, inset })) html.style.setProperty('--' + k, v + 'px');

    const el = (tag, cls, text) => {
      const e = document.createElement(tag);
      if (cls) e.className = cls;
      if (text != null) e.textContent = text;
      return e;
    };

    // ---------- reading the entry ----------
    const SKIP = /^(SCRIPT|STYLE|TITLE|NOSCRIPT)$/;
    const INLINE = /^(inline|contents|ruby)/;
    const blockOf = (e) => {
      const win = e.ownerDocument.defaultView;
      for (let x = e; x; x = x.parentElement) if (!INLINE.test(win.getComputedStyle(x).display)) return x;
      return e.ownerDocument.body;
    };
    const painted = (n) => n.parentElement && !SKIP.test(n.parentElement.tagName) && n.parentElement.getClientRects().length > 0;

    // Every painted line of text, top to bottom, with the block it belongs to.
    function lineBoxes(doc) {
      const out = [], sy = doc.defaultView.scrollY, r = doc.createRange();
      const walk = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        if (!/\S/.test(n.data) || !painted(n)) continue;
        r.selectNodeContents(n);
        const blk = blockOf(n.parentElement);
        for (const x of r.getClientRects()) if (x.width > 0 && x.height > 0) out.push({ t: x.top + sy, b: x.bottom + sy, l: x.left, r: x.right, blk, el: n.parentElement });
      }
      return out.sort((a, b) => a.t - b.t || a.b - b.b);
    }
    // Generated text hung before a line, a sense number or a bullet (a ::before with a
    // negative margin), is painted where no text node is. It has no box to measure: it
    // starts where its element's content does, plus its margin.
    const hangs = new WeakMap();
    function markers(doc, lines) {
      const win = doc.defaultView, sy = win.scrollY, seen = new Set(), out = [];
      for (const l of lines) {
        for (let x = l.el; x && x !== doc.body && !seen.has(x); x = x.parentElement) {
          seen.add(x);
          if (!hangs.has(x)) {
            const cs = win.getComputedStyle(x, '::before');
            const ml = parseFloat(cs.marginLeft) || 0;
            hangs.set(x, ml < 0 && !/^(none|normal|""|'')$/.test(cs.content) ? ml : null);
          }
          const ml = hangs.get(x), r = ml != null && x.getClientRects()[0];
          if (!r) continue;
          const cs = win.getComputedStyle(x);
          const t = r.top + sy;
          out.push({ t, b: t + parseFloat(cs.fontSize) * 1.2, l: r.left + parseFloat(cs.paddingLeft) + parseFloat(cs.borderLeftWidth) + ml });
        }
      }
      return out;
    }
    // Where the entry can be cut between two blocks without splitting a line:
    // [{y: bottom of what stays, next: top of what follows}], and its end.
    function blockCuts(lines) {
      const cuts = [];
      let bottom = -Infinity;
      lines.forEach((l, i) => {
        if (i && l.t >= bottom - 1 && l.blk !== lines[i - 1].blk) cuts.push({ y: bottom, next: l.t });
        bottom = Math.max(bottom, l.b);
      });
      return { cuts, end: bottom, lines };
    }
    // Painted rows (line boxes side by side merged) in [top, bottom].
    function rows(lines, top, bottom) {
      const out = [];
      for (const l of lines) {
        if (l.t < top - 1 || l.b > bottom + 1) continue;
        const r = out.find((x) => Math.min(x.b, l.b) - Math.max(x.t, l.t) > (l.b - l.t) * 0.5);
        if (r) Object.assign(r, { t: Math.min(r.t, l.t), b: Math.max(r.b, l.b), l: Math.min(r.l, l.l), r: Math.max(r.r, l.r) });
        else out.push({ t: l.t, b: l.b, l: l.l, r: l.r });
      }
      return out.sort((a, b) => a.t - b.t);
    }
    // The text in a range, piece by piece: one sub-range per painted text node.
    function pieces(doc, range) {
      const out = [], c = range.commonAncestorContainer;
      const walk = doc.createTreeWalker(c.nodeType === 3 ? c.parentNode : c, NodeFilter.SHOW_TEXT);
      for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        if (!/\S/.test(n.data) || !range.intersectsNode(n) || !painted(n)) continue;
        const part = doc.createRange();
        part.selectNodeContents(n);
        if (n === range.startContainer) part.setStart(n, range.startOffset);
        if (n === range.endContainer) part.setEnd(n, range.endOffset);
        out.push(part);
      }
      return out;
    }
    // The rows a range covers, each as wide as its text, not the boxes around it (a table
    // cell's box spans all its lines).
    function rangeRows(doc, range) {
      const sy = doc.defaultView.scrollY, out = [];
      const rects = pieces(doc, range).flatMap((p) => [...p.getClientRects()]);
      for (const x of rects.filter((x) => x.width > 1 && x.height > 1).sort((a, b) => a.top - b.top || a.left - b.left)) {
        const t = x.top + sy, b = x.bottom + sy;
        const row = out.find((y) => Math.min(y.b, b) - Math.max(y.t, t) > Math.min(b - t, y.b - y.t) * 0.5);
        if (row) Object.assign(row, { l: Math.min(row.l, x.left), r: Math.max(row.r, x.right), t: Math.min(row.t, t), b: Math.max(row.b, b) });
        else out.push({ l: x.left, r: x.right, t, b });
      }
      return out;
    }
    // The size most of the passage is set in.
    function bodySize(doc, range) {
      const win = doc.defaultView, count = new Map();
      for (const p of pieces(doc, range)) {
        const fs = Math.round(parseFloat(win.getComputedStyle(p.startContainer.parentElement).fontSize));
        count.set(fs, (count.get(fs) || 0) + p.toString().trim().length);
      }
      return [...count].sort((a, b) => b[1] - a[1])[0]?.[0] || 17;
    }

    // ---------- the reader's selection ----------
    const point = (doc, spec) => {
      const m = /^([\d.]*):(\d+)$/.exec(spec || '');
      if (!m) return null;
      let n = doc.body;
      for (const i of m[1] ? m[1].split('.') : []) if (!(n = n.childNodes[+i])) return null;
      return +m[2] <= (n.nodeType === 3 ? n.data.length : n.childNodes.length) ? [n, +m[2]] : null;
    };
    // A selection that starts or ends inside a word takes the whole word: half a word
    // marked reads as a slip. Scripts written without spaces keep the reader's bounds.
    const WORD = /[\p{L}\p{N}\p{M}]/u, UNSPACED = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Thai}\p{sc=Lao}\p{sc=Khmer}\p{sc=Myanmar}]/u;
    const inWord = (c) => c !== undefined && WORD.test(c) && !UNSPACED.test(c);
    function wholeWords(r) {
      const s = r.startContainer, e = r.endContainer;
      if (s.nodeType === 3 && inWord(s.data[r.startOffset])) {
        let i = r.startOffset;
        while (inWord(s.data[i - 1])) i--;
        r.setStart(s, i);
      }
      if (e.nodeType === 3 && inWord(e.data[r.endOffset - 1])) {
        let i = r.endOffset;
        while (inWord(e.data[i])) i++;
        r.setEnd(e, i);
      }
    }
    // The range the reader chose, by its path, if it still reads what it read on the page.
    function selection(doc) {
      const a = point(doc, P.start), b = point(doc, P.end);
      if (!a || !b) return null;
      const r = doc.createRange();
      r.setStart(...a);
      r.setEnd(...b);
      if (r.toString() !== P.text) return null;
      wholeWords(r);
      return r;
    }

    // ---------- what only works on screen ----------
    // A card can't play a sound or open a pop-up. Gone: sound links, buttons and anything
    // with a click handler or a button role, links with no text (an icon or badge pointing
    // elsewhere), and links drawn as buttons, unless the reader chose their words: what was
    // selected is never taken off the card. Labels stay: "UK" is the dictionary's word.
    function isControl(e, cs, range) {
      const tag = e.tagName;
      if (/^(BUTTON|INPUT|SELECT)$/.test(tag)) return true;
      if (e.hasAttribute('onclick') || e.getAttribute('role') === 'button') return true;
      const a = e.closest('a[href]');
      if (a && /^sound:/i.test(a.getAttribute('href'))) return true;
      if (tag === 'A' && e.hasAttribute('href')) {
        const t = e.textContent.trim();
        if (!/[\p{L}\p{N}]/u.test(t)) return true;
        // drawn as a button: a border on three sides or more, or a filled box, on the link
        // or on the one element that holds all its text
        const win = e.ownerDocument.defaultView;
        const kids = [...e.children].filter((c) => c.getClientRects().length);
        const boxes = [cs, ...(kids.length === 1 && kids[0].textContent.trim() === t ? [win.getComputedStyle(kids[0])] : [])];
        const button = (c) => ['Top', 'Right', 'Bottom', 'Left'].filter((d) => parseFloat(c['border' + d + 'Width']) > 0 && c['border' + d + 'Style'] !== 'none').length >= 3
          || !/rgba\(0, 0, 0, 0\)|transparent/.test(c.backgroundColor);
        if (t.length <= 30 && !range?.intersectsNode(e) && boxes.some(button)) return true;
      }
      return false;
    }
    const PICTURES = 'img, picture, svg, canvas, video, audio, object, embed, iframe';
    const hide = (e) => e.style.setProperty('display', 'none', 'important');
    // The line after `n` up to a line break, if it is one element and nothing else.
    const blank = (n) => n.nodeType === 3 ? !/\S/.test(n.data) : n.nodeType !== 1;
    const step = (n, dir) => { do n = n[dir]; while (n && blank(n)); return n; };
    function strip(doc, range) {
      const win = doc.defaultView;
      const gone = [];
      for (const e of doc.body.querySelectorAll('*')) {
        const cs = win.getComputedStyle(e);
        if (isControl(e, cs, range) || /url\(/.test(cs.backgroundImage) && !e.innerText.trim()) { hide(e); gone.push(e); }
      }
      // A picture alone between line breaks takes the break after it; so does a credit set
      // as one run on the line under it ("PhotoDisc, Inc."), which captions nothing now.
      for (const p of doc.body.querySelectorAll(PICTURES)) {
        gone.push(p);
        const before = step(p, 'previousSibling'), after = step(p, 'nextSibling');
        if (before && before.nodeName !== 'BR' || after?.nodeName !== 'BR') continue;
        hide(after);
        const credit = step(after, 'nextSibling'), end = credit && step(credit, 'nextSibling');
        if (credit?.nodeType === 1 && end?.nodeName === 'BR' && credit.innerText.trim()) { hide(credit); hide(end); }
      }
      for (const e of gone) e.dataset.sgGone = '';
      // What held only controls or pictures goes with them (a picture's frame, a box whose
      // title was its toggle); a table cell stays, or its column would close up. All found
      // before any is hidden, so the page is laid out once.
      const empty = new Set();
      for (const e of gone) {
        for (let p = e.parentElement; p && p !== doc.body && !p.matches('.sg-entry') && !empty.has(p); p = p.parentElement) {
          if (p.innerText.trim() || /^table/.test(win.getComputedStyle(p).display)) break;
          empty.add(p);
        }
      }
      empty.forEach(hide);
      // Two neighbours that now read the same ("/rʌn/ /rʌn/"), told apart only by the
      // control that went, show once.
      for (const box of new Set(gone.map((e) => e.parentElement))) {
        let prev = box.previousElementSibling;
        while (prev && !prev.getClientRects().length) prev = prev.previousElementSibling;
        const t = box.textContent.trim();
        if (prev && t && t.length <= 40 && prev.textContent.trim() === t && prev.querySelector('[data-sg-gone]')) hide(box);
      }
      // In dark, a foreign entry is inverted over white (article.css); over nothing it
      // inverts the same, without a seam where its white meets the card.
      doc.documentElement.style.setProperty('background', 'transparent', 'important');
    }

    // The looked-up word at the very top of the entry, as the title already says it:
    // matched letter by letter (case, accents, syllable dots, stress marks and spaces
    // aside), after at most a short numbering ("Ⅰ.", "—", "1"), and ending at a word
    // boundary. Hidden, with a homograph number after it, and its line if nothing but
    // punctuation is left. Kept if the reader chose any of it, and if the entry doesn't
    // open that way.
    const bare = (s) => s.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
    function stripEcho(doc, word, range) {
      const key = bare(word);
      const IGN = /[\s‧·•ˈˌ'’\-‐]/;
      const walk = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
      const segs = [];
      let pre = 0, k = 0, matched = false;
      scan: for (let n = walk.nextNode(); n; n = walk.nextNode()) {
        if (!painted(n)) continue;
        let from = -1;
        for (let i = 0; i < n.data.length; i++) {
          const ch = n.data[i];
          if (matched) {
            if (/[\d¹²³⁴⁵⁶⁷⁸⁹⁰]/.test(ch) && (from >= 0 || i === 0)) { if (from < 0) from = i; continue; }
            if (/\p{L}/u.test(ch)) return; // "run" inside "runner"
            if (from >= 0) segs.push([n, from, i]);
            break scan;
          }
          if (k === 0 && (!/[\p{L}\p{N}]/u.test(ch) || /\p{N}/u.test(ch) && !key.startsWith(ch))) {
            if (/\S/.test(ch) && ++pre > 8) return;
            if (from < 0) from = i;
            continue;
          }
          if (!IGN.test(ch)) {
            const f = bare(ch);
            if (!f || f !== key.slice(k, k + f.length)) return;
            k += f.length;
            matched = k >= key.length;
          }
          if (from < 0) from = i;
        }
        if (from >= 0) segs.push([n, from, n.data.length]);
      }
      if (!matched || !segs.length) return;
      const chosen = ([n, a, b]) => !(range.comparePoint(n, b) < 0 || n === range.startContainer && b <= range.startOffset)
        && !(range.comparePoint(n, a) > 0 || n === range.endContainer && a >= range.endOffset);
      if (segs.some(chosen)) return;
      const line = blockOf(segs[segs.length - 1][0].parentElement);
      const numbering = /^[\s\d\p{Nl}.)\-–—]*$/u;
      segs.reverse().forEach(([n, a, b], i) => {
        // a leading "[" or "(" stays, and so does its pair: only numbering goes with the word
        if (b <= a || i === segs.length - 1 && segs.length > 1 && !numbering.test(n.data.slice(a, b))) return;
        const r = doc.createRange();
        r.setStart(n, a);
        r.setEnd(n, b);
        const s = doc.createElement('span');
        hide(s);
        r.surroundContents(s);
      });
      if (!/[\p{L}\p{N}]/u.test(line.innerText)) hide(line);
    }

    // The passage at full ink, whatever grey the page sets it in; a coloured run (a
    // grammar label, a cross-reference) keeps its colour. Each grey run is wrapped in an
    // element of no kind the entry's styles know, which changes nothing but its colour (a
    // highlight would need a rendering update to show, and a view never on screen has none).
    function ink(doc, range) {
      const win = doc.defaultView;
      // foreign pages are inverted in dark (article.css): the light ink inverts to the dark one
      const dark = doc.body.classList.contains('sg-native') && win.matchMedia('(prefers-color-scheme: dark)').matches;
      const grey = pieces(doc, range).filter((p) => {
        const [r, g, b] = win.getComputedStyle(p.startContainer.parentElement).color.match(/[\d.]+/g).map(Number);
        return Math.max(r, g, b) - Math.min(r, g, b) <= 24;
      });
      for (const p of grey) {
        const w = doc.createElement('sg-ink');
        w.style.setProperty('color', dark ? '#ececec' : '#1d1d1f', 'important');
        w.style.setProperty('-webkit-text-fill-color', 'currentColor', 'important');
        p.surroundContents(w);
      }
    }

    // ---------- the card ----------
    const by = document.querySelector('.by');
    by.textContent = P.name;
    by.classList.toggle('caseless', P.name.toUpperCase() === P.name.toLowerCase());
    const grp = document.querySelector('.grp');
    const title = el('h1', null, P.word);
    title.dir = 'auto';
    grp.append(title);
    let ts = 72;
    const wide = () => {
      title.style.fontSize = ts + 'px';
      const r = document.createRange();
      r.selectNodeContents(title);
      return r.getBoundingClientRect().width > colW;
    };
    while (wide() && ts > 40) ts -= 2;
    if (wide()) title.style.whiteSpace = 'normal';
    const titleGap = Math.round(ts * 0.3);
    title.style.marginBottom = titleGap + 'px';

    // Two frames of the entry: the head under the title, and the passage, each at its own
    // zoom. Each loads in its window for good (an iframe moved in the page reloads).
    const hdv = el('div', 'win'), mid = el('div'), pv = el('div', 'win');
    grp.append(hdv, mid, pv);
    async function frame(into) {
      const f = el('iframe');
      f.src = '/?e=' + P.e; // as the reading page has it: the core reads the commas as they are
      into.append(f);
      await new Promise((r) => { f.onload = r; });
      const doc = f.contentDocument;
      const style = doc.createElement('style');
      style.textContent = PICTURES + '{display:none!important}';
      doc.head.append(style);
      await doc.fonts.ready;
      const e = { f, doc, edge: { l: 0, r: 0 } };
      e.sel = selection(doc); // before anything below changes the page
      strip(doc, e.sel);
      if (e.sel) stripEcho(doc, P.word, e.sel);
      return e;
    }
    const [Hf, Pf] = await Promise.all([frame(hdv), frame(pv)]);
    if (!Pf.sel) return finish('error', { reason: 'not-found' });
    const range = Pf.sel;
    const headInk = Hf.doc.createElement('link');
    headInk.rel = 'stylesheet';
    headInk.href = new URL('head.css', location.href).href;
    await new Promise((r) => { headInk.onload = headInk.onerror = r; Hf.doc.head.append(headInk); });

    // The card reads in the passage's direction.
    const rtl = Pf.doc.defaultView.getComputedStyle(blockOf(range.startContainer.parentElement || range.startContainer)).direction === 'rtl';
    if (rtl) html.dir = 'rtl';

    // A frame's lines, measured once per layout.
    const linesOf = (e) => (e.lines ||= lineBoxes(e.doc));
    // Lays a frame out `z` times its size, `edge.l` and `edge.r` wider than the column's
    // measure on each side.
    const lay = (e, z) => {
      e.z = z;
      e.f.style.width = colW / z + e.edge.l + e.edge.r + 'px';
      e.f.style.height = '10px';
      e.f.style.height = Math.ceil(Math.max(e.doc.documentElement.getBoundingClientRect().height, e.doc.body.scrollHeight)) + 'px';
      e.lines = null;
    };
    // Where a frame's text should meet the column's edge: the start of its leftmost line in
    // [a, b], or of a number hung before one (the end of its rightmost line, right to
    // left), and the far side of that line's block. Whatever margins the entry nests the
    // passage in, its text then sits on the card's edge at the column's measure; indents
    // inside it stay.
    const edgeOf = (e, a, b) => {
      const ls = linesOf(e).filter((l) => l.b > a + 1 && l.t < b - 1);
      if (!ls.length) return e.edge;
      const win = e.doc.defaultView, fw = parseFloat(e.f.style.width);
      const content = (blk) => {
        const x = blk.getBoundingClientRect(), cs = win.getComputedStyle(blk);
        return { l: x.left + parseFloat(cs.paddingLeft) + parseFloat(cs.borderLeftWidth), r: x.right - parseFloat(cs.paddingRight) - parseFloat(cs.borderRightWidth) };
      };
      if (rtl) {
        const x = ls.reduce((m, l) => (l.r > m.r ? l : m));
        return { l: content(x.blk).l, r: fw - x.r };
      }
      const x = ls.reduce((m, l) => (l.l < m.l ? l : m));
      const hung = markers(e.doc, ls).filter((m) => Math.min(m.b, b) - Math.max(m.t, a) > 1);
      return { l: Math.min(x.l, ...hung.map((m) => m.l)), r: fw - content(x.blk).r };
    };
    // Lays a frame out at `z` and moves its edge until `measure` (the span it will show,
    // as [a, b, …]) stops moving; returns what `measure` last gave.
    const settle = (e, z, measure) => {
      lay(e, z);
      let m = measure();
      for (let k = 0; m && k < 3; k++) {
        const n = edgeOf(e, m[0], m[1]);
        if (Math.abs(n.l - e.edge.l) < 0.5 && Math.abs(n.r - e.edge.r) < 0.5) break;
        e.edge = n;
        lay(e, z);
        m = measure();
      }
      return m;
    };

    // The entry's head: its first line, up to its first block boundary, one row at most (an
    // ellipsis says where it was clamped).
    const headOf = (e) => {
      const { cuts, end, lines } = blockCuts(linesOf(e));
      const t0 = lines.length ? lines[0].t : 0;
      const c = cuts.find((x) => x.y > t0 + 2);
      const he = c ? c.y : end, next = c ? c.next : end;
      const rs = rows(lines, t0, he);
      const row = rs[0] || { t: t0, b: t0, l: 0, r: 0 };
      return { t0, hb: rs.length > 1 ? row.b : he, clamp: rs.length > 1, row, cuts, end, next, lines };
    };

    lay(Pf, 1);
    const fe = bodySize(Pf.doc, range);
    const titleH = title.offsetHeight + titleGap;

    // The card at body size f: whole blocks around the passage ('blocks'), or the
    // passage's rows with as many of their neighbours as fit ('rows'). Null if it can't fit.
    const make = (f, mode) => {
      const z = Math.min(3, f / fe), zh = Math.max(z * 0.82, 15 / fe);
      const hh = settle(Hf, zh, () => { const h = headOf(Hf); return [h.t0, h.hb, h]; })[2];
      let g = null;
      settle(Pf, z, () => {
        g = null;
        const hd = headOf(Pf), L = rangeRows(Pf.doc, range);
        if (!L.length) return null;
        // a passage that starts in the head is shown from the top, with no head over it
        const showHead = L[0].t >= hd.next - 1;
        const above = [...hd.cuts].reverse().find((c) => c.y <= L[0].t + 1);
        const below = hd.cuts.find((c) => c.y >= L[L.length - 1].b - 1);
        let s = above ? above.next : hd.t0, e = below ? below.y : hd.end;
        if (showHead && s < hd.next) s = hd.next;
        const headH = showHead ? (hh.hb - hh.t0) * zh : 0;
        const fixed = (omitted) => titleH + headH + (showHead ? (omitted ? 42 : 10) : 0);
        if (mode === 'rows') {
          const rs = rows(hd.lines, s, e);
          let i = rs.findIndex((r) => r.b > L[0].t + 1), j = rs.findLastIndex((r) => r.t < L[L.length - 1].b - 1);
          if (i < 0 || j < i) return null;
          const space = (room - fixed(showHead && rs[i].t > hd.next + 2)) / z;
          if (rs[j].b - rs[i].t > space) return null;
          // neighbours below first, then above, while they fit
          for (let grew = true; grew;) {
            grew = false;
            if (j + 1 < rs.length && rs[j + 1].b - rs[i].t <= space) { j++; grew = true; }
            if (i > 0 && rs[j].b - rs[i - 1].t <= space) { i--; grew = true; }
          }
          s = rs[i].t; e = rs[j].b;
        }
        const omitted = showHead && s > hd.next + 2;
        g = { f, z, zh, hh, L, s, e, showHead, omitted, mode, total: fixed(omitted) + (e - s) * z };
        return [s, e];
      });
      return g && g.total <= room ? g : null;
    };
    // The frames are laid out for the last plan made: asked for again, it stands.
    let laid = {};
    const plan = (f, mode) => (laid.f === f && laid.mode === mode ? laid : (laid = { f, mode, g: make(f, mode) })).g;
    // The largest body size, in half pixels, at which `mode` fits.
    const largest = (mode) => {
      if (plan(FMAX, mode)) return FMAX;
      let a = FMIN * 2, b = FMAX * 2 - 1;
      if (!plan(FMIN, mode)) return null;
      while (a < b) { const m = Math.ceil((a + b) / 2); if (plan(m / 2, mode)) a = m; else b = m - 1; }
      return a / 2;
    };
    const fb = largest('blocks');
    const fr = fb >= FBLOCKS ? null : largest('rows');
    const best = fb >= FBLOCKS ? plan(fb, 'blocks') : fr && plan(fr, 'rows');
    if (!best) return finish('too-long'); // a card is never cut

    const { z, zh, hh, s, e, L } = best;
    const place = (win, fr, a, b, k) => {
      win.style.height = Math.ceil((b - a) * k) + 'px';
      fr.f.style.transform = `translate(${-fr.edge.l * k}px, ${-a * k}px) scale(${k})`;
    };
    if (best.showHead) {
      place(hdv, Hf, hh.t0, hh.hb, zh);
      if (hh.clamp) {
        const dot = el('span', 'ell', '…');
        const rh = (hh.row.b - hh.row.t) * zh;
        dot.style.fontSize = Math.round(rh * 0.62) + 'px';
        dot.style.top = (hh.row.t - hh.t0) * zh + rh * 0.22 + 'px';
        dot.style.left = rtl ? (hh.row.l - Hf.edge.l) * zh - rh * 0.62 + 'px' : (hh.row.r - Hf.edge.l) * zh + 2 + 'px';
        hdv.append(dot);
      }
      if (best.omitted) mid.append(el('div', 'gap', '[…]'));
      else hdv.style.marginBottom = '10px';
    } else hdv.hidden = true;
    place(pv, Pf, s, e, z);
    ink(Pf.doc, range); // last: wrapping its runs moves the range off them

    // Everything but the chosen rows recedes under a veil of the card's own background.
    const ns = 'http://www.w3.org/2000/svg';
    const vh = Math.ceil((e - s) * z), vw = colW + 40;
    const X = (x) => (x - Pf.edge.l) * z;
    const shown = L.filter((x) => x.b > s && x.t < e);
    const holes = shown.map((x) => `<rect x="${X(x.l) + 18}" y="${(x.t - s) * z - 2}" width="${(x.r - x.l) * z + 4}" height="${(x.b - x.t) * z + 4}" fill="black"/>`).join('');
    const veil = document.createElementNS(ns, 'svg');
    veil.classList.add('veil');
    veil.setAttribute('width', vw);
    veil.setAttribute('height', vh);
    veil.innerHTML = `<defs><mask id="m"><rect width="${vw}" height="${vh}" fill="white"/>${holes}</mask></defs>`
      + `<rect width="${vw}" height="${vh}" fill="var(--bg)" opacity="0.62" mask="url(#m)"/>`;
    pv.append(veil);
    // The accent beside the chosen rows, a constant distance from the first thing painted
    // on them (a sense number hung before the passage included).
    const rule = el('div', 'rule');
    const t = Math.max(0, (shown[0].t - s) * z), b = Math.min(vh, (shown[shown.length - 1].b - s) * z);
    const onRows = (l) => shown.some((x) => Math.min(x.b, l.b) - Math.max(x.t, l.t) > 1);
    const ls = linesOf(Pf).filter(onRows);
    const x = rtl ? X(Math.max(...ls.map((l) => l.r))) + 16 : X(Math.min(...ls.map((l) => l.l), ...markers(Pf.doc, ls).filter(onRows).map((m) => m.l))) - 18;
    Object.assign(rule.style, { top: t + 'px', height: b - t + 'px', left: x + 'px' });
    pv.append(rule);

    // A little above the middle of the room between byline and mark.
    grp.style.top = Math.round(lo + Math.max(0, room - grp.offsetHeight) * 0.4) + 'px';
    finish('ready');
  }
})();
