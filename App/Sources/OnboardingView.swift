import SwiftUI
import WhispCore
import WhispPlatform

/// Multi-step onboarding: welcome → permissions (+ live mic check) → a feature tour (Conference,
/// Files) that shows where each lives in the sidebar. Follows the app's light/dark theme.
struct OnboardingView: View {
    @Environment(OnboardingModel.self) private var onboarding
    let onContinue: () -> Void

    @State private var page = 0
    @State private var micLevel = MicLevelMonitor()
    private let lastPage = 3

    var body: some View {
        ZStack {
            Theme.windowBG.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch page {
                    case 0: welcomePage
                    case 1: permissionsPage
                    case 2: conferencePage
                    default: filesPage
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                footer
            }
            .padding(40)
        }
        .frame(minWidth: 640, minHeight: 640)
        .task { await onboarding.refresh() }
        .onChange(of: page) { _, new in
            if new == 1 { micLevel.start() } else { micLevel.stop() }
        }
        .onDisappear { micLevel.stop() }
        .animation(.easeInOut(duration: 0.28), value: page)
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Image("MenuBarIcon").resizable().renderingMode(.template)
                .frame(width: 52, height: 52).foregroundStyle(Theme.primaryText)
            Text("Welcome to whisp")
                .font(.geist(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(Theme.primaryText)
            Text("Dictate anywhere, and record & transcribe meetings, audio and video — privately, on your Mac.")
                .font(.geist(size: 17)).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 18) {
            pageTitle("Grant access", "whisp needs a few permissions to hear you and type for you.")
            VStack(spacing: 10) {
                ForEach(onboarding.steps) { stepRow($0) }
            }
            micCheck
        }
    }

    private var conferencePage: some View {
        featurePage(
            icon: "person.2.wave.2", title: "Record meetings",
            subtitle: "Press your Conference hotkey to capture your mic **and** the system audio of any call — Meet, Zoom, Telemost. On stop, whisp transcribes it and can tell participants apart.",
            highlight: "Conference",
            bullets: ["No bot joins the call — it records locally",
                      "Speaker modes in Settings → Audio: Mono · Duo · Speakers",
                      "Find recordings + transcripts in the Conference tab"])
    }

    private var filesPage: some View {
        featurePage(
            icon: "doc.text", title: "Transcribe audio & video",
            subtitle: "Drag an audio or video file onto the **Transcribe Files** card on Home — whisp extracts the audio, transcribes it with a live progress bar, and saves it to Files.",
            highlight: "Files",
            bullets: ["Audio (.mp3 .wav .m4a…) and video (.mp4 .mov…)",
                      "Rename, open the original, or delete — per transcription",
                      "Everything lands in the Files tab"])
    }

    // MARK: - Feature page scaffold

    private func featurePage(icon: String, title: String, subtitle: LocalizedStringKey,
                             highlight: String, bullets: [String]) -> some View {
        VStack(spacing: 20) {
            pageTitle(title, nil, icon: icon)
            HStack(alignment: .top, spacing: 22) {
                SidebarMock(highlight: highlight)
                VStack(alignment: .leading, spacing: 12) {
                    Text(subtitle)
                        .font(.geist(size: 14)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(bullets, id: \.self) { b in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.geist(size: 12)).foregroundStyle(Theme.accent)
                                Text(b).font(.geist(size: 13)).foregroundStyle(Theme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pageTitle(_ title: String, _ subtitle: String?, icon: String? = nil) -> some View {
        VStack(spacing: 10) {
            if let icon {
                ZStack {
                    Circle().fill(Theme.accentSoft).frame(width: 54, height: 54)
                    Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Theme.accent)
                }
            }
            Text(title).font(.geist(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(Theme.primaryText)
            if let subtitle {
                Text(subtitle).font(.geist(size: 15)).foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
        }
    }

    // MARK: - Permission row + mic check

    private func stepRow(_ step: OnboardingModel.Step) -> some View {
        HStack(spacing: 14) {
            Image(systemName: step.status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.status == .granted ? Color.green : Theme.mutedText)
                .font(.geist(size: 19, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).foregroundStyle(Theme.primaryText).font(.geist(size: 15, weight: .semibold))
                Text(step.detail).foregroundStyle(Theme.secondaryText).font(.geist(size: 11))
            }
            Spacer()
            if step.status != .granted {
                Button("Grant") { Task { await onboarding.request(step) } }
                Button("Settings") { onboarding.openSettings(step) }.buttonStyle(.link)
            }
        }
        .padding(14)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
    }

    private var micCheck: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill").font(.geist(size: 14)).foregroundStyle(Theme.secondaryText)
            Text("Mic check — say something").font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<14, id: \.self) { i in
                    let lit = micLevel.level >= Float(i + 1) / 14
                    Capsule()
                        .fill(lit ? (i > 11 ? Color.orange : Theme.accent) : Theme.primaryText.opacity(0.12))
                        .frame(width: 5, height: 16)
                }
            }
            .animation(.easeOut(duration: 0.08), value: micLevel.level)
        }
        .padding(14)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
    }

    // MARK: - Footer (dots + nav)

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(0...lastPage, id: \.self) { i in
                    Circle().fill(i == page ? Theme.accent : Theme.mutedText.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            HStack {
                Button("Back") { page -= 1 }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                    .opacity(page == 0 ? 0 : 1).disabled(page == 0)
                Spacer()
                if page == lastPage {
                    Button("Get Started", action: onContinue)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Continue") { page += 1 }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .frame(maxWidth: 460)
        }
    }
}

/// A small illustrative whisp sidebar with one row highlighted + a callout — shows the user where a
/// feature lives in the real UI.
private struct SidebarMock: View {
    let highlight: String
    private let rows: [(title: String, symbol: String)] = [
        ("Home", "house"), ("History", "clock"), ("Files", "doc.text"),
        ("Conference", "person.2.wave.2"), ("Power Mode", "bolt"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image("MenuBarIcon").resizable().renderingMode(.template).frame(width: 15, height: 15)
                Text("whisp").font(.geist(size: 14, weight: .bold))
            }
            .foregroundStyle(Theme.primaryText).padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 4)

            ForEach(rows, id: \.title) { row in
                let on = row.title == highlight
                HStack(spacing: 9) {
                    Image(systemName: row.symbol).font(.geist(size: 12))
                        .foregroundStyle(on ? Theme.accent : Theme.secondaryText).frame(width: 16)
                    Text(row.title).font(.geist(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.primaryText : Theme.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(on ? Theme.accentSoft : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(alignment: .leading) {
                    if on {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                            .frame(width: 3, height: 16).offset(x: -8)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 190)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
    }
}
