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
    private let hotKeyID: UInt32

    private let holdThreshold: TimeInterval = 0.25
    private var holdWorkItem: DispatchWorkItem?
    private var didActivateHold = false

    /// `id` distinguishes concurrently-registered hotkeys (e.g. dictation vs Conference Mode); each
    /// instance must use a unique id under the shared `'VINK'` signature.
    public init(id: UInt32 = 1) {
        self.hotKeyID = id
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
            // Every monitor's handler hangs off the same application target and sees EVERY hotkey
            // event, in reverse install order. Handle only OUR id and pass foreign ones down the
            // chain — otherwise the last-installed monitor swallows all the app's hotkeys.
            var firedID = EventHotKeyID()
            let status = GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr,
                  firedID.signature == OSType(0x56_49_4E_4B),
                  firedID.id == monitor.hotKeyID else { return OSStatus(eventNotHandledErr) }
            monitor.handle(pressed: GetEventKind(eventRef) == UInt32(kEventHotKeyPressed))
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, eventTypes.count, &eventTypes,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let eventHotKeyID = EventHotKeyID(signature: OSType(0x56_49_4E_4B), id: hotKeyID)   // 'VINK'
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(binding.modifiers),
                                         eventHotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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
