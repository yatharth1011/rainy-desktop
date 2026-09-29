import AppKit
import Metal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: WallpaperWindowController?
    private var radioWindows: [RadioWidgetWindow] = []
    private let nowPlaying = NowPlayingAggregator()
    private var statusItemController: StatusItemController?
    private var settingsButtonWindow: SettingsButtonWindow?
    private var chromeBridge: ChromeBridge?
    private var killSwitchHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching start")
        NSApp.setActivationPolicy(.accessory) // no dock icon / app switcher entry -- this is a background wallpaper agent
        debugLog("activation policy set")

        guard let device = MTLCreateSystemDefaultDevice() else {
            debugLog("no Metal device available, quitting.")
            NSApp.terminate(nil)
            return
        }
        debugLog("metal device: \(device.name)")

        windowController = WallpaperWindowController(device: device)
        debugLog("windowController created")
        killSwitchHotKey = GlobalHotKey.register(keyCode: 15 /* R */, modifiers: [.control, .option, .command]) {
            RainSettings.shared.effectsOff.toggle()
        }
        chromeBridge = ChromeBridge { [weak self] in
            MainActor.assumeIsolated { self?.windowController?.mainRainTime ?? 0 }
        }
        statusItemController = StatusItemController()
        debugLog("statusItemController created")

        if let mainScreen = NSScreen.main {
            let radioWindow = RadioWidgetWindow(screen: mainScreen)
            radioWindows.append(radioWindow)
            settingsButtonWindow = SettingsButtonWindow(screen: mainScreen, anchorFrame: radioWindow.frame)
        }
        debugLog("radio window + settings button created")

        nowPlaying.start { [weak self] info in
            guard let self else { return }
            for window in self.radioWindows {
                window.update(with: info)
            }
        }
        debugLog("applicationDidFinishLaunching end")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "rainydesktop" {
            switch (url.host, url.lastPathComponent) {
            case ("settings", _): statusItemController?.showSettings()
            case ("effects", "on"): RainSettings.shared.effectsOff = false
            case ("effects", "off"): RainSettings.shared.effectsOff = true
            case ("effects", "toggle"): RainSettings.shared.effectsOff.toggle()
            default: break
            }
        }
    }

    /// Launching Rainy again (Spotlight, Launchpad, Finder) while it's running
    /// opens settings -- the menu-bar icon can be hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItemController?.showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
