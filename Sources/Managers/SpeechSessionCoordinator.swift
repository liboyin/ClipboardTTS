import Foundation

/// How the request feeding one speech session ended.
///
/// A session's terminal event is delivered behind every byte of PCM that request accepted, so a
/// client can tell a stream that is still open from one that will receive nothing more.
/// Cancellation is deliberately not a termination: revoking a session withdraws its pending
/// terminal event along with its pending audio, because the session it would describe no longer
/// owns the pipeline.
enum SpeechStreamTermination: Equatable {
    /// The request finished without publishing a failure.
    case finished
    /// The request published a user-facing failure; `TTSNetworkManager.lastError` carries its text.
    case failed
}

/// The client one speech request delivers to: every byte of its PCM, then exactly one terminal
/// event describing how it ended.
///
/// The two travel together because they are one contract: a client that receives audio is owed the
/// event that says no more is coming, and both reach it through the same guarded, ordered handoff.
struct SpeechStreamClient: Sendable {
    let didReceiveAudio: @Sendable (Data) -> Void
    let didTerminate: @Sendable (SpeechStreamTermination) -> Void
}

/// The single owner of a speech session: what is speaking, the audio it is speaking into, and when
/// that session ends.
///
/// The menu, the macOS Services flow, and Settings' Test Voice each used to sequence the two
/// managers themselves, so the same cancel/reset/capture/forward dance existed in three places and
/// could drift in any one of them. Each entry point keeps the policy that is genuinely its own —
/// the menu's deferred clipboard read, idle revalidation, and OpenAI length refusal, and Settings'
/// provider synchronization and audio-format validation — and this type owns only what all three
/// do identically.
///
/// A session is named by the audio generation `AudioPlayerManager.startNewStream()` returns, which
/// is what makes delivery revocable from both ends: the network manager refuses to authorize a
/// delivery once its request generation moves on, and the player refuses one whose stream
/// generation is no longer current. Neither a late PCM chunk nor a late terminal event can
/// therefore reach the session that replaced it.
///
/// State is confined to the main queue, where all three entry points run: `AudioPlayerManager`'s
/// published properties and its `AVAudioEngine` control both require it.
final class SpeechSessionCoordinator: ObservableObject {
    private let audioPlayer: AudioPlayerManager
    private let networkManager: TTSNetworkManager

    init(audioPlayer: AudioPlayerManager, networkManager: TTSNetworkManager) {
        self.audioPlayer = audioPlayer
        self.networkManager = networkManager
    }

    /// Speaks `text` in a new session, replacing whichever session owned the pipeline.
    ///
    /// It refuses while the audio graph cannot play the selected format, because a session started
    /// against a stopped or misconfigured graph would either decode the provider's PCM at the wrong
    /// rate or never play it at all.
    ///
    /// Replacing the previous session takes exactly two steps, because each manager already revokes
    /// its own half: `startNewStream()` retires the old audio generation and discards what it had
    /// buffered, and `streamTTS` opens by revoking the old request. Cancelling the request here as
    /// well would advance the request generation twice for one action, and the menu's deferred
    /// clipboard read reads that count as the number of requests a click started. The window
    /// between the two steps is safe in both directions: PCM the old request authorized carries the
    /// retired audio generation, and its terminal event names a stream the player no longer has.
    func start(text: String) {
        guard audioPlayer.isReadyForNewStream else { return }
        let generation = audioPlayer.startNewStream()
        networkManager.streamTTS(text: text, client: SpeechStreamClient(
            didReceiveAudio: { [audioPlayer] data in
                audioPlayer.scheduleAudio(data: data, streamGeneration: generation)
            },
            didTerminate: { [audioPlayer] termination in
                audioPlayer.finishStream(streamGeneration: generation, termination: termination)
            }
        ))
    }

    /// Applies a PCM sample rate to the audio graph, ending the session a changed format invalidates.
    ///
    /// The format decides how a session's PCM is decoded, so audio buffered under the rate being
    /// replaced is unplayable and the player discards it. Its request is unplayable for the same
    /// reason and has to go with it: left running, it would stream PCM the player's retired audio
    /// generation drops byte by byte, spending the provider call and the user's quota on speech
    /// nobody can hear, and holding `isStreaming` true so the menu offers to clear a buffer that is
    /// already empty. Each manager still revokes its own half, as when a session is replaced: the
    /// request is cancelled here and `setSampleRate` clears the audio, so one change advances each
    /// generation once.
    ///
    /// The request is released before the graph is touched, as `cancel()` releases it before the
    /// audio, so a session's two halves always end in that order. That order is load-bearing rather
    /// than tidy: rebuilding the graph takes long enough for the request to complete inside it, and
    /// a cancellation arriving afterwards would find nothing to cancel and leave the finished
    /// request publishing the failure of a session this change had already retired.
    ///
    /// Only a rate that genuinely replaces the active format reaches the cancellation, and
    /// `stopActiveSpeechRequest` cancels only while a logical request owns the pipeline — its one
    /// permitted retry included. An unsupported rate applies no format, an unchanged one keeps the
    /// session speaking, and a change with nothing paired to it leaves the request generation where
    /// it was — which is what a menu click waiting out its deferred clipboard read, and a failure
    /// still on screen from the request before it, both depend on.
    func applyAudioFormat(sampleRate: Double) -> AudioPlayerManager.SampleRateUpdateResult {
        if audioPlayer.changesAudioFormat(to: sampleRate) {
            networkManager.stopActiveSpeechRequest()
        }
        return audioPlayer.setSampleRate(sampleRate)
    }

    /// Ends the session that owns the pipeline, cancelling its request and clearing its audio.
    func cancel() {
        networkManager.stopStreaming()
        audioPlayer.stop()
    }
}
