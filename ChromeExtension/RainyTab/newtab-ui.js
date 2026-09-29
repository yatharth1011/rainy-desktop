// Rainy Tab's New Tab UI: Google search with suggestions, shortcuts, and the
// liquid-glass physics fed to the renderer in rain.js (glassRects/stepGlass).


const form = document.getElementById('search');
const input = document.getElementById('q');
const suggestBox = document.getElementById('suggest');
const shortcuts = document.getElementById('shortcuts');

function destinationFor(text) {
  const q = text.trim();
  const hasScheme = /^[a-z][\w+.-]*:\/\//i.test(q);
  const looksLikeUrl = !/\s/.test(q) && (hasScheme || /^[\w-]+(\.[\w-]+)+(:\d+)?(\/.*)?$/.test(q) || /^localhost(:\d+)?(\/.*)?$/.test(q));
  if (looksLikeUrl) return hasScheme ? q : `https://${q}`;
  return `https://www.google.com/search?q=${encodeURIComponent(q)}`;
}

form.addEventListener('submit', (e) => {
  e.preventDefault();
  const item = items[selected];
  if (item) location.href = item.url;
  else if (input.value.trim()) location.href = destinationFor(input.value);
});

// ------------------------------------------------------- suggestions ----
// Google's own suggest endpoint (what the omnibox uses), shown in a glass
// dropdown with keyboard navigation.

let items = [], selected = -1, typed = '', suggestSeq = 0;

const SEARCH_ICON = '<svg viewBox="0 0 24 24"><path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>';
const GLOBE_ICON = '<svg viewBox="0 0 24 24"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm6.93 6h-2.95a15.65 15.65 0 0 0-1.38-3.56A8.03 8.03 0 0 1 18.93 8zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14a8.2 8.2 0 0 1 0-4h3.38a16.5 16.5 0 0 0 0 4H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56A7.99 7.99 0 0 1 5.08 16zm2.95-8H5.08a7.99 7.99 0 0 1 4.33-3.56A15.65 15.65 0 0 0 8.03 8zM12 19.96A14.1 14.1 0 0 1 10.09 16h3.82A14.1 14.1 0 0 1 12 19.96zM14.34 14H9.66a14.7 14.7 0 0 1 0-4h4.68a14.7 14.7 0 0 1 0 4zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95a8.03 8.03 0 0 1-4.33 3.56zM16.36 14a16.5 16.5 0 0 0 0-4h3.38a8.2 8.2 0 0 1 0 4h-3.38z"/></svg>';

async function fetchSuggestions(q) {
  const seq = ++suggestSeq;
  if (!q.trim()) return renderSuggestions([]);
  try {
    const url = `https://suggestqueries.google.com/complete/search?client=chrome&hl=${encodeURIComponent(navigator.language)}&q=${encodeURIComponent(q)}`;
    const data = await (await fetch(url)).json();
    if (seq !== suggestSeq) return;
    const types = data[4]?.['google:suggesttype'] || [];
    const list = (data[1] || []).map((text, i) => {
      const nav = types[i] === 'NAVIGATION';
      return { text, nav, url: nav ? destinationFor(text) : destinationFor(text) };
    });
    if (!list.some((it) => it.text.toLowerCase() === q.trim().toLowerCase())) {
      list.unshift({ text: q.trim(), nav: false, url: destinationFor(q) });
    }
    renderSuggestions(list.slice(0, 7));
  } catch {
    if (seq === suggestSeq) renderSuggestions([]);
  }
}

function renderSuggestions(list) {
  items = list;
  selected = -1;
  suggestBox.replaceChildren(...list.map((item, i) => {
    const row = document.createElement('div');
    row.className = 'row';
    row.setAttribute('role', 'option');
    row.innerHTML = item.nav ? GLOBE_ICON : SEARCH_ICON;
    const label = document.createElement('span');
    const lower = item.text.toLowerCase(), prefix = typed.trim().toLowerCase();
    if (!item.nav && prefix && lower.startsWith(prefix) && lower !== prefix) {
      label.append(item.text.slice(0, prefix.length));
      const rest = document.createElement('b');
      rest.textContent = item.text.slice(prefix.length);
      label.append(rest);
    } else {
      label.textContent = item.text;
    }
    row.append(label);
    row.addEventListener('pointerdown', (e) => e.preventDefault()); // keep focus in the box
    row.addEventListener('click', () => { location.href = item.url; });
    row.addEventListener('pointerenter', () => highlight(i));
    return row;
  }));
  const open = list.length > 0;
  suggestBox.hidden = !open;
  form.classList.toggle('open', open);
  shortcuts.style.visibility = open ? 'hidden' : '';
  requestRender(); // static mode: the dropdown's glass appeared/disappeared
}

function highlight(i) {
  selected = i;
  [...suggestBox.children].forEach((row, j) => row.classList.toggle('selected', j === i));
}

input.addEventListener('input', () => { typed = input.value; fetchSuggestions(typed); });
input.addEventListener('focus', () => { if (input.value.trim()) fetchSuggestions(input.value); });
input.addEventListener('blur', () => setTimeout(() => renderSuggestions([]), 120));
input.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') { renderSuggestions([]); return; }
  if (!items.length || (e.key !== 'ArrowDown' && e.key !== 'ArrowUp')) return;
  e.preventDefault();
  const n = items.length;
  const next = e.key === 'ArrowDown' ? (selected + 2) % (n + 1) - 1 : (selected + n + 1) % (n + 1) - 1;
  highlight(next);
  input.value = next >= 0 ? items[next].text : typed;
});

// -------------------------------------------------------- shortcuts ----

chrome.topSites.get((sites) => {
  for (const site of sites.slice(0, 8)) {
    const a = document.createElement('a');
    a.className = 'tile';
    a.href = site.url;
    const icon = document.createElement('div');
    icon.className = 'icon glass';
    icon.dataset.radius = '999';
    const img = document.createElement('img');
    img.alt = '';
    img.src = `/_favicon/?pageUrl=${encodeURIComponent(site.url)}&size=64`;
    icon.append(img);
    const label = document.createElement('span');
    label.textContent = site.title || new URL(site.url).hostname;
    a.append(icon, label);
    shortcuts.append(a);
  }
  requestRender(); // static mode: draw the new tiles' glass
});

// ----------------------------------------------------- glass physics ----
// Every glass element is a little jelly lens: springs on scale and stretch
// (hover swells it, press squishes it, dragging pulls it after the finger
// and it wobbles back on release), plus a ripple from each press and a
// highlight that follows the pointer -- all fed to the shader per element.

const glassState = new Map();
function stateFor(el) {
  let s = glassState.get(el);
  if (!s) {
    s = { hover: 0, hoverT: 0, press: 0, pressT: 0, scale: 1, scaleV: 0, sx: 0, sxV: 0, sy: 0, syV: 0,
          tx: 0, txV: 0, ty: 0, tyV: 0, drag: null, px: 0, py: 0, ripple: { x: 0, y: 0, t: -1e9 } };
    glassState.set(el, s);
  }
  return s;
}
function glassOf(target) {
  const t = target?.closest?.('.tile, #search, #suggest, #settings');
  if (!t) return null;
  return t.classList.contains('tile') ? t.querySelector('.glass') : t;
}

document.addEventListener('pointerover', (e) => { const g = glassOf(e.target); if (g) stateFor(g).hoverT = 1; });
document.addEventListener('pointerout', (e) => {
  const g = glassOf(e.target);
  if (g && glassOf(e.relatedTarget) !== g) stateFor(g).hoverT = 0;
});
document.addEventListener('pointermove', (e) => {
  const g = glassOf(e.target);
  if (g) { const s = stateFor(g); s.px = e.clientX; s.py = e.clientY; }
  for (const s of glassState.values()) if (s.drag) { s.drag.dx = e.clientX - s.drag.x; s.drag.dy = e.clientY - s.drag.y; }
});
document.addEventListener('pointerdown', (e) => {
  const g = glassOf(e.target);
  if (!g) return;
  const s = stateFor(g);
  s.pressT = 1;
  s.px = e.clientX; s.py = e.clientY;
  s.drag = { x: e.clientX, y: e.clientY, dx: 0, dy: 0 };
  s.ripple = { x: e.clientX, y: e.clientY, t: performance.now() };
});
const release = () => { for (const s of glassState.values()) { s.pressT = 0; s.drag = null; } };
window.addEventListener('pointerup', release);
window.addEventListener('pointercancel', release);
window.addEventListener('blur', release);

function spring(s, key, target, k, c, dt) {
  s[`${key}V`] += (k * (target - s[key]) - c * s[`${key}V`]) * dt;
  s[key] += s[`${key}V`] * dt;
}

function stepGlass(el, dt) {
  const s = stateFor(el);
  s.hover += (s.hoverT - s.hover) * Math.min(1, dt * 10);
  s.press += (s.pressT - s.press) * Math.min(1, dt * 18);
  if (el.dataset.jelly === 'off') return s;
  const b = el.getBoundingClientRect();
  const clamp = (v, m) => Math.max(-m, Math.min(m, v));
  const dx = s.drag ? s.drag.dx : 0, dy = s.drag ? s.drag.dy : 0;
  spring(s, 'scale', 1 + 0.035 * s.hoverT - 0.06 * s.pressT, 420, 15, dt);   // underdamped: wobbles
  spring(s, 'sx', clamp(dx / Math.max(b.width, 1) * 0.5, 0.14), 300, 13, dt);
  spring(s, 'sy', clamp(dy / Math.max(b.height, 1) * 0.5, 0.14), 300, 13, dt);
  spring(s, 'tx', clamp(dx * 0.14, 14), 300, 13, dt);
  spring(s, 'ty', clamp(dy * 0.14, 14), 300, 13, dt);
  const ax = Math.abs(s.sx), ay = Math.abs(s.sy);
  const scaleX = s.scale * (1 + ax - 0.5 * ay), scaleY = s.scale * (1 + ay - 0.5 * ax);
  el.style.transform = `translate(${s.tx.toFixed(2)}px, ${s.ty.toFixed(2)}px) scale(${scaleX.toFixed(4)}, ${scaleY.toFixed(4)})`;
  return s;
}

