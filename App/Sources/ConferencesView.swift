import SwiftUI
import SwiftData
import AVFoundation
import AppKit
import WhispCore

/// The "Conference" sidebar tab: recordings made in Conference Mode, each with its transcript and a
/// player for the captured audio. Master list on the left, detail (player + transcript) on the right.
struct ConferencesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conference.createdAt, order: .reverse) private var conferences: [Conference]
    @State private var selection: Conference.ID?

    private var selected: Conference? { conferences.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 300)
            Divider().overlay(Theme.hairline)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBG)
        .onAppear { if selection == nil { selection = conferences.first?.id } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ScreenHeader("Conference").padding(.bottom, 6)
                if conferences.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No conference recordings yet.")
                            .font(.geist(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        Text("Press your Conference hotkey (set in Settings → General) to record a meeting — your mic + the system audio. The first time, macOS asks for Audio Recording permission.")
                            .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Privacy Settings") { Self.openPrivacySettings() }
                            .pointingCursor()
                    }
                } else {
                    ForEach(conferences) { conf in
                        ConferenceRow(conference: conf, selected: conf.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = conf.id }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
    }

    @ViewBuilder private var detail: some View {
        if let conf = selected {
            ConferenceDetail(conference: conf) { delete(conf) }
        } else {
            Text("Select a conference")
                .font(.geist(size: 14)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func delete(_ conf: Conference) {
        if let url = conf.audioURL { try? FileManager.default.removeItem(at: url) }
        let nextID = conferences.first { $0.id != conf.id }?.id
        modelContext.delete(conf)
        try? modelContext.save()
        selection = nextID
    }

    private static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ConferenceRow: View {
    let conference: Conference
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conference.title.isEmpty ? "Conference" : conference.title)
                .font(.geist(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText).lineLimit(1)
            Text(conference.transcript.isEmpty ? "Transcribing…" : conference.transcript)
                .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selected ? Theme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }
}

private struct ConferenceDetail: View {
    @Bindable var conference: Conference
    let onDelete: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var isEditingTitle = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            if isEditingTitle {
                                TextField("Conference", text: $conference.title)
                                    .textFieldStyle(.plain)
                                    .font(.geist(size: 20, weight: .semibold))
                                    .foregroundStyle(Theme.primaryText)
                                    .focused($titleFocused)
                                    .onSubmit(commitTitle)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                                        .stroke(Theme.accent, lineWidth: 1.5))
                                Button(action: commitTitle) {
                                    Image(systemName: "checkmark.circle.fill").font(.geist(size: 17)).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain).pointingCursor().help("Done")
                            } else {
                                Text(conference.title.isEmpty ? "Conference" : conference.title)
                                    .font(.geist(size: 20, weight: .semibold)).foregroundStyle(Theme.primaryText)
                                Button { isEditingTitle = true } label: {
                                    Image(systemName: "pencil").font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                                }
                                .buttonStyle(.plain).pointingCursor().help("Rename")
                            }
                        }
                        HStack(spacing: 6) {
                            Text(conference.createdAt, format: .dateTime.day().month().year().hour().minute())
                            if conference.durationMs > 0 { Text("·"); Text(durationText) }
                        }
                        .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    if !conference.transcript.isEmpty {
                        Button(action: copyTranscript) { Image(systemName: "doc.on.doc").font(.geist(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                            .help("Copy transcript")
                    }
                    Button(action: onDelete) { Image(systemName: "trash").font(.geist(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                        .help("Delete")
                }
                .onChange(of: isEditingTitle) { _, editing in titleFocused = editing }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }

                if let url = conference.audioURL, FileManager.default.fileExists(atPath: url.path) {
                    ConferenceAudioPlayer(url: url)
                }

                if conference.transcript.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing…").font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    TranscriptSummaryView(transcript: conference.transcript, summary: $conference.summary) {
                        try? modelContext.save()
                    }
                    DiarizedTranscript(text: conference.transcript)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
        .id(conference.id)
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        try? modelContext.save()
    }

    private var durationText: String {
        let total = conference.durationMs / 1000
        let minutes = total / 60, seconds = total % 60
        return minutes > 0 ? "\(minutes) min \(seconds) s" : "\(seconds) s"
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(conference.transcript, forType: .string)
    }
}

/// Renders a speaker-labelled transcript ("Я: …" / "Собеседник: …") with the speaker styled, and any
/// non-labelled lines (e.g. a permission hint) as plain secondary text.
private struct DiarizedTranscript: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let turn = Self.parse(line) {
                    (Text(turn.speaker + "  ")
                        .font(.geist(size: 14, weight: .semibold))
                        .foregroundStyle(speakerColor(turn.speaker))
                     + Text(turn.text)
                        .font(.geist(size: 14))
                        .foregroundStyle(Theme.primaryText))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(line)
                        .font(.geist(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] { text.split(separator: "\n").map(String.init) }

    /// A "Speaker: text" line — any speaker label ("Я", "Собеседник 1", …), not a fixed set.
    private static func parse(_ line: String) -> (speaker: String, text: String)? {
        guard let range = line.range(of: ": "), range.lowerBound != line.startIndex else { return nil }
        let speaker = String(line[line.startIndex..<range.lowerBound])
        // Guard against false positives (a colon deep in a sentence): labels are short.
        guard speaker.count <= 20, !speaker.contains(".") else { return nil }
        return (speaker, String(line[range.upperBound...]))
    }

    /// "Я" is the accent; each remote speaker gets a stable colour so participants are easy to tell apart.
    private func speakerColor(_ speaker: String) -> Color {
        if speaker == "Я" { return Theme.accent }
        let palette: [Color] = [.blue, .green, .purple, .pink, .teal, .indigo, .brown]
        // Derive a stable index from the trailing number ("Собеседник 2" → 2), else hash the label.
        let n = Int(speaker.split(separator: " ").last ?? "") ?? abs(speaker.hashValue)
        return palette[(max(1, n) - 1) % palette.count]
    }
}

/// Minimal AVAudioPlayer-backed transport: play/pause + a scrub slider + time labels.
private struct ConferenceAudioPlayer: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var current: Double = 0
    @State private var duration: Double = 1
    @State private var scrubbing = false
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain).pointingCursor()

            Slider(value: $current, in: 0...max(duration, 0.1)) { editing in
                scrubbing = editing
                if !editing { player?.currentTime = current }
            }
            .tint(Theme.accent)

            Text("\(fmt(current)) / \(fmt(duration))")
                .font(.geistMono(size: 11)).foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(12)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).stroke(Theme.hairline))
        .onAppear(perform: load)
        .onDisappear { player?.stop() }
        .onReceive(tick) { _ in
            guard let p = player, isPlaying, !scrubbing else { return }
            current = p.currentTime
            if !p.isPlaying { isPlaying = false; current = 0 }
        }
    }

    private func load() {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = max(player?.duration ?? 1, 0.1)
    }

    private func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true }
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
