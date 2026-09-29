import AppKit

/// Renders `text` as a glowing LED dot-matrix readout: the string is drawn
/// into a supersampled offscreen bitmap once, then resampled onto a fine
/// grid of dots -- an actual dot-matrix look, not just a monospace font with
/// a shadow. Wraps across multiple stacked lines (rather than clipping) when
/// the text is wider than the view.
final class DotMatrixLabel: NSView {
    var text: String = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }
    var dotColor: NSColor = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.16, alpha: 1) {
        didSet { needsDisplay = true }
    }
    var fontSize: CGFloat = 16 {
        didSet { needsDisplay = true }
    }
    var maxLines: Int = 2

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: (fontSize + 6) * CGFloat(maxLines)) }

    // Supersampled higher than the dot pitch needs on its own so the finer
    // grain below still samples clean anti-aliased coverage rather than
    // getting blocky.
    private let supersample: CGFloat = 5
    // A real LED dot-matrix character is at least a 5x7-ish dot grid. A
    // tighter pitch than font-size alone would suggest, with small distinct
    // dots (radius well under half the pitch), is what actually reads as
    // "granular dot matrix" rather than either fused blobs or a font with a
    // shadow -- both extremes were tried and rejected before this.
    private let dotPitch: CGFloat = 1.05
    private let dotRadius: CGFloat = 0.4
    private let lineGap: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let outCtx = NSGraphicsContext.current?.cgContext else { return }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: 2.2]
        let lines = wrappedLines(for: text.uppercased(), attrs: attrs, maxWidth: bounds.width - 6)
        guard !lines.isEmpty else { return }

        var glyphBitmaps: [(ctx: CGContext, w: Int, h: Int)] = []
        for line in lines {
            if let bitmap = renderGlyphBitmap(line, attrs: attrs) {
                glyphBitmaps.append(bitmap)
            }
        }
        guard !glyphBitmaps.isEmpty else { return }

        let totalHeight = glyphBitmaps.reduce(CGFloat(0)) { $0 + CGFloat($1.h) } + lineGap * CGFloat(glyphBitmaps.count - 1)
        var cursorY = max((bounds.height - totalHeight) / 2, 0)

        outCtx.saveGState()
        // One glow around the whole composited word, not one shadow per dot
        // -- with dots only ~2.4pt apart, per-dot shadows compound into a
        // single blurred blob that erases the letterforms entirely.
        outCtx.setShadow(offset: .zero, blur: 2.4, color: dotColor.withAlphaComponent(0.85).cgColor)
        outCtx.beginTransparencyLayer(auxiliaryInfo: nil)
        dotColor.setFill()

        for bitmap in glyphBitmaps {
            let originX = (bounds.width - CGFloat(bitmap.w)) / 2
            drawDots(from: bitmap.ctx, w: bitmap.w, h: bitmap.h, originX: originX, originY: cursorY, into: outCtx)
            cursorY += CGFloat(bitmap.h) + lineGap
        }

        outCtx.endTransparencyLayer()
        outCtx.restoreGState()
    }

    private func wrappedLines(for text: String, attrs: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            let width = (candidate as NSString).size(withAttributes: attrs).width
            if width > maxWidth, !current.isEmpty {
                lines.append(current)
                current = word
                if lines.count == maxLines { break }
            } else {
                current = candidate
            }
        }
        if lines.count < maxLines, !current.isEmpty {
            lines.append(current)
        }
        return Array(lines.prefix(maxLines))
    }

    /// Draws `text` into a supersampled offscreen bitmap (CG's native,
    /// un-flipped, bottom-left origin -- the row index is flipped during
    /// sampling in `drawDots`, not the context itself).
    private func renderGlyphBitmap(_ text: String, attrs: [NSAttributedString.Key: Any]) -> (CGContext, Int, Int)? {
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrString.size()
        let w = max(Int(ceil(textSize.width)) + 6, 1)
        let h = max(Int(ceil(textSize.height)) + 6, 1)

        guard let bmp = CGContext(data: nil, width: Int(CGFloat(w) * supersample), height: Int(CGFloat(h) * supersample),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bmp.scaleBy(x: supersample, y: supersample)
        let nsCtx = NSGraphicsContext(cgContext: bmp, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        attrString.draw(at: CGPoint(x: 3, y: 3))
        NSGraphicsContext.restoreGraphicsState()
        return (bmp, w, h)
    }

    private func drawDots(from bmp: CGContext, w: Int, h: Int, originX: CGFloat, originY: CGFloat, into outCtx: CGContext) {
        guard let ptr = bmp.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let bytesPerRow = bmp.bytesPerRow
        let bytesPerPixel = 4
        let pw = bmp.width, ph = bmp.height
        let stepPx = max(Int(dotPitch * supersample), 1)

        var py = 0
        while py < ph {
            // bmp row 0 is already the TOP of the drawn glyph: CGBitmapContext
            // memory row 0 corresponds to the high end of CG's own bottom-up
            // drawing coordinate (where the text was drawn "upward" from),
            // which is exactly what a normal top-left-origin read expects --
            // no inversion needed. The previous version flipped this
            // unnecessarily, which rendered every glyph upside down (still in
            // left-to-right word order, since only Y was touched) -- that's
            // exactly what made "W" read as "M", "L" as a backwards "F", etc.
            let viewY = originY + CGFloat(py) / supersample
            var px = 0
            while px < pw {
                let offset = py * bytesPerRow + px * bytesPerPixel
                if ptr[offset + 3] > 110 {
                    let cx = originX + CGFloat(px) / supersample
                    let dotRect = CGRect(x: cx - dotRadius, y: viewY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    outCtx.fillEllipse(in: dotRect)
                }
                px += stepPx
            }
            py += stepPx
        }
    }
}
