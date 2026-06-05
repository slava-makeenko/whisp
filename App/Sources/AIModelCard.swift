import SwiftUI
import WhispLLM

/// Compact status widget shown on the Dashboard.
/// • Downloading → progress bar with model name and cancel.
/// • Downloaded & active → small "On-device AI" badge.
/// • Nothing → hidden (model selection lives in Settings → AI).
struct AIModelCard: View {
    @Environment(LocalModelStore.self) private var store

    /// The first model currently being downloaded, if any.
    private var downloading: (model: OnDeviceModel, progress: Double)? {
        for model in OnDeviceModel.catalog {
            if case .downloading(let p) = store.states[model.id] ?? .notDownloaded {
                return (model, p)
            }
        }
        return nil
    }

    var body: some View {
        if let dl = downloading {
            downloadCard(dl.model, progress: dl.progress)
        } else if let active = store.activeModel {
            activeChip(active)
        }
        // else: nothing — invite visible in Settings only
    }

    // MARK: - Download card

    private func downloadCard(_ model: OnDeviceModel, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    store.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingCursor()
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)

            HStack {
                Text("Downloading…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("\(Int(progress * 100))%  of \(model.sizeFormatted)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(14)
        .background(Theme.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    // MARK: - Active chip

    private func activeChip(_ model: OnDeviceModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.system(size: 11))
            Text("On-device AI · \(model.displayName)")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.accentSoft, in: Capsule())
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}
