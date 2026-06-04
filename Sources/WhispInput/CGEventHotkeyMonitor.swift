import Foundation
import CoreGraphics

public enum HotkeyError: Error, Sendable {
    /// Tap creation failed — usually missing Accessibility / Input Monitoring permission.
    case tapCreationFailed
}

/// A press gesture, normalized across keys and the middle mouse button.
enum HotkeyGesture: Sendable { case down, up }

/// Global hotkey monitor via a CGEvent tap installed on the main run loop.
///
/// `@unchecked Sendable`: every piece of mutable state is touched only on the main run loop
/// thread — both the tap callback and the hold timer are scheduled there. `start`/`stop` are
/// expected to be called from the main thread (UI).
// VERIFY-HK-1: which TCC permission a listen-only session tap needs (Accessibility vs Input
// Monitoring) is confirmed empirically; modifier-only chords (flagsChanged) are a later refinement.
public final class CGEventHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    public nonisolated let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var binding = HotkeyBinding()
    private var mode: HotkeyMode = .toggle

    private let holdThreshold: TimeInterval = 0.25
    private var holdWorkItem: DispatchWorkItem?
    private var didActivateHold = false

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
    }

    deinit {
        // The tap holds a non-owning pointer to self via `userInfo`; tear it down before
        // dealloc so a late callback can't fire on a freed object.
        stop()
    }

    public func start(_ binding: HotkeyBinding, mode: HotkeyMode) throws {
        stop()
        self.binding = binding
        self.mode = mode

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)

        // Must be a capture-free @convention(c) function: context flows through `userInfo`.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<CGEventHotkeyMonitor>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }

    // MARK: - Event handling (main run loop thread)

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }  // re-arm a throttled tap
            return
        }
        guard matches(type: type, event: event) else { return }
        let gesture: HotkeyGesture = (type == .keyDown || type == .otherMouseDown) ? .down : .up

        if mode == .hybridHold {
            handleHybrid(gesture)
        } else if let event = Self.mappedEvent(for: mode, gesture: gesture, heldLongEnough: false) {
            continuation.yield(event)
        }
    }

    private func handleHybrid(_ gesture: HotkeyGesture) {
        switch gesture {
        case .down:
            didActivateHold = false
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.didActivateHold = true
                self.continuation.yield(.activate)
            }
            holdWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
        case .up:
            holdWorkItem?.cancel()
            holdWorkItem = nil
            if let event = Self.mappedEvent(for: .hybridHold, gesture: .up, heldLongEnough: didActivateHold) {
                continuation.yield(event)
            }
        }
    }

    private func matches(type: CGEventType, event: CGEvent) -> Bool {
        if mode == .middleClick {
            return (type == .otherMouseDown || type == .otherMouseUp)
                && event.getIntegerValueField(.mouseEventButtonNumber) == 2
        }
        guard type == .keyDown || type == .keyUp, let keyCode = binding.keyCode else { return false }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return code == keyCode && flagsMatch(event.flags)
    }

    private func flagsMatch(_ flags: CGEventFlags) -> Bool {
        var required: CGEventFlags = []
        if binding.modifiers.contains(.command) { required.insert(.maskCommand) }
        if binding.modifiers.contains(.option)  { required.insert(.maskAlternate) }
        if binding.modifiers.contains(.control) { required.insert(.maskControl) }
        if binding.modifiers.contains(.shift)   { required.insert(.maskShift) }
        return flags.intersection(required) == required
    }

    // MARK: - Pure mode → event mapping (unit-tested)

    static func mappedEvent(for mode: HotkeyMode, gesture: HotkeyGesture, heldLongEnough: Bool) -> HotkeyEvent? {
        switch mode {
        case .toggle, .middleClick:
            return gesture == .down ? .toggle : nil
        case .pushToTalk:
            return gesture == .down ? .activate : .deactivate
        case .hybridHold:
            switch gesture {
            case .down: return nil                              // wait for hold timer or release
            case .up:   return heldLongEnough ? .deactivate : .toggle
            }
        }
    }
}
