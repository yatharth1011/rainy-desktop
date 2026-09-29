import AppKit
import QuartzCore
import CoreImage

/// A three-line vertical lyrics ticker (prev / current / next), styled and
/// choreographed to a specific reference spec: perspective-tilted side
/// lines, a pulsing glow on the current line colored from the track's
/// artwork, permanent directional motion blur on the side lines and a
/// transient one on the current line during a transition, and a two-phase
/// exit-then-enter animation (never an instant text swap) gated strictly on
/// the active lyric index actually changing.
final class LyricsTickerView: NSView {
    private let perspectiveContainer = CALayer()
    private let prevLayer = CATextLayer()
    private let currentLayer = CATextLayer()
    private let nextLayer = CATextLayer()

    private var allLines: [String] = []
    private var activeIndex = -1
    private var hasDisplayedOnce = false

    private var exitTimer: Timer?
    private var enterTimer: Timer?
    private var blurClearTimer: Timer?

    var glowColor: NSColor = DominantColorExtractor.fallback {
        didSet { applyGlowColor() }
    }
    private let sideColor = NSColor(calibratedWhite: 0.55, alpha: 1)

    private let currentFont = monoFont(size: 10.5, weight: .bold)
    private let sideFont = monoFont(size: 8.5, weight: .medium)

    private static func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let base = NSFont(name: "JetBrains Mono", size: size) ?? NSFont(name: "JetBrainsMono-Regular", size: size) {
            if weight == .bold, let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) as NSFont? {
                return bold
            }
            return base
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 160.0
        perspectiveContainer.sublayerTransform = perspective
        perspectiveContainer.masksToBounds = false
        layer?.addSublayer(perspectiveContainer)

        for l in [prevLayer, currentLayer, nextLayer] {
            l.isWrapped = true
            l.alignmentMode = .center
            l.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            l.opacity = 0
            perspectiveContainer.addSublayer(l)
        }

        prevLayer.anchorPoint = CGPoint(x: 0.5, y: 0)   // pivots around its bottom edge
        nextLayer.anchorPoint = CGPoint(x: 0.5, y: 1)   // pivots around its top edge
        currentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        prevLayer.font = sideFont
        prevLayer.fontSize = sideFont.pointSize
        prevLayer.foregroundColor = sideColor.cgColor
        nextLayer.font = sideFont
        nextLayer.fontSize = sideFont.pointSize
        nextLayer.foregroundColor = sideColor.cgColor
        currentLayer.font = currentFont
        currentLayer.fontSize = currentFont.pointSize

        prevLayer.transform = CATransform3DMakeRotation(-28 * .pi / 180, 1, 0, 0)
        nextLayer.transform = CATransform3DMakeRotation(28 * .pi / 180, 1, 0, 0)
        prevLayer.filters = [Self.motionBlurFilter(radius: 1.1)]
        nextLayer.filters = [Self.motionBlurFilter(radius: 1.1)]

        applyGlowColor()
        startGlowPulse()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        perspectiveContainer.frame = bounds
        positionLayers()
    }

    /// Sizes each slot to what its *actual* text needs (measured, wrapped at
    /// this width) rather than a fixed generous height -- an empty or
    /// single-line neighbor collapses close to the current line instead of
    /// leaving a fixed gap sized for a line that isn't there.
    /// A few points of inset keeps kerning/anti-aliasing at the very edge of
    /// the widest glyphs from getting clipped by the container's own
    /// masksToBounds -- using the full view width with zero margin was
    /// cutting off leading/trailing characters.
    private let textInset: CGFloat = 6

    private func positionLayers() {
        let width = bounds.width - textInset * 2
        let midY = bounds.height / 2
        let gap: CGFloat = 3

        let currentText = (currentLayer.string as? String) ?? ""
        let prevText = (prevLayer.string as? String) ?? ""
        let nextText = (nextLayer.string as? String) ?? ""

        let currentHeight = max(measuredHeight(currentText, font: currentFont, width: width), currentFont.pointSize + 4)
        let prevHeight = prevText.isEmpty ? 0 : max(measuredHeight(prevText, font: sideFont, width: width), sideFont.pointSize + 3)
        let nextHeight = nextText.isEmpty ? 0 : max(measuredHeight(nextText, font: sideFont, width: width), sideFont.pointSize + 3)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer.frame = CGRect(x: textInset, y: midY - currentHeight / 2, width: width, height: currentHeight)
        // Normal reading order top-to-bottom: prev (already sung) above,
        // next (upcoming) below current, like a subtitle history ticker.
        let prevGap = prevHeight > 0 ? gap : 0
        let nextGap = nextHeight > 0 ? gap : 0
        prevLayer.frame = CGRect(x: textInset, y: currentLayer.frame.maxY + prevGap, width: width, height: prevHeight)
        nextLayer.frame = CGRect(x: textInset, y: currentLayer.frame.minY - nextGap - nextHeight, width: width, height: nextHeight)
        CATransaction.commit()
    }

    private func measuredHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        return ceil(rect.height)
    }

    private func applyGlowColor() {
        currentLayer.foregroundColor = glowColor.cgColor
    }

    /// A continuous, independent-of-transitions pulse between a dim and a
    /// bright glow, 1.8s ease-in-out, matching the reference's two-intensity
    /// text-shadow animation (approximated here as one animated layer shadow
    /// oscillating between the trough and peak intensities).
    private func startGlowPulse() {
        currentLayer.shadowColor = glowColor.cgColor
        currentLayer.shadowOffset = .zero
        currentLayer.shadowOpacity = 0.7
        currentLayer.shadowRadius = 8

        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 8
        radius.toValue = 16
        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = 0.7
        opacity.toValue = 1.0

        for anim in [radius, opacity] {
            anim.duration = 0.9
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        currentLayer.add(radius, forKey: "glowRadiusPulse")
        currentLayer.add(opacity, forKey: "glowOpacityPulse")
    }

    private static func motionBlurFilter(radius: Double) -> CIFilter {
        let filter = CIFilter(name: "CIMotionBlur") ?? CIFilter()
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(Double.pi / 2, forKey: "inputAngle") // vertical: blur along the scroll direction
        return filter
    }

    // MARK: - Driving

    /// `lines` is the full synced lyric timeline's text; `index` is which
    /// line is current right now. A transition only ever runs when `index`
    /// actually changes -- not on every call (position ticks far more often
    /// than the line does).
    func update(lines: [String], activeIndex index: Int) {
        allLines = lines
        guard index >= 0, index < lines.count else {
            if !allLines.isEmpty { return } // out of range mid-song: hold last state
            reset()
            return
        }
        guard index != activeIndex else { return }

        if !hasDisplayedOnce {
            hasDisplayedOnce = true
            activeIndex = index
            setTextImmediately()
            return
        }

        activeIndex = index
        runTransition()
    }

    private func reset() {
        hasDisplayedOnce = false
        activeIndex = -1
        allLines = []
        exitTimer?.invalidate(); enterTimer?.invalidate(); blurClearTimer?.invalidate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [prevLayer, currentLayer, nextLayer] { l.opacity = 0 }
        CATransaction.commit()
    }

    private func text(at index: Int) -> String {
        (index >= 0 && index < allLines.count) ? allLines[index] : ""
    }

    private func setTextImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        prevLayer.string = text(at: activeIndex - 1)
        currentLayer.string = text(at: activeIndex)
        nextLayer.string = text(at: activeIndex + 1)
        positionLayers()
        prevLayer.opacity = prevLayer.string as? String == "" ? 0 : 1
        currentLayer.opacity = 1
        nextLayer.opacity = nextLayer.string as? String == "" ? 0 : 1
        prevLayer.transform = CATransform3DMakeRotation(-28 * .pi / 180, 1, 0, 0)
        nextLayer.transform = CATransform3DMakeRotation(28 * .pi / 180, 1, 0, 0)
        currentLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Phase 1 (90ms, ease-in): all three lines fade/continue their motion
    /// as the about-to-be-replaced content leaves. Deliberately never fades
    /// the current line fully to 0 -- that read as "flash to black" rather
    /// than a leave.
    private func runTransition() {
        exitTimer?.invalidate(); enterTimer?.invalidate(); blurClearTimer?.invalidate()

        currentLayer.filters = [Self.motionBlurFilter(radius: 0.6)]

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))

        currentLayer.opacity = 0.45
        currentLayer.transform = CATransform3DMakeTranslation(0, 6, 0) // up, in this y-up layer space
            .concatenating(CATransform3DMakeScale(0.95, 0.95, 1))

        prevLayer.opacity = 0
        prevLayer.transform = CATransform3DMakeTranslation(0, 4, 0)
            .concatenating(CATransform3DMakeRotation(-40 * .pi / 180, 1, 0, 0))

        nextLayer.opacity = 0
        nextLayer.transform = CATransform3DMakeTranslation(0, -4, 0)
            .concatenating(CATransform3DMakeRotation(40 * .pi / 180, 1, 0, 0))

        CATransaction.commit()

        exitTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: false) { [weak self] _ in
            self?.swapTextAndEnter()
        }
    }

    /// Phase 2 (220ms, ease-out): text is swapped and each line's model
    /// values go straight to their resting pose, with an explicit
    /// CABasicAnimation supplying the "start of entrance" pose (further from
    /// rest than normal -- e.g. prev/next both start below their own rest
    /// position and rise up, current starts below and grows in) purely for
    /// the presentation layer to animate from.
    ///
    /// This deliberately avoids the more obvious "snap to the start pose in
    /// one transaction, then animate to rest in a second" approach: that
    /// snap is a real committed state, and macOS reliably renders one actual
    /// frame at that snapped pose before the second transaction's animation
    /// begins -- visible as a one-frame flicker on every line change.
    /// Explicit animations don't have that problem: `fromValue` only steers
    /// what's drawn, the model (and hence the very first rendered frame) is
    /// already at rest.
    private func swapTextAndEnter() {
        prevLayer.string = text(at: activeIndex - 1)
        currentLayer.string = text(at: activeIndex)
        nextLayer.string = text(at: activeIndex + 1)

        let prevHasText = !(text(at: activeIndex - 1).isEmpty)
        let nextHasText = !(text(at: activeIndex + 1).isEmpty)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionLayers()
        CATransaction.commit()

        let duration = 0.22
        let timing = CAMediaTimingFunction(name: .easeOut)

        func enter(_ layer: CALayer, fromTransform: CATransform3D, toTransform: CATransform3D, toOpacity: Float) {
            let transformAnim = CABasicAnimation(keyPath: "transform")
            transformAnim.fromValue = NSValue(caTransform3D: fromTransform)
            transformAnim.toValue = NSValue(caTransform3D: toTransform)
            transformAnim.duration = duration
            transformAnim.timingFunction = timing

            let opacityAnim = CABasicAnimation(keyPath: "opacity")
            opacityAnim.fromValue = 0.55
            opacityAnim.toValue = toOpacity
            opacityAnim.duration = duration
            opacityAnim.timingFunction = timing

            // Disable implicit actions for the direct property sets -- only
            // the explicit animations above should drive the visible
            // transition; an implicit action here would double up with them.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = toTransform
            layer.opacity = toOpacity
            CATransaction.commit()

            layer.add(transformAnim, forKey: "enterTransform")
            layer.add(opacityAnim, forKey: "enterOpacity")
        }

        enter(currentLayer,
              fromTransform: CATransform3DMakeTranslation(0, -8, 0).concatenating(CATransform3DMakeScale(0.96, 0.96, 1)),
              toTransform: CATransform3DIdentity, toOpacity: 1)

        enter(prevLayer,
              fromTransform: CATransform3DMakeTranslation(0, -6, 0).concatenating(CATransform3DMakeRotation(-45 * .pi / 180, 1, 0, 0)),
              toTransform: CATransform3DMakeRotation(-28 * .pi / 180, 1, 0, 0), toOpacity: prevHasText ? 1 : 0)

        enter(nextLayer,
              fromTransform: CATransform3DMakeTranslation(0, 6, 0).concatenating(CATransform3DMakeRotation(45 * .pi / 180, 1, 0, 0)),
              toTransform: CATransform3DMakeRotation(28 * .pi / 180, 1, 0, 0), toOpacity: nextHasText ? 1 : 0)

        blurClearTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            self?.currentLayer.filters = nil
        }
    }
}

private extension CATransform3D {
    func concatenating(_ other: CATransform3D) -> CATransform3D {
        CATransform3DConcat(self, other)
    }
}
