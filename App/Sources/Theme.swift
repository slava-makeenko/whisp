import SwiftUI
import AppKit

// MARK: - Adaptive color helper

/// Creates a Color that picks light/dark variant based on the active NSAppearance.
/// This is the foundation of Night Mode — both schemes are defined once here and
/// SwiftUI picks the right one automatically when the window's colorScheme changes.
private func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}

// MARK: - Theme

/// Centralised palette. Light = warm cream (Wispr-style). Dark = icon's own dark palette
/// (#111317 background, #1D2025 cards) — the same deep charcoal used in the waveform icon.
enum Theme {
    // Backgrounds
    static let windowBG = adaptive(
        NSColor(red: 0.941, green: 0.933, blue: 0.922, alpha: 1),   // warm cream
        NSColor(red: 0.067, green: 0.075, blue: 0.086, alpha: 1)    // #111317 (icon bottomBlack)
    )
    static let cardBG = adaptive(
        NSColor.white,
        NSColor(red: 0.114, green: 0.125, blue: 0.145, alpha: 1)    // #1D2025 (icon bottomBlack start)
    )
    static let inputBG = adaptive(
        NSColor(white: 0.960, alpha: 1),
        NSColor(red: 0.149, green: 0.165, blue: 0.188, alpha: 1)    // slightly lighter than cardBG
    )
    static let groupBG = adaptive(
        NSColor(white: 0.955, alpha: 1),
        NSColor(red: 0.133, green: 0.149, blue: 0.169, alpha: 1)
    )

    // Text
    static let primaryText = adaptive(
        NSColor(red: 0.086, green: 0.094, blue: 0.110, alpha: 1),   // warm near-black
        NSColor(red: 0.929, green: 0.929, blue: 0.941, alpha: 1)    // near-white
    )
    static let secondaryText = adaptive(
        NSColor(red: 0.380, green: 0.369, blue: 0.349, alpha: 1),   // warm grey
        NSColor(red: 0.545, green: 0.565, blue: 0.604, alpha: 1)    // muted blue-grey
    )

    // Accents / utilities
    static var accent: Color { AccentPalette.selected.color }
    static var accentSoft: Color { accent.opacity(0.14) }
    static let badge = Color(red: 0.957, green: 0.659, blue: 0.235) // amber hotkey chip
    static let selection = adaptive(
        NSColor.black.withAlphaComponent(0.055),
        NSColor.white.withAlphaComponent(0.075)
    )
    static let hairline = adaptive(
        NSColor.black.withAlphaComponent(0.07),
        NSColor.white.withAlphaComponent(0.08)
    )
    /// Shadow colour for cards: visible in light, more pronounced in dark.
    static let cardShadow = adaptive(
        NSColor.black.withAlphaComponent(0.06),
        NSColor.black.withAlphaComponent(0.40)
    )
}

// MARK: - Accent palette

/// User-selectable accent color — includes mint derived from the icon's pastel gradient (#C8FFF0).
enum AccentPalette: String, CaseIterable, Identifiable {
    case violet, mint, blue, indigo, green, orange, pink, graphite
    var id: String { rawValue }

    static var selected: AccentPalette {
        AccentPalette(rawValue: UserDefaults.standard.string(forKey: "accentColor") ?? "violet") ?? .violet
    }

    var color: Color {
        switch self {
        case .violet:   Color(red: 0.545, green: 0.471, blue: 0.969)
        case .mint:     Color(red: 0.094, green: 0.765, blue: 0.710) // #18C3B5 — from icon #C8FFF0
        case .blue:     Color(red: 0.184, green: 0.486, blue: 0.965)
        case .indigo:   Color(red: 0.369, green: 0.361, blue: 0.902)
        case .green:    Color(red: 0.204, green: 0.741, blue: 0.349)
        case .orange:   Color(red: 0.957, green: 0.569, blue: 0.149)
        case .pink:     Color(red: 0.918, green: 0.271, blue: 0.451) // icon pastel #FFDFF0 saturated
        case .graphite: Color(red: 0.412, green: 0.412, blue: 0.439)
        }
    }
}

// MARK: - Font style

enum AppFontStyle: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system:  "System"
        case .rounded: "Rounded"
        case .serif:   "Serif"
        case .mono:    "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .system:  .default
        case .rounded: .rounded
        case .serif:   .serif
        case .mono:    .monospaced
        }
    }
    static var selected: AppFontStyle {
        AppFontStyle(rawValue: UserDefaults.standard.string(forKey: "fontStyle") ?? "system") ?? .system
    }
}

// MARK: - Card / field modifiers

private struct WispCard: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 10, x: 0, y: 4)
    }
}

extension View {
    func wispCard(padding: CGFloat = 20, radius: CGFloat = 18) -> some View {
        modifier(WispCard(padding: padding, radius: radius))
    }

    /// Adaptive input field: soft fill + hairline border, correct in both light and dark mode.
    func wispField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.inputBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline))
            .foregroundStyle(Theme.primaryText)
            .tint(Theme.accent)
    }
}

// MARK: - Shared UI components

struct ScreenHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .wispCard()
                .tint(Theme.accent)
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardCaption: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WispMenuPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        LabeledContent(title) {
            Menu {
                ForEach(options, id: \.value) { opt in
                    Button { selection = opt.value } label: {
                        if opt.value == selection {
                            Label(LocalizedStringKey(opt.label), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(opt.label))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(options.first { $0.value == selection }?.label ?? ""))
                        .foregroundStyle(Theme.primaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

struct HotkeyChip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.badge, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Window chrome

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onResolve(window) } }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Paints the window title bar to match the content background — adapts to light / dark mode.
    func wispWindowChrome() -> some View {
        background(WindowAccessor { window in
            window.backgroundColor = NSColor(Theme.windowBG)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        })
    }
}
