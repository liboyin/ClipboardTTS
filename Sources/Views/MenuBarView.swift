import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var textExtraction: TextExtractionManager
    @ObservedObject var networkManager: TTSNetworkManager
    /// The app-lifetime owner of the deferred clipboard read; see `speakCopiedText()`.
    let deferredClipboardAction: DeferredClipboardAction

    @Environment(\.openWindow) var openWindow

    @AppStorage(SettingsKeys.ttsProvider) private var ttsProvider: String = "OpenAI"
    @AppStorage(SettingsKeys.openAIVoice) private var openAIVoice: String = "alloy"
    @AppStorage(SettingsKeys.geminiVoice) private var geminiVoice: String = "Aoede"
    @AppStorage(SettingsKeys.customVoice) private var customVoice: String = ""

    var errorMessage: String? {
        networkManager.lastError ?? audioPlayer.sampleRateError
    }

    var requestErrorView: RequestErrorView? {
        errorMessage.map(RequestErrorView.init)
    }

    var selectedProvider: APIKeyProvider {
        APIKeyProvider(selectedProvider: ttsProvider)
    }

    var selectedVoice: String {
        switch selectedProvider {
        case .openAI:
            return openAIVoice
        case .gemini:
            return geminiVoice
        case .custom:
            return customVoice
        }
    }

    /// Voices eligible for selection by the menu's currently synchronized provider.
    var voiceOptions: [String] {
        guard networkManager.isCurrentProvider(selectedProvider.settingsValue) else { return [] }
        if selectedProvider == .custom {
            return customVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [customVoice]
        }
        return networkManager.availableVoices
    }

    /// Whether neither a network stream nor a retained audio buffer prevents a voice change.
    var isVoiceSelectionEnabled: Bool {
        !networkManager.isStreaming && !audioPlayer.hasAudio
    }

    /// Whether an idle, playable pipeline is available to start speech from the clipboard.
    ///
    /// Spelled out rather than reusing `isVoiceSelectionEnabled`: the two conditions coincide
    /// today, but a change to what may be selected must not silently change what may be spoken.
    var isReadyForNewSpeech: Bool {
        !networkManager.isStreaming && !audioPlayer.hasAudio && audioPlayer.isReadyForNewStream
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { selectedVoice }, set: { selectVoice($0) })
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Clipboard TTS")
                    .font(.headline)
                Spacer()
                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()

            HStack {
                Button(action: {
                    speakCopiedText()
                }) {
                    Text((networkManager.isStreaming || audioPlayer.hasAudio) ? "Clear Buffer" : "Speak Copied Text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if let requestErrorView {
                requestErrorView
                    .padding(.horizontal)
            }

            HStack {
                Button(action: {
                    togglePlayPause()
                }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!audioPlayer.hasAudio)

                Slider(value: Binding(
                    get: { audioPlayer.playbackProgress },
                    set: { audioPlayer.seek(to: $0) }
                ), in: 0...max(0.01, audioPlayer.bufferDuration))
                .disabled(!audioPlayer.hasAudio)
            }
            .padding(.horizontal)

            HStack {
                Text("Speed:")
                Slider(value: $audioPlayer.playbackRate, in: 0.5...2.5, step: 0.1)
                Text(String(format: "%.1fx", audioPlayer.playbackRate))
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal)

            HStack {
                Text("Voice:")
                Picker("Voice", selection: voiceBinding) {
                    ForEach(voiceOptions, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .labelsHidden()
                .disabled(!isVoiceSelectionEnabled)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 300)
        .onAppear(perform: fetchVoiceMetadata)
    }

    func speakCopiedText() {
        if networkManager.isStreaming || audioPlayer.hasAudio {
            networkManager.stopStreaming()
            audioPlayer.stop()
        } else {
            guard isReadyForNewSpeech else { return }
            NSApp.deactivate()
            // The 0.2-second delay lets the menu close before the pasteboard is read, so the
            // readiness observed above can be stale by the time it does: a Services request, a
            // Test Voice request, a Clear Buffer click, or a second Speak click can own the
            // pipeline by then. Starting speech now would replace that work without the Clear
            // Buffer click the two-click contract requires, so revalidate immediately before
            // reading the clipboard or changing any generation. The request generation carries
            // what the published state cannot: a request that already finished may still have
            // accepted audio in flight, which leaves both `isStreaming` and `hasAudio` false while
            // the pipeline is not this attempt's to take. Superseded attempts never arrive here at
            // all; `deferredClipboardAction` drops them.
            let pipelineGeneration = networkManager.currentRequestGeneration()
            deferredClipboardAction.schedule(after: 0.2) {
                guard networkManager.currentRequestGeneration() == pipelineGeneration,
                      isReadyForNewSpeech,
                      let text = textExtraction.getCopiedText() else { return }
                let gen = audioPlayer.startNewStream()
                networkManager.streamTTS(text: text) { [audioPlayer] data in
                    audioPlayer.scheduleAudio(data: data, streamGeneration: gen)
                }
            }
        }
    }

    func togglePlayPause() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.play()
        }
    }

    /// Saves an idle menu choice for the selected provider and applies it to future requests only.
    func selectVoice(_ voice: String) {
        guard isVoiceSelectionEnabled, voiceOptions.contains(voice) else { return }
        switch selectedProvider {
        case .openAI:
            openAIVoice = voice
        case .gemini:
            geminiVoice = voice
        case .custom:
            customVoice = voice
        }
        networkManager.updateVoice(voice)
    }

    private func fetchVoiceMetadata() {
        networkManager.fetchAvailableVoicesForCurrentProvider()
    }
}

/// An AppKit-backed, accessible request-failure label that wraps within the menu width.
struct RequestErrorView: NSViewRepresentable {
    let message: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemRed
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setAccessibilityIdentifier("tts-request-error")
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = message
    }
}
