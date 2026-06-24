import Foundation
import AVFoundation
import CoreAudio

public enum ConferenceCaptureError: Error, Sendable {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
}

/// Phase 1 core of Conference Mode. Captures the Mac's system-audio output (Core Audio process tap,
/// macOS 14.4+) together with the built-in microphone inside one **private aggregate device**, mixes
/// every input channel to mono, and records an AAC `.m4a`.
///
/// Putting the tap and the mic in the same aggregate device makes Core Audio the single master clock
/// and drift-compensates the subdevices, so a long meeting stays in sync without manual host-time
/// alignment. The meeting stays audible (the tap is unmuted).
///
/// `@unchecked Sendable`: the CoreAudio object ids are configured before `start(writingTo:)` returns
/// and torn down in `stop()`; the IO block touches only the `Sendable` writer and levels continuation.
/// `start`/`stop` are expected to be called from a single context (Phase 2's controller, on the main actor).
///
/// Process taps need macOS 14.2+; the app's deployment floor is 14.4, but the WhispAudio package
/// baseline is lower, so the type is gated explicitly.
@available(macOS 14.2, *)
public final class ConferenceCapturer: @unchecked Sendable {
    private let levelsStream: AsyncStream<Float>
    private let levelsContinuation: AsyncStream<Float>.Continuation
    /// RMS of the mixed audio, for the recording indicator.
    public var levels: AsyncStream<Float> { levelsStream }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: ConferenceRecordingWriter?
    private let ioQueue = DispatchQueue(label: "com.slavamakeenko.whisp.conference.io", qos: .userInitiated)

    public private(set) var isRecording = false

    public init() {
        (levelsStream, levelsContinuation) = AsyncStream.makeStream(of: Float.self)
    }

    /// Builds the tap + aggregate, opens the IOProc, and starts recording to `url` (AAC `.m4a`).
    public func start(writingTo url: URL) throws {
        guard !isRecording else { return }

        // 1. System-audio process tap over the whole global mix (excludes nothing).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted   // keep the meeting audible while recording
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapStatus == noErr else { throw ConferenceCaptureError.tapCreationFailed(tapStatus) }
        tapID = tap

        // 2. Private aggregate device = built-in mic (clock master) + the tap (drift-compensated).
        let micUID = Self.defaultInputUID()
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whisp Conference",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let micUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = micUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[
                kAudioSubDeviceUIDKey: micUID,
                kAudioSubDeviceDriftCompensationKey: true,
            ]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard aggStatus == noErr else { cleanup(); throw ConferenceCaptureError.aggregateCreationFailed(aggStatus) }
        aggregateID = agg

        // 3. Writer at the aggregate's nominal sample rate, mono.
        let sampleRate = Self.nominalSampleRate(of: agg) ?? 48_000
        let writer = try ConferenceRecordingWriter(url: url, sampleRate: sampleRate, channels: 1)
        self.writer = writer

        // 4. IO block on a dedicated queue: mix all input channels → mono → writer + levels.
        let levelsCont = levelsContinuation
        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { _, inInputData, _, _, _ in
            Self.mixAndWrite(inInputData, writer: writer, levels: levelsCont)
        }
        guard ioStatus == noErr, let proc else { cleanup(); throw ConferenceCaptureError.ioProcCreationFailed(ioStatus) }
        ioProcID = proc

        let startStatus = AudioDeviceStart(agg, proc)
        guard startStatus == noErr else { cleanup(); throw ConferenceCaptureError.deviceStartFailed(startStatus) }
        isRecording = true
    }

    /// Stops recording, flushes the file, and tears down every CoreAudio resource.
    public func stop() {
        guard isRecording else { return }
        isRecording = false
        if let proc = ioProcID { AudioDeviceStop(aggregateID, proc) }
        cleanup()
        writer?.finish()
        writer = nil
    }

    /// Releases the IOProc, aggregate device, and tap — in that order. Safe to call repeatedly.
    private func cleanup() {
        if let proc = ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - IO mixing (runs on `ioQueue`)

    private static func mixAndWrite(_ inInputData: UnsafePointer<AudioBufferList>,
                                    writer: ConferenceRecordingWriter,
                                    levels: AsyncStream<Float>.Continuation) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }

        var frameCount = 0
        for buf in abl {
            let ch = max(1, Int(buf.mNumberChannels))
            frameCount = max(frameCount, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch))
        }
        guard frameCount > 0 else { return }

        var mix = [Float](repeating: 0, count: frameCount)
        var streams = 0
        for buf in abl {
            guard let raw = buf.mData else { continue }
            let ch = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let samples = raw.assumingMemoryBound(to: Float.self)
            let lim = min(frames, frameCount)
            for i in 0..<lim {
                var s: Float = 0
                for c in 0..<ch { s += samples[i * ch + c] }   // downmix this stream's channels
                mix[i] += s / Float(ch)
            }
            streams += 1
        }
        if streams > 1 {
            let inv = 1 / Float(streams)
            for i in 0..<frameCount { mix[i] *= inv }
        }

        writer.append([mix], frames: frameCount)

        var sumSq: Float = 0
        for v in mix { sumSq += v * v }
        levels.yield((sumSq / Float(frameCount)).squareRoot())
    }

    // MARK: - CoreAudio helpers

    /// UID of the current default input device (the mic), for the aggregate's subdevice list.
    private static func defaultInputUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, $0)
        }
        return status == noErr ? (uid as String) : nil
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return Double(rate)
    }
}
