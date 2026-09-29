#ifndef RainTypes_h
#define RainTypes_h

#include <simd/simd.h>

// Uniforms for the ported "Heartfelt" rain-on-glass shader by Martijn
// Steinrucken (BigWings) -- https://www.shadertoy.com/view/ltffzl,
// CC BY-NC-SA 3.0. Every knob here is exposed live in the settings popover
// (App/RainSettings.swift); field order/types mirrored exactly by
// RainyDesktop/Rendering/SimTypes.swift.
struct RainUniforms {
    simd_float2 resolution;    // pixels
    float time;                 // seconds since launch (or frozen, if paused)

    float rainIntensity;        // 0..1, overrides the shader's automatic rainAmount
    float rainSpeed;             // multiplies the drop scroll/fall speed
    float staticDropDensity;     // extra multiplier on the resting-condensation layer
    float layer1Density;         // extra multiplier on drop layer 1
    float layer2Density;         // extra multiplier on drop layer 2 (the zoomed-in one)

    float fogMinBlur;             // glass blur floor (driest look)
    float fogMaxBlurLow;          // glass blur ceiling at rainIntensity 0
    float fogMaxBlurHigh;         // glass blur ceiling at rainIntensity 1
    float refractionStrength;     // scales how much drops bend the view

    float lightningBoost;         // peak brightness multiplier (HDR overbright on EDR displays)
    float lightningSpeed;         // multiplies the lightning flicker clock
    float lightningSharpness;     // higher = rarer, sharper strikes (exponent on the flash shape)

    float colorGradeStrength;     // 0..1, strength of the cool/warm color cycling
    float vignetteStrength;       // scales the corner vignette
    float brightness;              // final overall brightness multiplier

    float zoomAmount;              // scales the breathing zoom's amplitude
    float zoomSpeed;               // multiplies the breathing zoom's rate

    float dimAmount;                // 0..1, darkens the whole wallpaper (0 = off, 1 = black)
    float dropZoomOut;              // >1 shrinks the drop field so more, smaller drops fit on screen
};

#endif
