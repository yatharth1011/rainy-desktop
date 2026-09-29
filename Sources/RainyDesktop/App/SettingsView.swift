import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = RainSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rainy Desktop")
                    .font(.title3.bold())

                Toggle("Effects Off (save GPU)", isOn: $settings.effectsOff)
                Text("Stops everything: desktop rain, Chrome's New Tab and Dromac's glass. Shortcut: ⌃⌥⌘R")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Pause", isOn: $settings.isPaused)

                group("Rain") {
                    row("Intensity", $settings.rainIntensity, 0...1)
                    row("Fall Speed", $settings.rainSpeed, 0.1...3)
                    row("Static Droplets", $settings.staticDropDensity, 0...3)
                    row("Drop Layer 1", $settings.layer1Density, 0...3)
                    row("Drop Layer 2", $settings.layer2Density, 0...3)
                    row("Refraction", $settings.refractionStrength, 0...4)
                    row("Zoom Out (more drops)", $settings.dropZoomOut, 0.5...4)
                }

                group("Glass / Fog") {
                    row("Min Blur (driest)", $settings.fogMinBlur, 0...10)
                    row("Max Blur (dry)", $settings.fogMaxBlurLow, 0...12)
                    row("Max Blur (wet)", $settings.fogMaxBlurHigh, 0...14)
                }

                group("Lightning") {
                    row("Brightness", $settings.lightningBoost, 0...10)
                    row("Flicker Speed", $settings.lightningSpeed, 0.1...4)
                    row("Sharpness (rarity)", $settings.lightningSharpness, 1...20)
                }

                group("Look") {
                    row("Color Cycling", $settings.colorGradeStrength, 0...1)
                    row("Vignette", $settings.vignetteStrength, 0...2)
                    row("Brightness", $settings.brightness, 0.2...2)
                    row("Dim Wallpaper", $settings.dimAmount, 0...1)
                    row("Breathing Zoom Amount", $settings.zoomAmount, 0...1)
                    row("Breathing Zoom Speed", $settings.zoomSpeed, 0...3)
                }

                group("Chrome") {
                    row("Wallpaper Dim (all of Chrome)", $settings.chromeDim, 0...0.95)
                    row("Tab Strip Darkness", $settings.chromeThemeDarkness, 0...0.95)
                    row("Toolbar Darkness", $settings.chromeToolbarDarkness, 0...0.95)
                    Toggle("Pure Black Address Bar", isOn: $settings.chromeOmniboxBlack)
                    if !settings.chromeOmniboxBlack {
                        row("Address Bar Darkness", $settings.chromeOmniboxDarkness, 0...0.95)
                    }
                    row("Frost (blur)", $settings.chromeThemeFrost, 0...40)
                    row("Saturation", $settings.chromeThemeSaturation, 0...2)
                    Text("Dims the New Tab page and the Rainy Theme. Tab strip / toolbar darkness stack on top of it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                group("Radio Widget") {
                    Toggle("Show Radio Widget", isOn: $settings.showRadioWidget)
                    row("Vinyl Spin Speed", $settings.radioSpinSpeed, 0.2...3)
                    Text("Hidden automatically whenever nothing is playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reset to Defaults") {
                        settings.resetToDefaults()
                    }
                    Spacer()
                    Button("Quit Rainy Desktop") {
                        NSApplication.shared.terminate(nil)
                    }
                    .foregroundStyle(.red)
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
        .frame(width: 340, height: 560)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content()
        }
        Divider()
    }

    @ViewBuilder
    private func row(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
