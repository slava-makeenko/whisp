import Foundation

public enum InjectionStrategy: Sendable {
    case axInsertText     // AXUIElementSetAttributeValue on kAXSelectedText (VERIFY-INJ-1)
    case axSetValue       // replace kAXValue wholesale (VERIFY-INJ-1)
    case synthKeystrokes  // CGEventKeyboardSetUnicodeString (VERIFY-INJ-2)
    case pasteboardPaste  // set pasteboard + ⌘V, then restore (VERIFY-INJ-3)
}

/// The result of an injection, surfaced to the UI.
public enum InjectionOutcome: Sendable, Equatable {
    case inserted(app: String?)   // typed / AX-inserted into the named app
    case copiedToClipboard        // Accessibility off → text put on the clipboard instead
}

/// Injects transcribed text into the frontmost focused element. Implemented in Phase 4.
public protocol TextInjector: Sendable {
    /// `strategy == nil` → automatic: try AX, fall back to pasteboard paste.
    @discardableResult
    func inject(_ text: String, strategy: InjectionStrategy?) async throws -> InjectionOutcome
    /// Snapshot the focused element + caret at dictation start, so the next `inject` lands where
    /// the user began — even if focus drifts while transcription runs. Default: no-op.
    func captureFocus() async
    /// The text currently selected in the focused app (for Command Mode). Default: nil.
    func readSelection() async -> String?
}

public extension TextInjector {
    func captureFocus() async {}
    func readSelection() async -> String? { nil }
}
