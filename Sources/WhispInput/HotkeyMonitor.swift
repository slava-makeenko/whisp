import Foundation

public enum HotkeyMode: String, Sendable, CaseIterable {
    case toggle        // press once to start, again to stop
    case pushToTalk    // record while held
    case hybridHold    // tap = toggle, hold = push-to-talk
    case middleClick   // middle mouse button
}

public enum HotkeyEvent: Sendable, Equatable {
    case activate
    case deactivate
    case toggle
}

public struct HotkeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option  = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift   = HotkeyModifiers(rawValue: 1 << 3)
    public static let fn      = HotkeyModifiers(rawValue: 1 << 4)
}

public struct HotkeyBinding: Sendable {
    public var keyCode: UInt16?            // nil → modifier-only chord
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt16? = nil, modifiers: HotkeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Global hotkey monitoring via a `CGEvent` tap. Implemented in Phase 4.
// VERIFY-HK-1: tap capture of keyDown/keyUp, modifier-only chords and middle-click,
// plus which TCC permission the tap actually requires (Accessibility vs Input Monitoring).
public protocol HotkeyMonitor: Sendable {
    func start(_ binding: HotkeyBinding, mode: HotkeyMode) throws
    func stop()
    var events: AsyncStream<HotkeyEvent> { get }
}
