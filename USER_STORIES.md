# Clipboard TTS: An Improved macOS TTS Service

## App Appearance

- The app should reside in the menu bar, with a macOS native look and feel (built using Native Swift/SwiftUI).
- Clicking on the app button in the menu bar should open a drop-down menu with the following options:
    - Speak Copied Text/Clear Buffer
    - A progress slider representing the currently buffered audio. Its maximum length grows as more audio arrives dynamically.
    - Pause/Resume
    - Playback Speed, adjusted with a continuous slider from 0.5x to 2.5x (0.1x increments)
    - Settings (Model Selection, Voice Selection, API Key, Local/Online API Base URL, Test Voice, About, etc.). The provider list is a left sidebar with About below it, and the configuration pane fills the window at any window size.
- Voice selection lives only in Settings, alongside the model and API key it belongs with. The drop-down is for playback control; it neither offers nor displays the configured voice.
- The menu bar icon is a fixed `waveform.circle` and does not reflect playback state. The stateful-icon requirement was withdrawn on 2026-08-03 and is not planned.

## Starting Playback

- The user should be able to select text in any application and right-click -> Services -> click "Speak Selected Text with Clipboard TTS" to send to TTS engine for playback. Note that Services is not available in all applications, so there is also the next item.
- The user should be able to copy text in any application and click "Speak Copied Text" from the menu bar app to send to TTS engine for playback. 
- The app should start streaming audio within 2 seconds after the user clicks the button.
- When OpenAI is the selected provider and the copied text is longer than the 4,096 characters OpenAI accepts in one request, the click starts no request and shows a pop-up naming that maximum and how long the copied text is, so the user learns what is wrong instead of waiting for a generic failure. Text within the limit, Gemini and Custom requests, the Services entry point, and Settings' Test Voice are unaffected.
- While audio is streaming or buffered, the "Speak Copied Text" button becomes "Clear Buffer": clicking it stops playback and discards the buffer. Speaking new text is a second click of "Speak Copied Text" — the app deliberately does not interrupt-and-replace in one click.

### Control & Navigation During Playback
- The user should be able to pause and resume the currently playing audio from the menu bar.
- The user should be able to stop playback entirely from the menu bar to cancel a read and discard content that has yet to be sent to the TTS engine.
- The user should be able to change the playback speed anywhere from 0.5x to 2.5x (continuous slider, 0.1x increments) during playback.
- The user should be able to drag the slider thumb to jump to a precise point in the buffered audio.
