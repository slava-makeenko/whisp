import Foundation
import AVFoundation
import CoreAudio

public enum ConferenceCaptureError: Error, Sendable {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
}

/// Tracks the loudest level seen on each source during a recording — used after `stop()` to detect a
/// missing capture permission (e.g. the system-audio side stayed silent the whole time). Mutated on
/// the IO queue, read once the IOProc has stopped.
private final class LevelTracker: @unchecked Sendable {
    var maxMic: Float = 0
    var maxSystem: Float = 0
    func reset() { maxMic = 0; maxSystem = 0 }
}

/// Core of Conference Mode. Captures the Mac's system-audio output (Core Audio process tap,
/// macOS 14.4+) together with the built-in microphone inside one **private aggregate device**, and
/// records a **stereo** AAC `.m4a` — **mic on the left channel, system audio on the right**. Keeping
/// the two sources on separate channels is what lets the transcriber attribute speech to "me" (mic)
/// vs the remote side (system) with no ML at all — see `ConferenceTranscriber`.
///
/// One aggregate device makes Core Audio the single master clock and drift-compensates the
/// subdevices, so the two channels stay sample-aligned over a long meeting. The meeting stays
/// audible (the tap is unmuted).
///
/// `@unchecked Sendable`: CoreAudio ids are configured before `start` returns and torn down in
/// `stop`; the IO block touches only Sendable values. `start`/`stop` run from one context (the main actor).
@available(macOS 14.2, *)
public final class ConferenceCapturer: @unchecked Sendable {
    private let levelsStream: AsyncStream<Float>
    private let levelsContinuation: AsyncStream<Float>.Continuation
    /// RMS of the combined audio, for the recording indicator.
    public var levels: AsyncStream<Float> { levelsStream }

    private let levelTracker = LevelTracker()
    /// Peak level seen on each source this recording (valid after `stop()`), for permission hints.
    public var maxMicLevel: Float { levelTracker.maxMic }
    public var maxSystemLevel: Float { levelTracker.maxSystem }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: ConferenceRecordingWriter?
    private let ioQueue = DispatchQueue(label: "com.slavamakeenko.whisp.conference.io", qos: .userInitiated)

    public private(set) var isRecording = false

    public init() {
        (levelsStream, levelsContinuation) = AsyncStream.makeStream(of: Float.self)
    }

    /// Builds the tap + aggregate, opens the IOProc, and starts recording to `url` (stereo AAC `.m4a`).
    public func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        levelTracker.reset()

        // 1. System-audio process tap over the whole global mix (excludes nothing).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted   // keep the meeting audible while recording
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapStatus == noErr else { throw ConferenceCaptureError.tapCreationFailed(tapStatus) }
        tapID = tap

        // 2. Private aggregate device = built-in mic (clock master) + the tap (drift-compensated).
        //    The aggregate presents the subdevice's input channels FIRST, then the tap's — so the
        //    first `micChannels` input channels are the mic and the rest are the system audio.
        let micDevID = AudioInputSelection.selectedDeviceID() ?? Self.defaultInputDeviceID()
        let micUID = micDevID.flatMap { Self.deviceUID($0) }
        let micChannels = micDevID.map { Self.inputChannelCount(of: $0) } ?? 0

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

        // 3. Stereo writer (L = mic, R = system) at the aggregate's nominal sample rate.
        let sampleRate = Self.nominalSampleRate(of: agg) ?? 48_000
        let writer = try ConferenceRecordingWriter(url: url, sampleRate: sampleRate, channels: 2)
        self.writer = writer

        // 4. IO block: split input channels into mic (L) + system (R) → stereo writer + levels.
        let levelsCont = levelsContinuation
        let tracker = levelTracker
        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { _, inInputData, _, _, _ in
            Self.splitAndWrite(inInputData, micChannels: micChannels,
                               writer: writer, levels: levelsCont, tracker: tracker)
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

    // MARK: - IO splitting (runs on `ioQueue`)

    /// Splits the aggregate's input channels into mic (the first `micChannels` channels) and system
    /// (the rest), downmixes each group to one channel, and writes a stereo frame (L = mic, R = system).
    private static func splitAndWrite(_ inInputData: UnsafePointer<AudioBufferList>,
                                      micChannels: Int,
                                      writer: ConferenceRecordingWriter,
                                      levels: AsyncStream<Float>.Continuation,
                                      tracker: LevelTracker) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }

        var frameCount = 0
        for buf in abl {
            let ch = max(1, Int(buf.mNumberChannels))
            frameCount = max(frameCount, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch))
        }
        guard frameCount > 0 else { return }

        var mic = [Float](repeating: 0, count: frameCount)
        var system = [Float](repeating: 0, count: frameCount)
        var micCount = 0, systemCount = 0
        var globalChannel = 0
        for buf in abl {
            guard let raw = buf.mData else { continue }
            let ch = max(1, Int(buf.mNumberChannels))
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let samples = raw.assumingMemoryBound(to: Float.self)
            let lim = min(frames, frameCount)
            for c in 0..<ch {
                let isMic = (globalChannel + c) < micChannels
                for i in 0..<lim {
                    let v = samples[i * ch + c]
                    if isMic { mic[i] += v } else { system[i] += v }
                }
                if isMic { micCount += 1 } else { systemCount += 1 }
            }
            globalChannel += ch
        }
        if micCount > 1 { let inv = 1 / Float(micCount); for i in 0..<frameCount { mic[i] *= inv } }
        if systemCount > 1 { let inv = 1 / Float(systemCount); for i in 0..<frameCount { system[i] *= inv } }

        writer.append([mic, system], frames: frameCount)

        let micRMS = rms(mic), systemRMS = rms(system)
        if micRMS > tracker.maxMic { tracker.maxMic = micRMS }
        if systemRMS > tracker.maxSystem { tracker.maxSystem = systemRMS }
        levels.yield(max(micRMS, systemRMS))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - CoreAudio helpers

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != 0 else { return nil }
        return devID
    }

    private static func deviceUID(_ devID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (uid as String) : nil
    }

    /// Number of input channels the device exposes (built-in mic is usually 1).
    private static func inputChannelCount(of devID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, ptr) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
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
