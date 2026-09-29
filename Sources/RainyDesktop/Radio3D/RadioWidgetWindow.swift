import AppKit
import SceneKit
import Combine

/// A small floating desktop widget: the 3D radio (spinning vinyl with the
/// album art as its label, artwork on its screen), a glowing dot-matrix
/// track name/artist, and a three-line lyrics ticker colored from the
/// artwork's dominant color. Hidden automatically whenever nothing is
/// playing, or when the user turns it off from the settings popover. Sits
/// at the same "wallpaper" window level as the rain layer -- part of the
/// desktop, not a foreground app.
final class RadioWidgetWindow: NSWindow {
    private let sceneNodes: RadioSceneBuilder.Nodes
    private let titleLabel = DotMatrixLabel()
    private let artistLabel = DotMatrixLabel()
    private let lyricsView = LyricsTickerView(frame: .zero)
    private let sceneView: SCNView
    /// Frosted dark glass behind everything, shown only while Rainy's effects
    /// are off: with no fogged rain behind the widget, the real wallpaper can
    /// be bright enough to swallow the text. The blur is the window server's
    /// own behind-window material (what the Dock and menus use), not ours --
    /// over a still desktop picture it's computed once and cached -- with a
    /// static smoke gradient on top for contrast.
    private let backdrop = NSVisualEffectView()

    private var latestInfo: NowPlayingInfo = .empty
    private var sortedLyricLines: [LyricLine] = []
    private var lastArtworkIdentity: NSImage?
    private var lyricTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Stacked bottom-up with explicit gaps so slot heights actually match
    // what each view needs. Kept as instance state (not locals in init) so
    // update(with:) can re-run the same math when lyrics availability changes.
    private let width: CGFloat = 220
    private let padding: CGFloat = 6
    private let lyricsHeight: CGFloat = 72
    private let artistHeight: CGFloat = 18
    private let titleHeight: CGFloat = 44
    private let sceneHeight: CGFloat = 118
    private let gapArtistLyrics: CGFloat = 4
    private let gapTitleArtist: CGFloat = 2
    private let gapTitleScene: CGFloat = 3

    init(screen: NSScreen) {
        // Compact and tucked into the bottom-right corner, just above the
        // Dock -- visibleFrame already excludes the Dock's reserved strip,
        // so a small margin here is what actually pulls it down to sit
        // right above it rather than floating higher up the screen.
        let height: CGFloat = 272
        let margin: CGFloat = 10
        let origin = CGPoint(x: screen.visibleFrame.maxX - width - margin,
                              y: screen.visibleFrame.minY + margin)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))

        sceneNodes = RadioSceneBuilder.build()

        let sceneY = height - sceneHeight
        let scnView = SCNView(frame: CGRect(x: 0, y: sceneY, width: width, height: sceneHeight))
        scnView.scene = sceneNodes.scene
        scnView.backgroundColor = .clear
        scnView.antialiasingMode = .multisampling4X
        scnView.isPlaying = true
        scnView.autoenablesDefaultLighting = false
        sceneView = scnView

        // See WallpaperWindow's init for why this uses the 4-arg designated
        // initializer instead of the "...screen:" convenience form.
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
        isReleasedWhenClosed = false

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        contentView = container

        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active // a desktop-level window is never "key"; keep the blur on regardless
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.maskImage = Self.roundedMask(radius: 22)
        let smoke = CAGradientLayer()
        smoke.frame = backdrop.bounds
        smoke.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        smoke.colors = [NSColor(white: 0, alpha: 0.5).cgColor, NSColor(white: 0, alpha: 0.28).cgColor]
        smoke.startPoint = CGPoint(x: 0.5, y: 0) // bottom (under the lyrics) darkest
        smoke.endPoint = CGPoint(x: 0.5, y: 1)
        // maskImage only clips the blur itself; the smoke layer on top needs
        // its own rounding or it paints square corners over the frosted card.
        smoke.cornerRadius = 22
        smoke.cornerCurve = .continuous
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 22
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.addSublayer(smoke)
        backdrop.alphaValue = 0
        container.addSubview(backdrop)
        container.addSubview(sceneView)

        artistLabel.fontSize = 10
        artistLabel.maxLines = 1
        container.addSubview(titleLabel)
        container.addSubview(artistLabel)
        container.addSubview(lyricsView)

        applyLayout(hasLyrics: true) // matches sceneY computed above for the initial frame

        orderOut(nil) // start hidden; shown once something is actually playing

        RainSettings.shared.$showRadioWidget
            .sink { [weak self] _ in self?.refreshVisibilityAndSpin() }
            .store(in: &cancellables)
        RainSettings.shared.$radioSpinSpeed
            .sink { [weak self] _ in self?.refreshVisibilityAndSpin() }
            .store(in: &cancellables)
        // Same battery reasoning as the wallpaper's MTKView: stop the 3D
        // view's render loop outright while paused instead of just leaving
        // it spinning/rendering in the background.
        RainSettings.shared.$isPaused
            .combineLatest(RainSettings.shared.$effectsOff)
            .sink { [weak self] paused, off in self?.sceneView.isPlaying = !(paused || off) }
            .store(in: &cancellables)
        RainSettings.shared.$effectsOff
            .sink { [weak self] off in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    self?.backdrop.animator().alphaValue = off ? 1 : 0
                }
            }
            .store(in: &cancellables)

        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, !RainSettings.shared.isPaused else { return }
            self.refreshLyrics()
        }
    }

    /// Stretchable rounded-rect mask (NSVisualEffectView ignores layer corner radii).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Positions title/artist/lyrics. When there's no lyric timeline at all,
    /// the lyrics slot collapses and title+artist drop down to sit centered
    /// in the space it would have used, instead of staying pinned near the
    /// scene with a dead gap left below them.
    private func applyLayout(hasLyrics: Bool) {
        let sceneY = frame.height - sceneHeight
        let lowerRegionTop = sceneY - gapTitleScene
        let lowerRegionBottom = padding
        let lowerRegionHeight = lowerRegionTop - lowerRegionBottom

        let titleY: CGFloat
        let artistY: CGFloat
        let lyricsAlpha: CGFloat

        if hasLyrics {
            let lyricsY = lowerRegionBottom
            artistY = lyricsY + lyricsHeight + gapArtistLyrics
            titleY = artistY + artistHeight + gapTitleArtist
            lyricsView.frame = CGRect(x: padding, y: lyricsY, width: width - padding * 2, height: lyricsHeight)
            lyricsAlpha = 1
        } else {
            let blockHeight = artistHeight + gapTitleArtist + titleHeight
            let blockBottom = lowerRegionBottom + (lowerRegionHeight - blockHeight) / 2
            artistY = blockBottom
            titleY = artistY + artistHeight + gapTitleArtist
            lyricsView.frame = CGRect(x: padding, y: lowerRegionBottom, width: width - padding * 2, height: 0)
            lyricsAlpha = 0
        }

        titleLabel.frame = CGRect(x: padding, y: titleY, width: width - padding * 2, height: titleHeight)
        artistLabel.frame = CGRect(x: padding, y: artistY, width: width - padding * 2, height: artistHeight)
        lyricsView.alphaValue = lyricsAlpha
    }

    func update(with info: NowPlayingInfo) {
        latestInfo = info
        sortedLyricLines = info.lyricLines.sorted { $0.timeMs < $1.timeMs }
        applyLayout(hasLyrics: info.isUsable && !sortedLyricLines.isEmpty)
        titleLabel.text = info.isUsable ? (info.title ?? "") : ""
        artistLabel.text = info.isUsable ? (info.artist ?? "") : ""
        RadioSceneBuilder.updateArtwork(sceneNodes, image: info.isUsable ? info.artwork : nil)
        updateGlowColor(for: info)
        refreshVisibilityAndSpin()
        refreshLyrics()
    }

    private func updateGlowColor(for info: NowPlayingInfo) {
        guard let artwork = info.artwork, artwork !== lastArtworkIdentity else {
            if info.artwork == nil {
                lastArtworkIdentity = nil
                titleLabel.dotColor = DominantColorExtractor.fallback
                artistLabel.dotColor = DominantColorExtractor.fallback
                lyricsView.glowColor = DominantColorExtractor.fallback
            }
            return
        }
        lastArtworkIdentity = artwork
        let color = DominantColorExtractor.extract(from: artwork)
        titleLabel.dotColor = color
        artistLabel.dotColor = color
        lyricsView.glowColor = color
    }

    private func refreshVisibilityAndSpin() {
        let shouldShow = latestInfo.isUsable && RainSettings.shared.showRadioWidget
        RadioSceneBuilder.setSpinning(sceneNodes, spinning: latestInfo.playing, speed: RainSettings.shared.radioSpinSpeed)

        if shouldShow, !isVisible {
            orderFront(nil)
        } else if !shouldShow, isVisible {
            orderOut(nil)
        }
    }

    /// Drives the ticker's active index from the full synced timeline and
    /// the locally-extrapolated playhead, rather than only the last polled
    /// line, so it stays in sync between Dromac polls instead of lagging.
    private func refreshLyrics() {
        guard latestInfo.isUsable, !sortedLyricLines.isEmpty else {
            lyricsView.update(lines: [], activeIndex: -1)
            return
        }
        let elapsed = latestInfo.liveElapsedMs
        var idx = -1
        for (i, line) in sortedLyricLines.enumerated() {
            guard line.timeMs <= elapsed else { break }
            idx = i
        }
        lyricsView.update(lines: sortedLyricLines.map { $0.text }, activeIndex: idx)
    }
}
