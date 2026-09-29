// Rainy glass for any website -- opt-in per site from the toolbar button or
// ⌥⇧G (see background.js); never applied to a site you haven't turned on.
//
// Puts Rainy's rain (backdrop.html, the same renderer as the New Tab page)
// in a fixed frame behind the page, then re-skins the page as liquid glass:
// page backgrounds go transparent, page-scale wrappers become thin smoke,
// cards/panels and filled buttons become clear lenses the backdrop refracts
// (buttons keep their colour as text), and dark text is flipped light. With
// Rainy's kill switch on, the backdrop is a still wallpaper drawn only on
// change -- the glass stays. Every change is an inline !important override
// whose original value is recorded, so turning it off restores the page
// exactly.
(() => {
  if (window.__rainyGlass) return; // already loaded; background.js drives it by message
  window.__rainyGlass = true;

  const SKIP = new Set(['IMG', 'VIDEO', 'CANVAS', 'PICTURE', 'IFRAME', 'SCRIPT', 'STYLE', 'LINK', 'META',
                        'NOSCRIPT', 'BR', 'HEAD', 'TITLE', 'OBJECT', 'EMBED', 'SOURCE', 'TRACK']);
  const FIELDS = new Set(['INPUT', 'TEXTAREA', 'SELECT']);
  const originals = new Map(); // element -> { prop: [value, priority] }
  const liquid = new Set();    // filled accent buttons turned into liquid-glass lenses
  const unsized = new Set();   // filled elements classified while they had no size
  const panels = new Set();    // smaller opaque surfaces (cards, inputs, menus): lenses while effects are on
  const SMOKE = 'rgba(10, 10, 14, 0.3)';
  let glassOn = false;         // backdrop can draw lenses (WebGL ok); until it says so, flat smoke
  let live = false;            // effects on: rain animating, so lens positions stream every frame
  let moveTimer = null;
  let frameReady = false;      // backdrop loaded: before that, its window still has the page's origin
  let on = false, frame = null, observer = null;
  const pending = new Set();
  let flushTimer = null;

  // ---- colour helpers ----
  // Any CSS colour -> [r, g, b, a]. Computed styles come back as rgb() for
  // classic colours but as oklch()/lab()/color(srgb ...) for modern design
  // tokens (Google's, ChatGPT's); a 1x1 canvas converts those to sRGB.
  const colorCache = new Map();
  let colorCtx = null;
  function parseColor(str) {
    if (!str) return null;
    const m = /^rgba?\(([^)]+)\)$/.exec(str);
    if (m) {
      const p = m[1].split(/[\s,/]+/).filter(Boolean).map(parseFloat);
      return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
    }
    if (colorCache.has(str)) return colorCache.get(str);
    let out = null;
    try {
      colorCtx ??= new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
      colorCtx.clearRect(0, 0, 1, 1);
      colorCtx.fillStyle = 'rgba(0, 0, 0, 0)';
      colorCtx.fillStyle = str; // ignored if the browser can't parse it
      colorCtx.fillRect(0, 0, 1, 1);
      const [r, g, b, a] = colorCtx.getImageData(0, 0, 1, 1).data;
      out = [r, g, b, a / 255];
    } catch {}
    if (colorCache.size > 500) colorCache.clear();
    colorCache.set(str, out);
    return out;
  }
  const luminance = ([r, g, b]) => (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  const saturation = ([r, g, b]) => {
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    return max === 0 ? 0 : (max - min) / max;
  };

  // Dark text -> light, keeping its hue (links stay blue-ish, not white).
  function lighten([r, g, b, a]) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min;
    let h = 0, s = 0;
    if (d) {
      s = d / (1 - Math.abs(2 * l - 1));
      h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
      h *= 60;
    }
    const L = 0.9 - l * 0.55, S = s * 0.75;
    const c = (1 - Math.abs(2 * L - 1)) * S, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = L - c / 2;
    const [r1, g1, b1] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
      : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return `rgba(${Math.round((r1 + m) * 255)}, ${Math.round((g1 + m) * 255)}, ${Math.round((b1 + m) * 255)}, ${a})`;
  }

  // A filled button's colour, reused as its text colour on dark glass:
  // same hue, lifted to a readable lightness.
  function accentText([r, g, b]) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    let h = 0;
    if (d) h = 60 * (max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4);
    if (h < 0) h += 360;
    const l = Math.max((max + min) / 2, 0.66), sat = d ? Math.min(1, d / (1 - Math.abs(max + min - 1)) ) : 0;
    const c = (1 - Math.abs(2 * l - 1)) * sat, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = l - c / 2;
    const [r1, g1, b1] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
      : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return `rgb(${Math.round((r1 + m) * 255)}, ${Math.round((g1 + m) * 255)}, ${Math.round((b1 + m) * 255)})`;
  }

  function restoreProp(el, prop) {
    const saved = originals.get(el);
    if (!saved || !(prop in saved)) return;
    const [value, priority] = saved[prop];
    if (value) el.style.setProperty(prop, value, priority);
    else el.style.removeProperty(prop);
    delete saved[prop];
  }

  // ---- pseudo-element fills ----
  const pseudoFill = new Map();  // element -> '::before' | '::after' painting its surface
  const decorFill = new Map();   // element -> empty positioned child painting its surface
  const decorChildren = new Set();
  const hostFill = new Map();    // host -> the fill its pseudo/decoration painted
  const gradientEls = new WeakSet(); // elements whose own gradient background we keep
  const decorRadius = new Map(); // host -> border-radius adopted from its decoration
  const DECOR_CLEAR = [['background-color', 'transparent'], ['background-image', 'none'], ['box-shadow', 'none'],
                       ['border-color', 'transparent'], ['backdrop-filter', 'none'], ['-webkit-backdrop-filter', 'none']];
  // A fill from a style: its solid colour only.
  const isGradient = (img) => !!img && /gradient\(/.test(img);
  function fillOf(st, isPseudo) {
    if (isPseudo && (st.content === 'none' || st.content === 'normal' || st.position === 'static')) return null;
    const c = parseColor(st.backgroundColor);
    if (c && c[3] > 0.3) return c;
    // Gradient-only layers are rings/glows/gradient art, which we keep --
    // never a fill that makes something else a surface.
    return null;
  }
  // A pseudo-element is the host's surface only if it covers most of it --
  // not a bullet dot, badge or underline.
  function pseudoCovers(ps, box) {
    const w = parseFloat(ps.width), h = parseFloat(ps.height);
    return w > 0 && h > 0 && w * h >= 0.8 * box.width * box.height;
  }
  const pseudoMarked = new Set();
  const pseudoRules = new Set();
  let pseudoSheet = null, pseudoSeq = 0;
  function clearPseudo(el, pseudo) {
    if (!pseudoSheet) {
      const style = document.createElement('style');
      style.dataset.rainyGlass = '';
      document.documentElement.appendChild(style);
      pseudoSheet = style;
    }
    let id = el.getAttribute('data-rainy-p');
    if (!id) { id = String(++pseudoSeq); el.setAttribute('data-rainy-p', id); pseudoMarked.add(el); }
    if (pseudoRules.has(id + pseudo)) return; // already cleared on an earlier pass
    pseudoRules.add(id + pseudo);
    // Gradients stay (Google AI Mode's animated ring is a gradient ::before);
    // solid fills, shadows and borders go.
    const keepImage = isGradient(getComputedStyle(el, pseudo).backgroundImage);
    pseudoSheet.sheet.insertRule(`[data-rainy-p="${id}"]${pseudo}{background-color:transparent!important;` +
      (keepImage ? '' : 'background-image:none!important;') +
      'box-shadow:none!important;border-color:transparent!important;' +
      'backdrop-filter:none!important;-webkit-backdrop-filter:none!important}', pseudoSheet.sheet.cssRules.length);
  }
  function removePseudoRules() {
    pseudoSheet?.remove();
    pseudoSheet = null;
    for (const el of pseudoMarked) el.removeAttribute('data-rainy-p');
    pseudoMarked.clear();
    pseudoRules.clear();
    pseudoFill.clear();
    decorFill.clear();
    decorChildren.clear();
    hostFill.clear();
    decorRadius.clear();
  }

  function override(el, prop, value) {
    let saved = originals.get(el);
    if (!saved) originals.set(el, (saved = {}));
    if (!(prop in saved)) saved[prop] = [el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)];
    el.style.setProperty(prop, value, 'important');
  }

  // ---- floating layers ----
  // Menus, pop-ups, dialogs, tooltips and sticky/fixed bars sit on top of
  // other page content. A clear lens would only refract the wallpaper behind
  // the whole page, so the content underneath would show straight through
  // and two layers of text would mix. Those get frosted dark glass instead:
  // a real blur of what's under them (backdrop-filter) plus dense smoke.
  const FLOATING_ROLES = /^(dialog|alertdialog|menu|listbox|tooltip|combobox)$/;
  let floatCache = new Map(); // element -> its floating layer root (or null); per restyle pass
  function floatingRoot(el) {
    const path = [];
    for (let node = el; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      if (floatCache.has(node)) { const v = floatCache.get(node); for (const p of path) floatCache.set(p, v); return v; }
      path.push(node);
      const cs = getComputedStyle(node);
      // A page-sized absolutely positioned box is layout (Classroom lays out
      // its whole content area that way), not something floating over
      // content: keep looking further up. Fixed ones still count -- modal
      // overlays are page-sized fixed layers.
      let layoutBox = false;
      if (cs.position === 'absolute') {
        const r = node.getBoundingClientRect();
        layoutBox = r.width * r.height > innerWidth * innerHeight * 0.45 && r.width > 320 && r.height > 160;
      }
      if (!layoutBox && (cs.position === 'fixed' || cs.position === 'sticky' || cs.position === 'absolute'
          || node.tagName === 'DIALOG' || FLOATING_ROLES.test(node.getAttribute('role') || ''))) {
        for (const p of path) floatCache.set(p, node);
        return node;
      }
    }
    for (const p of path) floatCache.set(p, null);
    return null;
  }
  // Only the outermost filled surface of a floating stack gets a pane;
  // filled things anywhere inside another glass surface (a pane, a clear
  // panel, or a filled ancestor that will become one) just get a soft tint.
  // Page-scale wrappers don't count -- they're the page, not a surface.
  function insideSurface(el) {
    for (let p = el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
      if (layers.has(p) || panels.has(p) || hostFill.has(p)) return true;
      const bg = parseColor(getComputedStyle(p).backgroundColor);
      if (bg && bg[3] > 0.3) {
        const r = p.getBoundingClientRect();
        const big = r.width * r.height > innerWidth * innerHeight * 0.45 && r.width > 320 && r.height > 160;
        if (!big) return true;
      }
    }
    return false;
  }
  // A floating layer's surface gets a glass pane (pane.html): its own frame
  // drawing a liquid-glass lens over the wallpaper for exactly where the
  // layer sits, so it reads as glass over the desktop while fully covering
  // the page content beneath -- never text over text. No border or shadow:
  // the lens rim is the edge. Underneath is dark frosted blur: what shows
  // while a pane loads, for layers without one (tiny, or past the cap), and
  // for any sliver a pane doesn't cover -- never solid black, never the page
  // text through it.
  const PANE_LOOK = [['background-color', 'rgba(16, 16, 20, 0.9)'], ['background-image', 'none'],
                     ['backdrop-filter', 'blur(20px) saturate(1.2)'], ['-webkit-backdrop-filter', 'blur(20px) saturate(1.2)'],
                     ['border-color', 'transparent'], ['box-shadow', 'none'], ['isolation', 'isolate']];

  // ---- gradient glow rings ----
  // A gradient layer sitting right behind a filled surface of the same size
  // (Google's animated AI ring behind the search pill) only ever showed as a
  // band around that surface's edge. Once the surface turns to clear glass,
  // the whole gradient would show through it -- so mask the layer to a ring:
  // everything except the surface's (rounded) interior, outer glow included.
  function ringMaskFor(el, cs) {
    if (cs.position !== 'absolute' && cs.position !== 'fixed') return null;
    const r = el.getBoundingClientRect();
    if (r.width < 40 || r.height < 20) return null;
    const near = (a, b) => Math.abs(a - b) <= 24;
    let host = null;
    for (const cand of document.elementsFromPoint(r.left + r.width / 2, r.top + r.height / 2)) {
      if (cand === el || el.contains(cand) || cand.contains(el) || cand === frame) continue;
      const b = cand.getBoundingClientRect();
      if (!(near(b.left, r.left) && near(b.right, r.right) && near(b.top, r.top) && near(b.bottom, r.bottom))) continue;
      const bg = parseColor(getComputedStyle(cand).backgroundColor);
      if (panels.has(cand) || (bg && bg[3] > 0.3)) { host = cand; break; }
    }
    if (!host) return null;
    const hb = host.getBoundingClientRect(), hcs = getComputedStyle(host);
    const M = 48, band = 3; // outer margin kept for the glow; ring width inside the edge
    const w = r.width + 2 * M, h = r.height + 2 * M;
    const x = hb.left - r.left + M + band, y = hb.top - r.top + M + band;
    const iw = Math.max(hb.width - 2 * band, 0), ih = Math.max(hb.height - 2 * band, 0);
    const rad = Math.min(Math.max((parseFloat(hcs.borderTopLeftRadius) || 0) - band, 0), iw / 2, ih / 2);
    const hole = `M${x + rad} ${y}H${x + iw - rad}A${rad} ${rad} 0 0 1 ${x + iw} ${y + rad}V${y + ih - rad}` +
      `A${rad} ${rad} 0 0 1 ${x + iw - rad} ${y + ih}H${x + rad}A${rad} ${rad} 0 0 1 ${x} ${y + ih - rad}` +
      `V${y + rad}A${rad} ${rad} 0 0 1 ${x + rad} ${y}Z`;
    const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='${w}' height='${h}'>` +
      `<path fill-rule='evenodd' fill='black' d='M0 0H${w}V${h}H0Z${hole}'/></svg>`;
    const url = `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
    const out = [];
    for (const pre of ['', '-webkit-']) {
      out.push([`${pre}mask-image`, url], [`${pre}mask-repeat`, 'no-repeat'],
               [`${pre}mask-position`, `${-M}px ${-M}px`], [`${pre}mask-size`, `${w}px ${h}px`],
               [`${pre}mask-clip`, 'no-clip']);
    }
    return out;
  }

  // Per-site decorative picture surfaces that should be liquid glass instead
  // of a photo/illustration. Pictures are otherwise always left alone.
  const SITE_GLASS = {
    'classroom.google.com': '.PFLqgc', // class banner (theme illustration behind the class name)
  };
  const siteGlass = SITE_GLASS[location.hostname] || null;

  // SVG shapes painted in a near-white surface colour are page chrome, not
  // icons -- e.g. the concave corner piece Google Classroom draws beside its
  // tab bar (a 32x32 path filled with the frame colour), which showed as a
  // white wedge. Icons use currentColor (fill == text colour) and are left
  // alone, as are coloured shapes (logos, illustrations).
  const SVG_SHAPES = new Set(['path', 'rect', 'circle', 'ellipse', 'polygon']);
  function planSvgShape(el) {
    if (!SVG_SHAPES.has(el.tagName)) return null;
    // Never masks/clips/defs, clipped or filtered shapes, or SVGs acting as
    // images or links: Google's dark-mode logo is a white rect clipped to
    // the letter shapes, and clearing it made the logo vanish.
    if (el.closest('clipPath, clippath, mask, defs, pattern, symbol, marker, a, [role="img"], [aria-label]')) return null;
    for (let n = el; n && n.tagName !== 'svg'; n = n.parentElement) {
      if (n.hasAttribute('clip-path') || n.hasAttribute('mask') || n.hasAttribute('filter')) return null;
    }
    const cs = getComputedStyle(el);
    if (cs.clipPath !== 'none' || cs.mask !== 'none' && cs.maskImage !== 'none' || cs.filter !== 'none') return null;
    if (cs.fill === cs.color) return null; // currentColor
    const fill = parseColor(cs.fill);
    if (!fill || fill[3] < 0.5 || luminance(fill) < 0.85 || saturation(fill) > 0.15) return null;
    return [el, [['fill', 'transparent']]];
  }

  // ---- restyling: read everything first, then write (no layout thrash) ----
  function plan(el) {
    if (el === frame || SKIP.has(el.tagName)) return null;
    if (el instanceof SVGElement) return planSvgShape(el);
    // HTML inside an SVG (<foreignObject>) is part of a graphic -- Google's
    // logo is drawn that way -- not page chrome: leave it alone.
    if (el.closest('svg')) return null;
    const cs = getComputedStyle(el);
    // Gradient-coloured text (background-clip: text + transparent colour --
    // Google's greeting name, gradient logos/headlines) is text, not a
    // surface: clearing its "background" made the text vanish into a pill.
    if (cs.backgroundClip === 'text' || cs.webkitBackgroundClip === 'text') return null;
    const writes = [];
    let panel = false;
    if (el === document.documentElement || el === document.body) {
      writes.push(['background', 'transparent']);
    } else {
      let bg = parseColor(cs.backgroundColor);
      // A gradient painted as the element's own background (Google paints
      // many white surfaces as linear-gradient(white, white)) is a fill too;
      // it's cleared along with the colour.
      const ownGradient = isGradient(cs.backgroundImage);
      // Site-specific decorative picture surfaces (see SITE_GLASS): drop the
      // picture and treat the element as a glass surface.
      if (siteGlass && el.matches(siteGlass)) {
        writes.push(['background-image', 'none']);
        if (!(bg && bg[3] > 0.05)) bg = [236, 236, 238, 1];
      }
      // An element's own gradient background is kept (gradient buttons,
      // banners, headers): not treated as a fill, and never cleared below.
      if (ownGradient && !(siteGlass && el.matches(siteGlass))) {
        gradientEls.add(el);
        const ring = ringMaskFor(el, cs);
        if (ring) writes.push(...ring);
      }
      // Surfaces often paint their fill with a ::before/::after positioned
      // over them (inline styles can't reach those): treat the host as that
      // surface and clear the pseudo's fill via a stylesheet rule.
      if (!(bg && bg[3] > 0.05)) {
        const box = el.getBoundingClientRect();
        for (const pseudo of ['::before', '::after']) {
          const ps = getComputedStyle(el, pseudo);
          const fill = fillOf(ps, true);
          if (fill && pseudoCovers(ps, box)) { bg = fill; pseudoFill.set(el, pseudo); break; }
        }
      }
      if (!(bg && bg[3] > 0.05) && cs.position !== 'static') {
        // ...or with an empty, absolutely positioned decoration layer that
        // covers it (Google's input plate): the host is the surface, and the
        // decoration (plus its pseudos) gets cleared.
        if (!pseudoFill.has(el) && el.childElementCount) {
          const box = el.getBoundingClientRect();
          for (const child of el.children) {
            if (child.childElementCount || child.textContent.trim() || SKIP.has(child.tagName)) continue;
            const ccs = getComputedStyle(child);
            if (ccs.position !== 'absolute' && ccs.position !== 'fixed') continue;
            const cb = child.getBoundingClientRect();
            if (cb.width * cb.height < 0.8 * box.width * box.height) continue;
            const cbox = { width: cb.width, height: cb.height };
            const before = getComputedStyle(child, '::before'), after = getComputedStyle(child, '::after');
            const fill = fillOf(ccs, false) || (pseudoCovers(before, cbox) && fillOf(before, true))
              || (pseudoCovers(after, cbox) && fillOf(after, true));
            if (fill) {
              bg = fill;
              decorFill.set(el, child);
              decorChildren.add(child);
              // The decoration carries the shape (a rounded pill on a square
              // wrapper): the host adopts it, or its glass comes out square.
              if (parseFloat(cs.borderTopLeftRadius) === 0 && parseFloat(ccs.borderTopLeftRadius) > 0) {
                decorRadius.set(el, ccs.borderRadius);
              }
              break;
            }
          }
        }
      }
      // Re-checks: the pseudo/decoration is already cleared by then, so
      // reuse the fill found the first time.
      if (bg && bg[3] > 0.05 && (pseudoFill.has(el) || decorFill.has(el))) hostFill.set(el, bg);
      else if (!(bg && bg[3] > 0.05) && hostFill.has(el)) bg = hostFill.get(el);
      // Faintly tinted floating layers (translucent menus) still need frost.
      const layer = bg && bg[3] > 0.05 ? floatingRoot(el) : null;
      if (bg && (bg[3] > 0.3 || (layer && bg[3] > 0.05))) {
        const r = el.getBoundingClientRect();
        // Not laid out yet (app still hydrating, or hidden): classify now,
        // but re-check once it has a real size (see audit).
        if (r.width * r.height === 0) unsized.add(el); else unsized.delete(el);
        // Page-scale wrappers stay thin smoke; everything smaller is a panel.
        const big = r.width * r.height > innerWidth * innerHeight * 0.45 && r.width > 320 && r.height > 160;
        // Small, strongly coloured fills (buttons, badges, toggles) become
        // clear liquid-glass lenses drawn by the backdrop, with their fill
        // colour moved to the text.
        const accent = !big && saturation(bg) > 0.35 && r.width * r.height < 40000;
        if (accent) {
          const text = accentText(bg);
          writes.push(['background-color', 'transparent'], ['background-image', 'none'],
                      ['border-color', 'transparent'], ['box-shadow', 'none'], ['color', text]);
          // Inside a floating layer the lens would be hidden under it: just
          // keep the coloured text on the layer's frost.
          return [el, writes, layer ? null : text, false, layer ? text : null];
        }
        // Page-scale wrappers become thin smoke -- including absolutely
        // positioned or fixed ones with a solid fill (Classroom's main content
        // surface is one). Only see-through full-page layers (the dimming
        // scrim behind a dialog) keep their own look.
        if (big) { if (!layer || bg[3] >= 0.9) writes.push(['background-color', 'rgba(6, 6, 9, 0.18)']); }
        // Form fields keep a soft dark well: as clear glass inside a glass
        // card they'd vanish entirely.
        else if (FIELDS.has(el.tagName)) writes.push(['background-color', 'rgba(0, 0, 0, 0.28)'], ['border-color', 'transparent']);
        else if (layer && !insideSurface(el)) {
          writes.push(...PANE_LOOK);
          if (cs.position === 'static') writes.push(['position', 'relative']); // anchor for the pane
          return [el, writes, null, false, null, true];
        }
        // Nested inside glass (e.g. a toggle's selected-state pill): a soft
        // darker tint, shape kept, so it still reads on the glass.
        else if (layer) writes.push(['background-color', 'rgba(0, 0, 0, 0.22)'], ['background-image', 'none'],
                                    ['border-color', 'transparent'], ['box-shadow', 'none'],
                                    ['backdrop-filter', 'none'], ['-webkit-backdrop-filter', 'none']);
        else { panel = true; writes.push(...panelLook()); }
      }
    }
    const fg = parseColor(cs.color);
    if (fg && luminance(fg) < 0.5) writes.push(['color', lighten(fg)]);
    const visibleBorder = ['Top', 'Right', 'Bottom', 'Left'].some((side) => {
      const c = parseColor(cs[`border${side}Color`]);
      return parseFloat(cs[`border${side}Width`]) > 0 && c && c[3] > 0;
    });
    if (!panel && visibleBorder) {
      writes.push(['border-color', 'transparent']); // no dark (or light) outlines: glass edges mark shapes
    }
    return writes.length ? [el, writes, null, panel] : null;
  }

  // A panel is a clear lens whenever the backdrop can draw glass -- no fill,
  // no border, no shadow: the glass rim is its edge -- else flat smoke.
  function panelLook() {
    return glassOn
      ? [['background-color', 'transparent'], ['border-color', 'transparent'], ['box-shadow', 'none']]
      : [['background-color', SMOKE], ['border-color', 'transparent']];
  }

  function restyle(elements) {
    floatCache = new Map(); // positions/roles may have changed since last pass
    const plans = [];
    for (const el of elements) {
      if (!el.isConnected) continue;
      const p = plan(el);
      if (p) plans.push(p);
    }
    for (const [el, writes, liquidText, panel, layerText, pane] of plans) {
      if (decorChildren.has(el)) continue; // a decoration layer: cleared via its host, never its own lens
      for (const [prop, value] of writes) {
        if (prop === 'background-image' && gradientEls.has(el)) continue; // keep its gradient
        override(el, prop, value);
      }
      if (pseudoFill.has(el)) clearPseudo(el, pseudoFill.get(el));
      if (decorFill.has(el)) {
        const child = decorFill.get(el);
        const childGradient = isGradient(getComputedStyle(child).backgroundImage);
        for (const [prop, value] of DECOR_CLEAR) {
          if (prop === 'background-image' && childGradient) continue; // keep gradient rings
          override(child, prop, value);
        }
        if (decorRadius.has(el)) override(el, 'border-radius', decorRadius.get(el));
        clearPseudo(child, '::before');
        clearPseudo(child, '::after');
      }
      if (pane) layers.add(el);
      else if (layers.has(el)) {
        // No longer a floating surface (e.g. now measured page-sized): drop
        // its pane and the frost/isolation it was given.
        layers.delete(el);
        panes.get(el)?.remove();
        panes.delete(el);
        for (const prop of ['backdrop-filter', '-webkit-backdrop-filter', 'isolation', 'position']) {
          if (!writes.some(([w]) => w === prop)) restoreProp(el, prop);
        }
      }
      if (panel) panels.add(el);
      else panels.delete(el); // e.g. it has since become part of a floating layer
      if (!liquidText) liquid.delete(el);
      if (layerText) {
        for (const child of el.querySelectorAll('*')) {
          if (!(child instanceof SVGElement)) override(child, 'color', layerText);
        }
      }
      if (liquidText) {
        liquid.add(el);
        // Labels/icons inside the button follow the new text colour.
        for (const child of el.querySelectorAll('*')) {
          if (!(child instanceof SVGElement)) override(child, 'color', liquidText);
        }
      }
    }
    ignoreOwnMutations();
  }

  // We watch style attributes for the site's changes; our own writes must
  // not come back around as "changes" (that would loop).
  function ignoreOwnMutations() {
    observer?.takeRecords();
  }

  // New subtrees are restyled whole. A state change (class, open/hidden,
  // aria/data state, end of a fade-in) re-checks the element *and* its
  // subtree -- a revealed menu's items are often styled via the parent's
  // class -- unless the subtree is huge (a body-level class flip), where
  // re-walking the whole page on every flip would jank scrolling.
  const MAX_STATE_SUBTREE = 2000;
  // `fresh`: newly added content, always styled right away. Everything else
  // is a re-check of existing content after a state/style/animation change,
  // which waits while it's hovered, focused or pressed (see hoverLocked).
  function queue(node, deep = true, fresh = deep === true) {
    if (node.nodeType !== 1 || node === frame || node.tagName === 'IFRAME') return;
    const into = fresh ? pending : pendingRecheck;
    into.add(node);
    if (deep) {
      const subtree = node.querySelectorAll('*');
      if (deep === true || subtree.length <= MAX_STATE_SUBTREE) for (const child of subtree) into.add(child);
    }
    if (!flushTimer) flushTimer = setTimeout(flush, 80);
  }
  const pendingRecheck = new Set();

  // Re-checking an element while the site shows its :hover/:focus/:active
  // look would pin that look with our !important overrides -- "hovered once,
  // stays hovered". Those re-checks wait until the pointer/focus leaves.
  const deferred = new Set();
  function hoverLocked(el) {
    const h = el.closest(':hover, :focus-within, :active');
    return !!h && h !== document.body && h !== document.documentElement;
  }
  let releaseTimer = null;
  function releaseDeferredSoon() {
    if (!deferred.size || releaseTimer) return;
    releaseTimer = setTimeout(() => {
      releaseTimer = null;
      for (const el of deferred) {
        if (!el.isConnected) { deferred.delete(el); continue; }
        if (!hoverLocked(el)) { deferred.delete(el); pending.add(el); }
      }
      if (pending.size && !flushTimer) flushTimer = setTimeout(flush, 0);
    }, 150);
  }
  const STATE_ATTRS = ['class', 'hidden', 'open', 'aria-expanded', 'aria-hidden', 'aria-selected', 'data-state', 'data-open'];
  // Fade/slide-ins: the fill may still be transparent when first checked.
  const onAnimationDone = (e) => { if (e.target.nodeType === 1) queue(e.target, 'state'); };
  // Apps that hydrate after load (React/Next -- ChatGPT) can throw away
  // elements they didn't render, including our backdrop frame, which left
  // the page black. Put it straight back.
  function ensureFrame() {
    if (!on || !frame || frame.isConnected) return;
    frameReady = false; // re-inserting reloads it; its load handler resumes lenses
    document.documentElement.appendChild(frame);
  }

  function flush() {
    flushTimer = null;
    if (!on) return pending.clear();
    ensureFrame();
    const batch = [...pending];
    pending.clear();
    for (const el of pendingRecheck) {
      if (!el.isConnected) continue;
      if (hoverLocked(el)) deferred.add(el); else batch.push(el);
    }
    pendingRecheck.clear();
    restyle(batch);
    for (const el of originals.keys()) if (!el.isConnected) originals.delete(el);
    kick();
  }

  // ---- liquid lenses: tell the backdrop where the buttons are ----
  const fx = new WeakMap(); // el -> { hover, press, rippleAt, rx, ry }
  let lensRaf = null;
  const liquidOf = (t) => {
    for (let el = t; el && el.nodeType === 1; el = el.parentElement) if (liquid.has(el)) return el;
    return null;
  };
  const fxFor = (el) => { let f = fx.get(el); if (!f) fx.set(el, (f = { hover: 0, press: 0, rippleAt: -1e9 })); return f; };
  // Every other clickable (links, buttons, tabs, menu items...) gets a
  // transient lens while hovered: it grows in from its centre, presses in
  // with a ripple, and shrinks away on leave. Only the hovered one (plus any
  // still shrinking) is drawn, so it stays cheap.
  const CLICKABLE = 'a[href], button, summary, label, select, [role="button"], [role="link"], [role="tab"], ' +
    '[role="menuitem"], [role="option"], [role="checkbox"], [role="switch"], ' +
    'input[type="button"], input[type="submit"], input[type="reset"], input[type="checkbox"], input[type="radio"], ' +
    // ...and text fields: anything with the I-beam cursor
    'input:not([type]), input[type="text"], input[type="search"], input[type="email"], input[type="url"], ' +
    'input[type="tel"], input[type="password"], input[type="number"], textarea, [contenteditable=""], ' +
    '[contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="searchbox"], [role="combobox"]';
  const MAX_HOVER_AREA = 90000; // bigger "clickables" are whole cards: no lens over a card
  let hovered = null;           // { el, grow, target, press, rippleAt, rx, ry }
  const shrinking = [];         // lenses animating out
  function clickableOf(t) {
    if (!t || t.nodeType !== 1) return null;
    let el = t.closest(CLICKABLE);
    if (!el) { // a pointer or I-beam cursor marks script-driven ones, a few levels up at most
      for (let n = t, i = 0; n && n !== document.body && i < 4; n = n.parentElement, i++) {
        const cursor = getComputedStyle(n).cursor;
        if (cursor === 'pointer' || cursor === 'text') { el = n; break; }
      }
    }
    if (!el || liquid.has(el) || el === document.body) return null;
    const b = el.getBoundingClientRect();
    if (b.width * b.height > MAX_HOVER_AREA || b.width < 8 || b.height < 8) return null;
    for (let p = el; p; p = p.parentElement) if (layers.has(p)) return null; // inside a pane: hidden anyway
    return el;
  }

  // Floating layers (panes) are interactive glass too: hover swells the
  // pane and bends it harder, press squishes it and wobbles the refraction.
  let hoverPane = null, pressedPane = false;
  function paneOf(t) {
    for (let n = t; n && n.nodeType === 1; n = n.parentElement) if (panes.has(n)) return panes.get(n);
    return null;
  }
  function setPaneFx(pane, hover, press) {
    if (!pane?.isConnected) return;
    pane.style.setProperty('transition', 'transform .45s cubic-bezier(.3, 1.6, .5, 1)', 'important');
    pane.style.setProperty('transform', press ? 'scale(0.985)' : hover ? 'scale(1.012)' : 'none', 'important');
    try { pane.contentWindow.postMessage({ type: 'rainy-pane-fx', hover, press }, backdropOrigin); } catch {}
  }

  // A clickable that fills most of a glass panel (the text field in Google's
  // search pill) animates that panel's own lens rather than growing a second
  // lens inside it -- whose rim showed as stray lines inside the pill.
  let hoverPanel = null;
  function panelHostOf(c) {
    const cb = c.getBoundingClientRect();
    for (let p = c, i = 0; p && i < 5; p = p.parentElement, i++) {
      if (!panels.has(p)) continue;
      const pb = p.getBoundingClientRect();
      return cb.width * cb.height >= 0.4 * pb.width * pb.height ? p : null;
    }
    return null;
  }

  const onOver = (e) => {
    const pane = paneOf(e.target);
    if (pane !== hoverPane) { setPaneFx(hoverPane, 0, 0); hoverPane = pane; setPaneFx(pane, 1, 0); }
    const el = liquidOf(e.target);
    if (el) { fxFor(el).hover = 1; kick(); return; }
    const c = clickableOf(e.target);
    const host = c && panelHostOf(c);
    if (host) {
      if (hoverPanel !== host) {
        if (hoverPanel) fxFor(hoverPanel).hover = 0;
        hoverPanel = host;
        fxFor(host).hover = 1;
      }
      if (hovered) { hovered.target = 0; shrinking.push(hovered); hovered = null; }
      kick();
      return;
    }
    if (c && c !== hovered?.el) {
      if (hovered) { hovered.target = 0; shrinking.push(hovered); }
      hovered = { el: c, grow: 0, target: 1, press: 0, rippleAt: -1e9, rx: 0, ry: 0 };
      kick();
    }
  };
  const onOut = (e) => {
    releaseDeferredSoon();
    if (hoverPane && paneOf(e.relatedTarget) !== hoverPane) { setPaneFx(hoverPane, 0, 0); hoverPane = null; }
    if (hoverPanel && !hoverPanel.contains(e.relatedTarget)) {
      const f = fxFor(hoverPanel); f.hover = 0; f.press = 0;
      hoverPanel = null;
      kick();
    }
    const el = liquidOf(e.target);
    if (el && liquidOf(e.relatedTarget) !== el) { fxFor(el).hover = 0; kick(); }
    if (hovered && !hovered.el.contains(e.relatedTarget)) {
      hovered.target = 0; hovered.press = 0;
      shrinking.push(hovered);
      hovered = null;
      kick();
    }
  };
  // ---- jelly wobble: press squishes the glass, release springs it back ----
  // Web Animations only (no inline styles, so the site's own transitions and
  // our overrides are untouched), and never on elements that already have a
  // transform of their own. The lens follows the animated box every frame.
  const jellyAnims = new WeakMap();
  function jelly(el, pressed) {
    if (!el?.isConnected || getComputedStyle(el).transform !== 'none' && !jellyAnims.has(el)) return;
    jellyAnims.get(el)?.cancel();
    const anim = pressed
      ? el.animate([{ transform: 'scale(1)' }, { transform: 'scale(0.975, 0.93)' }],
                   { duration: 140, easing: 'cubic-bezier(.3, .7, .4, 1)', fill: 'forwards' })
      : el.animate([{ transform: 'scale(0.975, 0.93)' }, { transform: 'scale(1.025, 1.06)' },
                    { transform: 'scale(0.99, 0.975)' }, { transform: 'scale(1.006, 1.012)' }, { transform: 'scale(1)' }],
                   { duration: 700, easing: 'ease-out' });
    jellyAnims.set(el, anim);
    if (!pressed) anim.finished.then(() => { if (jellyAnims.get(el) === anim) jellyAnims.delete(el); }).catch(() => {});
    kick(pressed ? 400 : 900); // stream lens positions while it moves
  }
  let jellyTarget = null;

  const onDown = (e) => {
    if (hoverPane) { pressedPane = true; setPaneFx(hoverPane, 1, 1); }
    const el = liquidOf(e.target);
    const now = performance.now();
    jellyTarget = el || (hoverPanel?.contains(e.target) ? hoverPanel : null) || (hovered?.el.contains(e.target) ? hovered.el : null);
    if (jellyTarget) jelly(jellyTarget, true);
    if (el) Object.assign(fxFor(el), { press: 1, rippleAt: now, rx: e.clientX, ry: e.clientY });
    else if (hoverPanel?.contains(e.target)) Object.assign(fxFor(hoverPanel), { press: 1, rippleAt: now, rx: e.clientX, ry: e.clientY });
    else if (hovered?.el.contains(e.target)) Object.assign(hovered, { press: 1, rippleAt: now, rx: e.clientX, ry: e.clientY });
    else return;
    kick(1700); // keep frames coming for the ripple
  };
  const onUp = () => {
    releaseDeferredSoon();
    if (pressedPane) { pressedPane = false; setPaneFx(hoverPane, hoverPane ? 1 : 0, 0); }
    for (const el of liquid) { const f = fx.get(el); if (f) f.press = 0; }
    if (hovered) hovered.press = 0;
    if (hoverPanel) fxFor(hoverPanel).press = 0;
    if (jellyTarget) { jelly(jellyTarget, false); jellyTarget = null; }
    kick();
  };

  // Transient hover lenses for this frame, easing grow toward its target.
  let lastHoverStep = performance.now();
  function hoverLenses(now) {
    const dt = Math.min((now - lastHoverStep) / 1000, 1 / 20);
    lastHoverStep = now;
    const out = [];
    for (const h of [...shrinking, ...(hovered ? [hovered] : [])]) {
      h.grow += (h.target - h.grow) * Math.min(1, dt * 14);
      if (h.target === 0 && h.grow < 0.03) continue;
      if (!h.el.isConnected) continue;
      const b = h.el.getBoundingClientRect();
      const pad = 5, k = 0.8 + 0.2 * h.grow; // grow in from the centre
      const w = (b.width + pad * 2) * k, ht = (b.height + pad * 2) * k;
      const radius = Math.min(Math.max(parseFloat(getComputedStyle(h.el).borderTopLeftRadius) || 0, 10) + pad, ht / 2);
      out.push({ x: b.left + b.width / 2 - w / 2, y: b.top + b.height / 2 - ht / 2, w, h: ht, r: radius, frost: 0,
                 hover: h.grow, press: h.press, rippleAge: (now - h.rippleAt) / 1000, rx: h.rx, ry: h.ry });
      if (h.grow < 0.97 && h.target === 1) kick(); // still growing
      if (h.target === 0) kick();                  // still shrinking
    }
    for (let i = shrinking.length - 1; i >= 0; i--) if (shrinking[i].grow < 0.03) shrinking.splice(i, 1);
    return out;
  }

  function radiusOf(el, w, h) {
    const v = getComputedStyle(el).borderTopLeftRadius;
    const r = v.endsWith('%') ? (parseFloat(v) / 100) * Math.min(w, h) : parseFloat(v) || 0;
    return Math.min(Math.max(r, 6), Math.min(w, h) / 2);
  }

  // Panels are see-through lenses whenever the backdrop can draw glass --
  // with effects on (live rain) and off (still wallpaper, drawn on demand).
  // Only without WebGL do they fall back to flat smoke.
  function setGlass(nowOn) {
    if (nowOn === glassOn) return;
    glassOn = nowOn;
    for (const el of panels) {
      for (const [prop, value] of panelLook()) override(el, prop, value);
      if (!glassOn) restoreProp(el, 'box-shadow');
    }
    ignoreOwnMutations();
  }
  const onBackdropMessage = (e) => {
    if (e.source === frame?.contentWindow && e.data?.type === 'rainy-view') { viewScale = e.data.scale; kick(); return; }
    if (e.source !== frame?.contentWindow || e.data?.type !== 'rainy-effects') return;
    setGlass(!!e.data.glass);
    live = !!e.data.live;
    kick();
  };

  // Only the outermost panel of a nested stack becomes a lens; inner ones
  // just stay clear inside it.
  function outermost(el) {
    for (let p = el.parentElement; p; p = p.parentElement) if (panels.has(p)) return false;
    return true;
  }

  function lensFor(el, now, frost) {
    const b = el.getBoundingClientRect();
    if (b.width < 4 || b.bottom < 0 || b.top > innerHeight || b.right < 0 || b.left > innerWidth) return null;
    const f = fxFor(el);
    return { x: b.left, y: b.top, w: b.width, h: b.height, r: radiusOf(el, b.width, b.height), frost,
             hover: f.hover, press: f.press, rippleAge: (now - f.rippleAt) / 1000, rx: f.rx ?? 0, ry: f.ry ?? 0 };
  }

  // Lens positions stream every frame while the rain is live. With effects
  // off they're sent in short bursts after scrolls, resizes, hovers, presses
  // and DOM changes -- and only when they actually changed -- so an idle
  // page does no work at all.
  let kickUntil = 0, lastSent = '';
  function kick(ms = 700) {
    kickUntil = Math.max(kickUntil, performance.now() + ms);
    if (on && lensRaf === null) lensRaf = requestAnimationFrame(sendLenses);
  }
  const onScrollOrResize = () => kick();

  // ---- glass panes for floating layers ----
  // Panes are attached lazily, only to layers that are on screen and big
  // enough to matter, and capped per page: each is its own frame, and sites
  // like Google mark dozens of elements as floating.
  const layers = new Set();   // floating layer surfaces (styled with PANE_LOOK)
  const panes = new Map();    // layer surface -> its pane iframe
  let viewScale = 0.9;        // backdrop's current wallpaper UV scale (reported by rain.js)
  const MAX_PANES = 12, MIN_PANE_AREA = 2400;
  function attachPane(el) {
    if (panes.get(el)?.isConnected) return;
    panes.get(el)?.remove();
    const pane = document.createElement('iframe');
    pane.src = chrome.runtime.getURL('pane.html');
    pane.setAttribute('aria-hidden', 'true');
    pane.tabIndex = -1;
    // Absolute children sit inside the border; stretch out over it so the
    // (now transparent) border doesn't show the dark fallback as an outline.
    // (An iframe doesn't stretch between insets like a div -- it needs an
    // explicit size, or it falls back to 300x150.)
    const cs = getComputedStyle(el);
    const bw = (side) => parseFloat(cs[`border${side}Width`]) || 0;
    for (const [k, v] of Object.entries({
      position: 'absolute', top: `${-bw('Top')}px`, left: `${-bw('Left')}px`,
      width: `calc(100% + ${bw('Left') + bw('Right')}px)`, height: `calc(100% + ${bw('Top') + bw('Bottom')}px)`,
      border: '0', margin: '0', padding: '0',
      'z-index': '-1', 'pointer-events': 'none', 'border-radius': 'inherit', display: 'block',
      background: 'transparent', 'color-scheme': 'normal',
    })) pane.style.setProperty(k, v, 'important');
    pane.addEventListener('load', () => { pane.dataset.rainyReady = '1'; delete pane.dataset.rainyAt; kick(); });
    el.appendChild(pane); // last child: least in the way of the site's own DOM code
    panes.set(el, pane);
  }

  // Attach panes to visible layers (dropping ones for layers that left the
  // page, and, when over the cap, ones that are off screen), then tell each
  // pane where it is on screen so it can crop the wallpaper to match.
  function placePanes() {
    const visible = [];
    for (const el of layers) {
      if (!el.isConnected) { layers.delete(el); panes.get(el)?.remove(); panes.delete(el); continue; }
      const b = el.getBoundingClientRect();
      const onScreen = b.width * b.height >= MIN_PANE_AREA && b.bottom > 0 && b.top < innerHeight && b.right > 0 && b.left < innerWidth;
      if (onScreen) visible.push(el);
    }
    for (const el of visible) {
      if (panes.get(el)?.isConnected) continue;
      if (panes.size >= MAX_PANES) {
        for (const [other, pane] of panes) {
          if (!visible.includes(other)) { pane.remove(); panes.delete(other); break; }
        }
      }
      if (panes.size < MAX_PANES) attachPane(el);
    }
    const screenLeft = 'left' in screen ? screen.left : (screen.availLeft || 0);
    const screenTop = 'top' in screen ? screen.top : 0;
    const vpLeft = screenX - screenLeft + (outerWidth - innerWidth) / 2;
    const vpTop = screenY - screenTop + (outerHeight - innerHeight);
    for (const [el, pane] of panes) {
      if (!el.isConnected || !pane.isConnected) { pane.remove(); panes.delete(el); continue; }
      if (!pane.dataset.rainyReady) continue;
      const b = pane.getBoundingClientRect();
      if (b.width === 0 || b.bottom < 0 || b.top > innerHeight) continue;
      const radius = radiusOf(el, b.width, b.height);
      const at = `${Math.round(vpLeft + b.left)},${Math.round(vpTop + b.top)},${screen.width},${screen.height},${radius},${viewScale.toFixed(3)}`;
      if (pane.dataset.rainyAt === at) continue;
      pane.dataset.rainyAt = at;
      try {
        pane.contentWindow.postMessage({ type: 'rainy-pane', x: vpLeft + b.left, y: vpTop + b.top,
                                         sw: screen.width, sh: screen.height, radius, scale: viewScale }, backdropOrigin);
      } catch {}
    }
  }

  // Sites float things on the fly (hover cards, menus): inserted as ordinary
  // content, then positioned by script or inline style -- neither of which
  // our observer re-walks. So while the page is active, anything that's
  // currently glass on screen is re-checked; if it now lives in a floating
  // layer it's restyled as frost, so no clear lens ever sits over text.
  let lastAudit = 0;
  function audit(now) {
    if (now - lastAudit < 150) return;
    lastAudit = now;
    floatCache = new Map();
    const suspects = [];
    for (const el of unsized) {
      if (!el.isConnected) { unsized.delete(el); continue; }
      const b = el.getBoundingClientRect();
      if (b.width * b.height > 0) { unsized.delete(el); suspects.push(el); }
    }
    for (const set of [panels, liquid]) {
      for (const el of set) {
        if (!el.isConnected) { set.delete(el); continue; }
        const b = el.getBoundingClientRect();
        if (b.width === 0 || b.bottom < 0 || b.top > innerHeight) continue;
        if (floatingRoot(el)) suspects.push(el);
      }
    }
    if (!suspects.length) return;
    // Re-plan from the site's own fill, not our "transparent" override.
    for (const el of suspects) {
      for (const prop of ['background-color', 'background-image', 'border-color', 'box-shadow']) restoreProp(el, prop);
    }
    restyle(suspects);
  }

  const MAX_LENSES = 32;
  function sendLenses() {
    const now = performance.now();
    lensRaf = live || now < kickUntil ? requestAnimationFrame(sendLenses) : null;
    if (!frameReady || !frame?.contentWindow) return;
    audit(now);
    placePanes();
    const buttons = [], surfaces = [];
    for (const el of liquid) {
      if (!el.isConnected) { liquid.delete(el); continue; }
      const lens = lensFor(el, now, 0);
      if (lens && buttons.push(lens) === 12) break;
    }
    if (glassOn) {
      for (const el of panels) {
        if (!el.isConnected) { panels.delete(el); continue; }
        if (!outermost(el)) continue;
        const lens = lensFor(el, now, 0.85);
        if (lens && surfaces.push(lens) === MAX_LENSES - buttons.length) break;
      }
    }
    // Panels first, then buttons, hover lenses on top: later lenses draw over earlier.
    const hover = hoverLenses(now);
    const lenses = [...surfaces.slice(0, MAX_LENSES - buttons.length - hover.length), ...buttons, ...hover];
    for (const l of lenses) if (l.rippleAge > 2) l.rippleAge = 99; // settled ripples don't count as changes
    const key = JSON.stringify(lenses);
    if (key === lastSent && !live) return;
    lastSent = key;
    try {
      frame.contentWindow.postMessage({ type: 'rainy-lenses', lenses }, backdropOrigin);
    } catch {} // frame mid-navigation; the next kick retries
  }
  const backdropOrigin = new URL(chrome.runtime.getURL('')).origin;

  // ---- on / off ----
  function enable() {
    if (on) return;
    on = true;
    frame = document.createElement('iframe');
    frame.src = chrome.runtime.getURL('backdrop.html');
    frame.setAttribute('aria-hidden', 'true');
    frame.tabIndex = -1;
    frameReady = false;
    frame.addEventListener('load', () => { frameReady = true; lastSent = ''; kick(); });
    for (const [k, v] of Object.entries({
      position: 'fixed', inset: '0', width: '100vw', height: '100vh', border: '0', margin: '0',
      'z-index': '-2147483647', 'pointer-events': 'none', background: 'transparent', 'color-scheme': 'normal',
    })) frame.style.setProperty(k, v, 'important');
    document.documentElement.appendChild(frame);

    override(document.documentElement, 'color-scheme', 'dark');
    restyle([document.documentElement, ...document.querySelectorAll('body, body *')]);
    observer = new MutationObserver((records) => {
      if (!frame?.isConnected) ensureFrame();
      for (const r of records) {
        if (r.type === 'childList') r.addedNodes.forEach((n) => queue(n));
        // Inline style: the site may have shown the element (display) or
        // replaced one of our overrides -- re-check just that element.
        else if (r.attributeName === 'style') queue(r.target, false);
        else queue(r.target, 'state');
      }
    });
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true,
                                                  attributeFilter: [...STATE_ATTRS, 'style'] });
    document.addEventListener('transitionend', onAnimationDone, true);
    document.addEventListener('animationend', onAnimationDone, true);
    window.addEventListener('message', onBackdropMessage);
    document.addEventListener('pointerover', onOver, true);
    document.addEventListener('pointerout', onOut, true);
    document.addEventListener('pointerdown', onDown, true);
    window.addEventListener('pointerup', onUp, true);
    document.addEventListener('focusout', releaseDeferredSoon, true);
    window.addEventListener('scroll', onScrollOrResize, { capture: true, passive: true });
    window.addEventListener('resize', onScrollOrResize);
    // Moving the window changes which slice of wallpaper each pane shows.
    let placement = '';
    moveTimer = setInterval(() => {
      const now = `${screenX},${screenY}`;
      if (now !== placement) { placement = now; kick(); }
    }, 400);
    settleTimers.push(setTimeout(refreshAll, 1500));
    if (document.readyState !== 'complete') {
      addEventListener('load', () => settleTimers.push(setTimeout(refreshAll, 600)), { once: true });
    }
    kick();
  }

  // Re-apply everything from scratch (what toggling off and on did by hand),
  // keeping the backdrop frame so there's no flash. Run once the page has
  // settled: an app that renders/hydrates after load gets classified against
  // its real layout, not the half-built one we first saw.
  function refreshAll() {
    if (!on) return;
    for (const [el, saved] of originals) {
      for (const [prop, [value, priority]] of Object.entries(saved)) {
        if (value) el.style.setProperty(prop, value, priority);
        else el.style.removeProperty(prop);
      }
      if (el.getAttribute('style') === '') el.removeAttribute('style');
    }
    originals.clear();
    removePseudoRules();
    for (const pane of panes.values()) pane.remove();
    panes.clear();
    layers.clear();
    panels.clear();
    liquid.clear();
    unsized.clear();
    ensureFrame();
    override(document.documentElement, 'color-scheme', 'dark');
    restyle([document.documentElement, ...document.querySelectorAll('body, body *')]);
    if (glassOn) { glassOn = false; setGlass(true); } // re-apply lens looks to the fresh panels
    lastSent = '';
    if (frameReady) placePanes(); // panes back right away, not on the next frame
    kick();
  }
  const settleTimers = [];

  function disable() {
    if (!on) return;
    on = false;
    observer?.disconnect();
    observer = null;
    cancelAnimationFrame(lensRaf);
    lensRaf = null;
    window.removeEventListener('message', onBackdropMessage);
    document.removeEventListener('transitionend', onAnimationDone, true);
    document.removeEventListener('animationend', onAnimationDone, true);
    document.removeEventListener('pointerover', onOver, true);
    document.removeEventListener('pointerout', onOut, true);
    document.removeEventListener('pointerdown', onDown, true);
    window.removeEventListener('pointerup', onUp, true);
    document.removeEventListener('focusout', releaseDeferredSoon, true);
    deferred.clear();
    pendingRecheck.clear();
    window.removeEventListener('scroll', onScrollOrResize, { capture: true });
    window.removeEventListener('resize', onScrollOrResize);
    clearInterval(moveTimer);
    settleTimers.splice(0).forEach(clearTimeout);
    liquid.clear();
    panels.clear();
    unsized.clear();
    hovered = null;
    shrinking.length = 0;
    hoverPane = null;
    hoverPanel = null;
    for (const pane of panes.values()) pane.remove();
    panes.clear();
    layers.clear();
    glassOn = false;
    live = false;
    frameReady = false;
    frame?.remove();
    frame = null;
    for (const [el, saved] of originals) {
      for (const [prop, [value, priority]] of Object.entries(saved)) {
        if (value) el.style.setProperty(prop, value, priority);
        else el.style.removeProperty(prop);
      }
      if (el.getAttribute('style') === '') el.removeAttribute('style');
    }
    originals.clear();
    removePseudoRules();
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type !== 'rainy-glass') return;
    msg.on ? enable() : disable();
  });

  // Loaded only for sites the user turned on (registered script, or injected
  // by the toggle itself), so start on.
  enable();
  chrome.runtime.sendMessage({ type: 'rainy-glass-active' }).catch(() => {});
})();
