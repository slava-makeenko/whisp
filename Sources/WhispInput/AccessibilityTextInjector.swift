import AppKit
import ApplicationServices
import CoreGraphics

public enum InjectionError: Error, Sendable {
    case noFocusedElement
    case accessibilityDenied
    case axFailed(Int32)            // AXError.rawValue
    case eventSourceUnavailable
}

/// Injects text into the frontmost focused element. AppKit/AX work runs on the main actor.
/// `// VERIFY-INJ-1/2/3`: which strategy each target app accepts is empirical — validated by
/// manual runs across apps, not headless tests (AX injection needs Accessibility permission).
@MainActor
public final class AccessibilityTextInjector: TextInjector {
    /// Delay before restoring the pasteboard, giving the target app time to read ⌘V.
    private let pasteboardRestoreDelay: Duration = .milliseconds(250)

    /// The element + caret + app captured at dictation start, so the result lands where the user began.
    private var capturedElement: AXUIElement?
    private var capturedRange: CFTypeRef?
    private var capturedApp: NSRunningApplication?
    private var lastTargetApp: NSRunningApplication?   // most recent non-whisp app (for when whisp is frontmost)
    private var didPromptAX = false
    private var activationObserver: NSObjectProtocol?

    public init() {
        // Track the app the user was last in, so dictation still targets it even if it's started
        // while whisp's own window is frontmost.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid, let app = NSRunningApplication(processIdentifier: pid),
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self?.lastTargetApp = app
            }
        }
    }

    /// Snapshot the focused element and its caret/selection now (called when dictation starts).
    public func captureFocus() {
        capturedElement = nil
        capturedRange = nil
        capturedApp = nil
        let front = NSWorkspace.shared.frontmostApplication
        let isWhisp = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        capturedApp = isWhisp ? lastTargetApp : front   // target the user's app even if whisp is frontmost
        guard !isWhisp else { return }                  // can't read the target's element while whisp is front
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        // swiftlint:disable:next force_cast
        let element = raw as! AXUIElement
        capturedElement = element
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            capturedRange = range
        }
    }

    /// The text currently selected in the focused app — used by Command Mode to edit a selection.
    public func readSelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let element = raw as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    public func inject(_ text: String, strategy: InjectionStrategy?) async throws -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted(app: nil) }

        // Insertion needs Accessibility; without it AX and the synthesized ⌘V both fail silently.
        // Put the text on the clipboard so it isn't lost, surface the system prompt once, and report.
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if !didPromptAX {
                didPromptAX = true
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return .copiedToClipboard
        }

        // If we pinned a target at dictation start, insert there (re-activating its app if focus
        // drifted) — works even for Electron/web apps that reject AX text, via keystrokes.
        if capturedApp != nil || capturedElement != nil {
            return try await injectIntoPinnedTarget(text)
        }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        switch strategy {
        case .axInsertText:    try setAX(text, attribute: kAXSelectedTextAttribute)
        case .axSetValue:      try setAX(text, attribute: kAXValueAttribute)
        case .synthKeystrokes: try typeUnicode(text)
        case .pasteboardPaste: try await paste(text)
        case nil:
            // Auto: AX insert at cursor, fall back to pasteboard paste.
            do { try setAX(text, attribute: kAXSelectedTextAttribute) }
            catch { try await paste(text) }
        }
        return .inserted(app: app)
    }

    /// Inserts into the element/app captured at dictation start. Native fields take AX text directly
    /// (clean, no clipboard); otherwise bring the target app forward and paste — ⌘V works everywhere.
    private func injectIntoPinnedTarget(_ text: String) async throws -> InjectionOutcome {
        let app = capturedApp
        capturedElement = nil
        capturedApp = nil
        capturedRange = nil

        // Bring the target forward so the paste lands in it, not in whisp.
        if let app, !app.isActive {
            app.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Paste via ⌘V — reliable across native apps, terminals (Warp), web and Electron, where
        // AX text-set and synthesized unicode keystrokes silently no-op.
        try await paste(text)
        return .inserted(app: app?.localizedName)
    }

    // MARK: - Accessibility

    private func setAX(_ text: String, attribute: String) throws {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard copyErr != .apiDisabled else { throw InjectionError.accessibilityDenied }
        guard copyErr == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw InjectionError.noFocusedElement
        }
        // swiftlint:disable:next force_cast
        let element = raw as! AXUIElement
        let setErr = AXUIElementSetAttributeValue(element, attribute as CFString, text as CFString)
        guard setErr == .success else { throw InjectionError.axFailed(setErr.rawValue) }
    }

    // MARK: - Pasteboard paste

    private func paste(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Mark the dictated text as transient so clipboard managers (Maccy, Paste, Raycast…)
        // don't persist it to their history — this is dictation in flight, not a user copy.
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        try postCommandV()

        try? await Task.sleep(for: pasteboardRestoreDelay)
        pasteboard.clearContents()
        if let snapshot, !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
    }

    private func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.eventSourceUnavailable
        }
        let vKey: CGKeyCode = 0x09  // ANSI 'v'
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            throw InjectionError.eventSourceUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Unicode typing

    private func typeUnicode(_ text: String) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InjectionError.eventSourceUnavailable
        }
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw InjectionError.eventSourceUnavailable
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
