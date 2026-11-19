// Main reading surface. Native calls `sg.show(payload)`; each source renders in an
// isolated iframe (its own CSS/JS) that reports height and actions via postMessage.
(() => {
  const col = document.getElementById('col');
  const via = document.getElementById('via');
  const frames = new Map(); // contentWindow -> {id, iframe, section, sound}
  const collapsed = new Set();
  let generation = 0;

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
    if (p.via) {
      via.hidden = false;
      via.replaceChildren(document.createTextNode(p.word + ' → '), el('b', null, p.via));
    } else {
      via.hidden = true;
    }
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
      f.src = h.url;
      b.append(f);
      s.append(g, b);
      next.append(s);
      pending.add(f);
      frames.set(f, { id: h.id, iframe: f, section: s, sound: null });
    }
    col.classList.add('loading');
    col.replaceChildren(next);
    jumpTarget = null;
    window.scrollTo(0, 0);
    // Reveal once every frame has reported a height, or after a short grace period.
    const reveal = () => { if (gen === generation) col.classList.remove('loading'); };
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
          if (col._pending.size === 0) col._reveal();
        }
        break;
      case 'ready': f.sound = m.sound || null; break;
      case 'lookup': native({ type: 'lookup', word: String(m.word || '') }); break;
      case 'sound': native({ type: 'sound', dict: f.id, path: String(m.path || '') }); break;
      case 'open': native({ type: 'open', url: String(m.url || '') }); break;
      case 'key': native({ type: 'key', key: String(m.key || '') }); break;
    }
  });

  function sections() { return Array.from(col.querySelectorAll('.src')); }

  // Where the reader is: the section whose top is at or above the viewport top.
  const TOP = 6;
  let jumpTarget = null;
  let jumpUntil = 0;

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
    jumpUntil = performance.now() + 900;
    window.scrollTo({ top: i === 0 ? 0 : jumpTarget.offsetTop - TOP, behavior: 'smooth' });
  }

  // WebKit has no scroll anchoring: when a frame above the reading position grows
  // (late images, fonts), keep the text under the reader where it was.
  function setHeight(iframe, h) {
    const px = h + 'px';
    if (iframe.style.height === px) return;
    if (jumpTarget && performance.now() < jumpUntil) {
      iframe.style.height = px;
      const list = sections();
      const i = list.indexOf(jumpTarget);
      if (i >= 0) window.scrollTo({ top: i === 0 ? 0 : jumpTarget.offsetTop - TOP, behavior: 'smooth' });
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
    via.hidden = true;
    col.replaceChildren();
  }

  window.sg = { show, jump, pronounce, page, clear };
  native({ type: 'loaded' });
})();
