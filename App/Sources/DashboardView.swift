import SwiftUI
import SwiftData
import AppKit
import ApplicationServices
import WhispCore
import WhispInput
import WhispLLM

struct DashboardView: View {
    @Environment(DictationController.self) private var controller
    @Environment(FileQueueModel.self) private var fileQueue
    @Query(sort: \SessionMetric.date, order: .reverse) private var metrics: [SessionMetric]
    @Query(sort: \Transcription.createdAt, order: .reverse) private var transcriptions: [Transcription]

    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("enhancementStyle") private var enhancementStyle = "auto"
    @Environment(LocalModelStore.self) private var store

    private var downloadKey: String {
        OnDeviceModel.catalog.compactMap { m -> String? in
            if case .downloading(let p) = store.states[m.id] ?? .notDownloaded {
                return "\(m.id)\(Int(p*100))"
            }
            return nil
        }.joined()
    }

    @State private var dropTargeted = false
    @State private var recordHovering = false
    @State private var axTrusted = AXIsProcessTrusted()

    private var summary: MetricsSummary { MetricsSummary.from(metrics) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                greeting
                if !axTrusted { accessibilityBanner }
                HStack(alignment: .top, spacing: 16) {
                    recordCard
                    VStack(spacing: 12) {
                        statsCard
                        AIModelCard()
                            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                                       value: (store.activeModel?.id ?? "") + downloadKey)
                    }
                    .frame(width: 234)
                }
                if !controller.liveText.isEmpty { liveText }
                recentSection
                filesSection
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: - Greeting

    private var greeting: some View {
        HStack(spacing: 9) {
            Text("Hey \(firstName), get back into the flow with")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HotkeyChip(label: hotkeyBadge)
        }
        .padding(.bottom, 2)
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    private var hotkeyBadge: String {
        let mods = HotkeyModifiers(rawValue: hotkeyModifiers)
        if hotkeyKeyCode < 0 {
            if mods.contains(.fn) { return "fn" }
            if mods.contains(.command) { return "⌘" }
            if mods.contains(.option) { return "⌥" }
            if mods.contains(.control) { return "⌃" }
            if mods.contains(.shift) { return "⇧" }
            return "fn"
        }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        s += hotkeyKeyCode == 49 ? "Space" : "·"
        return s
    }

    // MARK: - Record card

    private var recordCard: some View {
        VStack(spacing: 14) {
            HStack {
                statusBadge
                Spacer()
                modePill
            }

            if let start = controller.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.elapsed(from: start, to: context.date))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }

            Button(action: controller.toggle) {
                Label(LocalizedStringKey(recordLabel), systemImage: recordIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(controller.state == .recording ? Color.red : Theme.accent,
                                in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(controller.state == .transcribing || controller.state == .injecting)
            .brightness(recordHovering ? 0.06 : 0)
            .scaleEffect(recordHovering ? 1.01 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: recordHovering)
            .onHover { hovering in
                recordHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if controller.state == .recording {
                WaveformView(level: controller.level, tint: .red, barCount: 9)
                    .frame(height: 28)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Text("Or press \(hotkeyBadge) anywhere to dictate.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }

            if let outcome = controller.lastInjection, controller.state == .idle {
                injectionStatus(outcome)
            }
        }
        .frame(maxWidth: .infinity)
        .wispCard()
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: controller.state)
        .animation(.default, value: controller.lastInjection)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch controller.state {
        case .idle:               ("Ready", Theme.secondaryText)
        case .preparing:          ("Preparing…", Theme.accent)
        case .recording:          (controller.isSpeaking ? "Listening…" : "Recording…", .red)
        case .transcribing:       ("Transcribing…", Theme.accent)
        case .injecting:          ("Inserting…", Theme.accent)
        case .error(let message): (message, .orange)
        }
        return Label(LocalizedStringKey(text), systemImage: "circle.fill")
            .foregroundStyle(color)
            .font(.system(size: 15, weight: .semibold))
            .contentTransition(.opacity)
    }

    private var currentMode: EnhancementStyle { EnhancementStyle(rawValue: enhancementStyle) ?? .auto }

    /// A violet pill in the record card to see and switch the active formatting mode (Wispr-style).
    private var modePill: some View {
        Menu {
            ForEach(EnhancementStyle.allCases) { style in
                Toggle(LocalizedStringKey(style.name), isOn: Binding(
                    get: { enhancementStyle == style.rawValue },
                    set: { if $0 { enhancementStyle = style.rawValue } }))
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars").font(.system(size: 11))
                Text(LocalizedStringKey(currentMode.name)).font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Theme.accentSoft, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingCursor()
    }

    @ViewBuilder
    private func injectionStatus(_ outcome: InjectionOutcome) -> some View {
        switch outcome {
        case .inserted(let app):
            Label {
                if let app { Text("Inserted into \(app)") } else { Text("Inserted") }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green).font(.callout)
        case .copiedToClipboard:
            Label("Copied to clipboard — enable Accessibility to auto-insert", systemImage: "doc.on.clipboard")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    // MARK: - Stats

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatRow(value: totalWords.formatted(), label: "total words")
            StatRow(value: "\(Int(summary.avgWPM))", label: "wpm")
            StatRow(value: "\(streakDays)", label: "day streak")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispCard()
        .frame(width: 240)
    }

    private var totalWords: Int {
        transcriptions.reduce(0) { $0 + $1.text.split { $0 == " " || $0 == "\n" }.count }
    }

    private var streakDays: Int {
        let cal = Calendar.current
        let days = Set(transcriptions.map { cal.startOfDay(for: $0.createdAt) })
        var streak = 0
        var day = cal.startOfDay(for: Date())
        while days.contains(day) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return streak
    }

    // MARK: - Recent

    private var liveText: some View {
        Text(controller.liveText)
            .textSelection(.enabled)
            .font(.system(size: 14))
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wispCard(padding: 16)
            .transition(.opacity)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 4)
            if transcriptions.isEmpty {
                Text("No transcriptions yet — press \(hotkeyBadge) and start talking.")
                    .font(.callout).foregroundStyle(Theme.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(transcriptions.prefix(6).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    HistoryRowLine(date: item.createdAt, text: item.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispCard()
        .animation(.default, value: transcriptions.count)
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TRANSCRIBE FILES")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button {
                    pickFiles()
                } label: {
                    Label("Add File", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }

            // Drop zone — uses onDrop with NSItemProvider to reliably receive Finder files.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? AnyShapeStyle(Theme.accent)
                                             : AnyShapeStyle(Theme.secondaryText.opacity(0.4)))
                .frame(height: 52)
                .background(dropTargeted ? AnyShapeStyle(Theme.accentSoft) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 14))
                        Text(dropTargeted ? "Release to transcribe" : "Drop audio files here")
                            .font(.callout)
                    }
                    .foregroundStyle(dropTargeted ? Theme.accent : Theme.secondaryText)
                }
                .scaleEffect(dropTargeted ? 1.02 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dropTargeted)
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadURLs(from: providers)
                    return true
                }

            if !fileQueue.jobs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(fileQueue.jobs) { job in
                        if job.id != fileQueue.jobs.first?.id { Divider().overlay(Theme.hairline) }
                        FileJobRow(job: job)
                    }
                }
                .wispCard(padding: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: fileQueue.jobs.map(\.id))
    }

    /// Opens a system file picker for audio files.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if panel.runModal() == .OK { fileQueue.enqueue(panel.urls) }
    }

    /// Extracts file URLs from NSItemProviders (the drop payload from Finder).
    private func loadURLs(from providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.fileQueue.enqueue([url]) }
            }
        }
    }

    // MARK: - Accessibility banner

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility is off").font(.headline).foregroundStyle(Theme.primaryText)
                Text("whisp can't insert text into other apps until you enable it for whisp.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .pointingCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private var recordLabel: String {
        switch controller.state {
        case .recording:    "Stop"
        case .preparing:    "Preparing…"
        case .transcribing: "Transcribing…"
        case .injecting:    "Inserting…"
        default:            "Start Dictation"
        }
    }

    private var recordIcon: String {
        controller.state == .recording ? "stop.fill" : "mic.fill"
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct FileJobRow: View {
    let job: TranscriptionJob
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                Text(job.url.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)

                Spacer()

                switch job.state {
                case .queued:
                    Text("Queued")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                case .running:
                    ProgressView().controlSize(.small)
                case .done(let text):
                    HStack(spacing: 8) {
                        Button { expanded.toggle() } label: {
                            Text(expanded ? "Hide" : "Show")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain).pointingCursor()

                        Button { copy(text) } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain).pointingCursor()
                        .help("Copy text")
                    }
                case .failed:
                    Text("Failed")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            if expanded, case .done(let text) = job.state {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    private var iconName: String {
        switch job.state {
        case .queued:  "clock"
        case .running: "waveform"
        case .done:    "checkmark.circle.fill"
        case .failed:  "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .queued:  Theme.secondaryText
        case .running: Theme.accent
        case .done:    .green
        case .failed:  .red
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct StatRow: View {
    let value: String
    let label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText())
            Text(LocalizedStringKey(label))
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct HistoryRowLine: View {
    let date: Date
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 74, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                Button { copy() } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .pointingCursor()
                .transition(.opacity)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
