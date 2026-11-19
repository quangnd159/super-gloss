// Main reading surface. Native calls `sg.show(payload)`; each source renders in an
// isolated iframe (its own CSS/JS) that reports height and actions via postMessage.
(() => {
  const col = document.getElementById('col');
  const via = document.getElementById('via');
  const frames = new Map(); // contentWindow -> {id, iframe, section, sound}
  const collapsed = new Set();
  let generation = 0;
  let shownWord = null;

  const native = (msg) => {
    try { window.webkit.messageHandlers.sg.postMessage(msg); } catch (_) {}
  };

  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  };

  function show(p) {
    const gen = ++generation;
    frames.clear();
    shownWord = p.word;
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
    for (const h of p.hits) {
      const s = el('section', 'src');
      s.dataset.id = h.id;
      if (collapsed.has(h.id)) s.classList.add('collapsed');
      const g = el('div', 'gloss');
      g.title = h.name + (collapsed.has(h.id) ? ' — click to show' : ' — click to hide');
      if (h.icon) {
        const img = el('img');
        img.src = h.icon;
        img.alt = '';
        img.onerror = () => img.remove();
        g.append(img);
      }
      g.append(document.createTextNode(h.short));
      if (h.count > 1) g.append(el('span', 'n', h.count + ' entries'));
      g.addEventListener('click', () => toggle(s, h));
      const b = el('div', 'body');
      const f = el('iframe');
      f.setAttribute('scrolling', 'no');
      f.setAttribute('title', h.name);
      if (land && land.dict === h.id) landSection = s;
      const anchored = land && land.dict === h.id && land.offset == null;
      f.src = h.url + (anchored ? '#' + encodeURIComponent(JSON.stringify({ id: land.id, find: land.find })) : '');
      b.append(f);
      s.append(g, b);
      next.append(s);
      pending.add(f);
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
      window.scrollTo(0, Math.max(0, jumpTop(sections())));
    }
    // Reveal once every frame has reported a height, or after a short grace period.
    col._onReveal = null;
    const reveal = () => {
      if (gen !== generation) return;
      col.classList.remove('loading');
      const then = col._onReveal;
      col._onReveal = null;
      if (then) then();
    };
    if (pending.size === 0) reveal();
    col._pending = pending;
    col._reveal = reveal;
    setTimeout(reveal, 220);
  }

  function toggle(s, h) {
    const on = !collapsed.has(h.id);
    if (on) collapsed.add(h.id); else collapsed.delete(h.id);
    s.classList.toggle('collapsed', on);
    s.querySelector('.gloss').title = h.name + (on ? ' — click to show' : ' — click to hide');
    if (find.q) {
      if (on && find.cur && find.cur.f.section === s) find.cur = null;
      report();
    }
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
        if (col._pending) {
          col._pending.delete(f.iframe);
          if (col._pending.size === 0) {
            // Everything has a height: hold a restored position only a moment longer.
            jumpUntil = Math.min(jumpUntil, performance.now() + 250);
            col._reveal();
          }
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

  function sections() { return Array.from(col.querySelectorAll('.src')); }

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
  function records() { return sections().map((s) => s._rec).filter(Boolean); }
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
    window.scrollTo({ top: Math.max(0, y - vh * 0.36), behavior: 'smooth' });
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

  // The margin gloss carries each source's count; sources without one recede (the
  // frame dims its own content: ancestor opacity doesn't reach out-of-process frames).
  function paintCount(f) {
    const g = f.section.querySelector('.gloss');
    if (!g) return;
    let fn = g.querySelector('.fn');
    const n = find.q && f.found ? f.found.length : null;
    f.section.classList.toggle('nofind', n === 0);
    if (n) {
      if (!fn) { fn = el('span', 'fn'); g.append(fn); }
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

  function jumpTop(list) {
    return list[0] === jumpTarget && !jumpOffset ? 0 : jumpTarget.offsetTop + jumpOffset - TOP;
  }

  // `y` is the anchor's position inside the frame. Near the top of its entry,
  // land on the section so the dictionary's name stays in view.
  function scrollToAnchor(f, y) {
    jumpTarget = f.section;
    jumpOffset = y < 48 ? 0 : f.iframe.getBoundingClientRect().top + window.scrollY + y - 18 - f.section.offsetTop;
    jumpUntil = performance.now() + 900;
    window.scrollTo(0, Math.max(0, jumpTop(sections())));
  }

  function mark(f, m) {
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
    const list = sections();
    let place = null;
    if (list.length && window.scrollY > 0) {
      const s = list[currentIndex(list)];
      place = { dict: s.dataset.id, offset: Math.round(window.scrollY - s.offsetTop) };
    }
    native({ type: 'place', word: shownWord, place });
  }
  window.addEventListener('scroll', () => {
    clearTimeout(placeTimer);
    placeTimer = setTimeout(reportPlace, 150);
  }, { passive: true });

  function currentIndex(list) {
    const y = window.scrollY + TOP + 8;
    let i = 0;
    for (let k = 0; k < list.length; k++) if (list[k].offsetTop <= y) i = k;
    return i;
  }

  function jump(dir) {
    const list = sections();
    if (!list.length) return;
    let i;
    if (jumpTarget && performance.now() < jumpUntil && list.includes(jumpTarget)) {
      // A jump is still animating: step from where it is going, not where it is.
      i = list.indexOf(jumpTarget) + dir;
    } else {
      i = currentIndex(list);
      const above = window.scrollY > list[i].offsetTop - TOP + 8;
      i = dir > 0 ? i + 1 : (above ? i : i - 1);
    }
    i = Math.max(0, Math.min(list.length - 1, i));
    jumpTarget = list[i];
    jumpOffset = 0;
    jumpUntil = performance.now() + 900;
    window.scrollTo({ top: jumpTop(list), behavior: 'smooth' });
  }

  // WebKit has no scroll anchoring: when a frame above the reading position grows
  // (late images, fonts), keep the text under the reader where it was.
  function setHeight(iframe, h) {
    const px = h + 'px';
    if (iframe.style.height === px) return;
    if (jumpTarget && performance.now() < jumpUntil) {
      iframe.style.height = px;
      const list = sections();
      if (list.includes(jumpTarget)) window.scrollTo({ top: jumpTop(list), behavior: jumpOffset ? 'auto' : 'smooth' });
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
    for (const s of sections()) {
      if (s.classList.contains('collapsed')) continue;
      for (const f of frames.values()) {
        if (f.section === s && f.sound) {
          native({ type: 'sound', dict: f.id, path: f.sound });
          return true;
        }
      }
    }
    return false;
  }

  function page(dir) {
    window.scrollBy({ top: dir * (window.innerHeight * 0.85), behavior: 'smooth' });
  }

  function clear() {
    generation++;
    frames.clear();
    shownWord = null;
    find.cur = null;
    via.hidden = true;
    col.replaceChildren();
  }

  window.sg = { show, jump, pronounce, page, clear, find: findIn, findStep, prepareFind };
  native({ type: 'loaded' });
})();
