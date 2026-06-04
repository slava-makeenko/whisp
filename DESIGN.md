# Whisp (whispmac) — Design Document

> **Status:** DRAFT for approval · **Date:** 2026-06-02
> **Deployment target:** macOS 14.4+ · **Built with:** Xcode 26.5 / Swift 6.3.2 / macOS 26.5 SDK
> Companion file: [`VERIFY.md`](./VERIFY.md) — every external API not yet pinned.

A native macOS dictation & transcription app: speak → local ASR → optional cloud-LLM
enhancement → inject text into the frontmost app. Global hotkeys, per-app/URL "Power
Mode" profiles, searchable history, a CloudKit-synced user dictionary, and a file
transcription queue.

---

## 0. Decisions locked this session

| # | Decision | Rationale |
|---|---|---|
| D1 | **Design-doc first**, code after approval | De-risk a ~14-subsystem build before writing it. |
| D2 | **Best-available-at-runtime ASR** behind one `TranscriptionService` protocol | macOS 26 native `SpeechAnalyzer` is faster than Whisper + free VAD, but the 14.4 floor still needs whisper/FluidAudio. One protocol, runtime selection. |
| D3 | **SPM core libraries + thin Xcode app shell** | Logic is `swift build`/`swift test`-able headlessly; only entitlements/Info.plist/`@main` live in the `.xcodeproj`. |

---

## 1. Toolchain & global constraints

- **Swift 6 language mode is the default** on this toolchain → strict concurrency is
  enforced, not opt-in. Every public boundary type is `Sendable`; all AppKit/SwiftUI
  access is `@MainActor`. This makes the Concurrency review a first-class gate.
- **Build against the 26.5 SDK, deploy to 14.4.** Anything newer than 14.4 is wrapped
  in `@available` and gated by a capability check, never assumed:
  - `SpeechAnalyzer`/`SpeechTranscriber`/`SpeechDetector` → `@available(macOS 26, *)`.
  - Any SwiftData/SwiftUI niceties from 15/16/26 → guarded, with a 14.4 fallback path.
- **`@Observable`** (Observation) is used for shared UI state (available 14+).
- macOS 26 "Liquid Glass" chrome is applied by the system to SwiftUI surfaces; the
  floating recorder must be validated against it (see §6.17, VERIFY-UI-1).

---

## 2. Dependency pins & open product inputs

### Verified dependency pins
| Dependency | Pin | Notes |
|---|---|---|
| Sparkle | `2.9.2` | 2.8 added macOS 26 compat. Disabled when `LOCAL_BUILD`. |
| FluidAudio | `from: 0.6.1` (`FluidInference/FluidAudio`) | Parakeet TDT v2 (EN) / v3 (multilingual incl. `ru`), CoreML on the ANE. |
| whisper | **binding TBD** — `ggml-org/whisper.cpp` (XCFramework/CMake) **or** `argmaxinc/WhisperKit` 1.0.0 | See VERIFY-ASR-1; WhisperKit is the lower-risk Swift-native option. |
| MediaRemoteAdapter | `ungive/mediaremote-adapter` (eval `ejbills` fork) | Bundle the built framework; **do not link**. Helper-process design. |
| LaunchAtLogin-Modern | latest tag at pin | Sindre Sorhus; confirm Swift 6 clean. |
| Zip | `marmelroy/Zip` latest | Confirm Swift 6 clean. |
| Swift Atomics | `apple/swift-atomics` 1.2.x | — |
| AXSwift | `tmandry/AXSwift` latest | Confirm Swift 6 clean. |

### Open product inputs (blockers for later phases — please supply)
| # | Input | Blocks |
|---|---|---|
| P1 | **LLMkit fork URL** (the spec's "LLMkit fork") | §6.10 AI enhancement. Until then I ship a thin `URLSession` enhancer behind `LLMEnhancer` and swap the fork in. |
| P2 | **Licensing backend** (Keygen / Gumroad / Paddle / custom server) | §6.13 trial + key activation. |
| P3 | **CloudKit container id + Apple Developer Team id** | §6.8 dictionary sync, entitlements. |
| P4 | **Sparkle appcast URL + EdDSA key pair** (generate `generate_keys`) | §6.15 updates. |
| P5 | **Bundle id, signing identity, notarization profile** | Phase 1 Xcode shell. |

---

## 3. Package topology

```
whispmac/
├─ Package.swift                 # SPM: all logic, headlessly testable
├─ Sources/
│  ├─ WhispCore/              # orchestrator, models, settings, power-mode rules, licensing
│  ├─ WhispAudio/            # AVAudioEngine capture, VAD, ducking glue
│  ├─ WhispASR/              # TranscriptionService + 3 backends + router
│  ├─ WhispInput/            # AX/CGEvent injection, hotkey monitor
│  ├─ WhispPlatform/         # permissions, Keychain, browser-URL, MediaRemote
│  └─ WhispLLM/              # LLMEnhancer (LLMkit fork swap-in)
├─ Tests/                        # Swift Testing + XCTest
└─ App/                          # Xcode target (.xcodeproj or XcodeGen project.yml)
   ├─ WhispApp.swift          # @main, ModelContainer wiring, Sparkle, CloudKit
   ├─ UI/ …                      # NavigationSplitView, MenuBarExtra, MiniRecorder
   ├─ Resources/ (Assets, models)
   ├─ Info.plist
   └─ Whisp.entitlements
```

Dependency direction (no cycles):
```
App ──▶ Core ──▶ {Audio, ASR, Input, Platform, LLM}
        Audio ──▶ Platform      (ducking)
        ASR   ──▶ Audio (types) , Platform (model files)
        Input ──▶ Platform      (permissions)
```
Build/test here: `swift build`, `swift test`. The `.app` (entitlements, hardened
runtime, notarization) is built via Xcode only.

---

## 4. Concurrency model (Swift 6 strict)

| Component | Isolation | Notes |
|---|---|---|
| `DictationController` (orchestrator) | `@MainActor @Observable` | Owns the state machine, binds to UI, awaits actors. |
| `AudioCapturer` | `actor` | Wraps `AVAudioEngine`. Tap callback copies PCM → `Sendable AudioChunk` at the boundary (`AVAudioPCMBuffer` is **not** Sendable). |
| `TranscriptionRouter` + backends | `actor` each | whisper `whisper_context` is **not thread-safe** → confined inside its actor, never crosses; so it needs no `Sendable`. |
| SwiftData writes (history, metrics) | `@ModelActor` background actors | `ModelContext` is non-`Sendable` and thread-confined. |
| SwiftData reads (UI) | `@MainActor` `mainContext` | |
| `HotkeyMonitor`, `MediaController`, `TextInjector` | `actor` or `@MainActor` as required | CGEventTap runs on a CFRunLoop; events bridged to an `AsyncStream`. |

Sendable strategy: domain types are `Sendable` value types; `@unchecked Sendable`
is used **only** to wrap a thread-confined C resource that is provably never shared,
with a comment justifying it. No global mutable state without isolation.

---

## 5. Data layer — three-store `ModelContainer`

One `ModelContainer`, three `ModelConfiguration`s, each scoping its models to a
separate store URL; only the dictionary config is CloudKit-backed in production.

```swift
// VERIFY-DATA-1: confirm ModelConfiguration(cloudKitDatabase:) case names on the 26.5 SDK,
// and that a mixed CloudKit + local container is accepted.
func makeContainer(localBuild: Bool) throws -> ModelContainer {
    let history    = ModelConfiguration("history",    schema: Schema([Transcription.self]),
                                        url: storeURL("transcriptions"), cloudKitDatabase: .none)
    let metrics    = ModelConfiguration("metrics",    schema: Schema([SessionMetric.self]),
                                        url: storeURL("metrics"),        cloudKitDatabase: .none)
    let dictionary = ModelConfiguration("dictionary", schema: Schema([DictionaryEntry.self]),
                                        url: storeURL("dictionary"),
                                        cloudKitDatabase: localBuild ? .none
                                                                     : .private("iCloud.<P3>"))
    return try ModelContainer(for: Transcription.self, SessionMetric.self, DictionaryEntry.self,
                              configurations: history, metrics, dictionary)
}
```

**CloudKit rule checklist — applied to `DictionaryEntry` (the only synced model):**
- ✅ Every attribute is **optional or has a default** (`= ""`, `= Date.now`, …).
- ✅ **No `@Attribute(.unique)`** and no unique constraints.
- ✅ Relationships are optional and have an explicit inverse (entry has none → trivially ok).
- ✅ No `@Attribute(.allowsCloudEncryption)` unless a CloudKit field is configured for it.
- ✅ Default `init()` present so CloudKit can materialize records.

```swift
@Model final class Transcription {            // local only
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = .now
    var durationMs: Int = 0
    var backend: String = ""                  // TranscriptionBackendID.rawValue
    var appBundleID: String?                  // capture context for metrics
    var wordCount: Int = 0
    init() {}
}

@Model final class DictionaryEntry {          // CloudKit-synced (prod)
    var term: String = ""
    var replacement: String = ""              // "" → pronunciation hint only
    var isEnabled: Bool = true
    var createdAt: Date = .now
    init() {}
}

@Model final class SessionMetric {            // local only
    var date: Date = .now
    var wordsDictated: Int = 0
    var keystrokesSaved: Int = 0
    var activeSeconds: Int = 0
    var wpm: Double = 0
    init() {}
}
```

---

## 6. Subsystem contracts

Contracts below are **my** abstractions (stable). The adapter/binding points to
external frameworks carry `// VERIFY-*` tags resolved in [`VERIFY.md`](./VERIFY.md).

### 6.1 Audio capture & VAD
```swift
public struct AudioChunk: Sendable { public let samples: [Float]; public let sampleRate: Double; public let hostTime: UInt64 }
public typealias AudioStream = AsyncThrowingStream<AudioChunk, Error>

public protocol AudioCapturer: Sendable {            // actor-backed
    func start(_ cfg: CaptureConfig) async throws -> AudioStream   // 16 kHz mono Float for whisper/parakeet
    func stop() async
    var levels: AsyncStream<Float> { get }            // RMS for the waveform UI
}

public enum VADDecision: Sendable { case speech, silence, endpoint }
public protocol VoiceActivityDetector: Sendable { func process(_ c: AudioChunk) -> VADDecision }
// Impls: EnergyVAD (dependency-free floor) · SpeechDetectorVAD (@available macOS 26) · FluidAudioVAD (VERIFY-ASR-2)
```

### 6.2 Transcription — router + three backends (best-available)
```swift
public enum TranscriptionBackendID: String, Sendable { case nativeSpeech, fluidAudioParakeet, whisper }
public struct TranscriptionOptions: Sendable { public var locale: Locale; public var modelID: String?; public var partials: Bool; public var useVAD: Bool }
public enum TranscriptionEvent: Sendable { case partial(String); case segment(TranscriptionSegment); case final(TranscriptionResult) }
public struct TranscriptionSegment: Sendable { public let text: String; public let start: Double; public let end: Double }
public struct TranscriptionResult: Sendable { public let text: String; public let segments: [TranscriptionSegment]; public let backend: TranscriptionBackendID }

public enum BackendAvailability: Sendable { case ready; case needsDownload; case unsupportedOS; case missingModel }

public protocol TranscriptionService: Sendable {
    var id: TranscriptionBackendID { get }
    func availability(for o: TranscriptionOptions) async -> BackendAvailability
    func prepare(_ o: TranscriptionOptions) async throws
    func stream(_ audio: AudioStream, options o: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, Error> // live dictation
    func transcribeFile(_ url: URL, options o: TranscriptionOptions) async throws -> TranscriptionResult                 // file queue (§6.9)
}

public actor TranscriptionRouter {
    public init(backends: [TranscriptionService], policy: SelectionPolicy)
    public func select(for o: TranscriptionOptions) async -> TranscriptionService   // best available
}
public struct SelectionPolicy: Sendable { public var preferNativeOnMacOS26: Bool; public var userOverride: TranscriptionBackendID? }
```
- `NativeSpeechBackend` — `@available(macOS 26,*)`, wraps `SpeechAnalyzer`+`SpeechTranscriber` (VERIFY-ASR-3).
- `FluidAudioBackend` — Parakeet via FluidAudio 0.6.1 (VERIFY-ASR-2).
- `WhisperBackend` — whisper.cpp/WhisperKit (VERIFY-ASR-1).
- Default policy on macOS 26+: native; else FluidAudio; whisper as override/fallback.

### 6.3 Orchestrator — the central state machine
```swift
@MainActor @Observable public final class DictationController {
    public enum State: Sendable { case idle, recording, transcribing, enhancing, injecting, error(String) }
    public private(set) var state: State = .idle
    public func toggle() ; public func begin() ; public func end()
    // pipeline: AudioCapturer ▶ VAD ▶ TranscriptionRouter ▶ (optional) LLMEnhancer ▶ TextInjector ▶ History+Metrics
    // media ducking (§6.11) wraps begin()/end(); active PowerProfile (§6.6) supplies options/prompt/dictionary.
}
```

### 6.4 Text injection
```swift
public enum InjectionStrategy: Sendable { case axInsertText, axSetValue, synthKeystrokes, pasteboardPaste }
public protocol TextInjector: Sendable {
    func inject(_ text: String, strategy: InjectionStrategy?) async throws   // nil → auto: try AX, fall back to paste
}
// VERIFY-INJ-1: AXUIElementSetAttributeValue on kAXSelectedText / kAXValue per app.
// VERIFY-INJ-2: CGEventKeyboardSetUnicodeString synthesis. VERIFY-INJ-3: pasteboard + ⌘V restore.
```

### 6.5 Global hotkeys — four modes
```swift
public enum HotkeyMode: Sendable { case toggle, pushToTalk, hybridHold, middleClick }
public enum HotkeyEvent: Sendable { case activate, deactivate, toggle }
public protocol HotkeyMonitor: Sendable {     // CGEvent tap on a CFRunLoop, bridged to AsyncStream
    func start(_ binding: HotkeyBinding, mode: HotkeyMode) throws   // requires Accessibility (+ maybe Input Monitoring)
    func stop()
    var events: AsyncStream<HotkeyEvent> { get }
}
// VERIFY-HK-1: CGEvent.tapCreate keyDown/keyUp + otherMouseDown(button 2) capture; modifier-only chords;
//             which TCC permission(s) the tap needs (Accessibility vs Input Monitoring).
```

### 6.6 Power Mode — context detection & profile switching
```swift
public struct AppContext: Sendable { public let bundleID: String?; public let appName: String?; public let url: URL? }
public protocol ContextProvider: Sendable {
    func current() async -> AppContext
    var changes: AsyncStream<AppContext> { get }   // NSWorkspace didActivateApplication + URL poll
}
public struct PowerProfile: Identifiable, Codable, Sendable {
    public var match: [ContextRule]      // bundleID == / url host matches
    public var backend: TranscriptionBackendID?
    public var enhancementPrompt: String?
    public var enableEnhancement: Bool
}
// VERIFY-PM-1: per-browser front-tab URL (Safari/Chrome/Arc/Edge AppleScript) + Automation TCC consent; AX address-bar fallback.
```

### 6.7 History & metrics
- History: `@ModelActor HistoryStore` (background writes), `@MainActor` reads with `#Predicate` search; CSV export via `FileExporter`.
- Metrics: `@ModelActor MetricsStore`; dashboard aggregates (Time Saved, Avg WPM, Keystrokes) over `SessionMetric`.

### 6.8 Dictionary + CloudKit
- `@ModelActor DictionaryStore` over the CloudKit config (§5). Applied at transcription
  time as post-processing replacements + fed to the ASR backend as vocabulary hints
  where supported (VERIFY-ASR per backend). `LOCAL_BUILD` → local store only.

### 6.9 File transcription queue
```swift
public struct TranscriptionJob: Identifiable, Sendable { public let id: UUID; public let url: URL; public var progress: Double; public var state: JobState }
public actor TranscriptionQueue {
    public func enqueue(_ urls: [URL]) async
    public var jobs: AsyncStream<[TranscriptionJob]> { get }   // drag-and-drop audio/video → transcribeFile(...)
}
// VERIFY-FILE-1: AVAsset audio extraction for video containers → AudioStream.
```

### 6.10 AI enhancement (LLM)
```swift
public struct LLMProvider: Codable, Sendable { public var id: String; public var baseURL: URL; public var model: String }  // OpenAI-compatible default
public protocol LLMEnhancer: Sendable {
    func enhance(_ text: String, prompt: String, provider: LLMProvider) async throws -> String   // key read from Keychain
}
// P1: swap in the LLMkit fork once the URL is known; ship a URLSession default until then.
```

### 6.11 Media ducking (private MediaRemote)
```swift
public struct NowPlaying: Sendable { public let title: String?; public let isPlaying: Bool }
public protocol MediaController: Sendable {
    func nowPlaying() async -> NowPlaying?
    func pause() async ; func resume() async
}
// VERIFY-MR-1: MediaRemoteAdapter invocation (bundled framework + helper binary), get/pause/resume API,
//             behaviour on macOS 26 given the 15.4+ now-playing C-API lockdown.
```

### 6.12 Permissions & onboarding
```swift
public enum Permission: Sendable { case microphone, accessibility, screenRecording, inputMonitoring, automation(bundleID: String) }
public enum PermissionStatus: Sendable { case granted, denied, undetermined }
public protocol PermissionsService: Sendable {
    func status(_ p: Permission) async -> PermissionStatus
    func request(_ p: Permission) async -> PermissionStatus
    func openSettings(for p: Permission)
}
// VERIFY-PERM-1: mic=AVCaptureDevice.authorizationStatus; accessibility=AXIsProcessTrustedWithOptions;
//             screenRecording=CGPreflight/RequestScreenCaptureAccess; inputMonitoring=IOHIDCheckAccess;
//             automation=AEDeterminePermissionToAutomateTarget. Confirm WHY screen recording is needed (VERIFY-PERM-2).
```
Onboarding: cinematic dark flow (black bg, white text, 30–42pt rounded hero, typewriter) per VISUAL DESIGN.

### 6.13 Licensing
```swift
public enum LicenseState: Sendable { case trial(daysLeft: Int), licensed, expired }
public protocol LicenseService: Sendable {
    func state() async -> LicenseState
    func activate(key: String) async throws -> LicenseState
    func deactivate() async throws
}
// P2: activation/validation backend unresolved → interface only until chosen.
```

### 6.14 Settings backup/restore
```swift
public struct SettingsBackup: Codable, Sendable { /* profiles, prompts, hotkeys, prefs — NO keys, NO license */ }
public func exportSettings() throws -> Data
public func importSettings(_ data: Data) throws
// API keys (Keychain) and license are explicitly excluded from export/import and logs.
```

### 6.15 Updates (Sparkle 2.9.2)
- Thin `UpdaterController` over `SPUStandardUpdaterController`; **no-op when `LOCAL_BUILD`**.
- Info.plist: `SUFeedURL` (P4), `SUPublicEDKey` (P4). VERIFY-UPD-1: SPM product name + key plist entries on 2.9.2.

### 6.16 Siri Shortcuts (App Intents)
```swift
struct ToggleDictationIntent: AppIntent { static let title: LocalizedStringResource = "Toggle Dictation"
    @MainActor func perform() async throws -> some IntentResult { DictationController.shared.toggle(); return .result() } }
struct WhispShortcuts: AppShortcutsProvider { static var appShortcuts: [AppShortcut] { /* … */ } }
// VERIFY-SIRI-1: App Intents registration & AppShortcutsProvider on 14.4.
```

### 6.17 UI shell
- **Main window:** `NavigationSplitView` — sidebar (Dashboard · History · AI Models · Power Mode · Settings) + detail, per WIREFRAME; `NSColor.windowBackgroundColor`, SF 9–14pt body / 28pt headers.
- **MenuBarExtra:** record toggle, last result, quick profile switch.
- **Mini recorder:** floating non-activating `NSPanel` (`.nonactivatingPanel`, `.floating`) hosting a SwiftUI waveform. VERIFY-UI-1: NSPanel + SwiftUI hosting under Liquid Glass; non-activation so it never steals focus from the injection target.
- Shared `@Observable AppState` injected through the SwiftUI environment; cross-surface sync via the controller + `NSWorkspace`/distributed notifications.

---

## 7. Environment flags

| Flag | Kind | Effect | Read at |
|---|---|---|---|
| `LOCAL_BUILD` | compile (`-D`) + runtime guard | Disables CloudKit (`cloudKitDatabase: .none`) and Sparkle (`UpdaterController` no-op) | `makeContainer`, `UpdaterController` |
| `ENABLE_NATIVE_SPEECH_ANALYZER` | compile (`-D`) | Compiles in `NativeSpeechBackend`; combined with the runtime `@available(macOS 26,*)` check before selection | `WhispASR` |
| `LLM_PROVIDER_API_KEY` | runtime env → **Keychain** | Cloud-enhancement key; stored in Keychain, **never** in backups or logs | `WhispLLM` (migrates env → Keychain on first run) |

---

## 8. Entitlements & hardened runtime (security review preview)

**Key finding:** CGEventTap + arbitrary AX injection + private MediaRemote + AppleScript
automation are **incompatible with the App Sandbox**. → Distribute as **Developer ID,
non-sandboxed, Hardened Runtime ON, notarized** (not Mac App Store).

| Capability | Mechanism | Notes |
|---|---|---|
| Microphone | `com.apple.security.device.audio-input` + TCC | |
| Accessibility (inject + hotkeys) | TCC `AXIsProcessTrusted` (not an entitlement) | Prompted in onboarding |
| Input Monitoring | TCC `IOHIDCheckAccess` | VERIFY-HK-1 whether the tap needs it |
| Screen Recording | TCC | VERIFY-PERM-2 whether actually required |
| Automation (browser URL) | TCC apple-events | Per-target consent |
| iCloud / CloudKit | `com.apple.developer.icloud-*` (P3) | Works without sandbox |
| Keychain | `keychain-access-groups` (optional) | API keys + license |

---

## 9. Build plan & gates (mapped to the spec)

| Phase | Deliverable | Gate (review persona) |
|---|---|---|
| 1 | SPM skeleton + Xcode shell, env flags, 3-store container | build · — |
| 2 | Audio pipeline + orchestrator | build · **Concurrency** |
| 3 | ASR backends + router | build · **Swift API** |
| 4 | Injection + 4 hotkey modes | build · **Security/Entitlements** |
| 5 | UI shell (split view, menu bar, mini recorder) | build · — |
| 6 | Power Mode | build · — |
| 7 | History & metrics | build · — |
| 8 | Dictionary + CloudKit | build · **SwiftData/CloudKit** |
| 9 | File queue | build · — |
| 10 | Onboarding/permissions, enhancement, backup, licensing, Siri | build · Security |
| 11 | Tests (orchestrator, VAD, store isolation, licensing) | `swift test` |

No phase advances past its gate with an unresolved `// VERIFY-*` on a call it ships.

## 10. Test strategy
Swift Testing for pure logic (orchestrator state machine, VAD decisions, selection
policy, settings export exclusions, licensing state transitions); XCTest where async
lifecycle/expectations fit better; store-isolation tests assert the three configs map
to distinct URLs and that the dictionary schema satisfies the CloudKit checklist.

## 11. Open uncertainties
All external-API unknowns are tracked in [`VERIFY.md`](./VERIFY.md). Product blockers
are P1–P5 in §2. Nothing here ships as a fabricated call.
