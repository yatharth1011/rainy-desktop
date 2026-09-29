import AppKit
import Metal

/// Keeps one WallpaperWindow per connected screen alive, rebuilding the set
/// whenever displays are added/removed/resized, and reloading each renderer's
/// wallpaper texture whenever the user changes their desktop picture.
final class WallpaperWindowController {
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private let device: MTLDevice
    /// Last-seen desktop picture (path + modification date) per display.
    private var wallpaperSignatures: [CGDirectDisplayID: String] = [:]
    private var wallpaperPollTimer: Timer?

    init?(device: MTLDevice) {
        self.device = device
        rebuildWindows()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                                 name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(desktopPictureChanged),
                                                              name: NSNotification.Name("com.apple.desktop"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(desktopPictureChanged),
                                                            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Modern macOS changes wallpapers through WallpaperAgent and no longer
        // reliably posts "com.apple.desktop", so also poll the (cheap) current
        // desktop image URL and reload only the screens whose picture changed.
        wallpaperPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.desktopPictureChanged()
        }
        wallpaperPollTimer?.tolerance = 1
        desktopPictureChanged()
    }

    private func rebuildWindows() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            seen.insert(displayID)

            if let existing = windows[displayID] {
                existing.updateFrame(for: screen)
            } else if let window = WallpaperWindow(screen: screen, device: device) {
                windows[displayID] = window
            }
        }
        for (id, window) in windows where !seen.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
    }

    /// The main screen's rain clock, so other surfaces (the Chrome New Tab
    /// page) can render drops in lockstep with the desktop behind them.
    var mainRainTime: Float {
        guard let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let window = windows[CGDirectDisplayID(number.uint32Value)] ?? windows.values.first else { return 0 }
        return window.renderer.time
    }

    @objc private func screensChanged() {
        rebuildWindows()
    }

    @objc private func desktopPictureChanged() {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let window = windows[CGDirectDisplayID(number.uint32Value)] else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let signature = WallpaperImageProvider.signature(for: screen)
            if wallpaperSignatures[displayID] == nil {
                wallpaperSignatures[displayID] = signature // renderer loaded this one at init
            } else if wallpaperSignatures[displayID] != signature {
                wallpaperSignatures[displayID] = signature
                window.renderer.reloadWallpaper()
            }
        }
    }
}
