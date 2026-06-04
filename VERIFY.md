# VERIFY ledger — external APIs not yet pinned

Every row is a call/contract the design **depends on but has not confirmed** against
current source. Resolved before the depending phase ships; none is emitted as a
fabricated call. `Risk`: H = version-fragile/undocumented, M = stable-but-unconfirmed.

| ID | Subsystem | What must be confirmed | Where to confirm | Risk |
|---|---|---|---|---|
| ASR-1 | whisper backend | ✅ **RESOLVED** (WhisperKit chosen): `WhisperKit(WhisperKitConfig(model:))`; `transcribe(audioPath:)` / `transcribe(audioArray:)` → `[TranscriptionResult]` (`.text`). | confirmed vs `argmaxinc/WhisperKit` `Core/WhisperKit.swift` checkout | ✅ |
| ASR-2 | FluidAudio | ✅ **RESOLVED**: `AsrModels.downloadAndLoad(version: .v3)`; `AsrManager(models:)`; `transcribe(_:decoderState:&)` → `ASRResult.text`; `TdtDecoderState(decoderLayers:)`. `stream` buffers→final (true streaming = later). | confirmed vs `FluidAudio` `…/TDT/AsrManager.swift` checkout | ✅ |
| ASR-3 | Native speech | ✅ **RESOLVED (compile)**: `SpeechTranscriber(locale:preset:.progressiveTranscription)`; `SpeechAnalyzer(modules:)` + `start(inputSequence:)`; `AnalyzerInput(buffer:)`; `transcriber.results` (`.text`/`.isFinal`); `AssetInventory.assetInstallationRequest(supporting:)`; `finalizeAndFinishThroughEndOfInput()`. **Runtime = manual.** | confirmed vs macOS 26.5 SDK `Speech.swiftinterface` | ✅ |
| MR-1 | Media ducking | MediaRemoteAdapter: how to invoke (bundled framework + helper binary), get-now-playing + pause/resume API, behaviour on macOS 26 vs the 15.4+ now-playing C-API lockdown. | `ungive/mediaremote-adapter` README; `ejbills/mediaremote-adapter` fork | H |
| INJ-1 | Text injection | ◑ **API compiled** vs SDK (`AXUIElementCopyAttributeValue`/`SetAttributeValue`, `kAXSelectedText`/`kAXValue`; `.apiDisabled` → surfaced). **Which apps accept AX vs paste = manual.** | macOS 26.5 SDK | ◑ |
| INJ-2 | Text injection | ◑ **Compiled**: `CGEvent.keyboardSetUnicodeString` synthesis. Runtime = manual. | macOS 26.5 SDK | ◑ |
| INJ-3 | Text injection | ◑ **Compiled**: pasteboard snapshot (all types) + ⌘V + 120 ms restore. Restore timing = manual tune. | macOS 26.5 SDK | ◑ |
| HK-1 | Hotkeys | ◑ **API compiled**: `CGEvent.tapCreate` (keyDown/keyUp + middle-click), 4 modes, run-loop lifecycle, UAF closed via `deinit`. **TCC permission (Accessibility vs Input Monitoring) + modifier-only chords = manual.** | macOS 26.5 SDK; empirical | ◑ |
| PM-1 | Power Mode | ◑ App detection (NSWorkspace) ✅; front-tab URL via AppleScript (Safari/Chrome/Edge/Arc/Brave) compiled. **Automation (Apple Events) TCC consent + per-browser correctness = manual.** | macOS 26.5 SDK; empirical | ◑ |
| FILE-1 | File queue | ◑ Audio files → `backend.transcribeFile` (works). **Video containers need AVAsset audio extraction — not yet added; video jobs fail until then.** | AVFoundation docs | ◑ |
| DATA-1 | SwiftData | ✅ Compile-confirmed vs 26.5 SDK: `ModelConfiguration(…cloudKitDatabase: .none/.private)`, mixed CloudKit+local container, `@ModelActor` codegen. DictionaryEntry CloudKit-compliant (all defaulted, no `.unique`, `init()`). **Real sync needs P3 + iCloud entitlement (manual).** | macOS 26.5 SDK | ◑ |
| PERM-1 | Permissions | ◑ Compiled vs SDK: mic (`AVCaptureDevice`), accessibility (`AXIsProcessTrusted`/`WithOptions`), input monitoring (`IOHIDCheckAccess`/`RequestAccess`), screen recording (`CGPreflight`/`Request`). Automation = prompted-on-use. **Grant flows = manual.** | macOS 26.5 SDK | ◑ |
| PERM-2 | Permissions | ✅ Resolved: screen recording is **not** needed by any implemented feature; omitted from onboarding (only mic / accessibility / input-monitoring). | — | ✅ |
| UPD-1 | Sparkle | ✅ Compiled (Debug no-op + Release) vs Sparkle 2.9.2: product "Sparkle", `@MainActor SPUStandardUpdaterController(startingUpdater:…)`, `updater.checkForUpdates()`, `publisher(for: \.canCheckForUpdates)`, Info.plist `SUFeedURL`/`SUPublicEDKey`/`SUEnableAutomaticChecks`. **Real updates need P4 (feed + EdDSA keys) + signing.** | Sparkle 2.9.2 headers | ◑ |
| SIRI-1 | Shortcuts | App Intents `perform()` signature + `AppShortcutsProvider` registration on 14.4. | App Intents docs | M |
| UI-1 | UI shell | Floating non-activating `NSPanel` hosting SwiftUI under macOS 26 Liquid Glass; non-activation preserves focus on the injection target. | AppKit/SwiftUI docs; empirical | M |
| DEP-1 | Build | LaunchAtLogin-Modern, AXSwift, Zip, swift-atomics build clean under Swift 6 strict concurrency at the pinned tags. | each repo | M |

## Product inputs (not API verification — needed from the user)
- **P1** LLMkit fork URL · **P2** licensing backend · **P3** CloudKit container id + Team id ·
  **P4** Sparkle appcast URL + EdDSA keys · **P5** bundle id / signing / notarization.
