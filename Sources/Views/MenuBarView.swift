import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var textExtraction: TextExtractionManager
    @ObservedObject var networkManager: TTSNetworkManager

    @Environment(\.openWindow) var openWindow

    var errorMessage: String? {
        networkManager.lastError
    }

    var requestErrorView: RequestErrorView? {
        errorMessage.map(RequestErrorView.init)
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
            .padding(.bottom)
        }
        .frame(width: 300)
    }

    func speakCopiedText() {
        if networkManager.isStreaming || audioPlayer.hasAudio {
            networkManager.stopStreaming()
            audioPlayer.stop()
        } else {
            NSApp.deactivate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let text = textExtraction.getCopiedText() {
                    let gen = audioPlayer.startNewStream()
                    networkManager.streamTTS(text: text) { data in
                        audioPlayer.scheduleAudio(data: data, streamGeneration: gen)
                    }
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
