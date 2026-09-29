import Metal
import Foundation

/// Compiles the Metal shaders from source at launch instead of relying on
/// SwiftPM to prebuild a .metallib resource -- SwiftPM's `.process()` resource
/// rule only copies .metal files verbatim on this toolchain, it doesn't invoke
/// the Metal compiler, so `device.makeDefaultLibrary(bundle:)` finds nothing.
/// Reading the sources relative to this file's own on-disk location (via
/// `#filePath`) is fine here since this app always runs from its source
/// checkout rather than as a redistributed signed bundle.
enum ShaderSource {
    enum LoadError: Error, CustomStringConvertible {
        case fileNotFound(String)
        var description: String {
            switch self {
            case .fileNotFound(let name): return "shader source not found: \(name)"
            }
        }
    }

    static func load(device: MTLDevice) throws -> MTLLibrary {
        // Prefer the copy bundle_app.sh puts in the .app's Resources, so an
        // installed app doesn't need access to the source checkout (which
        // lives in TCC-protected ~/Documents); fall back to it for `swift run`.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Shaders")
        let shadersDir = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Shaders")

        let header = try read(shadersDir.appendingPathComponent("RainTypes.h"))
        let render = try stripLocalInclude(read(shadersDir.appendingPathComponent("RenderShaders.metal")))

        let combined = header + "\n" + render
        let options = MTLCompileOptions()
        return try device.makeLibrary(source: combined, options: options)
    }

    private static func read(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw LoadError.fileNotFound(url.lastPathComponent)
        }
        return text
    }

    private static func stripLocalInclude(_ source: String) -> String {
        source.replacingOccurrences(of: "#include \"RainTypes.h\"", with: "")
    }
}
