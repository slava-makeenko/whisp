import Foundation
import AVFoundation
import CoreAudio

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

        // Pin the input to the built-in microphone so Bluetooth headphones are never
        // switched from A2DP (stereo output) to HFP (headset profile, mono) during capture.
        // Without this, AVAudioEngine picks the system default input, which can be the
        // headset mic — triggering a profile switch that macOS doesn't always reverse.
        // Pin the user-selected input device (Audio settings), else the built-in mic — the built-in
        // keeps Bluetooth headphones on A2DP instead of switching them to the mono headset profile.
        if let deviceID = AudioInputSelection.selectedDeviceID() ?? Self.builtInInputDeviceID() {
            pinInputDevice(deviceID)
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

    /// Sets the HAL audio unit's current device to `deviceID`, overriding the system default.
    /// Must be called after `engine.inputNode` exists and before `engine.prepare()`.
    private func pinInputDevice(_ deviceID: AudioDeviceID) {
        guard let au = engine.inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(au,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0, &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Searches all CoreAudio devices for the first built-in device that has input channels.
    /// Returns `nil` if none found (e.g. Mac mini with no built-in mic), in which case
    /// we fall back to the system default.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                        &addr, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            // Only consider built-in transport (not USB, Bluetooth, virtual, etc.)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0; var tSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            // Confirm it actually has input channels
            var iAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                  mScope: kAudioObjectPropertyScopeInput,
                                                  mElement: kAudioObjectPropertyElementMain)
            var iSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &iAddr, 0, nil, &iSize) == noErr,
                  iSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { continue }
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(iSize),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { ptr.deallocate() }
            guard AudioObjectGetPropertyData(id, &iAddr, 0, nil, &iSize, ptr) == noErr else { continue }
            let bl = ptr.load(as: AudioBufferList.self)
            guard bl.mNumberBuffers > 0 else { continue }
            return id
        }
        return nil
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
