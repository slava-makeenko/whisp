import SwiftUI
import AppKit
import WhispCore

struct RootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case dashboard  = "Home"
        case history    = "History"
        case files      = "Files"
        case conference = "Conference"
        case powerMode  = "Power Mode"
        case settings   = "Settings"
        case help       = "Help"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dashboard:  "house"
            case .history:    "clock"
            case .files:      "doc.text"
            case .conference: "person.2.wave.2"
            case .powerMode:  "bolt"
            case .settings:   "gearshape"
            case .help:       "questionmark.circle"
            }
        }
    }

    @State private var selection: Section = .dashboard
    @EnvironmentObject private var updater: UpdaterController
    @AppStorage("accentColor") private var accentColor = "clay"
    @AppStorage("colorScheme") private var colorSchemeRaw = "system"
    @AppStorage("didVisitHelp") private var didVisitHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Cross-fade (+ a slight rise) between sections instead of an instant swap.
            ZStack {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.windowBG)
                    .id(selection)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
            .animation(.easeOut(duration: 0.2), value: selection)
        }
        .navigationSplitViewStyle(.balanced)
        .ignoresSafeArea(.all, edges: .top)
        .tint((AccentPalette(rawValue: accentColor) ?? .clay).color)
        .font(.geist(size: 13))
        .preferredColorScheme(preferredScheme)
        .wispWindowChrome()
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenSettings)) { _ in
            selection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenHistory)) { _ in
            selection = .history
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenPowerMode)) { _ in
            selection = .powerMode
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenFiles)) { _ in
            selection = .files
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispOpenConference)) { _ in
            selection = .conference
        }
        .overlay(alignment: .bottomTrailing) {
            Text(appVersion)
                .font(.geist(size: 11))
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
                    .font(.geist(size: 19, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 16)

            ForEach([Section.dashboard, .history, .files, .conference, .powerMode]) { section in
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
            SidebarRow(title: "Help", symbol: "questionmark.circle",
                       selected: selection == .help, badge: !didVisitHelp) {
                selection = .help
                didVisitHelp = true
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBG)
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .dashboard:  DashboardView()
        case .history:    HistoryView()
        case .files:      FileTranscriptionsView()
        case .conference: ConferencesView()
        case .powerMode:  PowerModeView()
        case .settings:   SettingsView()
        case .help:       HelpView()
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
                        .font(.geist(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(message)
                        .font(.geist(size: 12, weight: .medium))
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
                        .font(.geist(size: 12, weight: .semibold))
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
    var badge: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.geist(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                    .frame(width: 20)
                Text(LocalizedStringKey(title))
                    .font(.geist(size: 14, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
                Spacer(minLength: 0)
                if badge {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }
}
