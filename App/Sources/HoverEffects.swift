import SwiftUI
import AppKit

extension View {
    /// Subtle scale + shadow on hover, spring-animated.
    func hoverLift(scale: CGFloat = 1.02) -> some View {
        modifier(HoverLiftModifier(scale: scale))
    }

    /// Shows the pointing-hand cursor while hovering.
    func pointingCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.18 : 0),
                    radius: hovering ? 8 : 0, x: 0, y: hovering ? 3 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Scale-down feedback on press.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
