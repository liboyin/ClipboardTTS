# Clipboard TTS: An Improved macOS TTS Service

## App Appearance

- The app should reside in the menu bar, with a macOS native look and feel (built using Native Swift/SwiftUI).
- Clicking on the app button in the menu bar should open a drop-down menu with the following options:
    - Speak Copied Text/Stop
    - A progress slider representing the currently buffered audio. Its maximum length grows as more audio arrives dynamically. Once the entire audio is buffered, also start showing remaining time. All times should be precise to the second.
    - Pause/Resume
    - Playback Speed, adjusted with a continuous slider from 0.5x to 2.5x (0.1x increments)
    - Voice (all available voices via OpenAI API, only changeable during idle state)
    - Settings (Model Selection, API Key, Local/Online API Base URL, Test Voice, About, etc.)
- The menu bar icon should change to reflect the current state (Idle, Playing, Paused).

## Starting Playback

- The user should be able to select text in any application and right-click -> Services -> click "Speak Selected Text with Clipboard TTS" to send to TTS engine for playback. Note that Services is not available in all applications, so there is also the next item.
- The user should be able to copy text in any application and click "Speak Copied Text" from the menu bar app to send to TTS engine for playback. 
- The app should start streaming audio within 2 seconds after the user clicks the button.
- If the user triggers "Speak Copied Text" while audio is already playing, the app should interrupt the current playback and immediately start playing the new text.

### Control & Navigation During Playback
- The user should be able to pause and resume the currently playing audio from the menu bar.
- The user should be able to stop playback entirely from the menu bar to cancel a read and discard content that has yet to be sent to the TTS engine.
- The user should be able to change the playback speed anywhere from 0.5x to 2.5x (continuous slider, 0.1x increments) during playback.
- The user should be able to drag the slider thumb to jump to a precise point in the buffered audio.
