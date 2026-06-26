import SwiftUI
import WhispCore
import WhispPlatform

/// Cinematic dark permission flow (black background, white type, rounded hero) per VISUAL DESIGN.
struct OnboardingView: View {
    @Environment(OnboardingModel.self) private var onboarding
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text("Welcome to whisp")
                    .font(.geist(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Three permissions to dictate anywhere on your Mac.")
                    .font(.geist(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                VStack(spacing: 12) {
                    ForEach(onboarding.steps) { step in
                        stepRow(step)
                    }
                }
                .frame(maxWidth: 460)

                Button(onboarding.isComplete ? "Get Started" : "Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Label("New here? Open Help in the sidebar for a quick guide — including how to connect a Groq key for smarter formatting.",
                      systemImage: "questionmark.circle")
                    .font(.geist(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Spacer()
            }
            .padding(40)
        }
        .frame(minWidth: 560, minHeight: 540)
        .task { await onboarding.refresh() }
    }

    private func stepRow(_ step: OnboardingModel.Step) -> some View {
        HStack(spacing: 14) {
            Image(systemName: step.status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.status == .granted ? Color.green : Color.white.opacity(0.5))
                .font(.geist(size: 19, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).foregroundStyle(.white).font(.geist(size: 15, weight: .semibold))
                Text(step.detail).foregroundStyle(.white.opacity(0.6)).font(.geist(size: 11))
            }
            Spacer()
            if step.status != .granted {
                Button("Grant") { Task { await onboarding.request(step) } }
                Button("Settings") { onboarding.openSettings(step) }.buttonStyle(.link)
            }
        }
        .padding()
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
