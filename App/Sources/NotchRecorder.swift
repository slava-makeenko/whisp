import SwiftUI
import AppKit
import Combine
import Observation
import WhispCore

/// A Dynamic-Island-style pill (top-center, just under the menu bar / notch). Created once at launch
/// and **always visible**: a small idle pill that morphs — with a spring — into the recording
/// indicator (equalizer) when dictation or Conference Mode starts. Floats above app windows and
/// fullscreen apps, click-through, on every Space.
@MainActor
final class NotchRecorderController {
    private var panel: NSPanel?
    /// A separate, **clickable** panel holding the mic-mute toggle. Shown just right of the pill only
    /// while a conference records (the always-on pill itself stays click-through).
    private var mutePanel: NSPanel?
    private let panelW: CGFloat = 130
    private let panelH: CGFloat = 40
    private let muteW: CGFloat = 36

    /// Builds the pill and shows it. Called once at launch with both controllers; the SwiftUI view
    /// polls their state itself, so there's no show/hide machinery to race.
    func attach(dictation: DictationController, conference: ConferenceController) {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // .screenSaver keeps the pill over fullscreen apps / Stage Manager (status-bar level hides
        // with the menu bar in fullscreen).
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingController(rootView: NotchPillView(dictation: dictation, conference: conference))
        host.view.setFrameSize(NSSize(width: panelW, height: panelH))
        panel.contentViewController = host
        self.panel = panel

        position(panel)
        panel.orderFrontRegardless()
        // Re-position one run-loop tick later in case the window server moved it on first display.
        DispatchQueue.main.async { self.position(panel) }

        // Interactive mute toggle that lives next to the pill during a conference recording.
        let mutePanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: muteW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        mutePanel.isFloatingPanel = true
        mutePanel.level = .screenSaver
        mutePanel.backgroundColor = .clear
        mutePanel.isOpaque = false
        mutePanel.hasShadow = false
        mutePanel.ignoresMouseEvents = false   // unlike the pill, this panel receives clicks
        mutePanel.hidesOnDeactivate = false
        mutePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let muteHost = NSHostingController(rootView: NotchMuteButton(conference: conference))
        muteHost.view.setFrameSize(NSSize(width: muteW, height: panelH))
        mutePanel.contentViewController = muteHost
        self.mutePanel = mutePanel
        observeConferenceState(conference)   // shows/hides the button as recording starts/stops

        // …and whenever displays / resolution change, re-place both.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.position(panel)
                if self.mutePanel?.isVisible == true { self.positionMute() }
            }
        }
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }
        let menuBar = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panelW / 2,
                                     y: screen.frame.maxY - menuBar - panelH))
    }

    /// Re-arms itself on every `conference.state` change and shows the mute button only while a
    /// conference records. Runs at the controller level (not in the detached SwiftUI view), so plain
    /// Observation is reliable here.
    private func observeConferenceState(_ conference: ConferenceController) {
        withObservationTracking {
            _ = conference.state
        } onChange: { [weak self, weak conference] in
            Task { @MainActor in
                guard let self, let conference else { return }
                self.setMuteButton(visible: conference.state == .recording)
                self.observeConferenceState(conference)   // re-arm for the next change
            }
        }
        setMuteButton(visible: conference.state == .recording)
    }

    private func setMuteButton(visible: Bool) {
        guard let mutePanel else { return }
        if visible {
            positionMute()
            mutePanel.orderFrontRegardless()
        } else {
            mutePanel.orderOut(nil)
        }
    }

    /// Just to the right of the recording pill (104 pt wide, centered under the notch).
    private func positionMute() {
        guard let mutePanel else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }
        let menuBar = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let pillHalfWidth: CGFloat = 52   // the conference pill is 104 pt wide
        mutePanel.setFrameOrigin(NSPoint(x: screen.frame.midX + pillHalfWidth + 6,
                                         y: screen.frame.maxY - menuBar - panelH))
    }
}

/// The always-on pill. Polls the controllers' state on a timer (the view lives in a detached panel
/// where @Observable updates don't reliably propagate) and morphs between a small idle pill and the
/// expanded recording indicator. Idle is static — no per-frame work — so it's cheap to keep up.
struct NotchPillView: View {
    let dictation: DictationController?
    let conference: ConferenceController?

    private enum Mode: Equatable { case idle, dictation, conference }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: Mode = .idle
    @State private var level: Float = 0
    @State private var micMuted = false
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: pillHeight / 2, style: .continuous)
                .fill(.black.opacity(mode == .idle ? 0.42 : 0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: pillHeight / 2, style: .continuous)
                        .stroke(.white.opacity(mode == .idle ? 0.45 : 0.12), lineWidth: 1))
            activeContent
                .opacity(mode == .idle ? 0 : 1)
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipShape(RoundedRectangle(cornerRadius: pillHeight / 2, style: .continuous))
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(ticker) { tick($0) }
    }

    @ViewBuilder private var activeContent: some View {
        HStack(spacing: 5) {
            if mode == .conference {
                // Muted → a red mic-slash so you can see at a glance your voice isn't being recorded
                // (the equalizer keeps moving because the system/other side is still captured).
                Image(systemName: micMuted ? "mic.slash.fill" : "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(micMuted ? Color.red : .white)
            }
            if reduceMotion {
                Image(systemName: "mic.fill").font(.geist(size: 13, weight: .semibold)).foregroundStyle(.white)
            } else {
                EqualizerBars(time: now.timeIntervalSinceReferenceDate, level: level)
                    .frame(width: mode == .conference ? 46 : 62, height: 18)
            }
        }
    }

    // Idle stays small; each active mode expands (conference is a touch wider for the icon).
    private var pillWidth: CGFloat { mode == .idle ? 46 : (mode == .conference ? 104 : 92) }
    private var pillHeight: CGFloat { mode == .idle ? 14 : 28 }

    private func tick(_ t: Date) {
        let next = currentMode()
        if next != mode {
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.7)) { mode = next }
        }
        guard next != .idle else { return }   // idle is static — skip the per-frame churn
        level = (next == .conference ? conference?.level : dictation?.level) ?? 0
        micMuted = (next == .conference) && (conference?.micMuted ?? false)
        if !reduceMotion { now = t }
    }

    private func currentMode() -> Mode {
        switch dictation?.state {
        case .preparing, .recording, .transcribing, .injecting: return .dictation   // dictation wins
        default: break
        }
        return conference?.state == .recording ? .conference : .idle
    }
}

/// The interactive mic-mute toggle that floats next to the pill while a conference records. Lives in
/// its own clickable panel; polls `micMuted` every tick so it also reflects a mute toggled elsewhere
/// (e.g. from the menu bar). Red mic-slash = your voice is dropped; the other side keeps recording.
private struct NotchMuteButton: View {
    let conference: ConferenceController
    @State private var muted = false
    private let ticker = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.92))
                    .overlay(Circle().stroke(.white.opacity(muted ? 0 : 0.14), lineWidth: 1))
                    .overlay(Circle().stroke(Color.red.opacity(muted ? 0.9 : 0), lineWidth: 1.5))
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(muted ? Color.red : .white)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .pointingCursor()
        .help(muted ? "Unmute microphone" : "Mute microphone")
        .padding(.top, 4)   // line up with the pill's top padding
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { muted = conference.micMuted }
        .onReceive(ticker) { _ in if conference.micMuted != muted { muted = conference.micMuted } }
    }

    private func tap() {
        conference.toggleMute()
        muted = conference.micMuted
    }
}

/// Centered white spectrum bars that grow up and down from the mid-line. A gentle baseline wave
/// keeps the pill alive even in silence; the live microphone RMS `level` drives the bars toward
/// the full pill height while speaking.
struct EqualizerBars: View {
    var time: TimeInterval
    var level: Float = 1
    var barCount: Int = 12

    var body: some View {
        // RMS is small — amplify and clamp so normal speech reaches the top of the range.
        let speech = min(CGFloat(level) * 10, 1)
        GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let base = sin(time * 7 + Double(index) * 0.8)
                    let detail = sin(time * 15 + Double(index) * 1.7) * 0.4
                    let phase = max(0, min(1, ((base + detail) / 1.4 + 1) / 2))   // 0...1
                    let idle = 0.16 + 0.20 * phase            // livelier baseline wave in silence
                    let live = 0.30 + 0.70 * phase            // full-height bounce while speaking
                    let frac = idle + (live - idle) * speech  // blend by the live mic level
                    Capsule()
                        .fill(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, h * frac))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
