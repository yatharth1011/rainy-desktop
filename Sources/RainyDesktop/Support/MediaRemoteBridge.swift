import Foundation

/// Thin bridge to the private MediaRemote framework -- the same mechanism
/// Control Center's system-wide Now Playing widget uses, so it picks up
/// whatever app (Music, Spotify, a Chrome tab playing YouTube, ...) currently
/// owns the "now playing" session, not just our own process.
///
/// There is no public API for this; MediaRemote is what every third-party
/// "now playing" menu-bar utility on macOS is built on. Loaded via dlopen so
/// a missing/renamed symbol on some future macOS just disables the fallback
/// instead of crashing.
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private typealias GetNowPlayingInfoFn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void

    private let getNowPlayingInfo: GetNowPlayingInfoFn?
    let isAvailable: Bool

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW
        ) else {
            debugLog("MediaRemoteBridge: dlopen failed")
            getNowPlayingInfo = nil
            isAvailable = false
            return
        }
        guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            debugLog("MediaRemoteBridge: dlopen succeeded but dlsym(MRMediaRemoteGetNowPlayingInfo) failed")
            getNowPlayingInfo = nil
            isAvailable = false
            return
        }
        getNowPlayingInfo = unsafeBitCast(sym, to: GetNowPlayingInfoFn.self)
        isAvailable = true
        debugLog("MediaRemoteBridge: loaded successfully")
    }

    func fetchNowPlaying() async -> [String: Any]? {
        guard let fn = getNowPlayingInfo else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            fn(DispatchQueue.global(qos: .utility)) { dict in
                continuation.resume(returning: dict as NSDictionary? as? [String: Any])
            }
        }
    }
}
