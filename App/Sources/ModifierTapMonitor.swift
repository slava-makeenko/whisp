import AppKit
import WhispInput

/// Drives dictation from a single modifier (🌐fn / ⌃ / ⌥ / ⌘ / ⇧), which Carbon's `RegisterEventHotKey`
/// can't bind. Watches `.flagsChanged` and maps it per `HotkeyMode`:
/// - `.pushToTalk` → **hold to talk**: activate after a short hold, deactivate on release.
/// - `.hybridHold` → **double-tap** toggles **and** **hold** talks — both at once (the requested mode).
/// - `.toggle`     → **double-tap** toggles (a single bare-modifier tap fires constantly — every ⌘C).
///
/// The **global** monitor needs Accessibility permission (same as the AX text injector); the **local**
/// one (app focused) works without it.
@MainActor
final class ModifierTapMonitor {
    var onEvent: @MainActor (HotkeyEvent) -> Void = { _ in }

    private var targetFlag: NSEvent.ModifierFlags?
    private var mode: HotkeyMode = .pushToTalk
    private var targetWasDown = false

    // Hold (pushToTalk / hybridHold)
    private let holdThreshold: TimeInterval = 0.2
    private var holdWork: DispatchWorkItem?
    private var didActivateHold = false

    // Double-tap (toggle)
    private let doubleTapWindow: TimeInterval = 0.4
    private var pendingCleanPress = false
    private var lastTapAt: Date?

    private var global: Any?
    private var local: Any?

    func start(modifier: HotkeyModifiers, mode: HotkeyMode) {
        stop()
        guard let flag = Self.nsFlag(modifier) else { return }
        self.mode = mode
        targetFlag = flag
        targetWasDown = false
        global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.modifierFlags) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.modifierFlags) }
            return event
        }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
        holdWork?.cancel()
        holdWork = nil
        targetFlag = nil
        targetWasDown = false
        didActivateHold = false
        pendingCleanPress = false
        lastTapAt = nil
    }

    private func handle(_ rawFlags: NSEvent.ModifierFlags) {
        guard let target = targetFlag else { return }
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let isDown = flags.contains(target)
        guard isDown != targetWasDown else { return }   // act only on the target's own transitions
        targetWasDown = isDown

        if isDown {
            // "Clean" press: only the target modifier is down (don't fire on ⌘C, ⌥-drag, etc.).
            let others = flags.intersection([.command, .option, .control, .shift, .function]).subtracting(target)
            pendingCleanPress = others.isEmpty
            // Hold-capable modes arm an activation timer; a release before it fires counts as a "tap".
            if mode == .pushToTalk || mode == .hybridHold {
                didActivateHold = false
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.didActivateHold = true
                    self.onEvent(.activate)
                }
                holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
            }
        } else {
            holdWork?.cancel()
            holdWork = nil
            if didActivateHold {
                onEvent(.deactivate)              // end push-to-talk (the modifier was held)
            } else {
                switch mode {
                case .toggle, .hybridHold:      registerTap()   // quick tap → double-tap toggles
                case .pushToTalk, .middleClick: break           // quick tap does nothing
                }
            }
            didActivateHold = false
        }
    }

    /// A quick clean tap. Toggles only on the second tap inside `doubleTapWindow` — a single bare-modifier
    /// tap would otherwise fire on ordinary use (every ⌘C), so we require a deliberate double-tap.
    private func registerTap() {
        guard pendingCleanPress else { return }
        pendingCleanPress = false
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) < doubleTapWindow {
            lastTapAt = nil
            onEvent(.toggle)
        } else {
            lastTapAt = now
        }
    }

    private static func nsFlag(_ mods: HotkeyModifiers) -> NSEvent.ModifierFlags? {
        if mods.contains(.command) { return .command }
        if mods.contains(.option)  { return .option }
        if mods.contains(.control) { return .control }
        if mods.contains(.shift)   { return .shift }
        if mods.contains(.fn)      { return .function }
        return nil
    }
}
