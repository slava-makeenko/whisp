import SwiftUI
import AppKit
import Combine
import Observation
import WhispCore

/// A Dynamic-Island-style recording indicator (top-center, just under the menu bar), shown while
/// a dictation session is active. Floats above app windows, click-through, on every Space.
@MainActor
final class NotchRecorderController {
    private var panel: NSPanel?
    private weak var observed: DictationController?
    private var observing = false

    /// Drive the indicator straight off the controller's state via Observation — independent of any
    /// window, so the pill keeps showing/animating even when whisp runs with its window closed.
    func observe(_ controller: DictationController) {
        guard !observing else { return }
        observing = true
        observed = controller
        update(for: controller.state)
        armTracking()
    }

    private func armTracking() {
        guard let observed else { return }
        withObservationTracking {
            _ = observed.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let controller = self.observed else { return }
                self.update(for: controller.state)
                self.armTracking()
            }
        }
    }

    func update(for state: DictationController.State) {
        switch state {
        case .preparing, .recording, .transcribing, .injecting:
            show()
        case .idle, .error:
            hide()
        }
    }

    // Fixed pill dimensions — must match the frame modifiers in NotchRecorderView.
    private let pillW: CGFloat = 96
    private let pillH: CGFloat = 36

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: pillW, height: pillH),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let hc = NSHostingController(rootView: NotchRecorderView(controller: observed))
            // Lock the hosting controller to our pill size so it never causes the panel
            // to resize before SwiftUI has laid out (which would break the first-show position).
            hc.view.setFrameSize(NSSize(width: pillW, height: pillH))
            panel.contentViewController = hc
            self.panel = panel
        }
        // Position using known constants — panel.frame.size is unreliable before first layout.
        if let panel { position(panel) }
        panel?.orderFrontRegardless()
        // Re-position one run-loop tick later in case the window server moved it on first display.
        if let panel {
            DispatchQueue.main.async { self.position(panel) }
        }
    }

    private func hide() { panel?.orderOut(nil) }

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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                EqualizerBars(time: now.timeIntervalSinceReferenceDate,
                              level: controller?.level ?? 1)
            }
        }
        .frame(width: 64, height: 18)
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

/// Centered white spectrum bars. The bar shape is time-driven, but the amplitude tracks the live
/// microphone RMS `level` — silence flattens the bars, speech makes them bounce.
struct EqualizerBars: View {
    var time: TimeInterval
    var level: Float = 1
    var barCount: Int = 12

    var body: some View {
        let amplitude = min(CGFloat(level) * 4, 1)   // RMS is small — amplify and clamp to 0...1
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let base = sin(time * 6 + Double(index) * 0.8)
                    let detail = sin(time * 13 + Double(index) * 1.7) * 0.4
                    let phase = max(0, min(1, ((base + detail) / 1.4 + 1) / 2))
                    let height = 3 + (geo.size.height - 3) * amplitude * (0.45 + 0.55 * CGFloat(phase))
                    Capsule()
                        .fill(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, height))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
