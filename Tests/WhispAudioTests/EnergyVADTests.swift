import Testing
import WhispAudio

@Suite struct EnergyVADTests {

    private func chunk(_ amplitude: Float, count: Int = 1600) -> AudioChunk {
        AudioChunk(samples: Array(repeating: amplitude, count: count), sampleRate: 16_000)
    }

    @Test func rmsComputation() {
        #expect(chunk(0.0).rms() == 0)
        #expect(abs(chunk(0.5).rms() - 0.5) < 1e-6)
    }

    @Test func speechHangoverEndpointSilence() {
        var vad = EnergyVAD(threshold: 0.1, hangoverChunks: 3)
        #expect(vad.process(chunk(0.5)) == .speech)    // loud → speaking
        #expect(vad.process(chunk(0.0)) == .speech)    // hangover 1
        #expect(vad.process(chunk(0.0)) == .speech)    // hangover 2
        #expect(vad.process(chunk(0.0)) == .endpoint)  // hangover 3 → endpoint
        #expect(vad.process(chunk(0.0)) == .silence)   // settled silence
    }

    @Test func startsSilent() {
        var vad = EnergyVAD(threshold: 0.1)
        #expect(vad.process(chunk(0.0)) == .silence)
    }
}
