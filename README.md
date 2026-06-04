# Whisp (whispmac)

Native macOS dictation & transcription: speak → local ASR → optional cloud-LLM
enhancement → inject text into the frontmost app. Global hotkeys, per-app/URL Power
Mode, searchable history, CloudKit-synced dictionary, file transcription queue.

See [`DESIGN.md`](./DESIGN.md) for the architecture and [`VERIFY.md`](./VERIFY.md) for
the ledger of external APIs still to be pinned.

## Toolchain
- Xcode 26.5 / Swift 6.3 (Swift 6 language mode, strict concurrency)
- Build against the macOS 26.5 SDK, deploy to **macOS 14.4+**

## Layout
```
Package.swift        SPM core — all logic, headlessly testable
Sources/             WhispCore · Audio · ASR · Input · Platform · LLM
Tests/               Swift Testing suites
project.yml          XcodeGen spec for the .app shell
App/                 Xcode app target (UI, Info.plist, entitlements)
```

## Build & test (SPM core)
```sh
swift build
swift test
```

## Generate & build the app shell
```sh
brew install xcodegen      # if needed
xcodegen generate          # → Whisp.xcodeproj
open Whisp.xcodeproj    # build/run in Xcode
```

## Environment flags
| Flag | Effect |
|---|---|
| `LOCAL_BUILD` | Disables CloudKit sync and Sparkle auto-updates |
| `ENABLE_NATIVE_SPEECH_ANALYZER` | Compiles in the macOS 26 native `SpeechAnalyzer` backend |
| `LLM_PROVIDER_API_KEY` | Cloud-enhancement key (migrated to Keychain; never logged/backed-up) |

## Build status
- [x] **Phase 1** — skeleton, env-flag plumbing, three-store `ModelContainer` *(builds + 6 tests green)*
- [x] **Phase 2** — audio capture + EnergyVAD + orchestrator *(clean build + 11 tests · Concurrency review done)*
- [x] **Phase 3** — ASR backends: native macOS 26 / FluidAudio-Parakeet / WhisperKit + router *(default+flagged builds · 13 tests · Swift API review done)*
- [x] **Phase 4** — AX/pasteboard injection + CGEventTap 4-mode hotkeys *(clean build · 17 tests · Security review done — UAF fixed)*
- [x] **Phase 5** — UI shell: NavigationSplitView + Dashboard + MenuBarExtra + floating mini-recorder *(.app builds via xcodebuild · 18 tests)*
- [x] **Phase 6** — Power Mode: NSWorkspace context + browser-URL + profile resolver + wiring *(.app builds · 22 tests)*
- [x] **Phase 7** — history (`@ModelActor` store · search · CSV) + metrics dashboard *(.app builds · 27 tests)*
- [x] **Phase 8** — dictionary store + replacements + Settings editor; CloudKit-compliant schema *(.app builds · 31 tests · SwiftData/CloudKit review done)*
- [x] **Phase 9** — file transcription queue + drag-and-drop *(.app builds · 33 tests)*
- [x] **Phase 10** — onboarding/permissions · AI enhancement (OpenAI-compat) · settings backup · trial licensing · Siri Shortcuts *(.app builds · 40 tests)*
- [x] **Phase 11** — test hardening: `.serialized` SwiftData suites (flake gone, 5×5 clean) + double-start regression *(41 tests)*

**All 11 phases complete.** Runtime-verified on macOS 26: launches, dictates, injects (CloudKit-entitlement gate + audio-tap double-start fixes applied).

**Sparkle 2.9.2 updater** wired (`UpdaterController` + "Check for Updates…" menu) — no-op in `LOCAL_BUILD`/Debug, real in Release; Debug+Release both compile. Open product inputs: P1–P5 (see `DESIGN.md` §2) — Sparkle needs **P4** (appcast URL + EdDSA keys) + signing for live updates.
