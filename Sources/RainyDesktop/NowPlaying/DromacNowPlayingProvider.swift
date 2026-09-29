import Foundation
import AppKit

/// Polls Dromac's local now-playing API (see Dromac-External-API.md).
/// Per that doc's guidance, position is a snapshot, not live -- we poll on a
/// modest interval and let NowPlayingInfo.liveElapsedMs extrapolate between polls.
actor DromacNowPlayingProvider {
    private let baseURL = URL(string: "http://127.0.0.1:8811")!
    private let session: URLSession
    private var artworkCache: (url: URL, image: NSImage)?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4
        session = URLSession(configuration: config)
    }

    func fetch() async -> NowPlayingInfo? {
        let endpoint = baseURL.appendingPathComponent("api/external/now-playing")
        guard let (data, response) = try? await session.data(from: endpoint),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard (json["connected"] as? Bool) == true else {
            return NowPlayingInfo(source: .dromac) // connected: false -> nothing playing, but Dromac itself is reachable
        }

        var info = NowPlayingInfo(source: .dromac)
        info.title = json["title"] as? String
        info.artist = json["artist"] as? String
        info.playing = (json["playing"] as? Bool) ?? false
        info.positionMs = (json["positionMs"] as? Int) ?? 0
        info.durationMs = json["durationMs"] as? Int
        info.positionCapturedAt = Date()

        if let lyrics = json["lyrics"] as? [String: Any] {
            info.currentLyric = lyrics["current"] as? String
            if let lines = lyrics["lines"] as? [[String: Any]] {
                info.lyricLines = lines.compactMap { entry in
                    guard let t = entry["t"] as? Int, let text = entry["text"] as? String else { return nil }
                    return LyricLine(timeMs: t, text: text)
                }
            }
        }

        if let artworkUrlString = json["artworkUrl"] as? String, let artworkURL = URL(string: artworkUrlString) {
            info.artwork = await loadArtwork(url: artworkURL)
        }

        return info
    }

    private func loadArtwork(url: URL) async -> NSImage? {
        if let cache = artworkCache, cache.url == url {
            return cache.image
        }
        guard let (data, _) = try? await session.data(from: url), let image = NSImage(data: data) else {
            return nil
        }
        artworkCache = (url, image)
        return image
    }
}
