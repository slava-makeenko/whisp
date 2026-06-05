import SwiftUI
import WhispLLM

/// Dashboard card for on-device AI model: shows the onboarding selector when no model is
/// downloaded, or the active model status when one is ready.
struct AIModelCard: View {
    @Environment(LocalModelStore.self) private var store
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("On-device AI", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if store.activeModel != nil {
                    Button("Change") { showPicker = true }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .pointingCursor()
                }
            }

            if showPicker || store.activeModel == nil {
                modelPicker
            } else {
                activeModelRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispCard()
        .animation(.easeInOut(duration: 0.2), value: showPicker)
        .animation(.easeInOut(duration: 0.2), value: store.activeModel?.id)
    }

    // MARK: - Active model status

    private var activeModelRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 20))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeModel?.displayName ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("On-device · private · no API key needed")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.activeModel == nil {
                Text("Download a model to enable private, on-device AI formatting — no API key, no internet required after download.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(OnDeviceModel.catalog) { model in
                ModelRow(model: model, isActive: store.activeModel?.id == model.id) {
                    showPicker = false
                }
            }
        }
    }
}

// MARK: - Single model row

private struct ModelRow: View {
    let model: OnDeviceModel
    let isActive: Bool
    let onSelected: () -> Void
    @Environment(LocalModelStore.self) private var store

    private var state: ModelDownloadState {
        store.states[model.id] ?? .notDownloaded
    }

    var body: some View {
        HStack(spacing: 12) {
            // Badge
            Text(model.badge)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(badgeColor, in: Capsule())
                .frame(width: 46)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    if isActive {
                        Text("active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(model.description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            // Action
            actionControl
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var actionControl: some View {
        switch state {
        case .notDownloaded:
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    store.startDownload(model)
                } label: {
                    Text("Download")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain).pointingCursor()
                Text(model.sizeFormatted)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }

        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .tint(Theme.accent)
                HStack(spacing: 8) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                    Button("Cancel") { store.cancelDownload(model) }
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .buttonStyle(.plain).pointingCursor()
                }
            }

        case .downloaded:
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 20))
            } else {
                Button {
                    store.select(model)
                    onSelected()
                } label: {
                    Text("Use")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain).pointingCursor()
            }

        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    store.startDownload(model)
                } label: {
                    Text("Retry")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.red.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain).pointingCursor()
                Text(msg.prefix(30))
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            }
        }
    }

    private var badgeColor: Color {
        switch model.badge {
        case "1B":   return Theme.accent.opacity(0.7)
        case "3B":   return Theme.accent
        case "3.8B": return Theme.accent.opacity(0.85)
        default:     return Theme.accent
        }
    }
}
