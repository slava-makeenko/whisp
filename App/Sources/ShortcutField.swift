import SwiftUI
import AppKit
import WhispInput

/// Click-to-record shortcut field: click, then press a key combo — captures keyCode + modifiers.
struct ShortcutField: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: HotkeyModifiers?

    var body: some View {
        Button(action: toggleRecording) {
            (recording ? Text("Press a combo or tap a modifier…") : displayText)
                .frame(minWidth: 150)
                .foregroundStyle(recording ? .secondary : .primary)
        }
        .buttonStyle(.bordered)
        .pointingCursor()
        .onDisappear(perform: stopRecording)
    }

    private var displayText: Text {
        let mods = HotkeyModifiers(rawValue: modifiers)
        var symbols = ""
        if mods.contains(.control) { symbols += "⌃" }
        if mods.contains(.option)  { symbols += "⌥" }
        if mods.contains(.shift)   { symbols += "⇧" }
        if mods.contains(.command) { symbols += "⌘" }
        let key = keyCode < 0 ? "" : KeyNames.name(for: keyCode)
        if !mods.contains(.fn) && symbols.isEmpty && key.isEmpty { return Text("None") }
        if mods.contains(.fn) {
            return Text("\(Image(systemName: "globe"))\(symbols + key)")   // 🌐 / fn key
        }
        return Text(symbols + key)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { stopRecording(); return nil }   // Esc cancels
                pendingModifier = nil
                keyCode = Int(event.keyCode)
                modifiers = mapFlags(event.modifierFlags)
                stopRecording()
                return nil   // swallow the captured event
            case .flagsChanged:
                // Bare modifier: remember on press; if released with no key, capture as modifier-only.
                if let single = singleModifier(event.modifierFlags) {
                    pendingModifier = single
                } else if let pending = pendingModifier {
                    keyCode = -1
                    modifiers = pending.rawValue
                    stopRecording()
                }
                return event
            default:
                return event
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        pendingModifier = nil
    }

    private func mapFlags(_ flags: NSEvent.ModifierFlags) -> Int {
        var mods: HotkeyModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.function){ mods.insert(.fn) }
        return mods.rawValue
    }

    /// Returns the single modifier if exactly one of fn/⌃/⌥/⇧/⌘ is held, else nil.
    private func singleModifier(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers? {
        var present: [HotkeyModifiers] = []
        if flags.contains(.command)  { present.append(.command) }
        if flags.contains(.option)   { present.append(.option) }
        if flags.contains(.control)  { present.append(.control) }
        if flags.contains(.shift)    { present.append(.shift) }
        if flags.contains(.function) { present.append(.fn) }
        return present.count == 1 ? present.first : nil
    }
}

/// Virtual key-code → display name (ANSI layout) for the shortcut field.
enum KeyNames {
    static func name(for code: Int) -> String { map[code] ?? "Key \(code)" }

    private static let map: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 32: "U", 34: "I",
        31: "O", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "␣", 36: "⏎", 48: "⇥", 53: "⎋", 51: "⌫",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
