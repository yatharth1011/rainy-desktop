import AppKit

/// Picks a single representative, glow-friendly color out of an artwork
/// image: downsample, bucket by quantized RGB, score buckets by
/// `pixelCount * (0.4 + saturation)` (so a big flat background can't
/// out-rank a smaller but more vivid region), then floor the winner's
/// lightness/saturation so it never renders too dark or too washed out to
/// read as a glow color.
enum DominantColorExtractor {
    static let fallback = NSColor(calibratedRed: 1.0, green: 213.0 / 255.0, blue: 74.0 / 255.0, alpha: 1)

    static func extract(from image: NSImage) -> NSColor {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return fallback
        }

        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return fallback
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return fallback }

        struct Bucket { var count = 0; var r = 0; var g = 0; var b = 0 }
        var buckets: [Int32: Bucket] = [:]
        let quantum = 24

        for y in 0..<size {
            for x in 0..<size {
                let off = y * size * 4 + x * 4
                guard ptr[off + 3] >= 40 else { continue } // skip near-transparent pixels
                let r = Int(ptr[off]), g = Int(ptr[off + 1]), b = Int(ptr[off + 2])
                let qr = (r / quantum), qg = (g / quantum), qb = (b / quantum)
                let key = Int32((qr << 16) | (qg << 8) | qb)
                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1
                bucket.r += r; bucket.g += g; bucket.b += b
                buckets[key] = bucket
            }
        }
        guard !buckets.isEmpty else { return fallback }

        var bestScore = -1.0
        var bestColor = fallback
        for bucket in buckets.values {
            let n = Double(bucket.count)
            let avgR = CGFloat(Double(bucket.r) / n / 255.0)
            let avgG = CGFloat(Double(bucket.g) / n / 255.0)
            let avgB = CGFloat(Double(bucket.b) / n / 255.0)
            let color = NSColor(calibratedRed: avgR, green: avgG, blue: avgB, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            let score = n * (0.4 + Double(s))
            if score > bestScore {
                bestScore = score
                bestColor = color
            }
        }

        let (h, s, l) = hsl(of: bestColor)
        if l < 0.72 {
            return color(h: h, s: max(s, 0.6), l: 0.72)
        }
        return bestColor
    }

    private static func hsl(of color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        guard let c = color.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: CGFloat
        if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if maxV == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    private static func color(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        guard s > 0 else { return NSColor(calibratedRed: l, green: l, blue: l, alpha: 1) }
        func hue2rgb(_ p: CGFloat, _ q: CGFloat, _ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return NSColor(calibratedRed: hue2rgb(p, q, h + 1 / 3), green: hue2rgb(p, q, h),
                        blue: hue2rgb(p, q, h - 1 / 3), alpha: 1)
    }
}
