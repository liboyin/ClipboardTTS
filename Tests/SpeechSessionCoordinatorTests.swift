import Combine
import XCTest
@testable import ClipboardTTSApp

/// The one owner every speech entry point starts through: what it refuses, what it replaces, and
/// where a request's audio and terminal event end up.
///
/// The session owner drives `AudioPlayerManager`, whose published state and engine control are
/// main-confined, so every test here runs on the main actor as the entry points do.
@MainActor
final class SpeechSessionCoordinatorTests: MockURLProtocolTestCase {

    func testStartingASessionSpeaksIntoTheAudioGenerationItOpened() {
        // WHY: This is the routing all three entry points gave up owning. If the session's PCM were
        // scheduled against any generation but the one this start took, every chunk would be
        // dropped as stale and the app would go silent while reporting a healthy request.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let audioPlayer = owned.audioPlayer
        let audioScheduled = expectation(description: "The session's PCM is buffered")
        audioScheduled.assertForOverFulfill = false
        MockURLProtocol.installRequestHandler { request in
            (mockHTTPResponse(for: request, statusCode: 200), Data(repeating: 0, count: 2_048))
        }
        let observation = audioPlayer.$hasAudio.sink { if $0 { audioScheduled.fulfill() } }
        defer { observation.cancel() }

        owned.session.start(text: "Speak me")

        wait(for: [audioScheduled], timeout: 2.0)
    }

    func testStartingASessionIsRefusedWhileTheGraphCannotPlayTheSelectedFormat() {
        // WHY: Every entry point used to carry its own version of this guard, or in Test Voice's
        // case a different one entirely. A session started against a graph that cannot play the
        // configured rate would decode the provider's PCM at the wrong rate or never play it, so
        // the refusal has to live with the owner rather than with each caller that remembers it.
        let owned = makeOwnedSpeechSession(sampleRate: 48_001)
        defer { finishSpeechSession(owned) }
        MockURLProtocol.installRequestHandler { request in
            XCTFail("An unplayable audio graph must not start a session")
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }

        owned.session.start(text: "Speak me")

        XCTAssertFalse(owned.networkManager.isStreaming, "A refused session must start no request.")
        XCTAssertFalse(owned.audioPlayer.hasAudio)
    }

    func testStartingASessionDiscardsWhatThePreviousSessionBuffered() {
        // WHY: Services and Test Voice replace whatever is speaking rather than asking for a second
        // click. Opening a new audio generation is what makes that replacement real: reusing the
        // previous one would leave the old speech buffered and splice the new provider's PCM onto
        // the end of it. The player's own generation guard then drops anything still in flight.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let audioPlayer = owned.audioPlayer
        let session = owned.session
        let firstSessionBuffered = expectation(description: "The first session buffers PCM")
        firstSessionBuffered.assertForOverFulfill = false
        MockURLProtocol.installRequestHandler { request in
            (mockHTTPResponse(for: request, statusCode: 200), Data(repeating: 0, count: 2_048))
        }
        let observation = audioPlayer.$hasAudio.sink { if $0 { firstSessionBuffered.fulfill() } }

        session.start(text: "First session")
        wait(for: [firstSessionBuffered], timeout: 2.0)
        observation.cancel()

        let replacementStarted = expectation(description: "The replacing session's request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            replacementStarted.fulfill()
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }
        session.start(text: "Replacing session")

        XCTAssertFalse(
            audioPlayer.hasAudio,
            "Starting a session must discard the audio the session it replaced had buffered."
        )
        wait(for: [replacementStarted], timeout: 2.0)
    }

    func testCancellingASessionReleasesTheRequestItWasStillRunningAndClearsItsAudio() {
        // WHY: This is the menu's Clear Buffer click. Both halves have to happen while the session
        // is genuinely live: stopping the request without clearing the buffer would leave the
        // button offering to clear audio the user already dismissed, and clearing without stopping
        // would let the request that is still running refill it. The response is therefore held
        // open and the PCM handed to the delegate, so the request is still in flight — a response
        // that had already completed would make the request-half assertion pass on its own.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let requestStarted = expectation(description: "The session's request reaches the provider")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }
        let audioBuffered = expectation(description: "The session buffers PCM before it is cancelled")
        audioBuffered.assertForOverFulfill = false
        let observation = owned.audioPlayer.$hasAudio.sink { if $0 { audioBuffered.fulfill() } }
        defer { observation.cancel() }

        owned.session.start(text: "Speak me")
        wait(for: [requestStarted], timeout: 2.0)
        defer { releaseResponse.signal() }
        guard let task = owned.networkManager.activeTaskForTesting else {
            XCTFail("Expected the session to retain the task it started.")
            return
        }
        owned.networkManager.urlSession(
            owned.networkManager.session,
            dataTask: task,
            didReceive: Data(repeating: 0, count: 2_048)
        )
        wait(for: [audioBuffered], timeout: 2.0)
        XCTAssertTrue(owned.networkManager.isStreaming, "The request must still own the pipeline when it is cancelled.")

        owned.session.cancel()

        XCTAssertNil(
            owned.networkManager.activeTaskForTesting,
            "Cancelling must release the request that was still running."
        )
        XCTAssertFalse(owned.audioPlayer.hasAudio, "Cancelling must clear the audio the session buffered.")
        XCTAssertFalse(owned.networkManager.isStreaming, "Cancelling must publish the released pipeline.")
    }

    func testAFinishedRequestEndsItsSessionOnThePlayerItSpokeInto() {
        // WHY: The point of routing both halves through one owner is that the player learns its
        // stream is closed from the very request that fed it. Without this wiring the terminal
        // event would be delivered to nobody, and the buffered stream would stay open forever.
        let owned = makeOwnedSpeechSession()
        defer { finishSpeechSession(owned) }
        let audioPlayer = owned.audioPlayer
        let terminationPublished = expectation(description: "The player records the session's termination")
        terminationPublished.assertForOverFulfill = false
        MockURLProtocol.installRequestHandler { request in
            (mockHTTPResponse(for: request, statusCode: 200), Data(repeating: 0, count: 2_048))
        }
        let observation = audioPlayer.$streamTermination.sink { if $0 != nil { terminationPublished.fulfill() } }
        defer { observation.cancel() }

        owned.session.start(text: "Speak me")

        wait(for: [terminationPublished], timeout: 2.0)
        XCTAssertEqual(audioPlayer.streamTermination, .finished)
        XCTAssertTrue(audioPlayer.hasAudio, "A finished stream keeps the speech it delivered.")
    }
}
