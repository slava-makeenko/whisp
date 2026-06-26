import SwiftUI
import SwiftData
import AppKit
import ApplicationServices
import WhispCore
import WhispInput
import WhispPlatform

struct DashboardView: View {
    @Environment(DictationController.self) private var controller
    @Environment(FileQueueModel.self) private var fileQueue
    @Query(sort: \SessionMetric.date, order: .reverse) private var metrics: [SessionMetric]
    @Query(sort: \Transcription.createdAt, order: .reverse) private var transcriptions: [Transcription]

    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    @AppStorage("recentCollapsed") private var recentCollapsed = false
    @AppStorage("enhancementProvider") private var enhancementProviderID = "openai"
    @AppStorage("forceLocalEnhancement") private var forceLocalEnhancement = false

    @State private var dropTargeted = false
    @State private var recordHovering = false
    @State private var heroPulse = false
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var cloudKeyConfigured = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: MetricsSummary { MetricsSummary.from(metrics) }
    private var totalWords: Int {
        transcriptions.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                greetingRow
                if !axTrusted { accessibilityBanner }

                HStack(alignment: .top, spacing: 20) {
                    // Main column
                    VStack(spacing: 16) {
                        heroCard
                        if controller.state != .idle || !controller.liveText.isEmpty || controller.lastInjection != nil {
                            liveCard
                        }
                        filesCard
                        recentSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    // Right rail
                    VStack(spacing: 16) {
                        statsPanel
                        enhancementCard
                    }
                    .frame(width: 268)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
        .onAppear { heroPulse = true; refreshCloudKey() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
            refreshCloudKey()
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: controller.state)
    }

    // MARK: - Greeting

    private var greetingRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Hey \(firstName), get back into the flow with")
                .font(.geist(size: 22, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(Array(hotkeyKeycaps.enumerated()), id: \.offset) { idx, cap in
                    if idx > 0 {
                        Text("+").font(.geist(size: 13, weight: .medium)).foregroundStyle(Theme.mutedText)
                    }
                    HotkeyChip(label: cap)
                }
            }

            Spacer(minLength: 12)

            recordButton
            themeToggle
        }
    }

    private var recordButton: some View {
        Button(action: controller.toggle) {
            ZStack {
                Circle()
                    .fill(controller.state == .recording
                          ? AnyShapeStyle(LinearGradient(colors: [.red, Color(red: 0.8, green: 0.1, blue: 0.2)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Theme.accent))
                    .frame(width: 38, height: 38)
                    .shadow(color: (controller.state == .recording ? Color.red : Theme.accent).opacity(0.35),
                            radius: 8, x: 0, y: 4)
                if controller.state == .recording {
                    WaveformView(level: controller.level, tint: .white, barCount: 5,
                                 maxBarHeight: 12, barWidth: 2, spacing: 1.5)
                        .frame(width: 18, height: 12)
                } else {
                    Image(systemName: controller.state == .transcribing ? "waveform" : "mic.fill")
                        .font(.geist(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.state == .transcribing || controller.state == .injecting)
        .scaleEffect(reduceMotion ? 1 : (recordHovering ? 1.08 : 1))
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: recordHovering)
        .onHover { h in recordHovering = h; if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
        .help(controller.state == .recording ? "Stop dictation" : "Start dictation")
    }

    private var themeToggle: some View {
        Button {
            // Cycle through all three states so "follow system" stays reachable.
            colorSchemeRaw = switch colorSchemeRaw {
            case "light": "dark"
            case "dark":  "system"
            default:      "light"
            }
        } label: {
            Image(systemName: themeIcon)
                .font(.geist(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 38, height: 38)
                .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).stroke(Theme.hairline))
                .fdShadowSm()
        }
        .buttonStyle(.plain).pointingCursor()
        .help(themeHelp)
    }

    private var themeIcon: String {
        switch colorSchemeRaw {
        case "light": "sun.max"
        case "dark":  "moon"
        default:      "circle.lefthalf.filled"   // follow system
        }
    }

    private var themeHelp: LocalizedStringKey {
        switch colorSchemeRaw {
        case "light": "Appearance: Light (click for Dark)"
        case "dark":  "Appearance: Dark (click for System)"
        default:      "Appearance: System (click for Light)"
        }
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    private var enhancementProvider: EnhancementProvider { EnhancementProvider(rawValue: enhancementProviderID) ?? .openAI }

    /// Whether the active enhancement provider has an API key — drives the dashboard "Local vs Cloud"
    /// status. Refreshed on appear and on app activation (e.g. returning from Settings).
    private func refreshCloudKey() {
        let key = (try? KeychainSecretStore().get(enhancementProvider.secretKey)) ?? nil
        cloudKeyConfigured = !(key ?? "").isEmpty
    }

    /// Hotkey rendered as individual keycaps (modifiers then key).
    private var hotkeyKeycaps: [String] {
        let mods = HotkeyModifiers(rawValue: hotkeyModifiers)
        var caps: [String] = []
        if hotkeyKeyCode < 0 {
            // Modifier-only (double-tap) hotkey
            if mods.contains(.fn)      { caps.append("fn") }
            if mods.contains(.command) { caps.append("⌘") }
            if mods.contains(.option)  { caps.append("⌥") }
            if mods.contains(.control) { caps.append("⌃") }
            return caps.isEmpty ? ["⌥", "Space"] : caps
        }
        if mods.contains(.control) { caps.append("⌃") }
        if mods.contains(.option)  { caps.append("⌥") }
        if mods.contains(.command) { caps.append("⌘") }
        caps.append(hotkeyKeyCode == 49 ? "Space" : "·")
        return caps
    }

    private var hotkeyInline: String { hotkeyKeycaps.joined(separator: " ") }

    // MARK: - Hero

    private var heroCard: some View {
        Button {
            NotificationCenter.default.post(name: .whispOpenPowerMode, object: nil)
        } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make whisp sound like you")
                        .font(.geist(size: 26, weight: .semibold))
                        .kerning(-0.4)
                        .foregroundStyle(.white)
                    Text("Set up different writing styles for different apps.")
                        .font(.geist(size: 14))
                        .foregroundStyle(.white.opacity(0.72))

                    HStack(spacing: 7) {
                        ZStack {
                            Circle().fill(Color(Fluid.peach300)).frame(width: 7, height: 7)
                            Circle().stroke(Color(Fluid.peach300).opacity(0.6), lineWidth: 2)
                                .frame(width: 7, height: 7)
                                .scaleEffect(heroPulse && !reduceMotion ? 2.4 : 1)
                                .opacity(heroPulse && !reduceMotion ? 0 : 0.8)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: false),
                                           value: heroPulse)
                        }
                        Text("Start now")
                            .font(.geist(size: 13, weight: .semibold))
                            .foregroundStyle(Color(Fluid.ink))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.gradDusk, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .fdShadowLg()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(HeroButtonStyle())
        .pointingCursor()
    }

    // MARK: - Live recording feedback

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.state != .idle {
                HStack(spacing: 10) {
                    if let start = controller.recordingStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text(Self.elapsed(from: start, to: ctx.date))
                                .font(.geistMono(size: 15, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                    }
                    statusBadge
                    Spacer()
                    if controller.state == .recording {
                        WaveformView(level: controller.level, tint: Theme.accent, barCount: 9, maxBarHeight: 18)
                            .frame(width: 64, height: 18)
                    }
                }
            }
            if !controller.liveText.isEmpty {
                Text(controller.liveText)
                    .textSelection(.enabled)
                    .font(.geist(size: 14))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Post-dictation outcome — surfaces the clipboard-fallback hint when AX can't auto-insert.
            if controller.state == .idle, let outcome = controller.lastInjection {
                injectionStatus(outcome)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispCard(padding: 16)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder private func injectionStatus(_ outcome: InjectionOutcome) -> some View {
        switch outcome {
        case .inserted(let app):
            Label(app.map { "Inserted into \($0)" } ?? "Inserted", systemImage: "checkmark.circle.fill")
                .font(.geist(size: 12, weight: .medium)).foregroundStyle(.green)
        case .copiedToClipboard:
            Label("Copied — enable Accessibility to auto-insert", systemImage: "doc.on.clipboard")
                .font(.geist(size: 12, weight: .medium)).foregroundStyle(.orange)
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch controller.state {
        case .idle:         ("Ready", .green)
        case .preparing:    ("Preparing…", Theme.accent)
        case .recording:    (controller.isSpeaking ? "Listening…" : "Recording…", .red)
        case .transcribing: ("Transcribing…", Theme.accent)
        case .injecting:    ("Inserting…", Theme.accent)
        case .error(let m): (m, .orange)
        }
        return Label(LocalizedStringKey(text), systemImage: "circle.fill")
            .font(.geist(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .contentTransition(.opacity)
    }

    // MARK: - Transcribe Files

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transcribe Files")
                    .font(.geist(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                GlassPillButton(title: "Add File", systemImage: "plus") { pickFiles() }
            }

            // Compact dropzone — smaller, especially while jobs are listed below.
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.geist(size: 16))
                    .foregroundStyle(dropTargeted ? Theme.accent : Color(Fluid.clay300))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drag and drop a file here")
                        .font(.geist(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Audio (.mp3, .wav, .m4a…) and video (.mp4, .mov…)")
                        .font(.geist(size: 11))
                        .foregroundStyle(Theme.mutedText)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(dropTargeted ? Theme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.accent : Color(Fluid.clay300).opacity(0.7),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .scaleEffect(dropTargeted ? 1.01 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dropTargeted)

            if !fileQueue.jobs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(fileQueue.jobs.enumerated()), id: \.element.id) { idx, job in
                        if idx > 0 { Divider().overlay(Theme.hairline) }
                        jobRow(job)
                    }
                }
            }
        }
        .wispCard(padding: 20)
        .contentShape(Rectangle())
        // Drop anywhere on the card, not just the compact strip — a small strip is an easy miss.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(from: providers); return true
        }
        .animation(.default, value: fileQueue.jobs)
    }

    @ViewBuilder private func jobRow(_ job: TranscriptionJob) -> some View {
        let isDone = { if case .done = job.state { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isDone {
                    // Finished: the name becomes a link straight to its saved transcription.
                    Button { openSavedTranscription(job) } label: {
                        HStack(spacing: 5) {
                            Text(job.url.lastPathComponent)
                                .font(.geist(size: 13, weight: .medium)).lineLimit(1)
                            Image(systemName: "arrow.up.forward").font(.geist(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain).pointingCursor().help("Open transcription")
                } else {
                    Text(job.url.lastPathComponent)
                        .font(.geist(size: 13, weight: .medium))
                        .lineLimit(1).foregroundStyle(Theme.primaryText)
                }
                Spacer()
                jobBadge(job.state)
                if isDone {
                    Button { fileQueue.remove(job.id) } label: { Image(systemName: "xmark").font(.geist(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor().help("Dismiss")
                }
            }
            if case .running(let progress) = job.state {
                ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent)
            }
            if case .failed(let error) = job.state {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.geist(size: 11)).foregroundStyle(.red.opacity(0.85)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { fileQueue.retry(job.id) }
                        .font(.geist(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                        .buttonStyle(.plain).pointingCursor()
                    Button { fileQueue.remove(job.id) } label: { Image(systemName: "xmark").font(.geist(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                }
            }
        }
        .padding(.vertical, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Recent (grouped by date)

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { recentCollapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Recent")
                            .font(.geist(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Image(systemName: "chevron.down")
                            .font(.geist(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .rotationEffect(.degrees(recentCollapsed ? -90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingCursor()
                .help(recentCollapsed ? "Show recent" : "Hide recent")
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .whispOpenHistory, object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Text("View all").font(.geist(size: 13, weight: .medium))
                        Image(systemName: "arrow.right").font(.geist(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).pointingCursor()
            }
            .padding(.bottom, 4)

            if !recentCollapsed {
                if transcriptions.isEmpty {
                    Text("No transcriptions yet — press \(hotkeyInline) and start talking.")
                        .font(.geist(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                } else {
                    ForEach(groupedRecent, id: \.key) { group in
                        DateOverline(text: group.label)
                            .padding(.top, 10).padding(.bottom, 2)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                if idx > 0 { Divider().overlay(Theme.hairline) }
                                RecentRow(date: item.createdAt, text: item.text)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: transcriptions.count)
    }

    private struct RecentGroup { let key: Date; let label: String; let items: [Transcription] }

    private var groupedRecent: [RecentGroup] {
        let cal = Calendar.current
        let recent = Array(transcriptions.prefix(3))
        let grouped = Dictionary(grouping: recent) { cal.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            RecentGroup(key: day, label: Self.overlineFormatter.string(from: day),
                        items: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt })
        }
    }

    // MARK: - Right rail: stats

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                StatFigure(value: totalWords.formatted(), unit: "total words", size: 30)
                StatFigure(value: "\(Int(summary.avgWPM))", unit: "wpm", size: 22)
                weekStreakRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispCard(padding: 20)
    }

    // MARK: - Week streak

    private struct DayDot: Identifiable {
        let id: Int
        let label: String
        let isUsed: Bool
        let isToday: Bool
        let isFuture: Bool
    }

    /// Mon→Sun dots for the current week: filled when dictated that day; today is
    /// ringed-but-empty until it's used.
    private var weekDots: [DayDot] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)   // Sun=1 … Sat=7
        let sinceMonday = (weekday + 5) % 7                  // Mon=0 … Sun=6
        let monday = cal.date(byAdding: .day, value: -sinceMonday, to: today) ?? today
        let used = Set(transcriptions.map { cal.startOfDay(for: $0.createdAt) })
        let labels = ["M", "T", "W", "T", "F", "S", "S"]     // Monday-first
        return (0..<7).map { i in
            let day = cal.date(byAdding: .day, value: i, to: monday) ?? monday
            return DayDot(id: i, label: labels[i],
                          isUsed: used.contains(day),
                          isToday: day == today,
                          isFuture: day > today)
        }
    }

    private var weekStreakRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("this week")
                .font(.geist(size: 12))
                .foregroundStyle(Theme.mutedText)
            HStack(spacing: 0) {
                ForEach(weekDots) { dot in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(dot.isUsed ? Theme.accent : Color.clear)
                                .overlay(
                                    Circle().strokeBorder(
                                        dot.isToday ? Theme.accent : Theme.hairlineStrong,
                                        lineWidth: dot.isToday && !dot.isUsed ? 2 : 1))
                                .frame(width: 22, height: 22)
                            if dot.isUsed {
                                Image(systemName: "checkmark")
                                    .font(.geist(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .opacity(dot.isFuture ? 0.4 : 1)
                        Text(dot.label)
                            .font(.geistMono(size: 10, weight: dot.isToday ? .semibold : .regular))
                            .foregroundStyle(dot.isToday ? Theme.primaryText : Theme.mutedText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Enhancement status

    /// Cloud actually runs only when a key is connected AND the user hasn't forced Local.
    private var effectiveCloud: Bool { !forceLocalEnhancement && cloudKeyConfigured }

    /// Lets the user switch which tool processes their dictation — on-device cleanup (Local) or the
    /// configured cloud provider (Cloud) — not just see it.
    private var enhancementCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: effectiveCloud ? "cloud.fill" : "cpu")
                    .font(.geist(size: 13)).foregroundStyle(effectiveCloud ? .green : Theme.accent)
                Text("Enhancement")
                    .font(.geist(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Spacer()
                Circle().fill(effectiveCloud ? .green : Theme.mutedText.opacity(0.5)).frame(width: 7, height: 7)
            }

            HStack(spacing: 3) {
                enhancementTab("Local", active: forceLocalEnhancement) { forceLocalEnhancement = true }
                enhancementTab("Cloud", active: !forceLocalEnhancement) { forceLocalEnhancement = false }
            }
            .padding(3)
            .background(Theme.groupBG, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

            if forceLocalEnhancement {
                Text("On-device cleanup.")
                    .font(.geist(size: 11)).foregroundStyle(Theme.mutedText)
            } else if cloudKeyConfigured {
                Text("\(enhancementProvider.displayName) · connected")
                    .font(.geist(size: 11)).foregroundStyle(Theme.secondaryText)
            } else {
                Button {
                    NotificationCenter.default.post(name: .whispOpenSettings, object: nil)
                } label: {
                    Text("No key — add one in Settings → AI")
                        .font(.geist(size: 11)).foregroundStyle(.orange)
                }
                .buttonStyle(.plain).pointingCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispCard(padding: 16)
    }

    private func enhancementTab(_ title: LocalizedStringKey, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.geist(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.primaryText : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(active ? Theme.cardBG : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).stroke(Theme.hairline)
                    }
                }
        }
        .buttonStyle(.plain).pointingCursor()
    }

    // MARK: - Accessibility banner

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility is off")
                    .font(.geist(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text("whisp can't insert text into other apps until you enable it.")
                    .font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }.pointingCursor()
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).stroke(.orange.opacity(0.25)))
    }

    // MARK: - Helpers

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let overlineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie, .video, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK { fileQueue.enqueue(panel.urls) }
    }

    /// Opens the Files tab on the transcription saved for this finished job.
    private func openSavedTranscription(_ job: TranscriptionJob) {
        NotificationCenter.default.post(name: .whispOpenFiles, object: fileQueue.recordID(for: job.id))
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
        case .queued:           Text("Queued").font(.geist(size: 11)).foregroundStyle(Theme.mutedText)
        case .running(let p):   Text("\(Int(p * 100))%").font(.geistMono(size: 11)).foregroundStyle(Theme.accent)
        case .done:             Label("Done", systemImage: "checkmark.circle.fill").font(.geist(size: 11)).foregroundStyle(.green)
        case .failed:           Label("Failed", systemImage: "xmark.circle.fill").font(.geist(size: 11)).foregroundStyle(.red)
        }
    }
}

// MARK: - Sub-views

/// Slight press-scale for the hero card.
private struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct RecentRow: View {
    let date: Date
    let text: String
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(date, format: .dateTime.hour().minute())
                .font(.geistMono(size: 12))
                .foregroundStyle(Theme.mutedText)
                .frame(width: 62, alignment: .leading)

            Text(text)
                .font(.geist(size: 14))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                Button { copy() } label: {
                    Image(systemName: "doc.on.doc").font(.geist(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).pointingCursor()
                .transition(.opacity)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(hovering ? Theme.selection : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
