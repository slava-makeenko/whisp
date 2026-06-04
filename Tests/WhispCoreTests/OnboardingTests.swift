import Testing
import WhispPlatform
@testable import WhispCore

@Suite struct OnboardingTests {
    private struct StubPermissions: PermissionsService {
        let result: PermissionStatus
        func status(_ permission: Permission) async -> PermissionStatus { result }
        func request(_ permission: Permission) async -> PermissionStatus { result }
        func openSettings(for permission: Permission) {}
    }

    @MainActor @Test func completeWhenAllGranted() async {
        let model = OnboardingModel(permissions: StubPermissions(result: .granted))
        await model.refresh()
        #expect(model.isComplete)
    }

    @MainActor @Test func incompleteWhenAnyDenied() async {
        let model = OnboardingModel(permissions: StubPermissions(result: .denied))
        await model.refresh()
        #expect(!model.isComplete)
        #expect(model.steps.count == 3)
    }
}
