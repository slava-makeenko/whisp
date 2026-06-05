import SwiftUI
import AppKit

struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Home"
        case history   = "History"
        case powerMode = "Power Mode"
        case settings  = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: "house"
            case .history:   "clock"
            case .powerMode: "bolt"
            case .settings:  "gearshape"
            }
        }
    }

    @State private var selection: Section = .dashboard
    @AppStorage("accentColor") private var accentColor = "violet"
    @AppStorage("fontStyle") private var fontStyle = "system"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"

    private var preferredScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    private var accentColor_: Color { (AccentPalette(rawValue: accentColor) ?? .violet).color }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Theme.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBG)
        }
        .background(Theme.windowBG)
        .tint(accentColor_)
        .fontDesign((AppFontStyle(rawValue: fontStyle) ?? .system).design)
        .preferredColorScheme(preferredScheme)
        .wispWindowChrome()
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenSettings)) { _ in
            selection = .settings
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            // App logo — left-aligned, offset to clear the traffic lights (~72 pt)
            HStack(spacing: 7) {
                Image("MenuBarIcon")
                    .resizable().renderingMode(.template)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Theme.primaryText)
                Text("whisp")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.leading, 80)

            Spacer()

            // Centered tabs
            HStack(spacing: 0) {
                ForEach(Section.allCases) { section in
                    TopTab(label: LocalizedStringKey(section.rawValue),
                           symbol: section.symbol,
                           selected: selection == section,
                           accent: accentColor_) {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = section }
                    }
                }
            }

            Spacer()

            // Mirror of the logo area so tabs stay centered
            Color.clear.frame(width: 100)
        }
        .frame(height: 42)
        .padding(.top, 28)   // clear macOS traffic-light row
        .background(Theme.windowBG)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .history:   HistoryView()
        case .powerMode: PowerModeView()
        case .settings:  SettingsView()
        }
    }
}

// MARK: - Top tab button

private struct TopTab: View {
    let label: LocalizedStringKey
    let symbol: String
    let selected: Bool
    let accent: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    Text(label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                }
                .foregroundStyle(selected ? Theme.primaryText : (hovering ? Theme.primaryText.opacity(0.75) : Theme.secondaryText))

                // Underline indicator
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(selected ? accent : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
