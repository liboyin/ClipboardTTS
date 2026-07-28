# Clipboard TTS App

Native macOS menu bar app (Swift/SwiftUI, macOS 13+) that reads clipboard text aloud via OpenAI-compatible TTS APIs. No external Swift dependencies; uses only Apple frameworks (AVAudioEngine, URLSession, NSPasteboard).

```
Sources/
  ClipboardTTSApp.swift       # app entry point, menu bar setup
  Managers/
    AudioPlayerManager.swift
    TextExtractionManager.swift
    TTSNetworkManager.swift
    TTSNetworkManager+Metadata.swift # guarded model/voice metadata requests
    ServicesCoordinator.swift   # bridges the macOS Services flow into the audio pipeline
  Views/
    MenuBarView.swift
    SettingsView.swift
Tests/                        # XCTest, including focused metadata state/race suites, shared
                              # MockURLProtocol, and UserDefaultsSnapshot (settings isolation)
project.yml                   # XcodeGen source of truth (*.xcodeproj is gitignored)
```

## Architecture

- **UI**: SwiftUI `MenuBarExtra` for playback controls; a separate `Window` hosts settings to keep the dropdown focused on play/pause/progress/speed. The settings window includes an endpoint test action.
- **Audio**: `AVAudioEngine` + `AVAudioPlayerNode` (not `AVPlayer`) so playback speed can be adjusted via `AVAudioUnitTimePitch` without altering pitch.
- **Text**: `TextExtractionManager` reads through an injected, read-only pasteboard adapter; the production adapter uses `NSPasteboard.general`. The menu-bar flow deactivates the app and defers the read by 0.2 seconds before starting TTS.
- **Network**: `URLSession` with HTTP chunked streaming, so playback starts on the first bytes from the TTS provider rather than after the full payload downloads. Each task captures its provider, endpoint, credentials, request inputs, decoder, and incremental parsing state at creation; later settings changes apply only to the next request. Model and voice metadata maintain independent cancellable request state and generation tokens; only metadata for the still-selected provider and endpoint may update the UI. Cancellation limits unnecessary work but is not a freshness guarantee: a completion must still match its active request token. Metadata source identity includes both the selected provider and endpoint, because multiple Custom endpoints use the same OpenAI-compatible transport. A delegate callback validates and records task state under a private serial queue before invoking its audio handler after releasing that queue, so handlers may synchronously stop or replace a stream. Because `@Published` notifies observers before storing a value, request-state publications track nested updates and defer observer-triggered replacement requests until the outermost update finishes. Invalid configuration, encoding, HTTP, transport, and empty or malformed provider-audio failures publish a short, application-owned message in the menu bar; provider response bodies are never rendered, and a new request or Clear Buffer clears the message. Minimizing Time-To-First-Byte is a primary design goal.
- **Settings**: API keys are generic-password Keychain items under the stable `com.clipboardtts.api-keys` service, one account per provider. `SettingsKeys` owns only persisted preferences plus the three temporary plaintext names used to migrate existing installs. Migration removes a legacy value only after Keychain accepts the write; a failure preserves it and presents Keychain-access guidance. If both stores contain a key, the existing Keychain value wins, preventing stale plaintext from overwriting a newer saved credential.
- **Services**: The macOS right-click "Speak Selected Text with Clipboard TTS" service posts a notification handled by `ServicesCoordinator`, which lives for the whole app lifetime (created in `ClipboardTTSApp.init`). This is deliberately *not* in `MenuBarView`: `MenuBarExtra(.window)` builds its body only when the dropdown is first opened, so a view-hosted observer would drop the service until then.

## Design Assumptions

- **OpenAI-compatible endpoints**: Local TTS engines must expose `/v1/audio/speech`. Cloud APIs that differ (e.g. Google Gemini) get dedicated payload formatters.
- **Custom provider contract**: Custom endpoints use the OpenAI-compatible speech payload. Users must configure a non-whitespace model and voice; every Custom request includes both values with `input` and PCM `response_format`. As with OpenAI, a successful response must contain at least one complete 16-bit PCM frame; otherwise the app reports a no-playable-audio failure.
- **Provider authentication**: OpenAI and Custom requests carry their saved key in `Authorization: Bearer`; native Gemini requests use the raw saved key in `x-goog-api-key`. Keys are never appended to URLs or included in app-owned errors.
- **Provider normalization**: An unknown persisted provider value is normalized to OpenAI and its fixed endpoint before any request is built. This fails safely instead of pairing a key with an arbitrary Custom endpoint.
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

Network-state tests wait for the relevant published terminal state (`lastError` and `isStreaming`) or an explicit mock-protocol event; do not use elapsed-time polling to infer that an asynchronous request completed.

To distribute locally without an Apple Developer Program account (ad-hoc signed, not notarized), run `./package.sh`.
