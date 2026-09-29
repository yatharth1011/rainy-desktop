import Foundation

/// Prefers whatever macOS itself reports as now-playing (Music, Spotify, a
/// Chrome tab, ...) -- if the Mac has an active now-playing session at all,
/// that takes priority over Dromac. Deliberately doesn't gate this on the
/// `playing` flag: some apps (Spotify, notably) don't reliably populate the
/// underlying MediaRemote playback-rate field, so a strict "must currently
/// be playing" check silently lost to Dromac even while Spotify was audibly
/// playing. Falls back to Dromac only when the Mac has nothing at all.
@MainActor
final class NowPlayingAggregator {
    private(set) var current: NowPlayingInfo = .empty
    private let dromac = DromacNowPlayingProvider()
    private let system = SystemNowPlayingProvider()
    private var pollTask: Task<Void, Never>?
    private var onUpdate: ((NowPlayingInfo) -> Void)?

    func start(onUpdate: @escaping (NowPlayingInfo) -> Void) {
        self.onUpdate = onUpdate
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        if let systemInfo = await system.fetch(), systemInfo.isUsable {
            apply(systemInfo) // any Mac now-playing session wins outright
            return
        }
        if let dromacInfo = await dromac.fetch(), dromacInfo.isUsable {
            apply(dromacInfo)
            return
        }
        apply(.empty)
    }

    private func apply(_ info: NowPlayingInfo) {
        guard info != current else { return }
        current = info
        onUpdate?(info)
    }
}
