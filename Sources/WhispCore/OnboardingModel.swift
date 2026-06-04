import Foundation
import Observation
import WhispPlatform

/// Drives the onboarding permission flow: the steps needed for core dictation, their live
/// status, and request/settings actions.
@MainActor
@Observable
public final class OnboardingModel {
    public struct Step: Identifiable, Sendable {
        public let permission: Permission
        public let title: String
        public let detail: String
        public var status: PermissionStatus
        public var id: String { title }
    }

    public private(set) var steps: [Step]
    public var isComplete: Bool { steps.allSatisfy { $0.status == .granted } }

    @ObservationIgnored private let permissions: any PermissionsService

    public init(permissions: any PermissionsService) {
        self.permissions = permissions
        self.steps = [
            Step(permission: .microphone, title: "Microphone",
                 detail: "Capture your voice for on-device transcription.", status: .undetermined),
            Step(permission: .accessibility, title: "Accessibility",
                 detail: "Insert transcribed text and run global hotkeys.", status: .undetermined),
            Step(permission: .inputMonitoring, title: "Input Monitoring",
                 detail: "Detect your dictation hotkey from any app.", status: .undetermined),
        ]
    }

    public func refresh() async {
        for index in steps.indices {
            steps[index].status = await permissions.status(steps[index].permission)
        }
    }

    public func request(_ step: Step) async {
        _ = await permissions.request(step.permission)
        await refresh()
    }

    public func openSettings(_ step: Step) {
        permissions.openSettings(for: step.permission)
    }
}
