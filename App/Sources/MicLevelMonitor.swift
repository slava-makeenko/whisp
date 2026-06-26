import AVFoundation
import CoreAudio
import Observation
import WhispAudio

/// Live input-level meter for the Audio settings section. Runs its own `AVAudioEngine` (independent
/// of the dictation / conference capturers), pins the user-selected input device, and publishes a
/// smoothed 0…1 level. Active only while the Audio section is on screen — opening the mic is what
/// lets the meter show real signal.
@Observable @MainActor
final class MicLevelMonitor {
    private(set) var level: Float = 0   // 0…1, amplified + smoothed

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<Float>.Continuation?

    func start() {
        guard !running else { return }
        let input = engine.inputNode

        // Pin the user-selected input device (same selection the capturers use).
        if let device = AudioInputSelection.selectedDeviceID(), let au = input.audioUnit {
            var id = device
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }

        let (stream, cont) = AsyncStream.makeStream(of: Float.self)
        continuation = cont
        // Install the tap from a nonisolated context: the block runs on the realtime audio thread, so
        // it must NOT inherit this type's @MainActor isolation (that traps the Swift 6 executor check).
        Self.installMeterTap(on: input, format: format, continuation: cont)

        do {
            try engine.start()
            running = true
            consumer = Task { @MainActor [weak self] in
                for await rms in stream {
                    guard let self else { continue }
                    // Amplify (speech RMS is small) and smooth so the meter doesn't jitter.
                    let target = min(rms * 12, 1)
                    self.level = self.level * 0.6 + target * 0.4
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            continuation = nil
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        consumer?.cancel(); consumer = nil
        continuation?.finish(); continuation = nil
        running = false
        level = 0
    }

    /// Re-pin after the selected device changes while the section stays open.
    func restart() {
        stop()
        start()
    }

    /// Installs the metering tap. `nonisolated` so the realtime block carries no actor isolation —
    /// it only touches the captured `Sendable` continuation.
    nonisolated private static func installMeterTap(on input: AVAudioInputNode,
                                                    format: AVAudioFormat,
                                                    continuation cont: AsyncStream<Float>.Continuation) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            let samples = channel[0]
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            cont.yield((sum / Float(n)).squareRoot())
        }
    }
}
