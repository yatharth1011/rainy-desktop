import AppKit
import CoreImage
import Network
import Combine

/// Feeds the "Rainy Tab" Chrome extension (ChromeExtension/RainyTab) and
/// keeps a generated Chrome theme in sync with the desktop picture.
///
/// - A tiny HTTP server on 127.0.0.1:47823 serves `/state.json` (rain
///   settings + the desktop's rain clock + a wallpaper version) and
///   `/wallpaper.jpg`. Only loopback, only requests whose Host header is the
///   loopback address (defeats DNS rebinding), and no CORS headers -- so web
///   pages can't read it; the extension can via its host permission.
/// - On every wallpaper change it regenerates an unpacked theme in
///   ~/Library/Application Support/RainyDesktop/ChromeTheme: the wallpaper's
///   top strip, fogged and darkened, as the tab strip/toolbar images, with
///   neutral light-on-dark text colors so it works with any wallpaper.
@MainActor
final class ChromeBridge {
    static let port: UInt16 = 47823
    static let themeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RainyDesktop/ChromeTheme")

    private let rainTime: () -> Float
    private var listener: NWListener?
    private var pollTimer: Timer?
    private var signature = ""
    private var version = 0
    private var wallpaperJPEG = Data()
    private var wallpaperImage: CGImage?
    private var themeSettingsSub: AnyCancellable?

    init(rainTime: @escaping () -> Float) {
        self.rainTime = rainTime
        refreshWallpaper()
        startServer()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWallpaper() }
        }
        pollTimer?.tolerance = 1
        // Re-render the theme when any of its sliders settles.
        let s = RainSettings.shared
        let themeInputs = [s.$chromeDim, s.$chromeThemeDarkness, s.$chromeToolbarDarkness, s.$chromeOmniboxDarkness,
                           s.$chromeThemeFrost, s.$chromeThemeSaturation]
        themeSettingsSub = Publishers.MergeMany(themeInputs.map { $0.dropFirst().map { _ in () }.eraseToAnyPublisher() }
                                                + [s.$chromeOmniboxBlack.dropFirst().map { _ in () }.eraseToAnyPublisher()])
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.regenerateTheme() } }
    }

    private func regenerateTheme() {
        guard let image = wallpaperImage, let screen = NSScreen.main else { return }
        version += 1 // tells the extension to re-apply the theme
        try? writeTheme(from: image, screen: screen)
    }

    // MARK: Wallpaper + theme

    private func refreshWallpaper() {
        guard let screen = NSScreen.main else { return }
        let current = WallpaperImageProvider.signature(for: screen)
        guard current != signature else { return }
        signature = current
        let image = WallpaperImageProvider.currentImage(for: screen)
            ?? WallpaperImageProvider.fallbackImage(size: screen.frame.size)
        wallpaperImage = image
        wallpaperJPEG = Self.jpeg(image, maxWidth: 3840, quality: 0.9) ?? Data()
        version = Int(Date().timeIntervalSince1970)
        do {
            try writeTheme(from: image, screen: screen)
        } catch {
            debugLog("ChromeBridge: theme write failed: \(error)")
        }
    }

    private func writeTheme(from image: CGImage, screen: NSScreen) throws {
        let dir = Self.themeDirectory
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)

        // The wallpaper as Rainy draws it: stretched to the screen, then the
        // strip behind a window's tab strip + toolbar at the top of the screen.
        let width = Int(screen.frame.width), height = Int(screen.frame.height)
        let stripHeight = 260
        let ci = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / CGFloat(image.width),
                                               y: CGFloat(height) / CGFloat(image.height)))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(RainSettings.shared.chromeThemeFrost, 0))) // frosted, like Mission Control's bar
        let context = CIContext()
        func strip(yOffset: Int, darken: CGFloat) -> CGImage? {
            let rect = CGRect(x: 0, y: CGFloat(height - yOffset - stripHeight), width: CGFloat(width), height: CGFloat(stripHeight))
            // A multiply (smoked glass), not a brightness offset -- an offset
            // crushes the darks and clips the highlights.
            let k = 1 - darken
            let tinted = ci.cropped(to: rect)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: RainSettings.shared.chromeThemeSaturation])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                ])
            return context.createCGImage(tinted, from: rect)
        }
        // Frame (tab strip) is darker so inactive tab titles stay legible; the
        // toolbar strip starts ~40pt down, roughly where Chrome's toolbar sits.
        // Each part's own darkness, stacked with the Chrome-wide wallpaper dim.
        let s = RainSettings.shared
        func stacked(_ own: Float) -> CGFloat {
            let clamp = { (v: Float) in CGFloat(min(max(v, 0), 0.95)) }
            return 1 - (1 - clamp(own)) * (1 - clamp(s.chromeDim))
        }
        guard let frame = strip(yOffset: 0, darken: stacked(s.chromeThemeDarkness)),
              let toolbar = strip(yOffset: 40, darken: stacked(s.chromeToolbarDarkness)) else { return }
        try Self.png(frame).write(to: dir.appendingPathComponent("images/frame.png"))
        try Self.png(toolbar).write(to: dir.appendingPathComponent("images/toolbar.png"))

        // Address bar: the toolbar strip's average colour, darkened further so
        // it sits as a smoky well in the toolbar and its text stays readable.
        let omnibox = s.chromeOmniboxBlack ? [0, 0, 0] : Self.averageColor(of: toolbar).map { c -> [Int] in
            let k = 1 - CGFloat(min(max(s.chromeOmniboxDarkness, 0), 0.95))
            return c.map { Int(($0 * k * 255).rounded()) }
        } ?? [14, 14, 17]
        let omniboxBase = s.chromeOmniboxBlack ? [0, 0, 0] : omnibox

        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Rainy Theme",
            "version": "1.0.\(version % 65535)",
            "description": "Generated by Rainy Desktop from your current wallpaper.",
            "theme": [
                "images": [
                    "theme_frame": "images/frame.png",
                    "theme_frame_inactive": "images/frame.png",
                    "theme_toolbar": "images/toolbar.png",
                    "theme_tab_background": "images/frame.png",
                ],
                // Neutral light-on-dark text works over any (fogged, darkened) wallpaper.
                "colors": [
                    "frame": [18, 18, 20],
                    "frame_inactive": [18, 18, 20],
                    // Hidden under the toolbar image, but Chrome 154 derives the
                    // address bar from it and ignores "omnibox_background" -- so
                    // this is what actually sets how dark the address bar gets.
                    "toolbar": omniboxBase,
                    "tab_text": [215, 215, 220],
                    "tab_background_text": [165, 165, 172],
                    "tab_background_text_inactive": [135, 135, 142],
                    "bookmark_text": [190, 190, 196],
                    "toolbar_button_icon": [185, 185, 192],
                    "toolbar_text": [200, 200, 206],
                    "omnibox_background": omnibox,
                    "omnibox_text": [210, 210, 216],
                    "ntp_background": [8, 8, 10],
                    "ntp_text": [200, 200, 206],
                ],
                "properties": ["ntp_background_alignment": "center"],
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: dir.appendingPathComponent("manifest.json"))
        // Chrome caches a compiled theme next to the images; drop it so the
        // next theme load re-reads the new images from disk.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("Cached Theme.pak"))
    }

    // MARK: HTTP

    private func startServer() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            debugLog("ChromeBridge: could not listen on \(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                MainActor.assumeIsolated {
                    guard let self, let data, let request = String(data: data, encoding: .utf8) else { conn.cancel(); return }
                    self.respond(to: request, on: conn)
                }
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { debugLog("ChromeBridge: listener failed: \(error)") }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func respond(to request: String, on conn: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst(5).trimmingCharacters(in: .whitespaces) ?? ""
        let allowedHosts = ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"]

        var status = "404 Not Found", type = "text/plain", body = Data("not found".utf8)
        if parts.count >= 2, parts[0] == "GET", allowedHosts.contains(host) {
            let path = parts[1].split(separator: "?").first.map(String.init) ?? ""
            switch path {
            case "/state.json":
                status = "200 OK"; type = "application/json"; body = stateJSON()
            case "/wallpaper.jpg":
                status = "200 OK"; type = "image/jpeg"; body = wallpaperJPEG
            default: break
            }
        } else if !allowedHosts.contains(host) {
            status = "403 Forbidden"; body = Data("forbidden".utf8)
        }
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func stateJSON() -> Data {
        let s = RainSettings.shared
        let state: [String: Any] = [
            "version": version,
            "time": rainTime(),
            "paused": s.isPaused,
            "effectsOff": s.effectsOff,
            "settings": [
                "rainIntensity": s.rainIntensity, "rainSpeed": s.rainSpeed,
                "staticDropDensity": s.staticDropDensity, "layer1Density": s.layer1Density,
                "layer2Density": s.layer2Density, "fogMinBlur": s.fogMinBlur,
                "fogMaxBlurLow": s.fogMaxBlurLow, "fogMaxBlurHigh": s.fogMaxBlurHigh,
                "refractionStrength": s.refractionStrength, "lightningBoost": s.lightningBoost,
                "lightningSpeed": s.lightningSpeed, "lightningSharpness": s.lightningSharpness,
                "colorGradeStrength": s.colorGradeStrength, "vignetteStrength": s.vignetteStrength,
                "brightness": s.brightness, "zoomAmount": s.zoomAmount, "zoomSpeed": s.zoomSpeed,
                "dimAmount": s.dimAmount, "dropZoomOut": s.dropZoomOut, "chromeDim": s.chromeDim,
                "effectsOff": s.effectsOff ? 1 : 0,
            ] as [String: Float],
        ]
        return (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    }

    // MARK: Encoding

    private static func jpeg(_ image: CGImage, maxWidth: Int, quality: CGFloat) -> Data? {
        let scale = min(1, CGFloat(maxWidth) / CGFloat(image.width))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Mean sRGB colour of an image, components 0...1.
    private static func averageColor(of image: CGImage) -> [CGFloat]? {
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return (0..<3).map { c in
            CGFloat(stride(from: c, to: px.count, by: 4).reduce(0) { $0 + Int(px[$1]) }) / CGFloat(n * n * 255)
        }
    }

    private static func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}
