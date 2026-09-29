// Rainy's rain renderer, shared by the New Tab page (newtab.html, whose UI
// lives in newtab-ui.js) and the per-site backdrop (backdrop.html, injected
// behind any page by glass-site.js). Renders Rainy Desktop's rain shader (a GLSL port of Rendering/Shaders/RenderShaders.metal)
// over the exact region of the wallpaper behind this browser viewport, on
// the desktop's own rain clock -- so drops line up with the real wallpaper
// behind the window -- and draws the page's UI as liquid-glass lenses in
// the same pass. Wallpaper, settings and clock come from the Rainy app's
// loopback bridge (Sources/RainyDesktop/Chrome/ChromeBridge.swift).
//
// The rain shader below is adapted from "Heartfelt" by Martijn Steinrucken
// (BigWings), https://www.shadertoy.com/view/ltffzl -- this file is licensed
// CC BY-NC-SA 3.0 (https://creativecommons.org/licenses/by-nc-sa/3.0/), not
// MIT; see NOTICE.

const BRIDGE = 'http://127.0.0.1:47823';
const MAX_GLASS = 32; // lenses per frame: New Tab UI, or a site's panels + buttons

// RainSettings defaults, used until/unless the bridge answers.
let settings = {
  rainIntensity: 0.7, rainSpeed: 1, staticDropDensity: 1, layer1Density: 1, layer2Density: 1,
  fogMinBlur: 2, fogMaxBlurLow: 3, fogMaxBlurHigh: 6, refractionStrength: 1,
  lightningBoost: 2.6, lightningSpeed: 1, lightningSharpness: 10,
  colorGradeStrength: 1, vignetteStrength: 1, brightness: 1,
  zoomAmount: 1, zoomSpeed: 1, dimAmount: 0, dropZoomOut: 1, chromeDim: 0.35,
};
let clock = { base: 10, at: performance.now(), paused: false };
let wallpaperVersion = null;

// ------------------------------------------------------------ bridge ----

async function cachedWallpaper() {
  try {
    const cache = await caches.open('rainy');
    const hit = await cache.match('/wallpaper');
    return hit ? await hit.blob() : null;
  } catch { return null; }
}

async function poll() {
  try {
    const res = await fetch(`${BRIDGE}/state.json`, { cache: 'no-store' });
    const state = await res.json();
    Object.assign(settings, state.settings);
    setEffectsOff(!!state.effectsOff);
    // Resync to the desktop's rain clock; tiny drift is smoothed by only
    // snapping when it's noticeable.
    const now = performance.now();
    const local = currentTime(now);
    if (state.paused !== clock.paused || Math.abs(local - state.time) > 0.08) {
      clock = { base: state.time, at: now, paused: state.paused };
    }
    const status = document.getElementById('status');
    if (status) status.hidden = true;
    if (state.version !== wallpaperVersion) {
      const img = await fetch(`${BRIDGE}/wallpaper.jpg`, { cache: 'no-store' });
      const blob = await img.blob();
      caches.open('rainy').then((c) => c.put('/wallpaper', new Response(blob))).catch(() => {});
      await setWallpaper(blob);
      if (wallpaperVersion !== null) chrome.runtime.sendMessage({ type: 'wallpaperChanged' }).catch(() => {});
      wallpaperVersion = state.version;
    }
  } catch {
    const status = document.getElementById('status');
    if (status) status.hidden = false;
    if (wallpaperVersion === null) {
      wallpaperVersion = 'cached';
      const blob = await cachedWallpaper();
      if (blob) await setWallpaper(blob);
    }
  }
}

function currentTime(now = performance.now()) {
  return clock.paused ? clock.base : clock.base + (now - clock.at) / 1000;
}

// -------------------------------------------------------------- WebGL ----

const canvas = document.getElementById('rain');
const gl = canvas.getContext('webgl2', { antialias: false, alpha: false, premultipliedAlpha: false });

const VERT = `#version 300 es
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

const FRAG = `#version 300 es
precision highp float;
uniform sampler2D u_sharp;
uniform sampler2D u_blur;
uniform vec2 u_res;      // screen size, device px (the space Rainy renders in)
uniform vec2 u_offset;   // this viewport's bottom-left within the screen, device px
uniform float u_time, u_dpr;
uniform float u_rainIntensity, u_rainSpeed, u_staticDropDensity, u_layer1Density, u_layer2Density;
uniform float u_fogMinBlur, u_fogMaxBlurLow, u_fogMaxBlurHigh, u_refractionStrength;
uniform float u_lightningBoost, u_lightningSpeed, u_lightningSharpness;
uniform float u_colorGradeStrength, u_vignetteStrength, u_brightness;
uniform float u_zoomAmount, u_zoomSpeed, u_dimAmount, u_dropZoomOut;
uniform float u_chromeDim; // Chrome-only wallpaper dim, on top of the desktop's own
uniform float u_static;    // 1 = effects off: still, sharp wallpaper, no rain/lightning/zoom -- glass only
uniform float u_bgBlur;    // behind websites: how fogged the still wallpaper is (0 = sharp)
uniform float u_bgDim;     // behind websites: extra darkening so page text reads over any wallpaper
uniform int u_glassCount;
uniform vec4 u_glassRect[${MAX_GLASS}];  // x, y (bottom-left, canvas px), w, h
uniform vec2 u_glassStyle[${MAX_GLASS}]; // corner radius px, frost (0 = default)
uniform vec4 u_glassFx[${MAX_GLASS}];    // hover, press, ripple age (s), unused
uniform vec4 u_glassPointer[${MAX_GLASS}]; // pointer xy, ripple origin xy (canvas px)
out vec4 outColor;

#define S(a, b, t) smoothstep(a, b, t)

// ---- "Heartfelt" by Martijn Steinrucken (BigWings), CC BY-NC-SA 3.0 ----
// https://www.shadertoy.com/view/ltffzl -- same port as RenderShaders.metal.
vec3 N13(float p) {
  vec3 p3 = fract(vec3(p) * vec3(.1031, .11369, .13787));
  p3 += dot(p3, p3.yzx + 19.19);
  return fract(vec3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}
float N(float t) { return fract(sin(t * 12345.564) * 7658.76); }
float Saw(float b, float t) { return S(0., b, t) * S(1., b, t); }

vec2 DropLayer2(vec2 uv, float t) {
  vec2 UV = uv;
  uv.y += t * 0.75;
  vec2 a = vec2(6., 1.);
  vec2 grid = a * 2.;
  vec2 id = floor(uv * grid);
  float colShift = N(id.x);
  uv.y += colShift;
  id = floor(uv * grid);
  vec3 n = N13(id.x * 35.2 + id.y * 2376.1);
  vec2 st = fract(uv * grid) - vec2(.5, 0);
  float x = n.x - .5;
  float y = UV.y * 20.;
  float wiggle = sin(y + sin(y));
  x += wiggle * (.5 - abs(x)) * (n.z - .5);
  x *= .7;
  float ti = fract(t + n.z);
  y = (Saw(.85, ti) - .5) * .9 + .5;
  vec2 p = vec2(x, y);
  float d = length((st - p) * a.yx);
  float mainDrop = S(.4, .0, d);
  float r = sqrt(S(1., y, st.y));
  float cd = abs(st.x - x);
  float trail = S(.23 * r, .15 * r * r, cd);
  float trailFront = S(-.02, .02, st.y - y);
  trail *= trailFront * r * r;
  y = UV.y;
  y = fract(y * 10.) + (st.y - .5);
  float dd = length(st - vec2(x, y));
  float droplets = S(.3, 0., dd);
  float m = mainDrop + droplets * r * trailFront;
  return vec2(m, trail);
}

float StaticDrops(vec2 uv, float t) {
  uv *= 40.;
  vec2 id = floor(uv);
  uv = fract(uv) - .5;
  vec3 n = N13(id.x * 107.45 + id.y * 3543.654);
  vec2 p = (n.xy - .5) * .7;
  float d = length(uv - p);
  float fade = Saw(.025, fract(t + n.z));
  return S(.3, 0., d) * fract(n.z * 10.) * fade;
}

vec2 Drops(vec2 uv, float t, float l0, float l1, float l2) {
  float s = StaticDrops(uv, t) * l0;
  vec2 m1 = DropLayer2(uv, t) * l1;
  vec2 m2 = DropLayer2(uv * 1.85, t) * l2;
  float c = S(.3, 1., s + m1.x + m2.x);
  return vec2(c, max(m1.y * l0, m2.y * l1));
}

float sdRoundRect(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.)) + min(max(q.x, q.y), 0.) - r;
}

vec3 encodeSRGB(vec3 c) {
  c = clamp(c, 0., 1.);
  return mix(c * 12.92, 1.055 * pow(c, vec3(1. / 2.4)) - .055, step(.0031308, c));
}

void main() {
  vec2 local = gl_FragCoord.xy;
  vec2 iResolution = u_res;
  vec2 fragCoord = local + u_offset;

  vec2 uv = (fragCoord - .5 * iResolution) / iResolution.y;
  vec2 UV = fragCoord / iResolution;
  float T = u_time;
  float t = T * .2 * u_rainSpeed;
  float rainAmount = clamp(u_rainIntensity, 0., 1.);
  float maxBlur = mix(u_fogMaxBlurLow, u_fogMaxBlurHigh, rainAmount);
  float minBlur = u_fogMinBlur;

  float zoom = u_static > .5 ? 0. : -cos(T * .2 * u_zoomSpeed) * u_zoomAmount;
  uv *= .7 + zoom * .3;
  uv *= max(u_dropZoomOut, 0.1);
  float uvScale = .9 + zoom * .1;
  UV = (UV - .5) * uvScale + .5;

  float staticDropsAmt = S(-.5, 1., rainAmount) * 2. * u_staticDropDensity;
  float layer1 = S(.25, .75, rainAmount) * u_layer1Density;
  float layer2 = S(.0, .5, rainAmount) * u_layer2Density;
  vec2 c = vec2(0.), n = vec2(0.);
  if (u_static < .5) { // the rain itself is skipped entirely when static
    c = Drops(uv, t, staticDropsAmt, layer1, layer2);
    vec2 e = vec2(.001, 0.);
    float cx = Drops(uv + e, t, staticDropsAmt, layer1, layer2).x;
    float cy = Drops(uv + e.yx, t, staticDropsAmt, layer1, layer2).x;
    n = vec2(cx - c.x, cy - c.x) * u_refractionStrength;
  }

  float focus = mix(maxBlur - c.y, minBlur, S(.1, .2, c.x));
  float blurAmount = u_static > .5 ? u_bgBlur : clamp(exp2(focus - maxBlur), 0., 1.);
  vec2 texUV = vec2(UV.x + n.x, 1. - (UV.y + n.y));
  vec3 col = mix(texture(u_sharp, texUV).rgb, texture(u_blur, texUV).rgb, blurAmount);

  float pt = (T + 3.) * .5 * u_lightningSpeed;
  float colFade = (sin(pt * .2) * .5 + .5) * clamp(u_colorGradeStrength, 0., 1.) * (1. - u_static);
  vec3 grade = mix(vec3(1.), vec3(.8, .9, 1.3), colFade);
  col *= grade;
  float fade = u_static > .5 ? 1. : S(0., 10., T);
  float lightning = sin(pt * sin(pt * 10.));
  lightning *= pow(max(0., sin(pt + sin(pt))), max(u_lightningSharpness, 0.01)) * (1. - u_static);
  float flash = 1. + lightning * fade * u_lightningBoost;
  col *= flash;
  vec2 vUV = (UV - .5) * u_vignetteStrength;
  col *= 1. - clamp(dot(vUV, vUV), 0., 1.);
  float exposure = fade * u_brightness * (1. - clamp(u_dimAmount, 0., 1.));
  col *= exposure;
  col *= 1. - u_bgDim;

  // ---- Liquid glass: each UI element is a lens over the fogged wallpaper ----
  for (int i = 0; i < ${MAX_GLASS}; i++) {
    if (i >= u_glassCount) break;
    vec4 R = u_glassRect[i];
    vec2 hb = R.zw * .5;
    vec2 p = local - (R.xy + hb);
    float r = min(u_glassStyle[i].x, min(hb.x, hb.y));
    vec4 fx = u_glassFx[i], ptr = u_glassPointer[i];
    float hover = fx.x, press = fx.y, age = fx.z;
    float d = sdRoundRect(p, hb, r);

    // Soft contact shadow, offset downward.
    float ds = sdRoundRect(p + vec2(0., 5. * u_dpr), hb, r);
    col *= 1. - .05 * (1. - S(-4. * u_dpr, 22. * u_dpr, ds)) * S(-1., 1., d);
    if (d > 1.) continue;

    float h = 1.5;
    vec2 g = vec2(sdRoundRect(p + vec2(h, 0.), hb, r) - sdRoundRect(p - vec2(h, 0.), hb, r),
                  sdRoundRect(p + vec2(0., h), hb, r) - sdRoundRect(p - vec2(0., h), hb, r));
    vec2 nrm = normalize(g + 1e-5);
    // Pure refraction, no added light (like Apple's Liquid Glass): the shape
    // reads only because the scene bends through it. A thick rounded rim
    // (a quarter-circle bevel profile) compresses and warps the background
    // hard toward the edge; the flat middle is a semi-clear, gently
    // magnifying lens -- clearer than the fogged, rainy glass around it.
    float bevel = min(22. * u_dpr, min(hb.x, hb.y));
    float x = clamp(1. + d / bevel, 0., 1.);                  // 0 inside the flat middle -> 1 at the rim
    float slope = x / sqrt(max(1. - x * x, 1e-3));           // circular bevel: steepens sharply at the edge
    float bend = min(slope, 6.) * (7. + 5. * press) * u_dpr;
    vec2 refr = -nrm * bend;
    refr -= p * (.05 + .04 * hover + .08 * press);           // lens magnification; swells on hover/press

    // Ripple from the last press: a refractive wave, no glow.
    if (age < 1.6) {
      vec2 rv = local - ptr.zw;
      float rd = length(rv);
      float ring = rd - age * 380. * u_dpr;
      float w = 22. * u_dpr;
      refr += rv / max(rd, 1.) * exp(-age * 3.) * exp(-ring * ring / (w * w)) * 16. * u_dpr;
    }

    // Semi-frosted interior (sharp/fog mix), with dispersion only in the rim.
    float frost = u_glassStyle[i].y > 0. ? u_glassStyle[i].y : .55;  // panels under text frost more
    vec3 glass;
    for (int k = 0; k < 3; k++) {
      vec2 fc = fragCoord + refr * (1. + float(k - 1) * .06 * x);
      vec2 gUV = (fc / iResolution - .5) * uvScale + .5;
      vec2 tuv = vec2(gUV.x, 1. - gUV.y);
      vec3 sm = mix(texture(u_sharp, tuv).rgb, texture(u_blur, tuv).rgb, frost) * grade * flash * exposure;
      glass[k] = sm[k];
    }
    glass *= .8 * (1. - .8 * u_bgDim);  // slight smoke only -- never lightened
    // Light bent away at the steep rim reads as a darker band (total
    // internal reflection) -- the edge is defined by losing light, not adding it.
    glass *= 1. - .15 * pow(x, 4.); // only a hint -- no black outline

    col = mix(col, glass, 1. - S(-1., 1., d));
  }

  col *= 1. - clamp(u_chromeDim, 0., .95);
  outColor = vec4(encodeSRGB(col), 1.);
}`;

function compile(type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

let program, uniforms = {}, sharpTex, blurTex, wallpaperBitmap = null, blurKey = '';

function makeTexture() {
  const t = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  // Placeholder until the wallpaper arrives: near-black.
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([10, 10, 12, 255]));
  return t;
}

function upload(tex, source) {
  gl.bindTexture(gl.TEXTURE_2D, tex);
  // sRGB internal format: sampling decodes to linear, like the app's pipeline.
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE, source);
}

let wallpaperUrl = null;
async function setWallpaper(blob) {
  if (wallpaperUrl) URL.revokeObjectURL(wallpaperUrl);
  wallpaperUrl = URL.createObjectURL(blob);
  document.body.style.setProperty('--wallpaper', `url("${wallpaperUrl}")`);
  if (!sharpTex) return; // no WebGL: the CSS wallpaper above is all there is
  wallpaperBitmap = await createImageBitmap(blob);
  upload(sharpTex, wallpaperBitmap);
  blurKey = ''; // rebuild fog
  requestRender();
}

// Fog texture, mirroring RainRenderer.encodeBlur: a gaussian of
// 2^(maxBlur-1) px at 1080p, built at the smallest size where that sigma
// still spans >= ~2.5 texels (smooth when upsampled, cheap to build). The
// canvas blur fades to transparent at the borders; uploading it
// unpremultiplied renormalizes those edges instead of darkening them.
function rebuildBlurIfNeeded() {
  if (!wallpaperBitmap) return;
  const screenH = screen.height * devicePixelRatio, screenW = screen.width * devicePixelRatio;
  const maxBlur = settings.fogMaxBlurLow + (settings.fogMaxBlurHigh - settings.fogMaxBlurLow) * Math.min(Math.max(settings.rainIntensity, 0), 1);
  // At least ~12 CSS px of frost, whatever the fog sliders say, so the glass
  // backdrop always reads as frosted rather than a sharp photo.
  const sigma = Math.min(Math.max(2 ** (maxBlur - 1) * screenH / 1080, 12 * devicePixelRatio), screenH);
  const key = `${Math.round(sigma * 10)}|${screenW}x${screenH}`;
  if (key === blurKey) return;
  blurKey = key;
  const scale = Math.min(1, 5 / Math.max(sigma, 0.001));
  const w = Math.max(16, Math.round(screenW * scale)), h = Math.max(16, Math.round(screenH * scale));
  const c = new OffscreenCanvas(w, h);
  const ctx = c.getContext('2d');
  ctx.filter = `blur(${sigma * scale}px)`;
  ctx.drawImage(wallpaperBitmap, 0, 0, w, h);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  upload(blurTex, c);
}

let lastFrame = performance.now();
let glassAnimating = false; // New Tab springs/ripples still moving -> keep drawing in static mode
// Backdrop page (behind a website): the page's liquid buttons arrive from
// glass-site.js as viewport rects; only the parent page may send them.
let externalLenses = [];
window.addEventListener('message', (e) => {
  if (e.source !== window.parent || e.data?.type !== 'rainy-lenses') return;
  externalLenses = e.data.lenses;
  requestRender();
});

function glassRects(now) {
  const dpr = devicePixelRatio;
  if (typeof stepGlass !== 'function') {
    return externalLenses.slice(0, MAX_GLASS).map((l) => ({
      x: l.x * dpr, y: (innerHeight - l.y - l.h) * dpr, w: l.w * dpr, h: l.h * dpr, r: l.r * dpr, frost: l.frost || 0,
      fx: [l.hover, l.press, l.rippleAge, 0],
      ptr: [(l.x + l.w / 2) * dpr, (innerHeight - l.y - l.h / 2) * dpr, l.rx * dpr, (innerHeight - l.ry) * dpr],
    }));
  }
  const dt = Math.min((now - lastFrame) / 1000, 1 / 30);
  lastFrame = now;
  glassAnimating = false;
  const out = [];
  for (const el of document.querySelectorAll('.glass')) {
    if (el.hidden || !el.checkVisibility({ visibilityProperty: true })) continue;
    const st = stepGlass(el, dt);
    if (Math.abs(st.hover - st.hoverT) > 0.01 || Math.abs(st.press - st.pressT) > 0.01 || now - st.ripple.t < 1600
        || Math.abs(st.scaleV) + Math.abs(st.sxV) + Math.abs(st.syV) + Math.abs(st.txV) + Math.abs(st.tyV) > 0.002
        || Math.abs(st.scale - (1 + 0.035 * st.hoverT - 0.06 * st.pressT)) > 0.0005) glassAnimating = true;
    const b = el.getBoundingClientRect();
    if (b.width === 0 || b.bottom < 0 || b.top > innerHeight) continue;
    out.push({
      x: b.left * dpr, y: (innerHeight - b.bottom) * dpr, w: b.width * dpr, h: b.height * dpr,
      r: parseFloat(el.dataset.radius || '16') * dpr * Math.min(b.width / Math.max(el.offsetWidth, 1), 1.2),
      fx: [st.hover, st.press, (now - st.ripple.t) / 1000, 0],
      ptr: [st.px * dpr, (innerHeight - st.py) * dpr, st.ripple.x * dpr, (innerHeight - st.ripple.y) * dpr],
    });
    if (out.length === MAX_GLASS) break;
  }
  return out;
}

function init() {
  if (!gl) return false;
  try {
    program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, VERT));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  } catch (err) {
    console.error('Rainy Tab shader failed:', err);
    return false;
  }
  gl.useProgram(program);
  const n = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < n; i++) {
    const name = gl.getActiveUniform(program, i).name.replace(/\[0\]$/, '');
    uniforms[name] = gl.getUniformLocation(program, name);
  }
  sharpTex = makeTexture();
  blurTex = makeTexture();
  gl.uniform1i(uniforms.u_sharp, 0);
  gl.uniform1i(uniforms.u_blur, 1);
  gl.bindVertexArray(gl.createVertexArray());
  return true;
}

function frame(now) {
  rafId = requestAnimationFrame(frame);
  draw(now);
}

// Static mode (effects off): one frame at a time, only when something
// changed, continuing only while glass is still animating.
let renderQueued = false;
function requestRender() {
  if (!glOk || rafId !== null || renderQueued) return;
  renderQueued = true;
  requestAnimationFrame((now) => {
    renderQueued = false;
    if (draw(now)) requestRender();
  });
}

// Behind a website, tell glass-site.js the wallpaper's current UV scale
// (the shader's breathing zoom: .9 still, .9 + zoom*.1 live) so the glass
// panes in pop-ups crop the wallpaper exactly like the backdrop around them.
let lastViewReport = 0, lastViewScale = 0;
function reportViewScale(now) {
  if (window.parent === window || now - lastViewReport < 400) return;
  lastViewReport = now;
  const zoom = effectsOff ? 0 : -Math.cos(currentTime(now) * 0.2 * settings.zoomSpeed) * settings.zoomAmount;
  const scale = 0.9 + zoom * 0.1;
  if (Math.abs(scale - lastViewScale) < 0.001) return;
  lastViewScale = scale;
  window.parent.postMessage({ type: 'rainy-view', scale }, '*');
}

function draw(now) {
  const dpr = devicePixelRatio;
  const w = Math.round(innerWidth * dpr), h = Math.round(innerHeight * dpr);
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
  gl.viewport(0, 0, w, h);
  rebuildBlurIfNeeded();

  // Where this viewport sits on its screen (CSS px): window position minus
  // the screen's origin, plus the browser chrome above the page.
  const screenLeft = 'left' in screen ? screen.left : (screen.availLeft || 0);
  const screenTop = 'top' in screen ? screen.top : 0;
  const vpLeft = screenX - screenLeft + (outerWidth - innerWidth) / 2;
  const vpTop = screenY - screenTop + (outerHeight - innerHeight);
  gl.uniform2f(uniforms.u_res, screen.width * dpr, screen.height * dpr);
  gl.uniform2f(uniforms.u_offset, vpLeft * dpr, (screen.height - vpTop - innerHeight) * dpr);
  gl.uniform1f(uniforms.u_time, currentTime(now));
  reportViewScale(now);
  gl.uniform1f(uniforms.u_dpr, dpr);
  for (const [k, v] of Object.entries(settings)) {
    const loc = uniforms[`u_${k}`];
    if (loc) gl.uniform1f(loc, v);
  }
  // Chrome's darkness is Chrome Dim alone. The desktop's own "Dim Wallpaper"
  // stacked on top made every Chrome surface so dark there was nothing left
  // for the glass to refract.
  gl.uniform1f(uniforms.u_dimAmount, 0);
  gl.uniform1f(uniforms.u_static, effectsOff ? 1 : 0);
  // Still mode frosts the wallpaper everywhere. Behind a website
  // (backdrop.html) the page's own text sits right on it, so it's also
  // darkened a little; the New Tab page isn't.
  const behindSite = window.parent !== window;
  gl.uniform1f(uniforms.u_bgBlur, 1); // still mode: frosted wallpaper everywhere (New Tab too)
  gl.uniform1f(uniforms.u_bgDim, behindSite ? 0.3 : 0);

  const rects = glassRects(now);
  const rectData = new Float32Array(MAX_GLASS * 4), styleData = new Float32Array(MAX_GLASS * 2);
  const fxData = new Float32Array(MAX_GLASS * 4), ptrData = new Float32Array(MAX_GLASS * 4);
  rects.forEach((g, i) => {
    rectData.set([g.x, g.y, g.w, g.h], i * 4);
    styleData.set([g.r, g.frost || 0], i * 2);
    fxData.set(g.fx, i * 4);
    ptrData.set(g.ptr, i * 4);
  });
  gl.uniform1i(uniforms.u_glassCount, rects.length);
  gl.uniform4fv(uniforms.u_glassRect, rectData);
  gl.uniform2fv(uniforms.u_glassStyle, styleData);
  gl.uniform4fv(uniforms.u_glassFx, fxData);
  gl.uniform4fv(uniforms.u_glassPointer, ptrData);

  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, sharpTex);
  gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, blurTex);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  return glassAnimating || externalLenses.some((l) => l.rippleAge < 1.6);
}

// ------------------------------------------------------- kill switch ----
// Rainy's "Effects Off" (⌃⌥⌘R): no rain and no render loop -- a still, sharp
// wallpaper with the liquid glass still on it, redrawn only when something
// changes (so idle GPU use is nil). Without WebGL at all it falls back to
// the plain wallpaper and CSS glass. Remembered locally so it holds even
// when Rainy isn't running.

let rafId = null;
const glOk = init();
let effectsOff = (() => { try { return localStorage.getItem('rainy.effectsOff') === '1'; } catch { return false; } })();

function applyEffects() {
  const live = glOk && !effectsOff;
  document.body.classList.toggle('webgl-glass', glOk);
  document.body.classList.toggle('effects-off', !glOk);
  canvas.hidden = !glOk;
  // Behind a website, tell glass-site.js whether the page's panels can be
  // lenses (glass) and whether to stream lens positions every frame (live)
  // or only when something moves.
  if (window.parent !== window) window.parent.postMessage({ type: 'rainy-effects', glass: glOk, live }, '*');
  if (live && rafId === null) {
    rafId = requestAnimationFrame(frame);
  } else if (!live && rafId !== null) {
    cancelAnimationFrame(rafId);
    rafId = null;
  }
  requestRender();
}

// Static mode redraw triggers: resize, the window moving on screen (the
// wallpaper is screen-aligned), and any interaction on the New Tab page.
addEventListener('resize', requestRender);
let lastPlacement = '';
setInterval(() => {
  const placement = `${screenX},${screenY},${outerWidth},${outerHeight},${innerWidth},${innerHeight}`;
  if (placement !== lastPlacement) { lastPlacement = placement; requestRender(); }
}, 250);
for (const type of ['pointermove', 'pointerover', 'pointerout', 'pointerdown', 'pointerup', 'keydown', 'input', 'focusin']) {
  addEventListener(type, requestRender, { capture: true, passive: true });
}

function setEffectsOff(off) {
  if (off === effectsOff) return;
  effectsOff = off;
  try { localStorage.setItem('rainy.effectsOff', off ? '1' : '0'); } catch {}
  applyEffects();
}

applyEffects();
poll().then(requestRender); // settings may have changed
setInterval(() => { if (!document.hidden) poll().then(requestRender); }, 2000);
