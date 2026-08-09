import Foundation

/// Wires the macOS Services flow into the TTS pipeline from app launch.
///
/// `ServicesProvider.handleServices` posts `speakSelectedTextNotification` with the selected text
/// as its object when the user invokes the "Speak Selected Text with Clipboard TTS" service. This
/// coordinator owns that subscription so the pipeline is live the moment the app starts. Previously
/// the only observer lived on `MenuBarView`, whose body SwiftUI does not build until the menu bar
/// dropdown is first opened, so the service was silently dropped until then.
///
/// Marked `@unchecked Sendable` because NotificationCenter delivers the observation through a
/// `@Sendable` closure on the posting thread. The coordinator's own state needs no further
/// synchronization: `observer` is assigned once in `init` and read only in `deinit`. Every
/// notification is handed to the main actor before it reads either manager's UI or engine state.
final class ServicesCoordinator: ObservableObject, @unchecked Sendable {
    static let speakSelectedTextNotification = Notification.Name("SpeakSelectedText")

    private let audioPlayer: AudioPlayerManager
    private let networkManager: TTSNetworkManager
    private let notificationCenter: NotificationCenter
    private let mainActionExecutor: (@escaping @MainActor @Sendable () -> Void) -> Void
    private let speechActionObserver: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    init(audioPlayer: AudioPlayerManager,
         networkManager: TTSNetworkManager,
         notificationCenter: NotificationCenter = .default,
         mainActionExecutor: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
             if Thread.isMainThread {
                 MainActor.assumeIsolated(action)
             } else {
                 DispatchQueue.main.async(execute: action)
             }
         },
         speechActionObserver: @escaping @MainActor () -> Void = {}) {
        self.audioPlayer = audioPlayer
        self.networkManager = networkManager
        self.notificationCenter = notificationCenter
        self.mainActionExecutor = mainActionExecutor
        self.speechActionObserver = speechActionObserver
        // queue: nil delivers synchronously on the posting thread. Explicitly hand the entire
        // pipeline to main because Services and tests can post from a background queue.
        observer = notificationCenter.addObserver(
            forName: Self.speakSelectedTextNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let text = notification.object as? String else { return }
            self.mainActionExecutor { [weak self] in
                self?.speak(text)
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    @MainActor private func speak(_ text: String) {
        speechActionObserver()
        guard audioPlayer.isReadyForNewStream else { return }
        networkManager.stopStreaming()
        audioPlayer.stop()
        let gen = audioPlayer.startNewStream()
        networkManager.streamTTS(text: text) { [audioPlayer] data in
            audioPlayer.scheduleAudio(data: data, streamGeneration: gen)
        }
    }
}
