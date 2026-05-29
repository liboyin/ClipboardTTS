# Clipboard TTS App

Native macOS menu bar app (Swift/SwiftUI, macOS 13+) that reads clipboard text aloud via OpenAI-compatible TTS APIs. No external Swift dependencies; uses only Apple frameworks (AVAudioEngine, URLSession, NSPasteboard).

```
Sources/
  ClipboardTTSApp.swift       # app entry point, menu bar setup
  Managers/
    AudioPlayerManager.swift
    TextExtractionManager.swift
    TTSNetworkManager.swift
  Views/
    MenuBarView.swift
    SettingsView.swift
Tests/                        # XCTest, one file per Manager/View
project.yml                   # XcodeGen source of truth (*.xcodeproj is gitignored)
```

## Architecture

- **UI**: SwiftUI `MenuBarExtra` for playback controls; a separate `Window` hosts settings to keep the dropdown focused on play/pause/progress/speed. The settings window includes an endpoint test action.
- **Audio**: `AVAudioEngine` + `AVAudioPlayerNode` (not `AVPlayer`) so playback speed can be adjusted via `AVAudioUnitTimePitch` without altering pitch.
- **Text**: Reads `NSPasteboard` directly, asynchronously, to avoid blocking the source app.
- **Network**: `URLSession` with HTTP chunked streaming, so playback starts on the first bytes from the TTS provider rather than after the full payload downloads. Minimizing Time-To-First-Byte is a primary design goal.

## Design Assumptions

- **OpenAI-compatible endpoints**: Local TTS engines must expose `/v1/audio/speech`. Cloud APIs that differ (e.g. Google Gemini) get dedicated payload formatters.
- **External toolchain**: `xcodegen` and `swiftlint` are user-managed; the app does not install or modify them.

## Build & Test

Regenerate Xcode project (required after editing `project.yml`):
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

To distribute locally without an Apple Developer Program account (ad-hoc signed, not notarized), run `./package.sh`.
