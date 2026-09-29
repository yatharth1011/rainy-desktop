import Foundation
import AppKit

struct LyricLine: Equatable {
    let timeMs: Int
    let text: String
}

struct NowPlayingInfo: Equatable {
    var source: Source
    var title: String?
    var artist: String?
    var playing: Bool = false
    var positionMs: Int = 0
    var durationMs: Int?
    var positionCapturedAt: Date = Date()
    var artwork: NSImage?
    var currentLyric: String?
    var lyricLines: [LyricLine] = []

    enum Source: String {
        case dromac = "Dromac"
        case system = "System"
        case none = "None"
    }

    /// NSImage isn't Equatable; artwork/lyrics are compared by presence only so
    /// a fresh NSImage instance with identical bytes doesn't spuriously count
    /// as "changed" on every poll.
    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.source == rhs.source &&
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.playing == rhs.playing &&
        lhs.positionMs == rhs.positionMs &&
        lhs.durationMs == rhs.durationMs &&
        (lhs.artwork == nil) == (rhs.artwork == nil) &&
        lhs.currentLyric == rhs.currentLyric &&
        lhs.lyricLines == rhs.lyricLines
    }

    static let empty = NowPlayingInfo(source: .none)

    /// Extrapolates playhead position forward from when it was captured, so the
    /// UI can show a live-moving progress bar without re-polling every second.
    var liveElapsedMs: Int {
        guard playing else { return positionMs }
        let elapsed = Date().timeIntervalSince(positionCapturedAt) * 1000
        let projected = Double(positionMs) + elapsed
        if let duration = durationMs {
            return min(Int(projected), duration)
        }
        return Int(projected)
    }

    var isUsable: Bool {
        (title?.isEmpty == false) || (artist?.isEmpty == false)
    }
}
