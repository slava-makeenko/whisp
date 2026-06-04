import Foundation
import AVFoundation

public enum CaptureError: Error, Sendable {
    case formatUnavailable
}

/// `AVAudioEngine`-backed microphone capture. The engine and its nodes are confined to
/// this actor; only `Sendable` values cross to the audio render thread and back.
///
/// Concurrency note: the tap block runs on the realtime audio thread. It captures only
/// `Sendable` values (two stream continuations and a thread-confined converter box) and
/// never touches actor state, so there is no shared mutable state across executors.
public actor AVAudioEngineCapturer: AudioCapturer {
    private let engine = AVAudioEngine()
    private nonisolated let levelsStream: AsyncStream<Float>
    private let levelsContinuation: AsyncStream<Float>.Continuation
    private var audioContinuation: AudioStream.Continuation?

    public nonisolated var levels: AsyncStream<Float> { levelsStream }

    public init() {
        (levelsStream, levelsContinuation) = AsyncStream.makeStream(of: Float.self)
    }

    public func start(_ config: CaptureConfig) async throws -> AudioStream {
        // Reset any prior session so installTap never hits an existing tap (`nullptr == Tap()`).
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        audioContinuation?.finish()
        audioContinuation = nil

        let inputFormat = input.outputFormat(forBus: 0)
        guard
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: config.sampleRate,
                                             channels: AVAudioChannelCount(config.channels),
                                             interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else { throw CaptureError.formatUnavailable }

        let box = ConverterBox(converter: converter, targetFormat: targetFormat,
                               targetSampleRate: config.sampleRate)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        audioContinuation = continuation
        let levelsCont = levelsContinuation

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            // Realtime audio thread — `box` is @unchecked Sendable, confined here.
            guard let chunk = box.convert(buffer) else { return }
            continuation.yield(chunk)
            levelsCont.yield(chunk.rms())
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish(throwing: error)
            audioContinuation = nil
            throw error
        }
        return stream
    }

    public func stop() async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audioContinuation?.finish()
        audioContinuation = nil
    }
}

/// Resamples each captured buffer to the target (16 kHz mono Float) format.
/// `@unchecked Sendable`: instances are only ever used on the single serial audio render
/// thread inside the tap block, never concurrently.
private final class ConverterBox: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let targetSampleRate: Double
    private var pendingInput: AVAudioPCMBuffer?   // confined to the audio render thread

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat, targetSampleRate: Double) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.targetSampleRate = targetSampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) -> AudioChunk? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        pendingInput = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] _, inputStatus in
            guard let buffer = pendingInput else { inputStatus.pointee = .noDataNow; return nil }
            pendingInput = nil
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return nil }
        let count = Int(output.frameLength)
        guard count > 0 else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: count))
        return AudioChunk(samples: samples, sampleRate: targetSampleRate)
    }
}
