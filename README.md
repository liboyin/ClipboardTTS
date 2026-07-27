# Clipboard TTS App

Native macOS menu bar app (Swift/SwiftUI, macOS 13+) that reads clipboard text aloud via OpenAI-compatible TTS APIs. No external Swift dependencies; uses only Apple frameworks (AVAudioEngine, URLSession, NSPasteboard).

```
Sources/
  ClipboardTTSApp.swift       # app entry point, menu bar setup
  Managers/
    AudioPlayerManager.swift
    TextExtractionManager.swift
    TTSNetworkManager.swift
    ServicesCoordinator.swift   # bridges the macOS Services flow into the audio pipeline
  Views/
    MenuBarView.swift
    SettingsView.swift
Tests/                        # XCTest, one file per Manager/View + shared MockURLProtocol
                              # and UserDefaultsSnapshot (settings isolation)
project.yml                   # XcodeGen source of truth (*.xcodeproj is gitignored)
```

## Architecture

- **UI**: SwiftUI `MenuBarExtra` for playback controls; a separate `Window` hosts settings to keep the dropdown focused on play/pause/progress/speed. The settings window includes an endpoint test action.
- **Audio**: `AVAudioEngine` + `AVAudioPlayerNode` (not `AVPlayer`) so playback speed can be adjusted via `AVAudioUnitTimePitch` without altering pitch.
- **Text**: `TextExtractionManager` reads through an injected, read-only pasteboard adapter; the production adapter uses `NSPasteboard.general`. The menu-bar flow deactivates the app and defers the read by 0.2 seconds before starting TTS.
- **Network**: `URLSession` with HTTP chunked streaming, so playback starts on the first bytes from the TTS provider rather than after the full payload downloads. Each task captures its provider, endpoint, credentials, request inputs, decoder, and incremental parsing state at creation; later settings changes apply only to the next request. A delegate callback validates and records task state under a private serial queue before invoking its audio handler after releasing that queue, so handlers may synchronously stop or replace a stream. Minimizing Time-To-First-Byte is a primary design goal.
- **Settings**: `SettingsKeys` is the sole owner of persisted preference names. It also retains the three legacy plaintext API-key names only until their Keychain migration; Keychain account identifiers remain separate.
- **Services**: The macOS right-click "Speak Selected Text with Clipboard TTS" service posts a notification handled by `ServicesCoordinator`, which lives for the whole app lifetime (created in `ClipboardTTSApp.init`). This is deliberately *not* in `MenuBarView`: `MenuBarExtra(.window)` builds its body only when the dropdown is first opened, so a view-hosted observer would drop the service until then.

## Design Assumptions

- **OpenAI-compatible endpoints**: Local TTS engines must expose `/v1/audio/speech`. Cloud APIs that differ (e.g. Google Gemini) get dedicated payload formatters.
- **External toolchain**: `xcodegen` and `swiftlint` are user-managed; the app does not install or modify them.

## Build & Test

Regenerate Xcode project after editing `project.yml` or adding/removing source or test files, so Xcode discovers the current file set:
```
xcodegen generate
```

Build:
```
xcodebuild -project ClipboardTTSApp.xcodeproj -scheme ClipboardTTSApp -configuration Debug build
```

Run tests and check the line coverage of `Sources/Managers/`:
```
./check-coverage.sh
```

The unit-test bundle is hosted inside the app, so `UserDefaults.standard` in a test is the real app's defaults domain. Any test that touches a settings key must call `isolateAppSettingsDefaults()` first (`Tests/UserDefaultsSnapshot.swift`), which clears those keys for the test and restores the developer's configuration on teardown.

Network tests must create managers and sessions through `TestNetworkFactory`, which routes all requests through `MockURLProtocol` with an immutable per-test identifier. `MockURLProtocolTestCase` serializes those tests, invalidates their sessions and drains active protocol loads before releasing the next test, clears the installed response handler in setup and teardown, and fails a test that has an undeclared request without a handler; an explicitly declared unhandled request fails locally with a URL-loading error. Clipboard tests inject `FakePasteboardReader` and never modify the user's shared pasteboard.

To distribute locally without an Apple Developer Program account (ad-hoc signed, not notarized), run `./package.sh`.
