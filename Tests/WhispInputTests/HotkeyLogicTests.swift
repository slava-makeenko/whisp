import Testing
@testable import WhispInput

/// Exercises the pure mode → event mapping (the four hotkey modes). The CGEvent tap plumbing
/// itself is permission-gated and validated by manual runs.
@Suite struct HotkeyLogicTests {

    @Test func toggleEmitsOnDownOnly() {
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .toggle, gesture: .down, heldLongEnough: false) == .toggle)
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .toggle, gesture: .up, heldLongEnough: false) == nil)
    }

    @Test func pushToTalkActivatesAndDeactivates() {
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .pushToTalk, gesture: .down, heldLongEnough: false) == .activate)
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .pushToTalk, gesture: .up, heldLongEnough: false) == .deactivate)
    }

    @Test func hybridTapTogglesButHoldDeactivates() {
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .hybridHold, gesture: .down, heldLongEnough: false) == nil)
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .hybridHold, gesture: .up, heldLongEnough: false) == .toggle)
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .hybridHold, gesture: .up, heldLongEnough: true) == .deactivate)
    }

    @Test func middleClickToggles() {
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .middleClick, gesture: .down, heldLongEnough: false) == .toggle)
        #expect(CGEventHotkeyMonitor.mappedEvent(for: .middleClick, gesture: .up, heldLongEnough: false) == nil)
    }
}
