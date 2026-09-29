#include <metal_stdlib>
#include "RainTypes.h"
using namespace metal;

// ---------------------------------------------------------------------
// Fullscreen triangle, shared by the rain fragment shader below.
// ---------------------------------------------------------------------

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VSOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = positions[vid] * float2(0.5, -0.5) + 0.5;
    return out;
}

// Seeds the blur target: a render-pass sample of the (sRGB) wallpaper
// texture properly gamma-decodes it. Compute kernels reading an sRGB
// texture via access::read don't reliably work the same way -- mixing that
// in is what caused the blur to render solid black at one point.
fragment float4 passthroughFragment(VSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(src.sample(s, in.uv).rgb, 1.0);
}

// ---------------------------------------------------------------------
// Separable gaussian blur building the fog texture -- not the
// mip-LOD-sampled "blur" the original shader uses, which is really a
// box-filter cascade that reads as visible soft blocks (pixelation) on a
// detailed wallpaper. Instead the renderer box-downsamples the wallpaper
// into a small pyramid, runs this gaussian at the level where the target
// sigma spans ~2.5-5 texels, and bilinearly upsamples the result: a blur
// that wide has no texel-scale detail left, so upscaling it stays smooth.
//
// Implemented as render passes (fragment shaders), not compute kernels.
// A compute version of this hit real, reproducible bugs -- a black result,
// then patchy hard-edged regions that were never fully blurred -- most
// likely from multiple compute encoders in one command buffer racing on
// the same texture across iterations. Every render-pass step in this
// pipeline (the main rain shader, the sRGB->linear seed copy) has worked
// correctly from the start, so the blur uses that same proven mechanism.
// ---------------------------------------------------------------------

// 9-tap gaussian (sigma = 2 taps). Weights are normalized in-shader: an
// earlier hardcoded table summed to ~0.5, so each pass halved brightness and
// six compounded passes left the blurred texture essentially black.
// `stepTexels` is the tap spacing in source texels; the renderer picks a
// pyramid level low enough that it stays <= ~1.5 so taps never "ghost".
static float4 gaussian9(texture2d<float> src, float2 uv, float2 stepUV) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 sum = float4(0.0);
    float total = 0.0;
    for (int i = -4; i <= 4; i++) {
        float w = exp(-float(i * i) / 8.0);
        sum += src.sample(s, uv + float(i) * stepUV) * w;
        total += w;
    }
    return float4(sum.rgb / total, 1.0);
}

fragment float4 blurHorizontalFragment(VSOut in [[stage_in]],
                                        texture2d<float> src [[texture(0)]],
                                        constant float &stepTexels [[buffer(0)]]) {
    return gaussian9(src, in.uv, float2(stepTexels / float(src.get_width()), 0.0));
}

fragment float4 blurVerticalFragment(VSOut in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      constant float &stepTexels [[buffer(0)]]) {
    return gaussian9(src, in.uv, float2(0.0, stepTexels / float(src.get_height())));
}

// ---------------------------------------------------------------------
// "Heartfelt" rain-on-glass, ported from GLSL to MSL.
//
// Original: Martijn Steinrucken (BigWings) -- countfrolic@gmail.com,
// @The_ArtOfCode -- https://www.shadertoy.com/view/ltffzl
// License: Creative Commons Attribution-NonCommercial-ShareAlike 3.0
// Unported (CC BY-NC-SA 3.0): https://creativecommons.org/licenses/by-nc-sa/3.0/
//
// Ported as directly as MSL syntax allows. Deliberately dropped: the
// iMouse-driven rain-amount control (this wallpaper has no mouse input --
// always takes the shader's own no-mouse default animation) and the
// HAS_HEART story/heart-shape sequence (a one-off 102s Valentine's-Day
// narrative in the original; a wallpaper should just rain continuously,
// not loop a story). Everything else -- both drop layers, static drops,
// the fog/trail-driven focus blur, the expensive-normals refraction, and
// the post-processing (color grade, lightning flicker, vignette, fade-in)
// -- is the original algorithm.
// ---------------------------------------------------------------------

#define S(a, b, t) smoothstep(a, b, t)

float3 N13(float p) {
    // from Dave Hoskins
    float3 p3 = fract(float3(p) * float3(.1031, .11369, .13787));
    p3 += dot(p3, p3.yzx + 19.19);
    return fract(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}

float N(float t) {
    return fract(sin(t * 12345.564) * 7658.76);
}

float Saw(float b, float t) {
    return S(0., b, t) * S(1., b, t);
}

float2 DropLayer2(float2 uv, float t) {
    float2 UV = uv;

    uv.y += t * 0.75;
    float2 a = float2(6., 1.);
    float2 grid = a * 2.;
    float2 id = floor(uv * grid);

    float colShift = N(id.x);
    uv.y += colShift;

    id = floor(uv * grid);
    float3 n = N13(id.x * 35.2 + id.y * 2376.1);
    float2 st = fract(uv * grid) - float2(.5, 0);

    float x = n.x - .5;

    float y = UV.y * 20.;
    float wiggle = sin(y + sin(y));
    x += wiggle * (.5 - abs(x)) * (n.z - .5);
    x *= .7;
    float ti = fract(t + n.z);
    y = (Saw(.85, ti) - .5) * .9 + .5;
    float2 p = float2(x, y);

    float d = length((st - p) * a.yx);

    float mainDrop = S(.4, .0, d);

    float r = sqrt(S(1., y, st.y));
    float cd = abs(st.x - x);
    float trail = S(.23 * r, .15 * r * r, cd);
    float trailFront = S(-.02, .02, st.y - y);
    trail *= trailFront * r * r;

    y = UV.y;
    float trail2 = S(.2 * r, .0, cd);
    float droplets = max(0., (sin(y * (1. - y) * 120.) - st.y)) * trail2 * trailFront * n.z;
    y = fract(y * 10.) + (st.y - .5);
    float dd = length(st - float2(x, y));
    droplets = S(.3, 0., dd);
    float m = mainDrop + droplets * r * trailFront;

    return float2(m, trail);
}

float StaticDrops(float2 uv, float t) {
    uv *= 40.;
    float2 id = floor(uv);
    uv = fract(uv) - .5;
    float3 n = N13(id.x * 107.45 + id.y * 3543.654);
    float2 p = (n.xy - .5) * .7;
    float d = length(uv - p);
    float fade = Saw(.025, fract(t + n.z));
    float c = S(.3, 0., d) * fract(n.z * 10.) * fade;
    return c;
}

float2 Drops(float2 uv, float t, float l0, float l1, float l2) {
    float s = StaticDrops(uv, t) * l0;
    float2 m1 = DropLayer2(uv, t) * l1;
    float2 m2 = DropLayer2(uv * 1.85, t) * l2;

    float c = s + m1.x + m2.x;
    c = S(.3, 1., c);

    return float2(c, max(m1.y * l0, m2.y * l1));
}

fragment float4 heartfeltRainFragment(VSOut in [[stage_in]],
                                       texture2d<float> wallpaper [[texture(0)]],
                                       texture2d<float> blurredWallpaper [[texture(1)]],
                                       constant RainUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, mip_filter::linear, mag_filter::linear, min_filter::linear);

    float2 iResolution = u.resolution;
    // Metal's fragment [[position]] has a top-left origin (y grows downward);
    // the original assumes GL's bottom-left-origin fragCoord. Flip so the
    // rain falls the same visual direction as the source.
    float2 fragCoord = float2(in.position.x, iResolution.y - in.position.y);

    float2 uv = (fragCoord - .5 * iResolution) / iResolution.y;
    float2 UV = fragCoord / iResolution;

    float T = u.time;
    float t = T * .2 * u.rainSpeed;

    float rainAmount = saturate(u.rainIntensity);

    float maxBlur = mix(u.fogMaxBlurLow, u.fogMaxBlurHigh, rainAmount);
    float minBlur = u.fogMinBlur;

    float zoom = -cos(T * .2 * u.zoomSpeed) * u.zoomAmount;
    uv *= .7 + zoom * .3;
    // Zooms out on the glass only (the drop field), not the wallpaper behind it.
    uv *= max(u.dropZoomOut, 0.1);
    UV = (UV - .5) * (.9 + zoom * .1) + .5;

    float staticDropsAmt = S(-.5, 1., rainAmount) * 2. * u.staticDropDensity;
    float layer1 = S(.25, .75, rainAmount) * u.layer1Density;
    float layer2 = S(.0, .5, rainAmount) * u.layer2Density;

    float2 c = Drops(uv, t, staticDropsAmt, layer1, layer2);

    float2 e = float2(.001, 0.);
    float cx = Drops(uv + e, t, staticDropsAmt, layer1, layer2).x;
    float cy = Drops(uv + e.yx, t, staticDropsAmt, layer1, layer2).x;
    float2 n = float2(cx - c.x, cy - c.x) * u.refractionStrength;

    float focus = mix(maxBlur - c.y, minBlur, S(.1, .2, c.x));
    // `focus` is the original's mip-LOD blur level; blurredWallpaper is
    // prebuilt at exactly the maxBlur level, so each LOD step below it halves
    // the blend toward sharp. Unlike normalizing by (maxBlur - minBlur), this
    // stays well-defined when the min/max sliders meet or cross.
    float blurAmount = saturate(exp2(focus - maxBlur));

    // The rain math above stays in the original shader's GL-style, bottom-left
    // origin UV space (needed so drops fall the correct visual direction), but
    // Metal's texture sampling is top-left-origin -- flip V only for the
    // actual texture lookup, or the wallpaper renders upside down while the
    // rain itself still looks right.
    float2 texUV = float2(UV.x + n.x, 1. - (UV.y + n.y));
    float3 sharpSample = wallpaper.sample(s, texUV).rgb;
    float3 blurredSample = blurredWallpaper.sample(s, texUV).rgb;
    float3 col = mix(sharpSample, blurredSample, blurAmount);

    // USE_POST_PROCESSING
    float pt = (T + 3.) * .5 * u.lightningSpeed; // sync with the first "lightning" flicker
    float colFade = (sin(pt * .2) * .5 + .5) * saturate(u.colorGradeStrength);
    col *= mix(float3(1.), float3(.8, .9, 1.3), colFade); // subtle color shift
    float fade = S(0., 10., T); // fade in at the start
    float lightning = sin(pt * sin(pt * 10.));
    lightning *= pow(max(0., sin(pt + sin(pt))), max(u.lightningSharpness, 0.01)); // lightning flash shape
    // u.lightningBoost amplifies the original's flicker into a punchier peak;
    // in this EDR-enabled pipeline that peak genuinely reads as HDR overbright
    // on capable displays rather than clamping at reference white.
    col *= 1. + lightning * fade * u.lightningBoost;
    float2 vUV = (UV - .5) * u.vignetteStrength;
    col *= 1. - saturate(dot(vUV, vUV)); // vignette

    col *= fade * u.brightness * (1. - saturate(u.dimAmount));

    return float4(col, 1.);
}
