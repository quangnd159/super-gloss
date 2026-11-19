// Injected into every article iframe (not the main page). Reports its height,
// routes link clicks to the app, and supports double-click lookup.
(() => {
  if (window.top === window) return;
  if (!/^sgloss:$/.test(location.protocol)) return;
  const post = (m) => { try { parent.postMessage({ sg: m }, '*'); } catch (_) {} };

  let last = -1;
  const measure = () => {
    const de = document.documentElement;
    const b = document.body;
    const h = Math.ceil(Math.max(de.getBoundingClientRect().height, b ? b.scrollHeight : 0));
    if (h !== last) { last = h; post({ type: 'height', h }); }
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

  const decode = (s) => { try { return decodeURIComponent(s); } catch (_) { return s; } };

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
      if (target.startsWith('#')) {
        const t = document.getElementById(target.slice(1)) || document.getElementsByName(target.slice(1))[0];
        if (t) t.scrollIntoView({ behavior: 'smooth' });
        return;
      }
      const word = decode(target.split('#')[0]).replace(/\/+$/, '');
      if (word) post({ type: 'lookup', word });
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

  // Typing while an article has focus goes back to the search field.
  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key.length === 1 || e.key === 'Escape') {
      post({ type: 'key', key: e.key });
      e.preventDefault();
    }
  });
})();
