import SwiftUI
import AppKit
import WhispCore

/// Manages a floating, non-activating panel shown while dictation is active.
/// Non-activating so it never steals keyboard focus from the app receiving the text.
// VERIFY-UI-1: NSPanel + SwiftUI hosting and non-activation behaviour under macOS 26
// Liquid Glass — validated visually by a manual run.
@MainActor
final class MiniRecorderController {
    private var panel: NSPanel?

    func update(for state: DictationController.State, controller: DictationController) {
        switch state {
        case .recording, .injecting: show(controller: controller)
        default:                     hide()
        }
    }

    private func show(controller: DictationController) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(
                rootView: MiniRecorderView().environment(controller))
            position(panel)
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
    }
}

struct MiniRecorderView: View {
    @Environment(DictationController.self) private var controller

    var body: some View {
        HStack(spacing: 12) {
            WaveformView(level: controller.level,
                         tint: controller.isSpeaking ? .red : .secondary,
                         barCount: 4)
                .frame(width: 30)

            Text(label)
                .lineLimit(1)
                .font(.geist(size: 16))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var label: String {
        if controller.state == .injecting { return "Inserting…" }
        return controller.liveText.isEmpty ? "Listening…" : controller.liveText
    }
}
