import SwiftUI
import AppKit
import Combine
import Observation
import WhispCore

/// A Dynamic-Island-style recording indicator (top-center, just under the menu bar), shown while
/// a dictation session is active. Floats above app windows, click-through, on every Space.
@MainActor
final class NotchRecorderController {
    private enum Mode: Equatable { case hidden, dictation, conference }

    private var panel: NSPanel?
    private weak var observed: DictationController?
    private weak var conference: ConferenceController?
    private var trackingGeneration = 0
    private var hostedMode: Mode = .hidden

    /// Drive the indicator straight off the controllers' state via Observation — independent of any
    /// window, so the pill keeps showing/animating even when whisp runs with its window closed.
    func observe(_ controller: DictationController) {
        observed = controller
        refresh()
        armTracking()
    }

    /// Conference Mode shares the pill; dictation takes priority if both are active at once.
    func observe(conference controller: ConferenceController) {
        conference = controller
        refresh()
        armTracking()
    }

    /// Re-arms one-shot Observation tracking on **both** controllers' state. The generation token
    /// makes stale registrations (armed before the second controller was attached) no-op instead of
    /// compounding — so a state change on *either* controller wakes the indicator. Without the
    /// re-arm, the conference controller (attached after dictation) was never tracked.
    private func armTracking() {
        trackingGeneration += 1
        let generation = trackingGeneration
        withObservationTracking {
            _ = observed?.state
            _ = conference?.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.trackingGeneration else { return }
                self.refresh()
                self.armTracking()
            }
        }
    }

    private func desiredMode() -> Mode {
        if let state = observed?.state {
            switch state {
            case .preparing, .recording, .transcribing, .injecting: return .dictation
            case .idle, .error: break
            }
        }
        if conference?.state == .recording {
            return .conference
        }
        return .hidden
    }

    private func refresh() {
        let mode = desiredMode()
        mode == .hidden ? hide() : show(mode)
    }

    // Fixed pill dimensions — must match the frame modifiers in NotchRecorderView.
    private let pillW: CGFloat = 96
    private let pillH: CGFloat = 36

    private func show(_ mode: Mode) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: pillW, height: pillH),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            // .screenSaver, not .statusBar: status-bar-level windows hide together with the menu bar
            // when an app goes fullscreen — the pill must stay visible over fullscreen/Stage Manager.
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.alphaValue = 0
            self.panel = panel
        }
        guard let panel else { return }
        // The hosting view is torn down on hide (stopping its render ticker) — rebuild it here, and
        // swap it when the active mode (dictation ↔ conference) changes.
        if panel.contentViewController == nil || hostedMode != mode {
            panel.contentViewController = makeHost(for: mode)
            hostedMode = mode
        }
        // Position using known constants — panel.frame.size is unreliable before first layout.
        position(panel)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // Re-position one run-loop tick later in case the window server moved it on first display.
        DispatchQueue.main.async { self.position(panel) }
    }

    private func makeHost(for mode: Mode) -> NSHostingController<AnyView> {
        let root: AnyView = mode == .conference
            ? AnyView(NotchConferenceView(controller: conference))
            : AnyView(NotchRecorderView(controller: observed))
        let hc = NSHostingController(rootView: root)
        // Lock the hosting controller to our pill size so it never resizes the panel before SwiftUI
        // has laid out (which would break the first-show position).
        hc.view.setFrameSize(NSSize(width: pillW, height: pillH))
        return hc
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new show() may have started mid-fade — only tear down if we stayed hidden.
            guard panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            // Release the hosting view so its 25fps ticker stops while the pill is hidden.
            panel.contentViewController = nil
            self?.hostedMode = .hidden
        })
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }
        let menuBar = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - pillW / 2,
                                     y: screen.frame.maxY - menuBar - pillH - 8))
    }
}

struct NotchRecorderView: View {
    // A plain main-runloop timer drives the animation clock. The view lives in a detached NSPanel
    // where @Observable updates don't reliably propagate, so each tick re-renders the equalizer
    // and samples the current microphone level from the controller.
    let controller: DictationController?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "mic.fill")
                    .font(.geist(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                EqualizerBars(time: now.timeIntervalSinceReferenceDate,
                              level: controller?.level ?? 1)
            }
        }
        .frame(width: 64, height: 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1))
        )
        .padding(2)
        .onReceive(ticker) { if !reduceMotion { now = $0 } }
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

/// Conference Mode pill — the same equalizer look as the dictation pill, with a leading meeting icon
/// so the two are distinguishable at a glance. Driven by the conference mic + system-audio mix level.
struct NotchConferenceView: View {
    let controller: ConferenceController?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Group {
                if reduceMotion {
                    Image(systemName: "mic.fill")
                        .font(.geist(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    EqualizerBars(time: now.timeIntervalSinceReferenceDate,
                                  level: controller?.level ?? 1)
                }
            }
            .frame(width: 48, height: 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.black)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1))
        )
        .padding(2)
        .onReceive(ticker) { if !reduceMotion { now = $0 } }
    }
}
