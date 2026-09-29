// A floating layer's glass pane: the wallpaper, frosted and dimmed, cropped
// to exactly where this layer sits on screen (glass-site.js sends its screen
// rect and corner radius), bent like a liquid-glass lens -- the rim
// compresses the wallpaper toward the edge, the middle magnifies a touch, no
// added light.
//
// The bend is an SVG displacement map (built once per pane size), not WebGL:
// a page can have many panes, and Chrome only allows ~16 live WebGL contexts
// per tab -- past that it drops the oldest, which showed as panes flashing
// black.
const img = document.getElementById('wallpaper');
const map = document.getElementById('map');
const bend = document.getElementById('bend');
let loadedSize = -1, mapKey = '';

async function wallpaperBlob() {
  try {
    const hit = await (await caches.open('rainy')).match('/wallpaper'); // cached by rain.js
    if (hit) return await hit.blob();
  } catch {}
  try {
    return await (await fetch('http://127.0.0.1:47823/wallpaper.jpg', { cache: 'no-store' })).blob();
  } catch { return null; }
}

// Match the page around the pane: the backdrop is dimmed by Chrome Dim and
// by 30% extra behind websites (rain.js u_bgDim); panes take the same, plus
// a little more so their text stays crisp -- never brighter than the page.
// Light frost: enough detail left in the wallpaper that the rim's bending
// reads as glass, not a flat blur.
let baseBrightness = (1 - 0.35) * 0.7 * 0.85, hoverGlow = 0;
function applyFilter() {
  img.style.filter = `blur(7px) brightness(${(baseBrightness * (1 + 0.08 * hoverGlow)).toFixed(3)}) saturate(1.15)`;
}

async function matchBrightness() {
  let chromeDim = 0.35;
  try {
    const state = await (await fetch('http://127.0.0.1:47823/state.json', { cache: 'no-store' })).json();
    chromeDim = state.settings?.chromeDim ?? chromeDim;
  } catch {}
  const k = (1 - Math.min(Math.max(chromeDim, 0), 0.95)) * 0.7 * 0.85;
  baseBrightness = k;
  applyFilter();
}

async function refresh() {
  matchBrightness();
  const blob = await wallpaperBlob();
  if (!blob || blob.size === loadedSize) return;
  loadedSize = blob.size;
  const old = img.src;
  img.src = URL.createObjectURL(blob);
  if (old) URL.revokeObjectURL(old);
}

// Displacement map for a rounded rect: R/G encode the x/y offset (0.5 = none).
// Same profile as the page lenses: a quarter-circle bevel whose slope
// steepens at the rim, plus a slight magnification toward the centre.
const MAX_SHIFT = 40; // CSS px at full displacement
function buildMap(w, h, radius) {
  const key = `${w}x${h}r${radius}`;
  if (key === mapKey || w < 2 || h < 2) return;
  mapKey = key;
  const s = 0.5; // half resolution: smooth once scaled up, 4x cheaper
  const mw = Math.max(2, Math.round(w * s)), mh = Math.max(2, Math.round(h * s));
  const c = new OffscreenCanvas(mw, mh);
  const ctx = c.getContext('2d');
  const data = ctx.createImageData(mw, mh);
  const hbx = w / 2, hby = h / 2, r = Math.min(radius, hbx, hby);
  const bevel = Math.min(22, hbx, hby);
  const sd = (px, py) => {
    const qx = Math.abs(px) - hbx + r, qy = Math.abs(py) - hby + r;
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
  };
  for (let j = 0; j < mh; j++) {
    for (let i = 0; i < mw; i++) {
      const px = (i + 0.5) / s - hbx, py = (j + 0.5) / s - hby;
      const d = sd(px, py);
      const gx = sd(px + 1, py) - sd(px - 1, py), gy = sd(px, py + 1) - sd(px, py - 1);
      const gl = Math.hypot(gx, gy) || 1;
      const x = Math.min(Math.max(1 + d / bevel, 0), 1);
      const slope = Math.min(x / Math.sqrt(Math.max(1 - x * x, 1e-3)), 6);
      // Sample inward along the rim normal, and toward the centre (magnify).
      const dx = -(gx / gl) * slope * 6.5 - px * 0.05, dy = -(gy / gl) * slope * 6.5 - py * 0.05;
      const k = (j * mw + i) * 4;
      data.data[k] = 128 + Math.max(-127, Math.min(127, (dx / MAX_SHIFT) * 127));
      data.data[k + 1] = 128 + Math.max(-127, Math.min(127, (dy / MAX_SHIFT) * 127));
      data.data[k + 2] = 128;
      data.data[k + 3] = 255;
    }
  }
  ctx.putImageData(data, 0, 0);
  c.convertToBlob().then((blob) => {
    const reader = new FileReader();
    reader.onload = () => {
      map.setAttribute('href', reader.result);
      map.setAttribute('width', w);
      map.setAttribute('height', h);
      setBend();
    };
    reader.readAsDataURL(blob);
  });
}

// Same wallpaper mapping as the backdrop: stretched over the screen, zoomed
// by the backdrop's current UV scale about the screen centre.
addEventListener('message', (e) => {
  if (e.source !== window.parent || e.data?.type !== 'rainy-pane') return;
  const { x, y, sw, sh, radius } = e.data;
  const scale = e.data.scale || 0.9; // the backdrop's current UV scale (breathing zoom)
  const w = sw / scale, h = sh / scale;
  Object.assign(img.style, {
    width: `${w}px`, height: `${h}px`,
    left: `${-x - (w - sw) / 2}px`, top: `${-y - (h - sh) / 2}px`,
  });
  buildMap(innerWidth, innerHeight, radius);
});

// ---- interaction: hover swells the bend, press wobbles it ----
let fx = { hover: 0, press: 0 }, boost = 1, pressAt = -1e9, fxRaf = null;
function setBend() { bend.setAttribute('scale', (MAX_SHIFT * 2 * boost).toFixed(2)); }
function animateFx(now) {
  const t = (now - pressAt) / 1000;
  const wobble = t < 1.2 ? 0.45 * Math.sin(t * 22) * Math.exp(-t * 4.5) : 0;
  const target = 1 + 0.35 * fx.hover + 0.4 * fx.press;
  boost += (target - boost) * 0.2;
  hoverGlow += (fx.hover - hoverGlow) * 0.2;
  const shown = boost + wobble;
  bend.setAttribute('scale', (MAX_SHIFT * 2 * shown).toFixed(2));
  applyFilter();
  const settled = Math.abs(target - boost) < 0.005 && Math.abs(fx.hover - hoverGlow) < 0.01 && t > 1.2;
  fxRaf = settled ? null : requestAnimationFrame(animateFx);
}
addEventListener('message', (e) => {
  if (e.source !== window.parent || e.data?.type !== 'rainy-pane-fx') return;
  if (e.data.press && !fx.press) pressAt = performance.now();
  fx = { hover: e.data.hover, press: e.data.press };
  if (fxRaf === null) fxRaf = requestAnimationFrame(animateFx);
});

applyFilter();
refresh();
setInterval(refresh, 5000); // wallpaper changes
