# Advanced TTS App Implementation Plan

We will build "Advanced TTS" as a native macOS application using Swift and SwiftUI. The app will live entirely in the menu bar and support streaming audio from either an online API (like Gemini TTS) or a local API that is compatible with the OpenAI TTS format.

## Architecture

We will create a new Xcode project using `xcodegen`.
- **UI**: SwiftUI with a `MenuBarExtra` scene for the drop-down and a separate `Window` for settings.
- **Audio Engine**: `AVAudioEngine` for streaming audio chunks and adjusting playback speed using `AVAudioUnitTimePitch`.
- **Text Extraction**: Reads copied text directly from `NSPasteboard`.
- **Network**: Standard `URLSession` data tasks to stream JSON audio data from the OpenAI-compatible `/v1/audio/speech` endpoints.

## Proposed Components

### 1. `project.yml`
Configuration file for `xcodegen` to generate the `.xcodeproj`. It will define the macOS App target, `Info.plist` settings (including the `NSServices` and `LSUIElement` for the menu bar app).

### 2. `Sources/AdvancedTTSApp.swift`
The main entry point using SwiftUI's `@main`. It will use `MenuBarExtra` to define the menu bar icon and drop-down menu.

### 3. `Sources/Views/MenuBarView.swift`
The SwiftUI view for the drop-down menu. It will contain:
- "Speak Copied Text" / "Stop" buttons
- Custom Slider for playback progress & buffering (Slider max value grows dynamically as chunks buffer).
- Play/Pause toggle
- Playback speed picker (0.5x to 2.5x)
- Settings button

### 4. `Sources/Views/SettingsView.swift`
A separate window for configuration:
- API Base URL (defaults to online API)
- API Key (stored securely)
- Model/Voice selection

### 5. `Sources/Managers/TextExtractionManager.swift`
Handles extracting copied text:
- Reads copied text directly from `NSPasteboard`.
- Handles the `NSService` callback from the macOS right-click menu.

### 6. `Sources/Managers/TTSNetworkManager.swift`
Handles the HTTP streaming connection to the TTS API:
- Sends text to the `/v1/audio/speech` endpoint.
- Receives the audio stream and passes data chunks to the `AudioEngine`.

### 7. `Sources/Managers/AudioPlayerManager.swift`
Handles audio playback and speed control:
- Uses `AVAudioEngine` and `AVAudioPlayerNode` to stream audio chunks seamlessly.
- Exposes buffering progress, current playback time, and handles pausing/resuming.
- Supports `AVAudioUnitTimePitch` to adjust playback speed without altering pitch.
- Instantly interrupts playback if a new TTS request comes in.
