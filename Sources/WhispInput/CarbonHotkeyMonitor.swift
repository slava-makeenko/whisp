import Foundation
import Carbon

/// Global keyboard hotkey via Carbon `RegisterEventHotKey` — **permission-free** (no Accessibility /
/// Input Monitoring), so it works immediately and survives ad-hoc rebuilds. Keyboard modes only;
/// `middleClick` is a no-op here (needs the CGEvent tap).
///
/// `@unchecked Sendable`: all state is touched on the main thread (the Carbon handler dispatches on
/// the app's main event target); `start`/`stop` are expected to be called from the main thread.
public final class CarbonHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    public nonisolated let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var mode: HotkeyMode = .toggle

    private let holdThreshold: TimeInterval = 0.25
    private var holdWorkItem: DispatchWorkItem?
    private var didActivateHold = false

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
    }

    deinit { stop() }

    public func start(_ binding: HotkeyBinding, mode: HotkeyMode) throws {
        stop()
        self.mode = mode
        guard mode != .middleClick, let keyCode = binding.keyCode else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                .handle(pressed: GetEventKind(eventRef) == UInt32(kEventHotKeyPressed))
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, eventTypes.count, &eventTypes,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x56_49_4E_4B), id: 1)   // 'VINK'
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(binding.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { throw HotkeyError.tapCreationFailed }
    }

    public func stop() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }

    // MARK: - Event handling (main thread)

    private func handle(pressed: Bool) {
        let gesture: HotkeyGesture = pressed ? .down : .up
        if mode == .hybridHold {
            handleHybrid(gesture)
        } else if let event = CGEventHotkeyMonitor.mappedEvent(for: mode, gesture: gesture, heldLongEnough: false) {
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
            if let event = CGEventHotkeyMonitor.mappedEvent(for: .hybridHold, gesture: .up, heldLongEnough: didActivateHold) {
                continuation.yield(event)
            }
        }
    }

    private static func carbonModifiers(_ mods: HotkeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if mods.contains(.command) { result |= UInt32(cmdKey) }
        if mods.contains(.option)  { result |= UInt32(optionKey) }
        if mods.contains(.control) { result |= UInt32(controlKey) }
        if mods.contains(.shift)   { result |= UInt32(shiftKey) }
        return result
    }
}
