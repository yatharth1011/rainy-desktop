import simd

// Mirrors Rendering/Shaders/RainTypes.h byte-for-byte. Keep field order and
// types in lockstep with the header when editing either side.
struct RainUniforms {
    var resolution: SIMD2<Float>
    var time: Float

    var rainIntensity: Float
    var rainSpeed: Float
    var staticDropDensity: Float
    var layer1Density: Float
    var layer2Density: Float

    var fogMinBlur: Float
    var fogMaxBlurLow: Float
    var fogMaxBlurHigh: Float
    var refractionStrength: Float

    var lightningBoost: Float
    var lightningSpeed: Float
    var lightningSharpness: Float

    var colorGradeStrength: Float
    var vignetteStrength: Float
    var brightness: Float

    var zoomAmount: Float
    var zoomSpeed: Float

    var dimAmount: Float
    var dropZoomOut: Float
}
