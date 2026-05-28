# Clipboard TTS App

## Architecture

A menu bar app provides an unobtrusive, always-available TTS tool.

- **UI**: SwiftUI `MenuBarExtra` for playback controls; a separate `Window` hosts settings to keep the dropdown focused on play/pause/progress/speed. The settings window includes an endpoint test action.
- **Audio**: `AVAudioEngine` + `AVAudioPlayerNode` (not `AVPlayer`) so playback speed can be adjusted via `AVAudioUnitTimePitch` without altering pitch.
- **Text**: Reads `NSPasteboard` directly, asynchronously, to avoid blocking the source app.
- **Network**: `URLSession` with HTTP chunked streaming, so playback starts on the first bytes from the TTS provider rather than after the full payload downloads. Minimizing Time-To-First-Byte is a primary design goal.

## Design Assumptions

- **OpenAI-compatible endpoints**: Local TTS engines must expose `/v1/audio/speech`. Cloud APIs that differ (e.g. Google Gemini) get dedicated payload formatters.
- **External toolchain**: `xcodegen` and related tools are user-managed; the app does not install or modify them.
