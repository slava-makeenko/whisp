import Testing
import Foundation
@testable import WhispASR

@Suite struct BackendFactoryTests {

    /// In the default (no-native-flag) build the router assembles FluidAudio + WhisperKit,
    /// both report `.ready`, and the priority order selects FluidAudio over whisper.
    /// Only `availability()` is exercised — no model downloads.
    @Test func defaultRouterPrefersFluidAudio() async throws {
        let router = TranscriptionBackends.makeRouter()
        let chosen = try await router.select(for: TranscriptionOptions(languages: [Locale(identifier: "en_US")]))
        #expect(chosen.id == .fluidAudioParakeet)
    }

    /// A user override is honoured when that backend is ready.
    @Test func userOverrideSelectsWhisper() async throws {
        let router = TranscriptionBackends.makeRouter(policy: .init(userOverride: .whisper))
        let chosen = try await router.select(for: TranscriptionOptions(languages: [Locale(identifier: "en_US")]))
        #expect(chosen.id == .whisper)
    }
}
