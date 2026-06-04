import SwiftUI
import AppKit

/// Wispr-Flow-inspired light visual language: warm cream background, white cards with soft shadows,
/// a violet accent and an amber hotkey badge. Centralised so every screen shares one palette.
enum Theme {
    static let windowBG     = Color(red: 0.949, green: 0.945, blue: 0.937)   // warm cream
    static let cardBG       = Color.white
    static let primaryText  = Color(red: 0.129, green: 0.121, blue: 0.114)   // warm near-black
    static let secondaryText = Color(red: 0.404, green: 0.392, blue: 0.373)  // warm grey (readable)
    static var accent: Color { AccentPalette.selected.color }                // user-selectable
    static var accentSoft: Color { accent.opacity(0.12) }
    static let badge        = Color(red: 0.957, green: 0.659, blue: 0.235)   // amber (hotkey chip)
    static let selection    = Color.black.opacity(0.055)
    static let hairline     = Color.black.opacity(0.06)
}

/// User-selectable accent color (persisted in UserDefaults under "accentColor").
enum AccentPalette: String, CaseIterable, Identifiable {
    case violet, blue, indigo, green, orange, pink, graphite
    var id: String { rawValue }

    static var selected: AccentPalette {
        AccentPalette(rawValue: UserDefaults.standard.string(forKey: "accentColor") ?? "violet") ?? .violet
    }

    var color: Color {
        switch self {
        case .violet:   Color(red: 0.545, green: 0.471, blue: 0.969)
        case .blue:     Color(red: 0.184, green: 0.486, blue: 0.965)
        case .indigo:   Color(red: 0.369, green: 0.361, blue: 0.902)
        case .green:    Color(red: 0.204, green: 0.741, blue: 0.349)
        case .orange:   Color(red: 0.957, green: 0.569, blue: 0.149)
        case .pink:     Color(red: 0.918, green: 0.271, blue: 0.451)
        case .graphite: Color(red: 0.412, green: 0.412, blue: 0.439)
        }
    }
}

/// User-selectable typography, applied app-wide via `.fontDesign`.
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

/// White rounded card with a soft drop shadow — the building block of every screen.
private struct WispCard: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func wispCard(padding: CGFloat = 20, radius: CGFloat = 18) -> some View {
        modifier(WispCard(padding: padding, radius: radius))
    }

    /// A clean light input (soft grey fill + hairline border + dark text) — the default macOS field
    /// renders dark/bezelled outside a Form, which clashes with the light cards.
    func wispField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.965), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline))
            .foregroundStyle(Theme.primaryText)
            .tint(Theme.accent)
    }
}

/// Big screen title (e.g. "Settings"), matching the Home greeting weight.
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

/// An uppercase caption + a white card holding the rows — the cream-screen building block. Forces dark
/// text inside (the grouped `Form` renders labels with vibrancy that goes invisible on a light backdrop).
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

/// A labelled menu picker with an always-visible dark value. SwiftUI's `.menu`-style `Picker` renders
/// its selected value invisibly inside the light cards (it follows the system dark appearance), so we
/// build the control out of a plain `Menu` with an explicit dark label instead.
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
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// A muted caption line under a card row.
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

/// A small amber keycap chip, e.g. the `fn` badge in the greeting ("get back into the flow with fn").
struct HotkeyChip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.badge, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Reaches the hosting `NSWindow` so we can paint the title bar the same cream as the content
/// (the unified, chrome-less look Wispr has).
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
    /// Paints the window background (incl. a transparent title bar) with the cream palette.
    func wispWindowChrome() -> some View {
        background(WindowAccessor { window in
            window.backgroundColor = NSColor(Theme.windowBG)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        })
    }
}
