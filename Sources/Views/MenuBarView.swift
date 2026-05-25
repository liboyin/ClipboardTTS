import SwiftUI

struct MenuBarView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var textExtraction: TextExtractionManager
    @ObservedObject var networkManager: TTSNetworkManager
    
    @Environment(\.openWindow) var openWindow
    
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
                    if networkManager.isStreaming || audioPlayer.hasAudio {
                        networkManager.stopStreaming()
                        audioPlayer.stop()
                    } else {
                        print("Speak Copied Text button clicked")
                        
                        // Deactivate our app to return focus to the previously active application
                        NSApp.deactivate()
                        
                        // Wait a brief moment for the OS to switch focus back
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if let text = textExtraction.getCopiedText() {
                                print("Extracted text successfully, length: \(text.count)")
                                networkManager.streamTTS(text: text) { data in
                                    audioPlayer.scheduleAudio(data: data)
                                }
                            } else {
                                print("Failed to extract any text")
                            }
                        }
                    }
                }) {
                    Text((networkManager.isStreaming || audioPlayer.hasAudio) ? "Clear Buffer" : "Speak Copied Text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            
            HStack {
                Button(action: {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.play()
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SpeakSelectedText"))) { notification in
            if let text = notification.object as? String {
                networkManager.stopStreaming()
                audioPlayer.stop()
                networkManager.streamTTS(text: text) { data in
                    audioPlayer.scheduleAudio(data: data)
                }
            }
        }
    }
}
