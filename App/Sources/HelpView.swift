import SwiftUI
import AppKit
import WhispInput

/// In-app Help: how to control whisp, plus a step-by-step guide to enabling cloud (Groq) enhancement,
/// with links to the resources you need — no trip to GitHub required.
struct HelpView: View {
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 49
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = HotkeyModifiers.option.rawValue
    @AppStorage("conferenceHotkeyKeyCode") private var conferenceHotkeyKeyCode = 49
    @AppStorage("conferenceHotkeyModifiers") private var conferenceHotkeyModifiers = HotkeyModifiers([.control, .option]).rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader("Help")

                CardSection("Controls") {
                    helpRow("Dictate anywhere",
                            "Press \(hotkeyString(hotkeyKeyCode, hotkeyModifiers)) to start, again to stop. whisp types the text into the focused app — grant Accessibility on first use so it can insert (otherwise it copies to the clipboard).")
                    Divider().overlay(Theme.hairline)
                    helpRow("Record a meeting",
                            "Press \(hotkeyString(conferenceHotkeyKeyCode, conferenceHotkeyModifiers)) to start / stop Conference Mode — it captures your mic and the system audio. The recording and its transcript appear in the Conference tab.")
                    Divider().overlay(Theme.hairline)
                    helpRow("Find your text & tweak settings",
                            "Recent dictations show on Home; everything lives in History (searchable, exportable). Change hotkeys, languages, and the microphone in Settings.")
                }

                CardSection("Smarter formatting with a cloud key") {
                    Text("By default whisp cleans up your dictation on-device (Local). Connect a Groq API key for LLM-grade formatting — Email, Message, and Code modes. Only the text is ever sent; your audio never leaves the Mac.")
                        .font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    step(1, "Create a free key at [console.groq.com/keys](https://console.groq.com/keys).")
                    step(2, "Open **Settings → AI** and choose **Groq** as the Cloud provider.")
                    step(3, "Paste the key into the **API key** field and press **Test** — a green check means it works.")
                    step(4, "On **Home**, switch the **Enhancement** card to **Cloud**. Flip back to Local anytime.")
                }

                CardSection("Resources") {
                    linkRow("Get a Groq API key", url: "https://console.groq.com/keys")
                    Divider().overlay(Theme.hairline)
                    linkRow("Groq documentation", url: "https://console.groq.com/docs")
                    Divider().overlay(Theme.hairline)
                    linkRow("whisp on GitHub", url: "https://github.com/slava-makeenko/whisp")
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.windowBG)
    }

    // MARK: - Rows

    private func helpRow(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.geist(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Text(body).font(.geist(size: 13)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ markdown: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.geistMono(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(Theme.accentSoft, in: Circle())
            Text(markdown)
                .font(.geist(size: 13)).foregroundStyle(Theme.primaryText)
                .tint(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkRow(_ title: LocalizedStringKey, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title).font(.geist(size: 14, weight: .medium)).foregroundStyle(Theme.primaryText)
                Spacer()
                Image(systemName: "arrow.up.forward").font(.geist(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingCursor()
    }

    // MARK: - Hotkey formatting

    private func hotkeyString(_ keyCode: Int, _ modifiers: Int) -> String {
        let mods = HotkeyModifiers(rawValue: modifiers)
        var symbols = ""
        if mods.contains(.control) { symbols += "⌃" }
        if mods.contains(.option)  { symbols += "⌥" }
        if mods.contains(.shift)   { symbols += "⇧" }
        if mods.contains(.command) { symbols += "⌘" }
        if keyCode < 0 {   // modifier-only chord (double-tap)
            if mods.contains(.fn) { symbols = "fn" + symbols }
            return symbols.isEmpty ? "fn" : symbols
        }
        let key = KeyNames.name(for: keyCode)
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }
}
