import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import IOKit.hid

/// Concrete TCC permission checks/requests. Status reads are safe to call anywhere;
/// `request` triggers the system prompts. Validated by manual runs (TCC can't be granted in CI).
public struct SystemPermissions: PermissionsService {
    public init() {}

    public func status(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            return Self.mapHID(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .automation:
            return .undetermined   // consent is prompted on first AppleScript use
        }
    }

    @discardableResult
    public func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            // kAXTrustedCheckOptionPrompt imports as a non-Sendable global var; use its literal value.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .automation:
            break
        }
        return await status(permission)
    }

    public func openSettings(for permission: Permission) {
        let anchor = Self.anchor(for: permission)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    // MARK: - Mapping

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:               return .granted
        case .denied, .restricted:      return .denied
        case .notDetermined:            return .undetermined
        @unknown default:               return .undetermined
        }
    }

    private static func mapHID(_ access: IOHIDAccessType) -> PermissionStatus {
        switch access {
        case kIOHIDAccessTypeGranted:   return .granted
        case kIOHIDAccessTypeDenied:    return .denied
        default:                        return .undetermined
        }
    }

    private static func anchor(for permission: Permission) -> String {
        switch permission {
        case .microphone:       return "Privacy_Microphone"
        case .accessibility:    return "Privacy_Accessibility"
        case .inputMonitoring:  return "Privacy_ListenEvent"
        case .screenRecording:  return "Privacy_ScreenCapture"
        case .automation:       return "Privacy_Automation"
        }
    }
}
