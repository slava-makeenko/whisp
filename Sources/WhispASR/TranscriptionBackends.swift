import Foundation

/// Assembles every compiled-in backend into a best-available router (decision D2).
/// The native backend is compiled in only under `ENABLE_NATIVE_SPEECH_ANALYZER` and is
/// added only on macOS 26+ at runtime; FluidAudio and WhisperKit are always present.
public enum TranscriptionBackends {
    public static func makeRouter(policy: SelectionPolicy = .init()) -> TranscriptionRouter {
        var backends: [any TranscriptionService] = []
        #if ENABLE_NATIVE_SPEECH_ANALYZER
        if #available(macOS 26, *) {
            backends.append(NativeSpeechBackend())
        }
        #endif
        backends.append(FluidAudioBackend())
        backends.append(WhisperKitBackend())
        backends.append(WhisperCppBackend())
        return TranscriptionRouter(backends: backends, policy: policy)
    }
}
