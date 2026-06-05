import SwiftUI
import AppKit

/// Main window: a Wispr-styled sidebar + a cream detail area.
struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Home"
        case history   = "History"
        case powerMode = "Power Mode"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard: "house"
            case .history:   "waveform"
            case .powerMode: "bolt"
            }
        }
    }

    @State private var selection: Section = .dashboard
    @AppStorage("accentColor") private var accentColor = "violet"
    @AppStorage("fontStyle") private var fontStyle = "system"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    @Environment(\.openWindow) private var openWindow

    private var preferredScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBG)
        }
        .navigationSplitViewStyle(.balanced)
        .tint((AccentPalette(rawValue: accentColor) ?? .violet).color)
        .fontDesign((AppFontStyle(rawValue: fontStyle) ?? .system).design)
        .preferredColorScheme(preferredScheme)
        .wispWindowChrome()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image("MenuBarIcon")
                    .resizable().renderingMode(.template).frame(width: 19, height: 19)
                    .foregroundStyle(Theme.primaryText)
                Text("whisp")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 16)

            ForEach([Section.dashboard, .history, .powerMode]) { section in
                SidebarRow(title: section.rawValue, symbol: section.symbol,
                           selected: selection == section) { selection = section }
            }

            Spacer()

            SidebarRow(title: "Settings", symbol: "gearshape", selected: false) {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            SidebarRow(title: "Help", symbol: "questionmark.circle", selected: false) {
                if let url = URL(string: "https://github.com") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBG)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .history:   HistoryView()
        case .powerMode: PowerModeView()
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
