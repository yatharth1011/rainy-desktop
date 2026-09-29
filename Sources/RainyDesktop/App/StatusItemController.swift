import AppKit
import SwiftUI

/// The one visible piece of UI this app has: a menu-bar icon that opens a
/// popover with every rain/lightning/radio control. Everything else about
/// the app is a click-through desktop layer with no windows of its own.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        debugLog("status item created, isVisible=\(statusItem.isVisible), length=\(statusItem.length), button=\(String(describing: statusItem.button))")

        if let button = statusItem.button {
            // A plain SF Symbol image in a status item can render at an
            // unpredictable/near-invisible size without an explicit symbol
            // configuration and isTemplate; pin both so it always shows up
            // (and falls back to an emoji glyph in the unlikely case the
            // symbol itself fails to load at all).
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let image = NSImage(systemSymbolName: "cloud.rain.fill", accessibilityDescription: "Rainy Desktop")?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🌧"
            }
            button.action = #selector(togglePopover)
            button.target = self
            debugLog("status item button configured, frame=\(button.frame), image=\(String(describing: button.image)), title=\(button.title)")
        } else {
            debugLog("status item has NO button")
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SettingsView())
        popover.delegate = self
    }

    private var settingsWindow: NSWindow?

    /// Opens settings in a standalone window (used by the rainydesktop://settings
    /// URL, e.g. the gear on Chrome's Rainy Tab page). Not the popover: the
    /// status item can be hidden behind the notch on a crowded menu bar,
    /// leaving a popover nothing visible to anchor to.
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Rainy Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 360, height: 640))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
