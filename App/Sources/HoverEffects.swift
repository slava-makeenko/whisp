import SwiftUI
import AppKit

extension View {
    /// Subtle scale + shadow on hover, spring-animated.
    func hoverLift(scale: CGFloat = 1.02) -> some View {
        modifier(HoverLiftModifier(scale: scale))
    }

    /// Shows the pointing-hand cursor while hovering.
    /// Uses `set()` (not the push/pop stack) so a skipped exit event — which AppKit
    /// does not synthesize when a hovered view is disabled or removed — cannot leave
    /// the cursor stuck or grow the cursor stack.
    func pointingCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (hovering ? scale : 1))
            .shadow(color: .black.opacity(hovering ? 0.18 : 0),
                    radius: hovering ? 8 : 0, x: 0, y: hovering ? 3 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Scale-down feedback on press; with Reduce Motion the press dims instead of scaling.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
            .opacity(reduceMotion && configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
