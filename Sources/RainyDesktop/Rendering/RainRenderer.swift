import MetalKit
import simd
import AppKit

/// Draws one screen's rain layer using the ported "Heartfelt" shader (see
/// Rendering/Shaders/RenderShaders.metal for attribution/license) -- a single
/// fullscreen fragment shader that procedurally computes the whole rain field
/// (static condensation, two layers of sliding drops with trails) per pixel,
/// blending between the sharp wallpaper and a precomputed, genuinely smooth
/// blurred copy of it for its fog-based focus effect.
///
/// Texture pipeline, deliberately simple: the wallpaper image loads as an
/// sRGB-format texture (`rawWallpaper`), converted *once* via a render-pass
/// copy into a plain linear `rgba16Float` texture (`sharpWallpaper`). Every
/// other texture here -- the blur source/target, everything the fragment
/// shader samples -- is that same plain linear format. `sharpWallpaper` is
/// then box-downsampled into a 2x pyramid (`pyramid[0]` is sharpWallpaper
/// itself), which serves both the sharp sample (the level nearest screen
/// resolution, so a 6K image doesn't alias) and the fog blur's source. sRGB-format textures
/// never touch a compute pass or get sampled a second time anywhere; mixing
/// those is what caused a chain of bugs (blocky mip-LOD "blur", then a black
/// blur target when a compute kernel tried to read the sRGB texture
/// directly). One clean conversion point, one format everywhere after it.
final class RainRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureLoader: MTKTextureLoader
    private let screen: NSScreen

    private let rainPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let blurHPipeline: MTLRenderPipelineState
    private let blurVPipeline: MTLRenderPipelineState
    private var uniformsBuffer: MTLBuffer
    private var sharpWallpaper: MTLTexture
    private var pyramid: [MTLTexture] = []
    private var blurredWallpaper: MTLTexture
    private var blurPing: MTLTexture
    /// Screen-pixel sigma `blurredWallpaper` was last built for; -1 = stale.
    private var blurredSigma: Float = -1

    private var resolution: SIMD2<Float>
    /// Rain clock (seconds, frozen while paused); also shared with Chrome by ChromeBridge.
    private(set) var time: Float = 0
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    init(device: MTLDevice, screen: NSScreen) throws {
        self.device = device
        self.screen = screen
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.metalSetupFailed("command queue")
        }
        self.commandQueue = queue
        self.textureLoader = MTKTextureLoader(device: device)

        let library = try ShaderSource.load(device: device)
        guard let vertexFn = library.makeFunction(name: "fullscreenVertex"),
              let fragmentFn = library.makeFunction(name: "heartfeltRainFragment"),
              let copyFragmentFn = library.makeFunction(name: "passthroughFragment"),
              let blurHFn = library.makeFunction(name: "blurHorizontalFragment"),
              let blurVFn = library.makeFunction(name: "blurVerticalFragment") else {
            throw RendererError.metalSetupFailed("missing shader functions")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        rainPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.vertexFunction = vertexFn
        copyDescriptor.fragmentFunction = copyFragmentFn
        copyDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        copyPipeline = try device.makeRenderPipelineState(descriptor: copyDescriptor)

        let blurHDescriptor = MTLRenderPipelineDescriptor()
        blurHDescriptor.vertexFunction = vertexFn
        blurHDescriptor.fragmentFunction = blurHFn
        blurHDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        blurHPipeline = try device.makeRenderPipelineState(descriptor: blurHDescriptor)

        let blurVDescriptor = MTLRenderPipelineDescriptor()
        blurVDescriptor.vertexFunction = vertexFn
        blurVDescriptor.fragmentFunction = blurVFn
        blurVDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        blurVPipeline = try device.makeRenderPipelineState(descriptor: blurVDescriptor)

        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                height: screen.frame.height * screen.backingScaleFactor)
        resolution = SIMD2(Float(pixelSize.width), Float(pixelSize.height))

        guard let uBuf = device.makeBuffer(length: MemoryLayout<RainUniforms>.stride, options: .storageModeShared) else {
            throw RendererError.metalSetupFailed("uniform buffer")
        }
        uniformsBuffer = uBuf

        sharpWallpaper = RainRenderer.makeColorTexture(device: device, size: pixelSize)
        blurredWallpaper = RainRenderer.makeColorTexture(device: device, size: CGSize(width: 1, height: 1))
        blurPing = RainRenderer.makeColorTexture(device: device, size: CGSize(width: 1, height: 1))

        super.init()

        loadAndProcessWallpaper()
    }

    func reloadWallpaper() {
        loadAndProcessWallpaper()
    }

    private func loadAndProcessWallpaper() {
        let raw = WallpaperImageProvider.loadTexture(loader: textureLoader, screen: screen)
            ?? device.makePlaceholderTexture(size: screen.frame.size, srgb: true)
        convertToLinear(raw)
        buildPyramid()
        blurredSigma = -1 // rebuilt on the next frame, at the current fog settings
    }

    private static func makeColorTexture(device: MTLDevice, size: CGSize) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                              width: max(Int(size.width), 1),
                                                              height: max(Int(size.height), 1),
                                                              mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)!
    }

    /// The one and only place an sRGB-format texture gets sampled: a render
    /// pass copy, which properly gamma-decodes it, into `sharpWallpaper`
    /// (plain linear rgba16Float). Everything downstream uses that.
    private func convertToLinear(_ raw: MTLTexture) {
        if sharpWallpaper.width != raw.width || sharpWallpaper.height != raw.height {
            sharpWallpaper = RainRenderer.makeColorTexture(device: device, size: CGSize(width: raw.width, height: raw.height))
        }
        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sharpWallpaper
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(copyPipeline)
            enc.setFragmentTexture(raw, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.commit()
    }

    /// Successive 2x downsamples of sharpWallpaper, down to ~16px. The
    /// passthrough's single bilinear tap lands on the shared corner of each
    /// 2x2 source block, so every level is an exact box average (no aliasing).
    private func buildPyramid() {
        pyramid = [sharpWallpaper]
        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        var w = sharpWallpaper.width, h = sharpWallpaper.height
        while max(w, h) > 16 {
            w = max(w / 2, 1); h = max(h / 2, 1)
            let level = RainRenderer.makeColorTexture(device: device, size: CGSize(width: w, height: h))
            encodePass(cmd, pipeline: copyPipeline, source: pyramid.last!, target: level)
            pyramid.append(level)
        }
        cmd.commit()
    }

    private func encodePass(_ cmd: MTLCommandBuffer, pipeline: MTLRenderPipelineState,
                            source: MTLTexture, target: MTLTexture, step: Float? = nil) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        if var step {
            enc.setFragmentBytes(&step, length: MemoryLayout<Float>.stride, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Pyramid level whose width is closest to (but not below) the screen's,
    /// so the sharp sample is minified at most ~2x and never aliases.
    private func sharpLevel() -> MTLTexture {
        var best = pyramid.first ?? sharpWallpaper
        for level in pyramid.dropFirst() where Float(level.width) >= resolution.x {
            best = level
        }
        return best
    }

    /// Builds `blurredWallpaper` as a gaussian of `sigmaScreen` screen pixels.
    /// Picks the smallest-resolution pyramid level where that sigma is still
    /// >= ~2.5 texels -- wide enough that bilinear upsampling back to screen
    /// size is perfectly smooth (no pixelation), small enough that three
    /// compounded 9-tap passes cover it with a tap spacing <= ~1.5 texels
    /// (no ghosting). Cheap, since it runs at low resolution.
    private func encodeBlur(_ cmd: MTLCommandBuffer, sigmaScreen: Float) {
        guard !pyramid.isEmpty else { return }
        let iterations = 3
        func sigmaTexels(_ t: MTLTexture) -> Float {
            max(sigmaScreen * Float(t.width) / resolution.x, sigmaScreen * Float(t.height) / resolution.y)
        }
        var source = pyramid[0]
        for level in pyramid.dropFirst() where sigmaTexels(level) >= 2.5 {
            source = level
        }
        let w = source.width, h = source.height
        if blurredWallpaper.width != w || blurredWallpaper.height != h {
            blurredWallpaper = RainRenderer.makeColorTexture(device: device, size: CGSize(width: w, height: h))
            blurPing = RainRenderer.makeColorTexture(device: device, size: CGSize(width: w, height: h))
        }
        // Per-pass sigma is 2 taps * step; N compounded passes give sqrt(N) of that.
        let stepX = sigmaScreen * Float(w) / resolution.x / (2 * Float(iterations).squareRoot())
        let stepY = sigmaScreen * Float(h) / resolution.y / (2 * Float(iterations).squareRoot())
        for i in 0..<iterations {
            encodePass(cmd, pipeline: blurHPipeline, source: i == 0 ? source : blurredWallpaper,
                       target: blurPing, step: stepX)
            encodePass(cmd, pipeline: blurVPipeline, source: blurPing, target: blurredWallpaper, step: stepY)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        resolution = SIMD2(Float(size.width), Float(size.height))
        blurredSigma = -1
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(Float(now - lastFrameTime), 1.0 / 15.0)
        lastFrameTime = now

        let settings = RainSettings.shared
        if !settings.isPaused {
            time += dt
        }

        var uniforms = RainUniforms(
            resolution: resolution, time: time,
            rainIntensity: settings.rainIntensity,
            rainSpeed: settings.rainSpeed,
            staticDropDensity: settings.staticDropDensity,
            layer1Density: settings.layer1Density,
            layer2Density: settings.layer2Density,
            fogMinBlur: settings.fogMinBlur,
            fogMaxBlurLow: settings.fogMaxBlurLow,
            fogMaxBlurHigh: settings.fogMaxBlurHigh,
            refractionStrength: settings.refractionStrength,
            lightningBoost: settings.lightningBoost,
            lightningSpeed: settings.lightningSpeed,
            lightningSharpness: settings.lightningSharpness,
            colorGradeStrength: settings.colorGradeStrength,
            vignetteStrength: settings.vignetteStrength,
            brightness: settings.brightness,
            zoomAmount: settings.zoomAmount,
            zoomSpeed: settings.zoomSpeed,
            dimAmount: settings.dimAmount,
            dropZoomOut: settings.dropZoomOut
        )
        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<RainUniforms>.stride)

        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // The fog texture is built at the current max blur level (the
        // original's mip LOD, ~2^LOD texels on a 1080p-ish canvas), and only
        // rebuilt when that changes -- i.e. while fog/intensity sliders move.
        let maxBlur = settings.fogMaxBlurLow
            + (settings.fogMaxBlurHigh - settings.fogMaxBlurLow) * min(max(settings.rainIntensity, 0), 1)
        let sigmaScreen = min(exp2(maxBlur - 1) * resolution.y / 1080, resolution.y)
        if abs(sigmaScreen - blurredSigma) > 0.01 * sigmaScreen + 0.01 {
            encodeBlur(commandBuffer, sigmaScreen: sigmaScreen)
            blurredSigma = sigmaScreen
        }

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        enc.setRenderPipelineState(rainPipeline)
        enc.setFragmentTexture(sharpLevel(), index: 0)
        enc.setFragmentTexture(blurredWallpaper, index: 1)
        enc.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

enum RendererError: Error, CustomStringConvertible {
    case metalSetupFailed(String)
    var description: String {
        switch self {
        case .metalSetupFailed(let what): return "Metal setup failed: \(what)"
        }
    }
}

private extension MTLDevice {
    func makePlaceholderTexture(size: CGSize, srgb: Bool) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .bgra8Unorm_srgb : .rgba16Float,
                                                              width: max(Int(size.width), 1),
                                                              height: max(Int(size.height), 1),
                                                              mipmapped: false)
        desc.usage = [.shaderRead]
        return makeTexture(descriptor: desc)!
    }
}
