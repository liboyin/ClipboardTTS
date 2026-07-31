import Foundation

/// Wires the macOS Services flow into the TTS pipeline from app launch.
///
/// `ServicesProvider.handleServices` posts `speakSelectedTextNotification` with the selected text
/// as its object when the user invokes the "Speak Selected Text with Clipboard TTS" service. This
/// coordinator owns that subscription so the pipeline is live the moment the app starts. Previously
/// the only observer lived on `MenuBarView`, whose body SwiftUI does not build until the menu bar
/// dropdown is first opened, so the service was silently dropped until then.
final class ServicesCoordinator: ObservableObject {
    static let speakSelectedTextNotification = Notification.Name("SpeakSelectedText")

    private let audioPlayer: AudioPlayerManager
    private let networkManager: TTSNetworkManager
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    init(audioPlayer: AudioPlayerManager,
         networkManager: TTSNetworkManager,
         notificationCenter: NotificationCenter = .default) {
        self.audioPlayer = audioPlayer
        self.networkManager = networkManager
        self.notificationCenter = notificationCenter
        // queue: nil delivers synchronously on the posting thread. Services messages are dispatched
        // on the main thread, so the pipeline runs on main just as it did from MenuBarView's view.
        observer = notificationCenter.addObserver(
            forName: Self.speakSelectedTextNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let text = notification.object as? String else { return }
            self.speak(text)
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    private func speak(_ text: String) {
        guard audioPlayer.isReadyForNewStream else { return }
        networkManager.stopStreaming()
        audioPlayer.stop()
        let gen = audioPlayer.startNewStream()
        networkManager.streamTTS(text: text) { [audioPlayer] data in
            audioPlayer.scheduleAudio(data: data, streamGeneration: gen)
        }
    }
}
