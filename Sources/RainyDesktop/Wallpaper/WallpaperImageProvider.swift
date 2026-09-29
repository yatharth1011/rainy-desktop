import AppKit
import MetalKit

/// Reads the user's actual current desktop picture for a given screen, so the
/// rain effect is layered on top of their real wallpaper rather than a stand-in.
enum WallpaperImageProvider {
    static func currentImage(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cgImage
    }

    /// Changes whenever the screen's desktop picture does (a different file,
    /// or the same file rewritten in place) -- cheap enough to poll.
    static func signature(for screen: NSScreen) -> String {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return "" }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    /// A soft gradient used only if the real desktop picture can't be read
    /// (e.g. a dynamic/slideshow wallpaper macOS won't hand back a static file for).
    static func fallbackImage(size: CGSize) -> CGImage {
        let width = max(Int(size.width), 2)
        let height = max(Int(size.height), 2)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.07, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height),
                                    options: [])
        return context.makeImage()!
    }

    /// SRGB: true so Metal gamma-decodes on sample -- the source image's
    /// bytes are gamma-encoded, and this pipeline composites in linear light
    /// (EDR drawable), so skipping the decode washes out the result.
    static func loadTexture(loader: MTKTextureLoader, screen: NSScreen) -> MTLTexture? {
        let cgImage = currentImage(for: screen) ?? fallbackImage(size: screen.frame.size)
        return try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: true,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue
        ])
    }
}
