import Foundation

/// Placeholder media controller used until MediaRemoteAdapter ducking lands (later phase).
/// Lets the orchestrator wire its pause/resume calls with no side effects.
public struct NoOpMediaController: MediaController {
    public init() {}
    public func nowPlaying() async -> NowPlaying? { nil }
    public func pause() async {}
    public func resume() async {}
}
