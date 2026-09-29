import AppKit
import SwiftUI

/// A small button that opens the settings popover, sitting at the same
/// desktop level as the wallpaper/radio windows -- visible when you're
/// looking at the desktop, covered by other apps like a desktop icon would
/// be, never floating on top of whatever you're working in.
///
/// This exists because NSStatusItem silently fails to register with the
/// system menu bar in this environment: AppKit reports the item as created
/// and visible, but the Accessibility API confirms zero actual registration
/// (`menu bar 2` doesn't exist for the process), and SystemUIServer's own
/// log shows it never even received a request -- across a plain build, a
/// SystemUIServer restart, and an ad-hoc code-signed build. Since ordinary
/// NSWindows work reliably here (the wallpaper and radio widget both prove
/// that), this is the dependable way to always have a way into settings,
/// independent of whatever is blocking the menu bar path.
final class SettingsButtonWindow: NSWindow, NSPopoverDelegate {
    private let popover = NSPopover()
    private let button = NSButton()

    /// `anchorFrame` is the radio widget's frame -- the button sits just
    /// above its top-right corner. The screen's literal corner was a bad
    /// spot: it's awkward to click precisely, and corners get special
    /// treatment (hot corners etc.) from the system.
    init(screen: NSScreen, anchorFrame: CGRect) {
        let size: CGFloat = 34
        let gap: CGFloat = 8
        let origin = CGPoint(x: anchorFrame.maxX - size, y: anchorFrame.maxY + gap)
        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false // unlike the wallpaper/radio windows, this one needs clicks
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // desktopIconWindow, not an offset from desktopWindow: that's the
        // *actual* level Finder's own clickable desktop icons use (it's a
        // distinct constant, ~20 above desktopWindow -- not "a bit above the
        // wallpaper"). WallpaperWindow/RadioWidgetWindow sit below this on
        // purpose (passive visual layers, ignoresMouseEvents=true); this
        // window needs real clicks, and that gap zone below the icon layer
        // doesn't reliably deliver them -- only this level does.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        isReleasedWhenClosed = false

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "cloud.rain.fill", accessibilityDescription: "Rainy Desktop Settings")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false

        button.frame = CGRect(origin: .zero, size: frame.size)
        button.image = image
        button.imagePosition = .imageOnly
        button.bezelStyle = .circular
        button.isBordered = true
        button.target = self
        button.action = #selector(toggleSettings)
        contentView = button

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SettingsView())
        popover.delegate = self

        orderFront(nil)
    }

    override var canBecomeKey: Bool { true }

    @objc private func toggleSettings() {
        debugLog("settings button clicked, popover.isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
