import Foundation
import AppKit

/// Falls back to whatever macOS itself considers "now playing" system-wide --
/// Music, Spotify, a Chrome tab playing YouTube, anything using the standard
/// media-session APIs -- for when Dromac has nothing connected.
struct SystemNowPlayingProvider {
    func fetch() async -> NowPlayingInfo? {
        guard MediaRemoteBridge.shared.isAvailable else {
            debugLog("SystemNowPlaying: MediaRemote bridge unavailable (dlopen/dlsym failed)")
            return nil
        }
        guard let dict = await MediaRemoteBridge.shared.fetchNowPlaying() else {
            debugLog("SystemNowPlaying: fetchNowPlaying returned nil")
            return nil
        }
        debugLog("SystemNowPlaying: raw dict keys = \(dict.keys.sorted())")

        var info = NowPlayingInfo(source: .system)
        info.title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        info.artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String

        let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        info.playing = rate > 0.01

        let elapsedSeconds = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        info.positionMs = Int(elapsedSeconds * 1000)
        if let durationSeconds = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double, durationSeconds > 0 {
            info.durationMs = Int(durationSeconds * 1000)
        }
        info.positionCapturedAt = (dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date) ?? Date()

        if let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
           let image = NSImage(data: artworkData) {
            info.artwork = image
        }

        guard info.isUsable else {
            debugLog("SystemNowPlaying: not usable, title=\(String(describing: info.title)) artist=\(String(describing: info.artist))")
            return nil
        }
        return info
    }
}
