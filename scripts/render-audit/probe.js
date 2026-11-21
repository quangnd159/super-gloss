// Injected into each article frame once it has loaded: what the reader would see go wrong.
(() => {
  if (window.top === window) return;
  const describe = (e) => {
    let s = e.tagName.toLowerCase();
    if (e.id) s += '#' + e.id;
    if (typeof e.className === 'string' && e.className.trim()) s += '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.');
    return s;
  };
  const probe = () => {
    const b = document.body;
    const edge = b.getBoundingClientRect().right;
    // The outermost element reaching past the frame's edge: what makes it scroll.
    let culprit = null;
    if (b.scrollWidth > b.clientWidth) {
      for (const e of b.querySelectorAll('*')) {
        const r = e.getBoundingClientRect();
        if (!r.width || r.right <= edge + 0.5) continue;
        culprit = describe(e) + ' +' + Math.round(r.right - edge) + 'px';
        break;
      }
    }
    // The face the text reads in, weighted by characters.
    const faces = {};
    let chars = 0;
    const walk = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      const k = n.data.trim().length;
      if (!k || !n.parentElement || !n.parentElement.getClientRects().length) continue;
      const cs = getComputedStyle(n.parentElement);
      const face = cs.fontFamily.split(',')[0].trim().replace(/^"|"$/g, '') + ' ' + cs.fontSize;
      faces[face] = (faces[face] || 0) + k;
      chars += k;
    }
    const face = Object.entries(faces).sort((x, y) => y[1] - x[1])[0];
    webkit.messageHandlers.probe.postMessage({
      url: location.href.split('#')[0],
      overflow: b.scrollWidth - b.clientWidth,
      height: Math.ceil(b.getBoundingClientRect().height),
      culprit,
      face: face ? face[0] : '',
      faceShare: face ? face[1] / chars : 0,
      broken: [...document.images].filter((i) => i.complete && !i.naturalWidth).map((i) => i.getAttribute('src')),
      errors: window.__probeErrors || [],
    });
  };
  if (document.readyState === 'complete') setTimeout(probe, 400);
  else addEventListener('load', () => setTimeout(probe, 400));
})();
