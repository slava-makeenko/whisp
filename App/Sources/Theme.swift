import SwiftUI
import AppKit

// MARK: - Adaptive color helper

/// Creates a Color that picks light/dark variant based on the active NSAppearance.
/// This is the foundation of Night Mode — both schemes are defined once here and
/// SwiftUI picks the right one automatically when the window's colorScheme changes.
private func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}

private func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
}

// MARK: - Fluid Design palette (Whisp-x)

/// Raw ramps from the Whisp-x "Fluid Design" system. Semantic tokens below resolve from these.
enum Fluid {
    // Neutral (warm paper → ink)
    static let neutral0   = hex(0xFFFFFF)
    static let neutral50  = hex(0xF7F4EF)   // app background field
    static let neutral100 = hex(0xF0ECE5)
    static let neutral200 = hex(0xE3DDD3)
    static let neutral300 = hex(0xCFC8BC)
    static let neutral400 = hex(0xA9A296)
    static let neutral500 = hex(0x7E776C)
    static let neutral600 = hex(0x574F49)
    static let neutral700 = hex(0x3A363B)
    static let neutral800 = hex(0x2A2932)
    static let neutral900 = hex(0x20212B)
    static let neutral950 = hex(0x16161E)

    // Clay (accent)
    static let clay100 = hex(0xF0E2DB)
    static let clay200 = hex(0xDCC0B2)
    static let clay300 = hex(0xC29984)
    static let clay400 = hex(0xAE7A63)
    static let clay500 = hex(0x9E6752)
    static let clay600 = hex(0x835343)
    static let clay700 = hex(0x654036)
    static let clay800 = hex(0x4A2F28)

    // Peach (keycaps, progress)
    static let peach100 = hex(0xFFF3E4)
    static let peach200 = hex(0xFFE7C9)
    static let peach300 = hex(0xFED7A5)
    static let peach400 = hex(0xF6C079)
    static let peach500 = hex(0xE9A552)

    static let ink      = hex(0x20212B)
    static let espresso = hex(0x534145)
}

// MARK: - Theme (semantic tokens)

/// Centralised palette resolving the Whisp-x semantic tokens. Light = warm paper,
/// dark = deep neutral. Names are kept stable so the rest of the app keeps compiling.
enum Theme {
    // Backgrounds
    static let windowBG = adaptive(Fluid.neutral50, Fluid.neutral950)   // --bg
    static let cardBG   = adaptive(Fluid.neutral0,  Fluid.neutral800)   // --surface
    static let inputBG  = adaptive(Fluid.neutral100, Fluid.neutral700)
    static let groupBG  = adaptive(Fluid.neutral100, Fluid.neutral700)

    // Text
    static let primaryText   = adaptive(Fluid.ink, Fluid.neutral50)        // --text
    static let secondaryText = adaptive(Fluid.neutral600, Fluid.neutral300) // --text-secondary
    static let mutedText     = adaptive(Fluid.neutral500, Fluid.neutral400) // --text-muted

    // Accent / utilities
    static var accent: Color { AccentPalette.selected.color }
    static var accentSoft: Color { accent.opacity(0.12) }
    /// Peach highlight — keycaps & progress fill (independent of the user accent).
    static let peach    = adaptive(Fluid.peach300, Fluid.peach300)
    static let peachInk = adaptive(Fluid.ink, Fluid.ink)
    static let badge    = adaptive(Fluid.peach300, Fluid.peach300)
    static let danger   = adaptive(hex(0xB05340), hex(0xC97A66))

    static let selection = adaptive(
        NSColor(srgbRed: 0.126, green: 0.129, blue: 0.169, alpha: 0.07),
        NSColor.white.withAlphaComponent(0.07))
    static let hairline = adaptive(
        NSColor(srgbRed: 42/255, green: 41/255, blue: 50/255, alpha: 0.10),  // --border
        NSColor.white.withAlphaComponent(0.10))
    static let hairlineStrong = adaptive(
        NSColor(srgbRed: 42/255, green: 41/255, blue: 50/255, alpha: 0.18),
        NSColor.white.withAlphaComponent(0.18))

    /// Card shadow — soft in light (warm shadow-color), heavier in dark.
    static let cardShadow = adaptive(
        NSColor(srgbRed: 28/255, green: 24/255, blue: 30/255, alpha: 0.07),
        NSColor.black.withAlphaComponent(0.40))

    // Gradients
    static var gradDusk: LinearGradient {  // hero
        LinearGradient(colors: [Color(Fluid.clay400), Color(Fluid.espresso), Color(Fluid.ink)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var gradWarm: LinearGradient {  // progress
        LinearGradient(colors: [Color(Fluid.peach300), Color(Fluid.clay500)],
                       startPoint: .leading, endPoint: .trailing)
    }
    static var gradEmber: LinearGradient { // reserve
        LinearGradient(colors: [Color(Fluid.peach400), Color(Fluid.clay600)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Radii (Whisp-x scale)
    enum Radius {
        static let xs: CGFloat = 8    // keycaps
        static let sm: CGFloat = 12   // sidebar items / icon buttons
        static let md: CGFloat = 16   // rows & cards
        static let lg: CGFloat = 22
        static let pill: CGFloat = 999 // buttons, badges, progress
    }
}

// MARK: - Geist fonts

/// Bundled Geist (UI) + Geist Mono (figures / time / keycaps), registered via
/// ATSApplicationFontsPath. Referenced by exact PostScript name for reliable weights.
enum GeistFont {
    static func sansName(_ weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy, .bold: return "Geist-Bold"
        case .semibold:             return "Geist-SemiBold"
        case .medium:               return "Geist-Medium"
        default:                    return "Geist-Regular"
        }
    }
    static func monoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy, .bold, .semibold: return "GeistMono-SemiBold"
        case .medium:                          return "GeistMono-Medium"
        default:                               return "GeistMono-Regular"
        }
    }
}

extension Font {
    /// Geist UI font. Mirrors `.system(size:weight:design:)` so call sites convert 1:1.
    /// `design: .monospaced` resolves to Geist Mono.
    static func geist(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        if design == .monospaced { return .geistMono(size: size, weight: weight) }
        return .custom(GeistFont.sansName(weight), size: size)
    }

    /// Geist Mono — numerals, timestamps, keycaps.
    static func geistMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(GeistFont.monoName(weight), size: size)
    }
}

// MARK: - Accent palette

/// User-selectable accent color. Default = clay (the Whisp-x accent).
enum AccentPalette: String, CaseIterable, Identifiable {
    case clay, violet, mint, blue, indigo, green, orange, pink, graphite
    var id: String { rawValue }

    static var selected: AccentPalette {
        AccentPalette(rawValue: UserDefaults.standard.string(forKey: "accentColor") ?? "clay") ?? .clay
    }

    var color: Color {
        switch self {
        case .clay:     adaptive(Fluid.clay500, Fluid.clay300) // #9E6752 → clay-300 in dark
        case .violet:   Color(red: 0.545, green: 0.471, blue: 0.969)
        case .mint:     Color(red: 0.094, green: 0.765, blue: 0.710)
        case .blue:     Color(red: 0.184, green: 0.486, blue: 0.965)
        case .indigo:   Color(red: 0.369, green: 0.361, blue: 0.902)
        case .green:    Color(red: 0.204, green: 0.741, blue: 0.349)
        case .orange:   Color(red: 0.957, green: 0.569, blue: 0.149)
        case .pink:     Color(red: 0.918, green: 0.271, blue: 0.451)
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

// MARK: - Elevation modifiers

private struct ShadowSm: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.cardShadow, radius: 5, x: 0, y: 2)
            .shadow(color: Theme.cardShadow.opacity(0.7), radius: 1.5, x: 0, y: 1)
    }
}

private struct ShadowLg: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.cardShadow.opacity(1.4), radius: 28, x: 0, y: 18)
            .shadow(color: Theme.cardShadow, radius: 10, x: 0, y: 6)
    }
}

extension View {
    func fdShadowSm() -> some View { modifier(ShadowSm()) }
    func fdShadowLg() -> some View { modifier(ShadowLg()) }
}

// MARK: - Card / field modifiers

private struct WispCard: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .fdShadowSm()
    }
}

extension View {
    func wispCard(padding: CGFloat = 20, radius: CGFloat = Theme.Radius.md) -> some View {
        modifier(WispCard(padding: padding, radius: radius))
    }

    /// Adaptive input field: soft fill + hairline border, correct in both light and dark mode.
    func wispField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.inputBG, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).stroke(Theme.hairline))
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
            .font(.geist(size: 26, weight: .semibold))
            .kerning(-0.4)
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
                    .font(.geist(size: 12, weight: .semibold))
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
            .font(.geist(size: 12))
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
                        .font(.geist(size: 9)).foregroundStyle(Theme.secondaryText)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// Keycap chip — peach fill, inset bottom edge, Geist Mono. Used for hotkeys.
struct HotkeyChip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.geistMono(size: 13, weight: .semibold))
            .foregroundStyle(Color(Fluid.ink))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.peach, in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .strokeBorder(Color(Fluid.peach500).opacity(0.55), lineWidth: 1)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom))
            )
    }
}

/// Frosted "glass" pill button — hairline border + top sheen, clay icon.
struct GlassPillButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.geist(size: 13, weight: .semibold))
                Text(title).font(.geist(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairlineStrong, lineWidth: 1))
            .overlay(
                Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
            )
            .fdShadowSm()
            .offset(y: hovering ? -1 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }
}

/// Big Geist Mono numeral + muted unit label (stat figure).
struct StatFigure: View {
    let value: String
    let unit: LocalizedStringKey
    var size: CGFloat = 30
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .font(.geistMono(size: size, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText())
            Text(unit)
                .font(.geist(size: 12))
                .foregroundStyle(Theme.mutedText)
        }
    }
}

/// All-caps mono overline (date separators).
struct DateOverline: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.geistMono(size: 11, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.mutedText)
    }
}

/// Pill progress meter with warm-gradient fill.
struct ProgressMeter: View {
    var value: Double            // 0...1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.gradWarm)
                    .frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
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
