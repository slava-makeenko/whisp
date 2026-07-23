import Foundation
import AppKit
import SwiftData
import Observation
import WhispAudio
import WhispCore

/// Drives Conference Mode: records the mic + system-audio mix, shows a notch indicator while
/// recording, and on stop persists a `Conference` and transcribes the recording in the background.
/// Separate from `DictationController` — long-form, dual-source, no live injection and **no media
/// ducking/VAD** (the meeting must keep playing for the tap to capture it).
@MainActor
@Observable
final class ConferenceController {
    enum State: Equatable { case idle, recording, transcribing }

    private(set) var state: State = .idle
    private(set) var level: Float = 0
    private(set) var recordingStartedAt: Date?
    /// Live "mute me" during a recording — your voice is dropped, the other side keeps recording.
    private(set) var micMuted = false

    @ObservationIgnored var modelContainer: ModelContainer?
    @ObservationIgnored private let capturer = ConferenceCapturer()
    @ObservationIgnored private var levelsTask: Task<Void, Never>?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var recordingID = UUID()
    @ObservationIgnored private var sourceApp: NSRunningApplication?

    func toggle() {
        switch state {
        case .idle:        start()
        case .recording:   stop()
        case .transcribing: break   // ignore while a recording is still finishing
        }
    }

    /// Mute/unmute your own microphone mid-recording. No-op unless a recording is in progress.
    func toggleMute() {
        guard state == .recording else { return }
        micMuted.toggle()
        capturer.setMuted(micMuted)
    }

    private func start() {
        guard state == .idle, let dir = try? AppConstants.conferenceRecordingsDirectory() else { return }
        let id = UUID()
        do {
            try capturer.start(writingTo: dir.appendingPathComponent("\(id.uuidString).m4a"))
        } catch {
            NSLog("[Conference] start failed: \(error)")
            return
        }
        recordingID = id
        recordingStartedAt = .now
        sourceApp = NSWorkspace.shared.frontmostApplication
        micMuted = false
        state = .recording
        // Keep capture alive while another app is focused (App Nap would throttle the IO proc).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "whisp conference recording")
        levelsTask = Task { @MainActor [weak self, capturer] in
            for await value in capturer.levels { self?.level = value }
        }
    }

    private func stop() {
        guard state == .recording, let started = recordingStartedAt else { return }
        capturer.stop()
        levelsTask?.cancel(); levelsTask = nil
        level = 0
        micMuted = false
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        recordingStartedAt = nil
        state = .transcribing

        let durationMs = Int(Date.now.timeIntervalSince(started) * 1000)
        let fileName = "\(recordingID.uuidString).m4a"
        let appName = (sourceApp?.bundleIdentifier == AppConstants.bundleIdentifier
                       ? nil : sourceApp?.localizedName) ?? "Conference"
        let title = "\(appName) · \(Self.dateFormatter.string(from: started))"

        guard let container = modelContainer else { state = .idle; return }
        let conference = Conference(title: title, audioFileName: fileName, createdAt: started,
                                    durationMs: durationMs, sourceAppBundleID: sourceApp?.bundleIdentifier)
        container.mainContext.insert(conference)
        try? container.mainContext.save()

        let url = (try? AppConstants.conferenceRecordingsDirectory())?.appendingPathComponent(fileName)
        let micSilent = capturer.maxMicLevel <= Self.silenceThreshold
        let systemSilent = capturer.maxSystemLevel <= Self.silenceThreshold
        Task { @MainActor in
            if micSilent && systemSilent {
                // Nothing captured at all — almost always a missing capture permission.
                conference.transcript = Self.noAudioHint
            } else if let url {
                // Diarized, window-by-window transcription (Я = mic, Собеседник = system audio).
                for await partial in ConferenceTranscriber.stream(url) {
                    conference.transcript = partial
                    conference.wordCount = partial.split(whereSeparator: \.isWhitespace).count
                    try? container.mainContext.save()
                }
                // Mic worked but the system side stayed silent → the tap permission is the usual cause.
                if systemSilent {
                    conference.transcript = Self.noSystemAudioHint + "\n\n" + conference.transcript
                }
            }
            try? container.mainContext.save()
            state = .idle
        }
    }

    /// Below this peak RMS a source is treated as silent (no audio captured).
    private static let silenceThreshold: Float = 0.0008
    private static let noAudioHint =
        "⚠️ No audio was captured. Conference Mode needs Microphone and Audio Recording permission — "
        + "grant them in System Settings → Privacy & Security, then record again."
    private static let noSystemAudioHint =
        "⚠️ Only your microphone was captured — the system audio was silent. Grant Audio Recording "
        + "permission (System Settings → Privacy & Security) so the other side is recorded too."

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}
