import Foundation

public enum Permission: Sendable, Hashable {
    case microphone
    case accessibility
    case screenRecording   // VERIFY-PERM-2: confirm a feature actually needs this
    case inputMonitoring
    case automation(bundleID: String)
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

/// Permission status/request flows. Implemented in Phase 10 (onboarding).
// VERIFY-PERM-1: mic = AVCaptureDevice; accessibility = AXIsProcessTrustedWithOptions;
// screenRecording = CGPreflight/RequestScreenCaptureAccess; inputMonitoring = IOHIDCheckAccess;
// automation = AEDeterminePermissionToAutomateTarget.
public protocol PermissionsService: Sendable {
    func status(_ permission: Permission) async -> PermissionStatus
    @discardableResult
    func request(_ permission: Permission) async -> PermissionStatus
    func openSettings(for permission: Permission)
}
