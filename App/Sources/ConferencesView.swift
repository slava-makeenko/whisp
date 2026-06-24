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
    let conference: Conference
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conference.title.isEmpty ? "Conference" : conference.title)
                            .font(.geist(size: 20, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        Text(conference.createdAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Button(action: onDelete) { Image(systemName: "trash").font(.geist(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                }

                if let url = conference.audioURL, FileManager.default.fileExists(atPath: url.path) {
                    ConferenceAudioPlayer(url: url)
                }

                if conference.transcript.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing…").font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    Text(conference.transcript)
                        .textSelection(.enabled)
                        .font(.geist(size: 14)).foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
