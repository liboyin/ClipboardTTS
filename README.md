# Clipboard TTS App

## Architecture
The application is structured as a native macOS menu bar app utilizing SwiftUI. The core rationale for this architecture is to provide an unobtrusive, easily accessible global tool for Text-to-Speech (TTS) functionality.

- **UI Layer**: SwiftUI is chosen for its declarative syntax and modern approach to building macOS interfaces, allowing seamless integration with `MenuBarExtra`. A secondary SwiftUI `Window` is utilized for settings management to keep the main menu bar interface uncluttered.
- **Audio Engine**: `AVAudioEngine` and `AVAudioPlayerNode` are used instead of `AVPlayer` to allow for precise real-time control over the audio stream, specifically the ability to manipulate playback speed via `AVAudioUnitTimePitch` without affecting pitch.
- **Text Extraction**: The app directly accesses `NSPasteboard` to read text copied by the user.
- **Networking**: `URLSession` is employed to handle HTTP chunked streaming of the TTS audio payload from OpenAI-compatible APIs (such as Gemini TTS). This ensures that audio playback can begin before the entire payload is downloaded, minimizing latency.

## Dataflow Strategy
The dataflow architecture is designed strictly around minimizing Time-To-First-Byte (TTFB) and ensuring zero UI blocking during execution.
- **Decoupled Text Acquisition**: Text extraction from the system pasteboard is kept asynchronous to prevent freezing the active application the user is reading from.
- **Immediate Streaming Pipeline**: Rather than downloading a complete audio payload before playback (which would introduce significant latency for long text), the HTTP layer is configured for chunked streaming. This guarantees that audio playback commences the exact millisecond the first bytes arrive from the TTS provider, creating a real-time responsive feel.

## Design Decisions & Assumptions
- **OpenAI-Compatible Endpoint Requirement**: We assume local TTS engines must provide an OpenAI-compatible `/v1/audio/speech` endpoint. This simplifies the network layer and allows users to flexibly swap between local engines, while native cloud APIs like Google's Gemini are handled with dedicated payload formatters.
- **No Direct Environment Modification**: It is assumed that tools like `xcodegen` are either already installed or managed by the user outside of this agent context. This maintains system integrity.
- **Streaming over Pre-generation**: The system is designed to stream audio rather than waiting for the entire file to generate. The design assumes that low latency (Time-To-First-Byte) is critical for a smooth user experience.
- **State Segregation**: All settings are managed in a separate `SettingsView` window to keep the menu bar dropdown focused purely on real-time playback controls (play/pause, progress, speed). The settings window also provides a test mechanism to verify endpoint configurations before full use.
