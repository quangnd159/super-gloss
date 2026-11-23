// Main reading surface. Native calls `sg.show(payload)`; each source renders in an
// isolated iframe (its own CSS/JS) that reports height and actions via postMessage.
(() => {
  let col = document.getElementById('col');
  const via = document.getElementById('via');
  const ix = document.getElementById('index');
  const frames = new Map(); // iframe -> {id, iframe, section, sound, …}
  const collapsed = new Set();
  let generation = 0;
  let shownWord = null;
  let list = []; // the page's sections, in order
  let ghost = null; // the page being replaced, kept on screen until the new one is ready
  const still = matchMedia('(prefers-reduced-motion: reduce)');
  const glide = () => (still.matches ? 'auto' : 'smooth');

  const native = (msg) => {
    try { window.webkit.messageHandlers.sg.postMessage(msg); } catch (_) {}
  };

  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };

  // The page on screen stays there, inert, while the next one lays out out of sight:
  // typing goes from word to word without a blank in between.
  function keepOnScreen() {
    if (col.classList.contains('loading') || !col.firstChild) {
      col.replaceChildren(); // never shown: the ghost already stands for the page
      return;
    }
    dropGhost();
    const r = col.getBoundingClientRect();
    const name = pinned && pinned.firstChild;
    const at = name && name.getBoundingClientRect().top;
    ghost = col;
    ghost.removeAttribute('id');
    ghost.className = 'ghost';
    Object.assign(ghost.style, { top: r.top + 'px', left: r.left + 'px', width: r.width + 'px' });
    // A pinned name has nothing to stick to in a fixed layer: keep it where it was.
    if (name) {
      const d = at - name.getBoundingClientRect().top;
      if (d) name.style.transform = `translateY(${d}px)`;
    }
    col = el('main');
    col.id = 'col';
    ghost.after(col);
  }
  function dropGhost() {
    if (ghost) ghost.remove();
    ghost = null;
  }

  function show(p) {
    if (placeTimer) reportPlace(); // where the reader left the page being replaced
    const gen = ++generation;
    indexClose('stay', true); // the list was for the page being replaced
    frames.clear();
    keepOnScreen();
    pinned = null;
    shownWord = p.word;
    icons(p.icons !== false);
    if (p.via) {
      via.hidden = false;
      via.replaceChildren(document.createTextNode(p.word + ' → '), el('b', null, p.via));
    } else {
      via.hidden = true;
    }
    const land = p.land || null;
    let landSection = null;
    const next = document.createDocumentFragment();
    const pending = new Set();
    list = [];
    for (const h of p.hits) {
      const s = el('section', 'src');
      s.dataset.id = h.id;
      s._hit = h;
      const hidden = collapsed.has(h.id);
      if (hidden) s.classList.add('collapsed');
      // The entry opens with its dictionary's name; a click on it hides or shows the entry.
      const name = el('h2', 'name');
      const tag = el('button', 'tag');
      tag.type = 'button';
      tag.title = h.name + (hidden ? ' — click to show' : ' — click to hide');
      tag.setAttribute('aria-expanded', String(!hidden));
      if (h.icon) tag.append(icon(h.icon));
      tag.append(document.createTextNode(h.short));
      if (h.count > 1) tag.append(el('span', 'n', h.count + ' entries'));
      tag.addEventListener('click', () => toggle(s, h));
      name.append(tag);
      const b = el('div', 'body');
      const f = el('iframe');
      f.setAttribute('scrolling', 'no');
      f.setAttribute('title', h.name);
      const landing = land && land.dict === h.id;
      if (landing) landSection = s;
      const anchored = landing && land.offset == null;
      const url = h.url + (anchored ? '#' + encodeURIComponent(JSON.stringify({ id: land.id, find: land.find })) : '');
      // A hidden entry loads when it is shown.
      if (hidden && !landing) f.dataset.src = url;
      else { f.src = url; pending.add(f); }
      b.append(f);
      s.append(name, b);
      next.append(s);
      list.push(s);
      // Follow the anchor while the frame settles: from its first report, for a moment.
      const rec = { id: h.id, iframe: f, section: s, sound: null, anchorUntil: anchored ? Infinity : 0, marked: false, found: null };
      s._rec = rec;
      frames.set(f, rec);
    }
    // A find still open (the same word re-shown) runs again as the frames arrive.
    find.gen++;
    find.cur = null;
    find.from = 0;
    find.settled = !find.q;
    clearTimeout(find.timer);
    if (find.q) find.timer = setTimeout(settle, 600); // a frame that never answers
    col.classList.add('loading');
    col.replaceChildren(next);
    jumpTarget = null;
    jumpOffset = 0;
    window.scrollTo(0, 0);
    // Back/Forward: return to where the reader was, held while frames settle.
    if (landSection && land.offset != null) {
      jumpTarget = landSection;
      jumpOffset = land.offset + TOP;
      jumpUntil = performance.now() + 2000;
      window.scrollTo(0, Math.max(0, jumpTop()));
    }
    indexBuild(list);
    reportCurrent();
    // Reveal once every frame has reported a height, or after a short grace period.
    col._onReveal = null;
    const reveal = () => {
      if (gen !== generation || !col.classList.contains('loading')) return;
      col.classList.remove('loading');
      dropGhost();
      const then = col._onReveal;
      col._onReveal = null;
      if (then) then();
    };
    col._pending = pending.size ? pending : null;
    col._reveal = reveal;
    if (!pending.size) reveal();
    else setTimeout(reveal, 220);
  }

  const icon = (src) => {
    const img = el('img');
    img.src = src;
    img.alt = '';
    img.onerror = () => img.remove();
    return img;
  };

  function toggle(s, h) {
    const on = !collapsed.has(h.id);
    if (on) collapsed.add(h.id); else collapsed.delete(h.id);
    s.classList.toggle('collapsed', on);
    const f = s.querySelector('iframe');
    if (!on && f.dataset.src) {
      f.src = f.dataset.src;
      delete f.dataset.src;
    }
    const tag = s.querySelector('.tag');
    tag.title = h.name + (on ? ' — click to show' : ' — click to hide');
    tag.setAttribute('aria-expanded', String(!on));
    if (s._row) s._row.el.classList.toggle('hid', on);
    // Hiding the entry being read (its name pinned above the text) leaves the name in
    // view, where showing it again is one click or key away.
    if (on && s.offsetTop - TOP < window.scrollY) {
      jumpTarget = null;
      window.scrollTo(0, Math.max(0, s.offsetTop - TOP));
    }
    if (find.q) {
      if (on && find.cur && find.cur.f.section === s) find.cur = null;
      report();
    }
    reportCurrent();
  }

  // The entry the keyboard's Hide and Show act on: the one selected in ⌘J's list while it
  // is open, else the one being read. Native names it in the Go menu.
  function current(i = currentIndex()) {
    if (index.open) return index.rows[index.sel] ? index.rows[index.sel].section : null;
    return list.length ? list[i] : null;
  }
  let lastCurrent = '';
  function reportCurrent(i) {
    const s = current(i);
    const msg = s ? { type: 'current', name: s._hit.short, hidden: s.classList.contains('collapsed') } : { type: 'current' };
    const key = JSON.stringify(msg);
    if (key === lastCurrent) return;
    lastCurrent = key;
    native(msg);
  }
  function hideCurrent(hide) {
    const s = current();
    if (s && s.classList.contains('collapsed') !== hide) toggle(s, s._hit);
  }

  function frameFor(source) {
    for (const f of frames.values()) {
      if (f.iframe.contentWindow === source) return f;
    }
    return null;
  }

  window.addEventListener('message', (e) => {
    const m = e.data && e.data.sg;
    if (!m) return;
    const f = frameFor(e.source);
    if (!f) return;
    switch (m.type) {
      case 'height':
        setHeight(f.iframe, m.h);
        if (col._pending && col._pending.delete(f.iframe) && !col._pending.size) {
          col._pending = null;
          // Everything has a height: hold a restored position only a moment longer.
          jumpUntil = Math.min(jumpUntil, performance.now() + 250);
          col._reveal();
        }
        break;
      case 'ready':
        f.sound = m.sound || null;
        if (find.q) sendFind(f);
        break;
      case 'found':
        if (m.gen !== find.gen) break;
        f.found = Array.isArray(m.ys) ? m.ys : [];
        paintCount(f);
        if (!find.settled) {
          if (answeredAll()) settle();
        } else if (!find.cur) {
          const list = hits();
          if (list.length) setCurrent(list.find((x) => x.y >= find.from) || list[0], false);
          else report();
        } else {
          report();
        }
        break;
      case 'anchor':
        if (f.anchorUntil === Infinity) f.anchorUntil = performance.now() + 1500;
        if (performance.now() < f.anchorUntil) scrollToAnchor(f, m.y);
        if (m.mark && !f.marked) {
          f.marked = true;
          if (col.classList.contains('loading')) col._onReveal = () => mark(f, m.mark);
          else mark(f, m.mark);
        }
        break;
      case 'goto':
        // A link to elsewhere in the same entry: the page scrolls, not the frame.
        jumpTarget = null;
        window.scrollTo({ top: Math.max(0, landingTop(f, m.y)), behavior: glide() });
        if (m.mark) mark(f, m.mark);
        break;
      case 'press':
        cancelHold();
        indexClose('stay', true);
        break;
      case 'wheel':
        cancelHold();
        break;
      case 'lookup':
        reportPlace();
        native({ type: 'lookup', word: String(m.word || '') });
        break;
      case 'link':
        reportPlace();
        native({ type: 'link', dict: f.id, target: String(m.target || ''), text: String(m.text || '') });
        break;
      case 'sound': native({ type: 'sound', dict: f.id, path: String(m.path || '') }); break;
      case 'open': native({ type: 'open', url: String(m.url || '') }); break;
      case 'key': native({ type: 'key', key: String(m.key || '') }); break;
    }
  });
  // With the page itself in focus (a click between entries, on a name), keys go where an
  // entry's go (frame.js keeps the same rules): ↑↓ and Space scroll, ⌥↑↓ go along the
  // related words, typing searches. While ⌘J's list is open, ↑↓ go through it.
  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey) return;
    let key = null;
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !e.shiftKey) {
      if (!e.altKey && !index.open) return;
      key = (e.altKey ? 'Alt' : '') + e.key;
    }
    else if (e.altKey) return;
    else if ((e.key.length === 1 && e.key !== ' ') || e.key === 'Escape' || e.key === 'Enter') {
      key = e.key === 'Enter' && e.shiftKey ? 'ShiftEnter' : e.key;
    }
    if (key) { native({ type: 'key', key }); e.preventDefault(); }
  });

  // A right-click on the page itself (a name, the space between entries) has no word to
  // offer; an entry's own right-click says which it has (frame.js).
  document.addEventListener('contextmenu', () => native({ type: 'menu', word: '' }));

  // The reader takes over: a position being held while frames settle is let go.
  function cancelHold() {
    jumpTarget = null;
    jumpUntil = 0;
  }
  window.addEventListener('wheel', cancelHold, { passive: true });
  document.addEventListener('mousedown', cancelHold, true);

  // ---------- find in entries ----------
  // Each frame searches its own text and paints its own highlights; this side
  // orders their matches into one sequence, picks the current one and scrolls.
  const find = { q: '', gen: 0, cur: null, from: 0, settled: true, timer: 0 };

  function sendFind(f) {
    try { f.iframe.contentWindow.postMessage({ sg: { type: 'find', q: find.q, gen: find.gen } }, '*'); } catch (_) {}
  }
  function sendCurrent(f, i) {
    try { f.iframe.contentWindow.postMessage({ sg: { type: 'findCurrent', i } }, '*'); } catch (_) {}
  }
  function records() { return list.map((s) => s._rec); }
  function frameTop(f) { return f.iframe.getBoundingClientRect().top + window.scrollY; }
  function visible(f) { return !f.section.classList.contains('collapsed'); }

  // Every match in reading order, in page coordinates; hidden sources are skipped.
  function hits() {
    const out = [];
    for (const f of records()) {
      if (!visible(f) || !f.found || !f.found.length) continue;
      const top = frameTop(f);
      f.found.forEach((y, i) => out.push({ f, i, y: top + y }));
    }
    return out;
  }
  function answeredAll() { return records().every((f) => !visible(f) || f.found); }
  const same = (x) => find.cur && x.f === find.cur.f && x.i === find.cur.i;

  function findIn(q) {
    // Typing more keeps the place: the search resumes from the current match.
    const c = find.cur && find.cur.f.found && find.cur.f.found[find.cur.i];
    const from = c != null ? frameTop(find.cur.f) + c - 1 : window.scrollY + TOP;
    find.q = q;
    find.gen++;
    find.cur = null;
    find.from = from;
    find.settled = !q;
    document.body.classList.toggle('finding', !!q);
    for (const f of frames.values()) {
      f.found = null;
      sendFind(f);
    }
    // Counts and dimming stay until the new answers arrive, so typing doesn't flicker.
    if (!q) for (const f of frames.values()) paintCount(f);
    clearTimeout(find.timer);
    if (q) find.timer = setTimeout(settle, 160);
    report();
  }

  // Find is about to be used: let every source get its text ready.
  function prepareFind() {
    for (const f of frames.values()) {
      try { f.iframe.contentWindow.postMessage({ sg: { type: 'prepare' } }, '*'); } catch (_) {}
    }
  }

  function settle() {
    clearTimeout(find.timer);
    if (find.settled || !find.q) return;
    find.settled = true;
    const list = hits();
    if (list.length) setCurrent(list.find((x) => x.y >= find.from) || list[0], true);
    else report();
  }

  function setCurrent(h, scroll) {
    if (find.cur && find.cur.f !== h.f) sendCurrent(find.cur.f, -1);
    find.cur = { f: h.f, i: h.i };
    sendCurrent(h.f, h.i);
    if (scroll) revealY(h.y);
    report();
  }

  // Bring a match into the comfortable middle of the view, only if it is not there.
  function revealY(y) {
    const top = window.scrollY;
    const vh = window.innerHeight;
    if (y >= top + 48 && y <= top + vh - 96) return;
    jumpTarget = null;
    window.scrollTo(0, Math.max(0, y - vh * 0.36));
  }

  function findStep(dir) {
    if (!find.q) return;
    settle();
    const list = hits();
    if (!list.length) return;
    let k = list.findIndex(same);
    if (k >= 0) {
      k = (k + dir + list.length) % list.length;
    } else {
      const y = window.scrollY + TOP;
      if (dir > 0) {
        k = list.findIndex((x) => x.y >= y);
        if (k < 0) k = 0;
      } else {
        k = list.length - 1;
        while (k > 0 && list[k].y >= y) k--;
      }
    }
    setCurrent(list[k], true);
  }

  function report() {
    let total = 0;
    let index = 0;
    if (find.q) {
      const list = hits();
      total = list.length;
      index = list.findIndex(same) + 1;
    }
    native({ type: 'find', total, index, pending: !!find.q && !find.settled });
  }

  // Each entry's name carries its count; entries without a match recede, in the page and
  // in ⌘J's list (the frame dims its own content: ancestor opacity doesn't reach
  // out-of-process frames).
  function paintCount(f) {
    const tag = f.section.querySelector('.tag');
    let fn = tag.querySelector('.fn');
    const n = find.q && f.found ? f.found.length : null;
    f.section.classList.toggle('nofind', n === 0);
    if (f.section._row) f.section._row.el.classList.toggle('nofind', n === 0);
    if (n) {
      if (!fn) { fn = el('span', 'fn'); tag.append(fn); }
      fn.textContent = n >= 2000 ? '2000+ matches' : n + (n === 1 ? ' match' : ' matches');
    } else if (fn) {
      fn.remove();
    }
  }

  // Where the reader is: the section whose top is at or above the viewport top.
  const TOP = 6;
  let jumpTarget = null;
  let jumpOffset = 0; // from the target section's top, for anchors inside it
  let jumpUntil = 0;
  let jumpGlides = false; // a click's jump glides; the keyboard's land at once

  function jumpTop() {
    return list[0] === jumpTarget && !jumpOffset ? 0 : jumpTarget.offsetTop + jumpOffset - TOP;
  }

  // Where the page scrolls to bring `y`, a position inside the frame, to the top: just
  // under the entry's pinned name. Near the top of its entry, the section's own top, so
  // the name stays where it is.
  function landingTop(f, y) {
    if (y < 48) return f.section.offsetTop - TOP;
    const bar = f.section.firstChild.offsetHeight + 12;
    return f.iframe.getBoundingClientRect().top + window.scrollY + y - bar;
  }

  function scrollToAnchor(f, y) {
    jumpTarget = f.section;
    jumpGlides = false;
    jumpOffset = landingTop(f, y) + TOP - f.section.offsetTop;
    jumpUntil = performance.now() + 900;
    window.scrollTo(0, Math.max(0, jumpTop()));
  }

  function mark(f, m) {
    if (!f.iframe.isConnected) return;
    const el = document.createElement('div');
    el.className = 'mark';
    el.style.left = (f.iframe.offsetLeft + m.x - 5) + 'px';
    el.style.top = (f.iframe.offsetTop + m.y - 2) + 'px';
    el.style.width = (m.w + 10) + 'px';
    el.style.height = (m.h + 4) + 'px';
    f.iframe.parentElement.append(el);
    const a = el.animate(
      [{ opacity: 0 }, { opacity: 1, offset: 0.08 }, { opacity: 1, offset: 0.5 }, { opacity: 0 }],
      { duration: 1800, easing: 'ease-out' });
    a.onfinish = a.oncancel = () => el.remove();
  }

  // The reading position, kept by native for Back/Forward. Reported when scrolling
  // settles, and right before following a link so it is never stale.
  let placeTimer = 0;
  function reportPlace() {
    clearTimeout(placeTimer);
    placeTimer = 0;
    if (shownWord == null) return;
    let place = null;
    if (list.length && window.scrollY > 0) {
      const s = list[currentIndex()];
      place = { dict: s.dataset.id, offset: Math.round(window.scrollY - s.offsetTop) };
    }
    native({ type: 'place', word: shownWord, place });
  }
  // What follows the reading position, once a frame however fast the page scrolls.
  let scrolled = 0;
  window.addEventListener('scroll', () => {
    clearTimeout(placeTimer);
    placeTimer = setTimeout(reportPlace, 150);
    if (!scrolled) scrolled = requestAnimationFrame(afterScroll);
  }, { passive: true });
  function afterScroll() {
    scrolled = 0;
    const i = currentIndex();
    pin(list[i]);
    if (index.open) followReading();
    reportCurrent(i);
  }

  // The name of the entry being read stays pinned at the top (app.css); text passing
  // under it fades.
  let pinned = null;
  function pin(s) {
    const p = s && s.firstChild.getBoundingClientRect().top <= 0.5 ? s : null;
    if (p === pinned) return;
    if (pinned) pinned.classList.remove('pinned');
    if (p) p.classList.add('pinned');
    pinned = p;
  }

  function currentIndex() {
    const y = window.scrollY + TOP + 8;
    let i = 0;
    for (let k = 0; k < list.length; k++) if (list[k].offsetTop <= y) i = k;
    return i;
  }

  function jump(dir) {
    if (!list.length) return;
    let i;
    if (jumpTarget && performance.now() < jumpUntil && list.includes(jumpTarget)) {
      // A jump is still settling (a glide, frames growing): step from where it is going.
      i = list.indexOf(jumpTarget) + dir;
    } else {
      i = currentIndex();
      const above = window.scrollY > list[i].offsetTop - TOP + 8;
      i = dir > 0 ? i + 1 : (above ? i : i - 1);
    }
    i = Math.max(0, Math.min(list.length - 1, i));
    jumpTarget = list[i];
    jumpOffset = 0;
    jumpGlides = false;
    jumpUntil = performance.now() + 900;
    window.scrollTo(0, jumpTop());
  }

  // WebKit has no scroll anchoring: when a frame above the reading position grows
  // (late images, fonts), keep the text under the reader where it was.
  function setHeight(iframe, h) {
    const px = h + 'px';
    if (iframe.style.height === px) return;
    if (jumpTarget && performance.now() < jumpUntil) {
      iframe.style.height = px;
      if (list.includes(jumpTarget)) window.scrollTo({ top: jumpTop(), behavior: jumpGlides ? glide() : 'auto' });
      return;
    }
    const y = window.scrollY;
    const section = iframe.closest('.src');
    if (y <= 0 || !section || section.offsetTop + section.offsetHeight > y) {
      iframe.style.height = px;
      return;
    }
    const before = section.offsetHeight;
    iframe.style.height = px;
    const delta = section.offsetHeight - before;
    if (delta) window.scrollTo(0, y + delta);
  }

  function pronounce() {
    const f = records().find((f) => visible(f) && f.sound);
    if (f) native({ type: 'sound', dict: f.id, path: f.sound });
    return !!f;
  }

  function clear() {
    if (placeTimer) reportPlace();
    indexClose('stay', true); // the list was for the page being replaced
    generation++;
    frames.clear();
    shownWord = null;
    find.cur = null;
    clearTimeout(find.timer);
    via.hidden = true;
    dropGhost();
    col.replaceChildren();
    col.classList.remove('loading');
    col._pending = null;
    list = [];
    pinned = null;
    cancelHold();
    indexBuild([]);
    reportCurrent();
  }

  // ---------- go to a dictionary (⌘J) ----------
  // Every dictionary on the page, as a contents page over the article. The one being
  // read is selected; a click goes to any of them. Typing narrows it by name, initials
  // included ("ldoce"), and the page follows the selection. Leaving it: 'pick' (Return) shows
  // the dictionary if it was hidden; 'stay' keeps the place; 'back' returns to where it was.
  const index = { open: false, q: '', sel: -1, rows: [], back: 0 };

  // Letters that carry no separate accent mark to strip.
  const PLAIN = { đ: 'd', ð: 'd', ħ: 'h', ı: 'i', ł: 'l', ø: 'o', ß: 'ss', æ: 'ae', œ: 'oe', þ: 'th' };

  // Lowercase, accents off, with each folded character's index in the original.
  function folded(s) {
    let t = '';
    const at = [];
    for (let i = 0; i < s.length; i++) {
      const lower = s[i].toLowerCase();
      const f = PLAIN[lower] || lower.normalize('NFD').replace(/\p{M}/gu, '');
      for (let k = 0; k < f.length; k++) { t += f[k]; at.push(i); }
    }
    return { t, at };
  }
  const isWordChar = (c) => /[\p{L}\p{N}]/u.test(c);

  // How well `q` (folded) names `s`: 4 a prefix, 3 a word's start, 2 word starts in
  // order ("ldoce", "oald", "camb adv"), 1 anywhere, else null. Ranges are in `s`.
  // Words start after a non-letter or at a capital inside one ("CollinsCobuild").
  function match(q, s) {
    const { t, at } = folded(s);
    const range = (a, b) => [at[a], at[b - 1] + 1];
    const isStart = (j) => isWordChar(t[j]) && (j === 0 || !isWordChar(t[j - 1]) ||
      (/\p{Lu}/u.test(s[at[j]]) && /\p{Ll}/u.test(s[at[j - 1]])));
    const k = t.indexOf(q);
    if (k === 0) return { score: 4, ranges: [range(0, q.length)] };
    for (let j = k; j > 0; j = t.indexOf(q, j + 1)) {
      if (isStart(j)) return { score: 3, ranges: [range(j, j + q.length)] };
    }
    const starts = [];
    for (let j = 0; j < t.length; j++) if (isStart(j)) starts.push(j);
    const parts = initials(q.replace(/\s+/g, ''), t, starts);
    if (parts) return { score: 2, ranges: parts.map(([a, b]) => range(a, b)) };
    if (k > 0) return { score: 1, ranges: [range(k, k + q.length)] };
    return null;
  }

  // `q` as prefixes of successive words, longest prefix first; failed states are
  // remembered so the search stays linear in practice.
  function initials(q, t, starts) {
    if (!q) return null;
    const out = [];
    const failed = new Set();
    const go = (qi, wi) => {
      if (qi === q.length) return true;
      const key = qi * 4096 + wi;
      if (failed.has(key)) return false;
      for (let w = wi; w < starts.length; w++) {
        const a = starts[w];
        let n = 0;
        while (qi + n < q.length && t[a + n] === q[qi + n]) n++;
        for (; n > 0; n--) {
          out.push([a, a + n]);
          if (go(qi + n, w + 1)) return true;
          out.pop();
        }
      }
      failed.add(key);
      return false;
    };
    return go(0, 0) ? out : null;
  }

  function paint(span, text, ranges) {
    if (!ranges) { span.textContent = text; return; }
    const parts = [];
    let at = 0;
    for (const [a, b] of ranges) {
      if (a > at) parts.push(document.createTextNode(text.slice(at, a)));
      parts.push(el('b', null, text.slice(a, b)));
      at = b;
    }
    if (at < text.length) parts.push(document.createTextNode(text.slice(at)));
    span.replaceChildren(...parts);
  }

  function indexRow(s) {
    const h = s._hit;
    const row = el('div', 'row');
    row.id = 'ix' + index.rows.length;
    row.setAttribute('role', 'option');
    row.title = h.name;
    if (s.classList.contains('collapsed')) row.classList.add('hid');
    // Every row keeps the icon's place, so the names line up with or without one.
    const ic = el('span', 'ic');
    if (h.icon) ic.append(icon(h.icon));
    const nm = el('span', 'nm', h.short);
    row.append(ic, nm);
    if (h.count > 1) row.append(el('span', 'n', String(h.count)));
    row.addEventListener('mousedown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      if (index.open) indexClose('stay', true);
      goTo(s);
    });
    const r = { el: row, nm, short: h.short, name: h.name, section: s, score: 1 };
    s._row = r;
    return r;
  }

  function indexBuild(list) {
    index.sel = -1;
    index.rows = [];
    for (const s of list) index.rows.push(indexRow(s));
    ix.replaceChildren(...index.rows.map((r) => r.el));
    ix.classList.toggle('icons', list.some((s) => s._hit.icon));
    ix.scrollTop = 0;
    followReading();
  }

  // A click on a name: the entry glides to the top, shown if it was hidden.
  function goTo(s) {
    if (s.classList.contains('collapsed')) toggle(s, s._hit);
    jumpTarget = s;
    jumpOffset = 0;
    jumpGlides = true;
    jumpUntil = performance.now() + 900;
    window.scrollTo({ top: Math.max(0, jumpTop()), behavior: glide() });
    followReading();
  }

  function indexOpen() {
    if (index.open || !index.rows.length) return indexReport();
    index.open = true;
    index.q = '';
    index.back = window.scrollY;
    document.body.classList.add('indexing');
    // Opening never moves the page: the selection starts where the reader is.
    followReading();
    const r = index.rows[index.sel];
    if (r) keepInView(r.el);
    indexReport();
  }

  function indexQuery(q) {
    if (!index.open) return;
    index.q = folded(q).t.trim().replace(/\s+/g, ' ');
    let best = -1;
    for (const [i, r] of index.rows.entries()) {
      // The full name counts too ("4th"), though only the short one is shown.
      const a = index.q ? match(index.q, r.short) : null;
      const b = index.q ? match(index.q, r.name) : null;
      r.score = index.q ? Math.max(a ? a.score : 0, b ? b.score : 0) : 1;
      paint(r.nm, r.short, a && a.ranges);
      r.el.classList.toggle('out', !r.score);
      if (r.score && (best < 0 || r.score > index.rows[best].score)) best = i;
    }
    // Nothing by that name: nothing is selected, and the page is back where it was.
    if (index.q && best < 0) {
      setSel(-1, false);
      cancelHold();
      window.scrollTo(0, index.back);
      return;
    }
    // Stay put while the selection is still among the best; clearing keeps the place.
    const cur = index.rows[index.sel];
    if (!index.q || (cur && cur.score === index.rows[best].score)) return indexReport();
    setSel(best, true);
  }

  function indexMove(dir) {
    if (!index.open) return;
    const n = index.rows.length;
    for (let k = 1; k <= n; k++) {
      const i = (((index.sel + dir * k) % n) + n) % n;
      if (index.rows[i].score) return setSel(i, true);
    }
  }

  function setSel(i, follow) {
    const prev = index.rows[index.sel];
    if (prev) {
      prev.el.classList.remove('sel');
      prev.el.removeAttribute('aria-selected');
    }
    index.sel = i;
    const r = index.rows[i];
    if (r) {
      r.el.classList.add('sel');
      r.el.setAttribute('aria-selected', 'true');
      ix.setAttribute('aria-activedescendant', r.el.id);
      keepInView(r.el);
      if (follow) {
        jumpTarget = r.section;
        jumpOffset = 0;
        jumpGlides = false;
        jumpUntil = performance.now() + 900;
        window.scrollTo(0, Math.max(0, jumpTop()));
      }
    } else {
      ix.removeAttribute('aria-activedescendant');
    }
    if (index.open) indexReport();
    reportCurrent();
  }

  // The list says where you are: the entry at the top, or the one a jump is going to.
  // Typing that matches nothing leaves nothing marked.
  function followReading() {
    if (!index.rows.length || (index.q && !index.rows.some((r) => r.score))) return;
    const i = jumpTarget && performance.now() < jumpUntil && list.includes(jumpTarget)
      ? list.indexOf(jumpTarget) : currentIndex();
    if (i !== index.sel) setSel(i, false);
  }

  // The list scrolls on its own when it is taller than the window, keeping a row's
  // worth of room around the selection.
  const ROOM = 26;
  function keepInView(row) {
    const top = row.offsetTop;
    const bottom = top + row.offsetHeight;
    if (top - ROOM < ix.scrollTop) ix.scrollTop = Math.max(0, top - ROOM);
    else if (bottom + ROOM > ix.scrollTop + ix.clientHeight) ix.scrollTop = bottom + ROOM - ix.clientHeight;
  }
  // A press anywhere but on a name closes the list, as outside a popover.
  document.addEventListener('mousedown', (e) => {
    if (e.button === 0 && index.open && !e.target.closest('#index .row')) indexClose('stay', true);
  }, true);

  // `how`: 'pick', 'stay' or 'back' (above). `tell`: the page closed it, not native.
  function indexClose(how, tell) {
    if (!index.open) return;
    index.open = false;
    index.q = '';
    document.body.classList.remove('indexing');
    for (const x of index.rows) {
      x.score = 1;
      x.el.classList.remove('out');
      paint(x.nm, x.short, null);
    }
    const r = index.rows[index.sel];
    if (how === 'back') {
      cancelHold();
      window.scrollTo(0, index.back);
    } else if (how === 'pick' && r && r.section.classList.contains('collapsed')) {
      toggle(r.section, r.section._hit);
    }
    followReading();
    reportCurrent();
    if (tell) native({ type: 'index', open: false });
  }

  function indexReport() {
    // A lone dictionary is named even when the typing doesn't match it ("Only in …").
    const r = index.rows[index.sel] || (index.rows.length === 1 ? index.rows[0] : null);
    native({
      type: 'index',
      open: index.open,
      name: r ? r.short : '',
      matches: index.rows.reduce((n, x) => n + (x.score ? 1 : 0), 0),
      total: index.rows.length,
    });
  }

  // Dictionaries' icons, beside their names here and in ⌘J's list (a setting: some have none).
  function icons(on) { document.documentElement.classList.toggle('noicons', !on); }

  window.sg = {
    icons, show, jump, pronounce, clear, find: findIn, findStep, prepareFind, hideCurrent, cancelHold,
    indexOpen, indexQuery, indexMove, indexClose: (how) => indexClose(how, false),
  };
  native({ type: 'loaded' });
})();
