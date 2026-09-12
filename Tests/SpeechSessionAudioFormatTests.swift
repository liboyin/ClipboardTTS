import Combine
import XCTest
@testable import ClipboardTTSApp

/// What replacing the live PCM format does to the session speaking in it: which request the change
/// is paired with, and which changes are paired with nothing at all.
///
/// The session owner drives `AudioPlayerManager`, whose published state and engine control are
/// main-confined, so every test here runs on the main actor as Settings does.
@MainActor
final class SpeechSessionAudioFormatTests: MockURLProtocolTestCase {

    func testChangingTheAudioFormatCancelsTheRequestFeedingTheSessionItInvalidates() {
        // WHY: This is NB9. The player discards audio decoded with the rate being replaced, and the
        // request that was filling it is invalid for the same reason: left running it streams PCM
        // into a retired audio generation, spending the provider call on speech nobody can hear and
        // holding `isStreaming` true so the menu offers to clear a buffer that is already empty.
        // The response is held open and its PCM handed to the delegate, so the request is genuinely
        // in flight when the format changes.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let releaseResponse = DispatchSemaphore(value: 0)
        let held = startHeldSpeechSession(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        defer { held.observation.cancel() }
        wait(for: [held.audioBuffered], timeout: 2.0)

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        XCTAssertNil(
            owned.networkManager.activeTaskForTesting,
            "A changed format must cancel the request feeding the audio it discards."
        )
        XCTAssertFalse(owned.networkManager.isStreaming, "The cancelled request must release the pipeline it published.")
        XCTAssertFalse(owned.audioPlayer.hasAudio, "The audio decoded with the replaced format must be discarded.")
        XCTAssertEqual(owned.audioPlayer.sampleRate, 48_000)
    }

    func testAnUnchangedAudioFormatLeavesTheSessionSpeaking() {
        // WHY: Settings applies a rate on every edit it synchronizes, and all but one of them names
        // the rate already active. Cancelling on those would stop speech the user never asked to
        // stop; no mixed-format PCM can exist when the graph did not change.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let releaseResponse = DispatchSemaphore(value: 0)
        let held = startHeldSpeechSession(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        defer { held.observation.cancel() }
        wait(for: [held.audioBuffered], timeout: 2.0)

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: AudioPlayerManager.defaultSampleRate), .unchanged)

        XCTAssertNotNil(
            owned.networkManager.activeTaskForTesting,
            "An unchanged format must leave the request that owns the pipeline running."
        )
        XCTAssertTrue(owned.networkManager.isStreaming)
        XCTAssertTrue(owned.audioPlayer.hasAudio, "An unchanged format must keep the audio the session buffered.")
    }

    func testAnUnsupportedAudioFormatLeavesTheSessionSpeaking() {
        // WHY: A rate the graph cannot represent applies no format at all, so there is nothing for
        // it to invalidate. Treating the refusal as a change would let a typo in the Settings field
        // cancel a stream that is playing correctly.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let releaseResponse = DispatchSemaphore(value: 0)
        let held = startHeldSpeechSession(owned, releasedBy: releaseResponse)
        defer { releaseResponse.signal() }
        defer { held.observation.cancel() }
        wait(for: [held.audioBuffered], timeout: 2.0)

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_001), .invalid)

        XCTAssertNotNil(
            owned.networkManager.activeTaskForTesting,
            "A refused format must leave the request that owns the pipeline running."
        )
        XCTAssertTrue(owned.networkManager.isStreaming)
        XCTAssertTrue(owned.audioPlayer.hasAudio, "A refused format must keep the audio the session buffered.")
        XCTAssertEqual(owned.audioPlayer.sampleRate, AudioPlayerManager.defaultSampleRate)
    }

    func testAFormatChangeCancelsTheRetryThatContinuesTheSessionsRequest() {
        // WHY: The one automatic retry a Gemini 500 earns continues the same logical request, so it
        // is what the session is paired with once the attempt that started it has ended. A format
        // change that let the retry run on would leave the provider streaming PCM into a retired
        // audio generation — NB9's defect reached through the one path where a request outlives the
        // attempt that opened it.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        configureGeminiProvider(owned.networkManager)
        let attempts = RequestAttemptLog()
        let retryStarted = expectation(description: "The retry reaches the provider")
        let releaseRetry = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            guard attempts.record(request) > 1 else {
                return (mockHTTPResponse(for: request, statusCode: 500), Data("{\"error\":{}}".utf8))
            }
            retryStarted.fulfill()
            _ = releaseRetry.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), geminiAudioEvent(Data([0, 1, 2, 3])))
        }

        owned.session.start(text: "Transient Gemini failure")
        wait(for: [retryStarted], timeout: 2.0)
        defer { releaseRetry.signal() }
        XCTAssertEqual(attempts.count, 2, "The retry must be the request in flight when the format changes.")

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        XCTAssertNil(
            owned.networkManager.activeTaskForTesting,
            "A changed format must cancel the retry continuing the request it invalidates."
        )
        XCTAssertFalse(owned.networkManager.isStreaming, "The cancelled retry must release the pipeline it inherited.")
        releaseRetry.signal()
        drainSpeechDelivery(of: owned.networkManager)
        drainSpeechMainQueueTurn()
        XCTAssertFalse(owned.audioPlayer.hasAudio, "A cancelled retry's PCM must not reach the session.")
    }

    func testAChangedAudioFormatWithNoRequestToCancelLeavesTheRequestGenerationAlone() {
        // WHY: The request generation is how the rest of the app tells that somebody claimed or
        // released the pipeline: the menu's deferred clipboard read drops its click when the count
        // moved while it waited. A format change that cancels nothing must not advance it, or
        // editing the sample rate would silently discard a Speak click and clear the failure the
        // previous request left on screen. Here the request has already ended, so only the audio it
        // delivered is left to discard.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let terminationPublished = expectation(description: "The session's request ends")
        terminationPublished.assertForOverFulfill = false
        MockURLProtocol.installRequestHandler { request in
            (mockHTTPResponse(for: request, statusCode: 200), Data(repeating: 0, count: 2_048))
        }
        let observation = owned.audioPlayer.$streamTermination.sink { if $0 != nil { terminationPublished.fulfill() } }
        defer { observation.cancel() }
        owned.session.start(text: "Speak me")
        wait(for: [terminationPublished], timeout: 2.0)
        XCTAssertNil(owned.networkManager.activeTaskForTesting, "The request must have ended before the format changes.")
        let pipelineGeneration = owned.networkManager.currentRequestGeneration()

        XCTAssertEqual(owned.session.applyAudioFormat(sampleRate: 48_000), .updated)

        XCTAssertEqual(
            owned.networkManager.currentRequestGeneration(),
            pipelineGeneration,
            "A format change with no request paired to it must not claim the pipeline."
        )
        XCTAssertFalse(owned.audioPlayer.hasAudio, "The audio decoded with the replaced format must be discarded.")
    }

}
