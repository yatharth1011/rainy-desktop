import Foundation
import Combine

/// Every user-adjustable knob for the rain shader and the radio widget, backed
/// by UserDefaults so they survive a relaunch. Read live (every frame, for the
/// shader fields) by each screen's RainRenderer and by the radio widget --
/// deliberately a plain ObservableObject, not @MainActor, since it's touched
/// from both SwiftUI (the settings popover) and MTKView's render callback,
/// which in practice both run on the main thread but aren't statically the
/// same actor.
final class RainSettings: ObservableObject {
    static let shared = RainSettings()

    // Rain
    @Published var rainIntensity: Float { didSet { save() } }
    @Published var rainSpeed: Float { didSet { save() } }
    @Published var staticDropDensity: Float { didSet { save() } }
    @Published var layer1Density: Float { didSet { save() } }
    @Published var layer2Density: Float { didSet { save() } }

    // Glass / fog
    @Published var fogMinBlur: Float { didSet { save() } }
    @Published var fogMaxBlurLow: Float { didSet { save() } }
    @Published var fogMaxBlurHigh: Float { didSet { save() } }
    @Published var refractionStrength: Float { didSet { save() } }
    @Published var dropZoomOut: Float { didSet { save() } }

    // Lightning
    @Published var lightningBoost: Float { didSet { save() } }
    @Published var lightningSpeed: Float { didSet { save() } }
    @Published var lightningSharpness: Float { didSet { save() } }

    // Look / grade
    @Published var colorGradeStrength: Float { didSet { save() } }
    @Published var vignetteStrength: Float { didSet { save() } }
    @Published var brightness: Float { didSet { save() } }
    @Published var dimAmount: Float { didSet { save() } }
    @Published var chromeDim: Float { didSet { save() } }
    @Published var chromeThemeDarkness: Float { didSet { save() } }
    @Published var chromeOmniboxDarkness: Float { didSet { save() } }
    @Published var chromeThemeSaturation: Float { didSet { save() } }
    @Published var chromeThemeFrost: Float { didSet { save() } }
    @Published var chromeToolbarDarkness: Float { didSet { save() } }

    // Breathing zoom
    @Published var zoomAmount: Float { didSet { save() } }
    @Published var zoomSpeed: Float { didSet { save() } }

    // Playback
    @Published var isPaused: Bool { didSet { save() } }
    /// Universal GPU kill switch: desktop rain, Chrome's Rainy Tab and Dromac's glass all stop.
    @Published var effectsOff: Bool { didSet { save() } }
    @Published var chromeOmniboxBlack: Bool { didSet { save() } }

    // Radio widget
    @Published var showRadioWidget: Bool { didSet { save() } }
    @Published var radioSpinSpeed: Float { didSet { save() } }

    private init() {
        let d = UserDefaults.standard
        func f(_ key: String, _ def: Float) -> Float {
            d.object(forKey: key) != nil ? Float(d.double(forKey: key)) : def
        }
        func b(_ key: String, _ def: Bool) -> Bool {
            d.object(forKey: key) != nil ? d.bool(forKey: key) : def
        }

        rainIntensity = f(Keys.rainIntensity, Defaults.rainIntensity)
        rainSpeed = f(Keys.rainSpeed, Defaults.rainSpeed)
        staticDropDensity = f(Keys.staticDropDensity, Defaults.staticDropDensity)
        layer1Density = f(Keys.layer1Density, Defaults.layer1Density)
        layer2Density = f(Keys.layer2Density, Defaults.layer2Density)

        fogMinBlur = f(Keys.fogMinBlur, Defaults.fogMinBlur)
        fogMaxBlurLow = f(Keys.fogMaxBlurLow, Defaults.fogMaxBlurLow)
        fogMaxBlurHigh = f(Keys.fogMaxBlurHigh, Defaults.fogMaxBlurHigh)
        refractionStrength = f(Keys.refractionStrength, Defaults.refractionStrength)
        dropZoomOut = f(Keys.dropZoomOut, Defaults.dropZoomOut)

        lightningBoost = f(Keys.lightningBoost, Defaults.lightningBoost)
        lightningSpeed = f(Keys.lightningSpeed, Defaults.lightningSpeed)
        lightningSharpness = f(Keys.lightningSharpness, Defaults.lightningSharpness)

        colorGradeStrength = f(Keys.colorGradeStrength, Defaults.colorGradeStrength)
        vignetteStrength = f(Keys.vignetteStrength, Defaults.vignetteStrength)
        brightness = f(Keys.brightness, Defaults.brightness)
        dimAmount = f(Keys.dimAmount, Defaults.dimAmount)
        chromeDim = f(Keys.chromeDim, Defaults.chromeDim)
        chromeThemeDarkness = f(Keys.chromeThemeDarkness, Defaults.chromeThemeDarkness)
        chromeOmniboxDarkness = f(Keys.chromeOmniboxDarkness, Defaults.chromeOmniboxDarkness)
        chromeThemeSaturation = f(Keys.chromeThemeSaturation, Defaults.chromeThemeSaturation)
        chromeThemeFrost = f(Keys.chromeThemeFrost, Defaults.chromeThemeFrost)
        chromeToolbarDarkness = f(Keys.chromeToolbarDarkness, Defaults.chromeToolbarDarkness)

        zoomAmount = f(Keys.zoomAmount, Defaults.zoomAmount)
        zoomSpeed = f(Keys.zoomSpeed, Defaults.zoomSpeed)

        isPaused = b(Keys.isPaused, false)
        effectsOff = b(Keys.effectsOff, false)
        chromeOmniboxBlack = b(Keys.chromeOmniboxBlack, true)
        showRadioWidget = b(Keys.showRadioWidget, true)
        radioSpinSpeed = f(Keys.radioSpinSpeed, Defaults.radioSpinSpeed)
    }

    func resetToDefaults() {
        rainIntensity = Defaults.rainIntensity
        rainSpeed = Defaults.rainSpeed
        staticDropDensity = Defaults.staticDropDensity
        layer1Density = Defaults.layer1Density
        layer2Density = Defaults.layer2Density
        fogMinBlur = Defaults.fogMinBlur
        fogMaxBlurLow = Defaults.fogMaxBlurLow
        fogMaxBlurHigh = Defaults.fogMaxBlurHigh
        refractionStrength = Defaults.refractionStrength
        dropZoomOut = Defaults.dropZoomOut
        lightningBoost = Defaults.lightningBoost
        lightningSpeed = Defaults.lightningSpeed
        lightningSharpness = Defaults.lightningSharpness
        colorGradeStrength = Defaults.colorGradeStrength
        vignetteStrength = Defaults.vignetteStrength
        brightness = Defaults.brightness
        dimAmount = Defaults.dimAmount
        chromeDim = Defaults.chromeDim
        chromeThemeDarkness = Defaults.chromeThemeDarkness
        chromeOmniboxDarkness = Defaults.chromeOmniboxDarkness
        chromeThemeSaturation = Defaults.chromeThemeSaturation
        chromeThemeFrost = Defaults.chromeThemeFrost
        chromeToolbarDarkness = Defaults.chromeToolbarDarkness
        zoomAmount = Defaults.zoomAmount
        zoomSpeed = Defaults.zoomSpeed
        radioSpinSpeed = Defaults.radioSpinSpeed
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Double(rainIntensity), forKey: Keys.rainIntensity)
        d.set(Double(rainSpeed), forKey: Keys.rainSpeed)
        d.set(Double(staticDropDensity), forKey: Keys.staticDropDensity)
        d.set(Double(layer1Density), forKey: Keys.layer1Density)
        d.set(Double(layer2Density), forKey: Keys.layer2Density)
        d.set(Double(fogMinBlur), forKey: Keys.fogMinBlur)
        d.set(Double(fogMaxBlurLow), forKey: Keys.fogMaxBlurLow)
        d.set(Double(fogMaxBlurHigh), forKey: Keys.fogMaxBlurHigh)
        d.set(Double(refractionStrength), forKey: Keys.refractionStrength)
        d.set(Double(dropZoomOut), forKey: Keys.dropZoomOut)
        d.set(Double(lightningBoost), forKey: Keys.lightningBoost)
        d.set(Double(lightningSpeed), forKey: Keys.lightningSpeed)
        d.set(Double(lightningSharpness), forKey: Keys.lightningSharpness)
        d.set(Double(colorGradeStrength), forKey: Keys.colorGradeStrength)
        d.set(Double(vignetteStrength), forKey: Keys.vignetteStrength)
        d.set(Double(brightness), forKey: Keys.brightness)
        d.set(Double(dimAmount), forKey: Keys.dimAmount)
        d.set(Double(chromeDim), forKey: Keys.chromeDim)
        d.set(Double(chromeThemeDarkness), forKey: Keys.chromeThemeDarkness)
        d.set(Double(chromeOmniboxDarkness), forKey: Keys.chromeOmniboxDarkness)
        d.set(Double(chromeThemeSaturation), forKey: Keys.chromeThemeSaturation)
        d.set(Double(chromeThemeFrost), forKey: Keys.chromeThemeFrost)
        d.set(Double(chromeToolbarDarkness), forKey: Keys.chromeToolbarDarkness)
        d.set(Double(zoomAmount), forKey: Keys.zoomAmount)
        d.set(Double(zoomSpeed), forKey: Keys.zoomSpeed)
        d.set(isPaused, forKey: Keys.isPaused)
        d.set(effectsOff, forKey: Keys.effectsOff)
        d.set(chromeOmniboxBlack, forKey: Keys.chromeOmniboxBlack)
        d.set(showRadioWidget, forKey: Keys.showRadioWidget)
        d.set(Double(radioSpinSpeed), forKey: Keys.radioSpinSpeed)
    }

    private enum Keys {
        static let rainIntensity = "rain.rainIntensity"
        static let rainSpeed = "rain.rainSpeed"
        static let staticDropDensity = "rain.staticDropDensity"
        static let layer1Density = "rain.layer1Density"
        static let layer2Density = "rain.layer2Density"
        static let fogMinBlur = "rain.fogMinBlur"
        static let fogMaxBlurLow = "rain.fogMaxBlurLow"
        static let fogMaxBlurHigh = "rain.fogMaxBlurHigh"
        static let refractionStrength = "rain.refractionStrength"
        static let dropZoomOut = "rain.dropZoomOut"
        static let lightningBoost = "rain.lightningBoost"
        static let lightningSpeed = "rain.lightningSpeed"
        static let lightningSharpness = "rain.lightningSharpness"
        static let colorGradeStrength = "rain.colorGradeStrength"
        static let vignetteStrength = "rain.vignetteStrength"
        static let brightness = "rain.brightness"
        static let dimAmount = "rain.dimAmount"
        static let chromeDim = "rain.chromeDim"
        static let chromeThemeDarkness = "rain.chromeThemeDarkness"
        static let chromeOmniboxDarkness = "rain.chromeOmniboxDarkness"
        static let chromeThemeSaturation = "rain.chromeThemeSaturation"
        static let chromeThemeFrost = "rain.chromeThemeFrost"
        static let chromeToolbarDarkness = "rain.chromeToolbarDarkness"
        static let zoomAmount = "rain.zoomAmount"
        static let zoomSpeed = "rain.zoomSpeed"
        static let isPaused = "rain.isPaused"
        static let effectsOff = "rain.effectsOff"
        static let chromeOmniboxBlack = "rain.chromeOmniboxBlack"
        static let showRadioWidget = "rain.showRadioWidget"
        static let radioSpinSpeed = "rain.radioSpinSpeed"
    }

    private enum Defaults {
        static let rainIntensity: Float = 0.7
        static let rainSpeed: Float = 1.0
        static let staticDropDensity: Float = 1.0
        static let layer1Density: Float = 1.0
        static let layer2Density: Float = 1.0
        static let fogMinBlur: Float = 2.0
        static let fogMaxBlurLow: Float = 3.0
        static let fogMaxBlurHigh: Float = 6.0
        static let refractionStrength: Float = 1.0
        static let dropZoomOut: Float = 1.0
        static let lightningBoost: Float = 2.6
        static let lightningSpeed: Float = 1.0
        static let lightningSharpness: Float = 10.0
        static let colorGradeStrength: Float = 1.0
        static let vignetteStrength: Float = 1.0
        static let brightness: Float = 1.0
        static let dimAmount: Float = 0.0
        static let chromeDim: Float = 0.35
        static let chromeThemeDarkness: Float = 0.55
        static let chromeOmniboxDarkness: Float = 0.6
        static let chromeThemeSaturation: Float = 1.0
        static let chromeThemeFrost: Float = 14
        static let chromeToolbarDarkness: Float = 0.4
        static let zoomAmount: Float = 1.0
        static let zoomSpeed: Float = 1.0
        static let radioSpinSpeed: Float = 1.0
    }
}
