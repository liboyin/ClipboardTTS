# Advanced TTS App

## Architecture
The application is structured as a native macOS menu bar app utilizing SwiftUI. The core rationale for this architecture is to provide an unobtrusive, easily accessible global tool for Text-to-Speech (TTS) functionality.

- **UI Layer**: SwiftUI is chosen for its declarative syntax and modern approach to building macOS interfaces, allowing seamless integration with `MenuBarExtra`. A secondary SwiftUI `Window` is utilized for settings management to keep the main menu bar interface uncluttered.
- **Audio Engine**: `AVAudioEngine` and `AVAudioPlayerNode` are used instead of `AVPlayer` to allow for precise real-time control over the audio stream, specifically the ability to manipulate playback speed via `AVAudioUnitTimePitch` without affecting pitch.
- **Text Extraction**: The app relies primarily on `AXUIElement` to interact directly with the frontmost application's accessibility tree. This allows grabbing selected text instantly without polluting the user's clipboard. A fallback to `NSPasteboard` exists for applications that do not properly implement the accessibility API.
- **Networking**: `URLSession` is employed to handle HTTP chunked streaming of the TTS audio payload from OpenAI-compatible APIs (such as Gemini TTS). This ensures that audio playback can begin before the entire payload is downloaded, minimizing latency.

## Dataflow
1. **User Action**: The user highlights text in any application and triggers the app (either via a global shortcut, NSService, or menu bar click).
2. **Text Acquisition**: `TextExtractionManager` queries the active window via `AXUIElement` or `NSPasteboard` to retrieve the target text.
3. **API Request**: `TTSNetworkManager` submits the text to the configured `/v1/audio/speech` endpoint using the credentials stored securely by the app.
4. **Streaming Response**: The API responds with an audio stream. `TTSNetworkManager` passes incoming data chunks to `AudioPlayerManager`.
5. **Playback**: `AudioPlayerManager` schedules the audio buffers via `AVAudioEngine` and adjusts the timing/pitch according to the user's slider preferences.

## Design Decisions & Assumptions
- **OpenAI-Compatible Endpoint Requirement**: We assume the target TTS engine (online or local) exposes an OpenAI-compatible `/v1/audio/speech` endpoint. This simplifies the network layer and allows users to flexibly swap between engines (e.g., local models or cloud-based Gemini/OpenAI).
- **No Direct Environment Modification**: It is assumed that tools like `xcodegen` are either already installed or managed by the user outside of this agent context. This maintains system integrity.
- **Streaming over Pre-generation**: The system is designed to stream audio rather than waiting for the entire file to generate. The design assumes that low latency (Time-To-First-Byte) is critical for a smooth user experience.
- **State Segregation**: All settings are managed in a separate `SettingsView` window to keep the menu bar dropdown focused purely on real-time playback controls (play/pause, progress, speed).
