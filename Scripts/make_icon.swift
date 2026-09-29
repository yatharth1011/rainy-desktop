// Renders the app icon with the app's *own* rain shader: a dark crimson /
// ember backdrop, fogged by the same gaussian pyramid the wallpaper uses,
// with the Heartfelt drops refracting through it -- so the icon is literally
// a frame of the wallpaper, clipped to a macOS squircle.
// Run: swift Scripts/make_icon.swift && iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns && rm -r Assets/AppIcon.iconset
import AppKit
import Metal

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let shaders = "Sources/RainyDesktop/Rendering/Shaders/"

// Mirrors Rendering/SimTypes.swift / Shaders/RainTypes.h.
struct RainUniforms {
    var resolution: SIMD2<Float>; var time: Float
    var rainIntensity: Float; var rainSpeed: Float
    var staticDropDensity: Float; var layer1Density: Float; var layer2Density: Float
    var fogMinBlur: Float; var fogMaxBlurLow: Float; var fogMaxBlurHigh: Float; var refractionStrength: Float
    var lightningBoost: Float; var lightningSpeed: Float; var lightningSharpness: Float
    var colorGradeStrength: Float; var vignetteStrength: Float; var brightness: Float
    var zoomAmount: Float; var zoomSpeed: Float
    var dimAmount: Float; var dropZoomOut: Float
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}

// --- Backdrop: near-black with a low crimson/ember glow, like the wallpaper ---
let bg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                   space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bg.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [rgb(0x050203), rgb(0x1A0405), rgb(0x3A0808)] as CFArray,
                                 locations: [0, 0.55, 1])!,
                      start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
for (x, y, r, c, a) in [(330.0, 260.0, 420.0, 0xB3140F, 0.75), (760.0, 420.0, 300.0, 0xE0401C, 0.55),
                        (560.0, 120.0, 260.0, 0xFF8A2A, 0.45), (180.0, 640.0, 220.0, 0x7A0A0C, 0.5),
                        (820.0, 820.0, 180.0, 0x5A0708, 0.4)] as [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] {
    bg.drawRadialGradient(CGGradient(colorsSpace: cs, colors: [rgb(c, a), rgb(c, 0)] as CFArray, locations: [0, 1])!,
                          startCenter: CGPoint(x: x, y: y), startRadius: 0,
                          endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}
// Thin warm streaks of light (distant signage) that the drops can refract.
for (x, w, c) in [(240.0, 10.0, 0xFF6A2A), (470.0, 6.0, 0xFFB050), (700.0, 12.0, 0xE02A20), (880.0, 5.0, 0xFF9A40)]
    as [(CGFloat, CGFloat, UInt32)] {
    bg.setFillColor(rgb(c, 0.55)); bg.fill(CGRect(x: x, y: 60, width: w, height: 380))
}

// --- Metal: same pipeline as RainRenderer ---
let dev = MTLCreateSystemDefaultDevice()!
let src = try String(contentsOfFile: shaders + "RainTypes.h") + "\n"
    + String(contentsOfFile: shaders + "RenderShaders.metal").replacingOccurrences(of: "#include \"RainTypes.h\"", with: "")
let lib = try dev.makeLibrary(source: src, options: nil)
func pipe(_ f: String) throws -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = lib.makeFunction(name: "fullscreenVertex")
    d.fragmentFunction = lib.makeFunction(name: f)
    d.colorAttachments[0].pixelFormat = .rgba16Float
    return try dev.makeRenderPipelineState(descriptor: d)
}
let queue = dev.makeCommandQueue()!
func tex(_ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .renderTarget]; d.storageMode = .shared
    return dev.makeTexture(descriptor: d)!
}
func run(_ p: MTLRenderPipelineState, _ s: [MTLTexture], _ t: MTLTexture, bytes: UnsafeRawPointer? = nil, len: Int = 0) {
    let cmd = queue.makeCommandBuffer()!
    let pd = MTLRenderPassDescriptor()
    pd.colorAttachments[0].texture = t; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
    let e = cmd.makeRenderCommandEncoder(descriptor: pd)!
    e.setRenderPipelineState(p)
    for (i, x) in s.enumerated() { e.setFragmentTexture(x, index: i) }
    if let bytes { e.setFragmentBytes(bytes, length: len, index: 0) }
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
    cmd.commit(); cmd.waitUntilCompleted()
}

// Upload backdrop (sRGB bytes -> sRGB texture -> linear via passthrough, like the app).
// CGContext memory rows are top-down, matching Metal's texture origin.
let rawDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: false)
let raw = dev.makeTexture(descriptor: rawDesc)!
raw.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bg.data!, bytesPerRow: size * 4)
let copy = try pipe("passthroughFragment")
let sharp = tex(size, size); run(copy, [raw], sharp)

// Fog: a pyramid level + three compounded gaussian passes (see RainRenderer.encodeBlur).
let sigma: Float = 44
var level = sharp
while Float(level.width / 2) * sigma / Float(size) >= 2.5 {
    let l = tex(level.width / 2, level.height / 2); run(copy, [level], l); level = l
}
let blur = tex(level.width, level.height), ping = tex(level.width, level.height)
var step = sigma * Float(level.width) / Float(size) / (2 * Float(3).squareRoot())
let bh = try pipe("blurHorizontalFragment"), bv = try pipe("blurVerticalFragment")
for i in 0..<3 { run(bh, [i == 0 ? level : blur], ping, bytes: &step, len: 4); run(bv, [ping], blur, bytes: &step, len: 4) }

// Rain frame. Big drops (dropZoomOut < 1) so they still read at small
// sizes; no lightning/colour cycling; heavy fog so drops and trails pop.
let time = Float(CommandLine.arguments.dropFirst().first.flatMap(Float.init) ?? 23.1)
var u = RainUniforms(resolution: SIMD2(Float(size), Float(size)), time: time,
                     rainIntensity: 0.85, rainSpeed: 1, staticDropDensity: 1.1, layer1Density: 1.2, layer2Density: 1.2,
                     fogMinBlur: 1, fogMaxBlurLow: 5, fogMaxBlurHigh: 6, refractionStrength: 1.4,
                     lightningBoost: 0, lightningSpeed: 1, lightningSharpness: 10,
                     colorGradeStrength: 0, vignetteStrength: 1.1, brightness: 1.35,
                     zoomAmount: 0, zoomSpeed: 0, dimAmount: 0, dropZoomOut: Float(ProcessInfo.processInfo.environment["ZOOM"] ?? "0.85")!)
let frame = tex(size, size)
run(try pipe("heartfeltRainFragment"), [sharp, blur], frame, bytes: &u, len: MemoryLayout<RainUniforms>.stride)

// Read back (linear half floats) -> sRGB CGImage.
var half = [Float16](repeating: 0, count: size * size * 4)
frame.getBytes(&half, bytesPerRow: size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
var px = [UInt8](repeating: 255, count: size * size * 4)
func encode(_ l: Float) -> UInt8 {
    let v = max(0, min(1, l))
    return UInt8((v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
}
for i in 0..<(size * size) { for c in 0..<3 { px[i * 4 + c] = encode(Float(half[i * 4 + c])) } }
let rainImage = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!

// --- Compose into the macOS icon tile ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: rgb(0x000000, 0.5))
out.addPath(tilePath); out.setFillColor(rgb(0x050203)); out.fillPath()
out.restoreGState()
out.saveGState()
out.addPath(tilePath); out.clip()
out.draw(rainImage, in: tile.insetBy(dx: -40, dy: -40)) // crop past the vignette's darkest corners
out.restoreGState()
out.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
out.setStrokeColor(rgb(0xFF8A5A, 0.16)); out.setLineWidth(3); out.strokePath()
let master = out.makeImage()!

// --- Write iconset ---
let iconset = URL(fileURLWithPath: "Assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func writePNG(px: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
}
for pt in [16, 32, 128, 256, 512] {
    try writePNG(px: pt, to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try writePNG(px: pt * 2, to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try writePNG(px: 1024, to: URL(fileURLWithPath: "Assets/AppIcon.png"))
print("Wrote \(iconset.path)")
