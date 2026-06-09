import SwiftUI
import AppKit
import WhispCore

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
    @EnvironmentObject private var updater: UpdaterController
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

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "whisp \(v)"
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
        .ignoresSafeArea(.all, edges: .top)
        .tint((AccentPalette(rawValue: accentColor) ?? .violet).color)
        .fontDesign((AppFontStyle(rawValue: fontStyle) ?? .system).design)
        .preferredColorScheme(preferredScheme)
        .wispWindowChrome()
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenSettings)) { _ in
            selection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenHistory)) { _ in
            selection = .history
        }
        .overlay(alignment: .bottomTrailing) {
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Sidebar

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
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 16)

            ForEach([Section.dashboard, .history, .powerMode]) { section in
                SidebarRow(title: section.rawValue, symbol: section.symbol,
                           selected: selection == section) { selection = section }
            }

            Spacer()

            UpdateSidebarCard(status: updater.status) {
                updater.installUpdate()
            }
            .padding(.bottom, 8)

            SidebarRow(title: "Settings", symbol: "gearshape",
                       selected: selection == .settings) { selection = .settings }
            SidebarRow(title: "Help", symbol: "questionmark.circle", selected: false) {
                if let url = URL(string: "https://github.com/slava-makeenko/whisp") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBG)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .history:   HistoryView()
        case .powerMode: PowerModeView()
        case .settings:  SettingsView()
        }
    }
}

// MARK: - Sidebar update status

private struct UpdateSidebarCard: View {
    let status: UpdateStatus
    let install: () -> Void

    var body: some View {
        if status.isSidebarVisible, let message = status.sidebarMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                }

                if case .downloading(let progress) = status {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                } else if case .extracting(let progress) = status {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                } else if case .installing = status {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                }

                if let actionTitle = status.actionTitle {
                    Button(actionTitle, action: install)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .buttonStyle(.plain)
                        .pointingCursor()
                }
            }
            .padding(10)
            .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
        }
    }

    private var icon: String {
        switch status {
        case .downloading: "arrow.down.circle.fill"
        case .extracting: "archivebox.fill"
        case .readyToInstall: "arrow.triangle.2.circlepath.circle.fill"
        case .installing: "gearshape.2.fill"
        default: "sparkles"
        }
    }
}

// MARK: - Sidebar row

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
            .background(
                selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
