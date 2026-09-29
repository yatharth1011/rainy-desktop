import AppKit
import MetalKit
import Combine

/// One borderless, click-through window per screen, pinned just above the real
/// desktop background layer (and below desktop icons) so it behaves like a
/// wallpaper replacement rather than a floating window.
final class WallpaperWindow: NSWindow {
    let metalView: MTKView
    let renderer: RainRenderer
    private var cancellables = Set<AnyCancellable>()

    init?(screen: NSScreen, device: MTLDevice) {
        let builtRenderer: RainRenderer
        do {
            builtRenderer = try RainRenderer(device: device, screen: screen)
        } catch {
            NSLog("RainyDesktop: failed to create renderer for screen \(screen.localizedName): \(error)")
            return nil
        }
        self.renderer = builtRenderer

        let view = MTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = .rgba16Float
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        self.metalView = view

        // NSWindow's true designated initializer is the 4-arg form; the
        // "...screen:" variant is a convenience wrapper that AppKit's own
        // internals sometimes bypass (e.g. when lazily creating an auxiliary
        // backing window), which traps on a subclass that only overrides the
        // 5-arg form. `contentRect` is already in global screen coordinates
        // (from `screen.frame`), so no `screen:` argument is needed for
        // correct placement.
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        isReleasedWhenClosed = false

        contentView = view
        view.delegate = renderer

        configureEDR()
        setFrame(screen.frame, display: true)
        orderFront(nil)

        // Pause should actually save battery, not just freeze the shader's
        // clock while still rendering 60 identical frames a second -- stop
        // MTKView's internal draw loop outright, the same as if the whole
        // app weren't running.
        RainSettings.shared.$isPaused
            .combineLatest(RainSettings.shared.$effectsOff)
            .sink { [weak self, weak view] paused, off in
                view?.isPaused = paused || off
                // Effects off: get out of the way entirely, so the real desktop
                // picture shows and the compositor has nothing of ours to draw.
                if off { self?.orderOut(nil) } else { self?.orderFront(nil) }
            }
            .store(in: &cancellables)
    }

    /// Opts the backing CAMetalLayer into Extended Dynamic Range so lightning
    /// flashes with color values above 1.0 actually read as true HDR overbright
    /// on capable displays, instead of being clamped to reference white.
    private func configureEDR() {
        guard let layer = metalView.layer as? CAMetalLayer else { return }
        layer.wantsExtendedDynamicRangeContent = true
        if let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            layer.colorspace = cs
        }
        metalView.colorspace = layer.colorspace
    }

    func updateFrame(for screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
