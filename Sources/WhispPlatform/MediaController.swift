import Foundation

public struct NowPlaying: Sendable {
    public let title: String?
    public let artist: String?
    public let isPlaying: Bool
    public init(title: String?, artist: String?, isPlaying: Bool) {
        self.title = title; self.artist = artist; self.isPlaying = isPlaying
    }
}

/// Duck/pause whatever is playing while recording, then resume. Backed by MediaRemoteAdapter
/// (bundled framework + helper). Implemented in Phase 2/Phase 11.
// VERIFY-MR-1: adapter invocation + get/pause/resume API + macOS 26 behaviour given the
// 15.4+ now-playing C-API lockdown.
public protocol MediaController: Sendable {
    func nowPlaying() async -> NowPlaying?
    func pause() async
    func resume() async
}
