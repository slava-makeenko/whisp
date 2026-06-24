import Foundation
import AVFoundation

/// Serial-queue-backed AAC (`.m4a`) writer for Conference Mode. The capture IO block hands it mixed
/// float frames; the encode happens off the audio callback on a private serial queue so the IO cycle
/// never blocks on file I/O.
///
/// `@unchecked Sendable`: all mutable state (`file`, `failed`) is confined to `queue`.
public final class ConferenceRecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.slavamakeenko.whisp.conference.writer", qos: .userInitiated)
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var failed = false

    /// Creates an AAC `.m4a` at `url`, encoding `channels`-channel float audio at `sampleRate`.
    public init(url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        // `processingFormat` (what `write(from:)` expects) is derived from these args: float32,
        // non-interleaved, at the settings sample rate — which is exactly what the mixer feeds.
        self.file = try AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        self.format = file.processingFormat
    }

    /// Appends `frames` frames. `channelData[c]` holds `frames` floats for channel `c`; a mono mix
    /// passes a single-element array.
    public func append(_ channelData: [[Float]], frames: Int) {
        guard frames > 0, !channelData.isEmpty else { return }
        queue.async { [self] in
            guard !failed,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let dst = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            for c in 0..<Int(format.channelCount) {
                let src = channelData[min(c, channelData.count - 1)]
                src.withUnsafeBufferPointer { p in
                    guard let base = p.baseAddress else { return }
                    dst[c].update(from: base, count: min(frames, p.count))
                }
            }
            do { try file.write(from: buffer) } catch { failed = true }
        }
    }

    /// Drains pending writes; the file finalizes when this writer is released.
    public func finish() {
        queue.sync { }
    }
}
