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
    @Environment(LocalModelStore.self) private var store
    @Query(sort: \SessionMetric.date, order: .reverse) private var metrics: [SessionMetric]
    @Query(sort: \Transcription.createdAt, order: .reverse) private var transcriptions: [Transcription]

    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("enhancementStyle") private var enhancementStyle = "auto"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    @AppStorage("dictationLanguages") private var dictationLanguages = "en-US"

    @State private var dropTargeted = false
    @State private var recordHovering = false
    @State private var axTrusted = AXIsProcessTrusted()

    private var summary: MetricsSummary { MetricsSummary.from(metrics) }
    private var todaySessions: Int {
        let cal = Calendar.current
        return transcriptions.filter { cal.isDateInToday($0.createdAt) }.count
    }
    private var totalWords: Int {
        transcriptions.reduce(0) { $0 + $1.text.split { $0 == " " || $0 == "\n" }.count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                if !axTrusted { accessibilityBanner }
                topCards
                if !controller.liveText.isEmpty { liveTextView }
                recentSection
                filesSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Text("Hey \(firstName), get back into the flow with")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                HotkeyChip(label: hotkeyBadge)
            }
            Spacer()
            Button {
                colorSchemeRaw = colorSchemeRaw == "dark" ? "light" : "dark"
            } label: {
                Image(systemName: colorSchemeRaw == "dark" ? "sun.max" : "moon")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain).pointingCursor()
        }
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
            return "fn"
        }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.command) { s += "⌘" }
        s += hotkeyKeyCode == 49 ? "Space" : "·"
        return s
    }

    // MARK: - Top 3 cards

    private var topCards: some View {
        HStack(alignment: .top, spacing: 14) {
            recordCard
            statsCard
            aiCard
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Record card

    private var recordCard: some View {
        VStack(spacing: 0) {
            if let start = controller.recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Text(Self.elapsed(from: start, to: ctx.date))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.red)
                }
                .padding(.bottom, 8)
            }

            // Circular mic button
            Button(action: controller.toggle) {
                ZStack {
                    Circle()
                        .fill(
                            controller.state == .recording
                            ? LinearGradient(colors: [.red, Color(red: 0.8, green: 0.1, blue: 0.2)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: (controller.state == .recording ? Color.red : Theme.accent).opacity(0.35),
                                radius: 12, x: 0, y: 6)
                    if controller.state == .recording {
                        WaveformView(level: controller.level, tint: .white, barCount: 7)
                            .frame(width: 36, height: 20)
                    } else {
                        Image(systemName: controller.state == .transcribing ? "waveform" : "mic.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.state == .transcribing || controller.state == .injecting)
            .scaleEffect(recordHovering ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: recordHovering)
            .onHover { h in recordHovering = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .padding(.bottom, 10)

            Text(LocalizedStringKey(recordLabel))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("Press \(hotkeyBadge) to dictate")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 2)

            if let outcome = controller.lastInjection, controller.state == .idle {
                injectionStatus(outcome).padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: controller.state)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch controller.state {
        case .idle:               ("Ready", .green)
        case .preparing:          ("Preparing…", Theme.accent)
        case .recording:          (controller.isSpeaking ? "Listening…" : "Recording…", .red)
        case .transcribing:       ("Transcribing…", Theme.accent)
        case .injecting:          ("Inserting…", Theme.accent)
        case .error(let m):       (m, .orange)
        }
        return Label(LocalizedStringKey(text), systemImage: "circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .contentTransition(.opacity)
    }

    private var currentMode: EnhancementStyle { EnhancementStyle(rawValue: enhancementStyle) ?? .auto }

    private var modePill: some View {
        Menu {
            ForEach(EnhancementStyle.allCases) { style in
                Toggle(LocalizedStringKey(style.name), isOn: Binding(
                    get: { enhancementStyle == style.rawValue },
                    set: { if $0 { enhancementStyle = style.rawValue } }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(currentMode.name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointingCursor()
    }

    private var recordLabel: String {
        switch controller.state {
        case .recording:    "Stop"
        case .preparing:    "Preparing…"
        case .transcribing: "Transcribing…"
        case .injecting:    "Inserting…"
        default:            "Start dictation"
        }
    }

    private var recordIcon: String {
        controller.state == .recording ? "stop.fill" : "mic.fill"
    }

    @ViewBuilder private func injectionStatus(_ outcome: InjectionOutcome) -> some View {
        switch outcome {
        case .inserted(let app):
            Label { if let app { Text("Inserted into \(app)") } else { Text("Inserted") } }
                icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green).font(.caption)
        case .copiedToClipboard:
            Label("Copied — enable Accessibility to auto-insert", systemImage: "doc.on.clipboard")
                .foregroundStyle(.orange).font(.caption)
        }
    }

    // MARK: - Stats card (2x2 grid)

    private var statsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                StatCell(icon: "doc.text", value: totalWords.formatted(), label: "total words")
                Divider().overlay(Theme.hairline)
                StatCell(icon: "speedometer", value: "\(Int(summary.avgWPM))", label: "wpm")
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                StatCell(icon: "flame", value: "\(streakDays)", label: "day streak")
                Divider().overlay(Theme.hairline)
                StatCell(icon: "chart.line.uptrend.xyaxis", value: "\(todaySessions)", label: "sessions today")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
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

    // MARK: - AI card

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Icon
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: "cpu")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
            }

            // Title
            VStack(alignment: .leading, spacing: 2) {
                if let model = store.activeModel {
                    HStack(spacing: 6) {
                        Text("On-device AI").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                        Text("·").foregroundStyle(Theme.secondaryText)
                        Text(model.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    }
                    Text("Running locally and privately")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Label("Active", systemImage: "circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                } else {
                    Text("On-device AI")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                    Text("No model downloaded")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Text("Go to Settings → AI to download a model")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .padding(.top, 2)
                }
            }

            if store.activeModel != nil {
                Divider().overlay(Theme.hairline)
                // Language — tappable menu
                HStack {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 16)
                    Text("Language").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Menu {
                        ForEach(DictationLanguage.all) { lang in
                            Toggle(lang.name, isOn: Binding(
                                get: { DictationLanguage.selectedIDs(dictationLanguages).contains(lang.id) },
                                set: { _ in dictationLanguages = DictationLanguage.toggle(lang.id, in: dictationLanguages) }))
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(DictationLanguage.compactSummary(dictationLanguages))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().pointingCursor()
                }

                // Mode — tappable menu
                HStack {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 16)
                    Text("Mode").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Menu {
                        ForEach(EnhancementStyle.allCases) { style in
                            Toggle(LocalizedStringKey(style.name), isOn: Binding(
                                get: { enhancementStyle == style.rawValue },
                                set: { if $0 { enhancementStyle = style.rawValue } }))
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(LocalizedStringKey(currentMode.name))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().pointingCursor()
                }

                AIInfoRow(icon: "lock.shield", label: "Privacy", value: "Local")
            }

            // Download progress if any
            ForEach(OnDeviceModel.catalog) { model in
                if case .downloading(let p) = store.states[model.id] ?? .notDownloaded {
                    VStack(alignment: .leading, spacing: 4) {
                        Divider().overlay(Theme.hairline)
                        Text("Downloading \(model.displayName)")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent)
                        Text("\(Int(p * 100))%").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
    }

    // MARK: - Live text

    private var liveTextView: some View {
        Text(controller.liveText)
            .textSelection(.enabled)
            .font(.system(size: 14))
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wispCard(padding: 14)
            .transition(.opacity)
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Recent", systemImage: "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .whispOpenHistory, object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Text("View all history")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.accent)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(.plain).pointingCursor()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Divider().overlay(Theme.hairline)

            if transcriptions.isEmpty {
                Text("No transcriptions yet — press \(hotkeyBadge) and start talking.")
                    .font(.callout).foregroundStyle(Theme.secondaryText)
                    .padding(16)
            } else {
                ForEach(Array(transcriptions.prefix(6).enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider().overlay(Theme.hairline) }
                    RecentRowNew(date: item.createdAt, text: item.text)
                }
            }
        }
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .animation(.default, value: transcriptions.count)
    }

    // MARK: - Files

    private var filesSection: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Transcribe Files", systemImage: "doc.waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button { pickFiles() } label: {
                    Label("Add File", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).pointingCursor()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Divider().overlay(Theme.hairline)

            // Drop zone
            VStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 28))
                    .foregroundStyle(dropTargeted ? Theme.accent : Theme.secondaryText.opacity(0.5))
                Text("Drag and drop audio files here")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Text("Supports .mp3, .wav, .m4a and more")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(dropTargeted ? Theme.accentSoft : .clear)
            .scaleEffect(dropTargeted ? 1.01 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dropTargeted)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadURLs(from: providers); return true
            }

            if !fileQueue.jobs.isEmpty {
                Divider().overlay(Theme.hairline)
                ForEach(fileQueue.jobs) { job in
                    HStack {
                        Text(job.url.lastPathComponent).lineLimit(1).foregroundStyle(Theme.primaryText)
                        Spacer()
                        jobBadge(job.state)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .animation(.default, value: fileQueue.jobs)
    }

    // MARK: - Accessibility banner

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility is off").font(.headline).foregroundStyle(Theme.primaryText)
                Text("whisp can't insert text into other apps until you enable it.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }.pointingCursor()
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if panel.runModal() == .OK { fileQueue.enqueue(panel.urls) }
    }

    private func loadURLs(from providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.fileQueue.enqueue([url]) }
            }
        }
    }

    @ViewBuilder private func jobBadge(_ state: TranscriptionJob.State) -> some View {
        switch state {
        case .queued:       Text("Queued").foregroundStyle(Theme.secondaryText)
        case .running:      ProgressView().controlSize(.small)
        case .done:         Text("Done").foregroundStyle(.green)
        case .failed:       Text("Failed").foregroundStyle(.red)
        }
    }
}

// MARK: - Sub-views

private struct StatCell: View {
    let icon: String
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText())
            Text(LocalizedStringKey(label))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

private struct AIInfoRow: View {
    let icon: String
    let label: String
    let value: String
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primaryText)
        }
    }
}

private struct RecentRowNew: View {
    let date: Date
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)

            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, alignment: .leading)

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                Button { copy() } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                .transition(.opacity)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText.opacity(0.5))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
