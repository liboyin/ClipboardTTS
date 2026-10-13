import Foundation
import XCTest
@testable import ClipboardTTSApp

/// Proves `MetadataTestCase`'s own teardown ends a metadata test's lifecycle: a publication its
/// requests queued runs, and is recorded, before teardown returns, and the test's recorders are
/// closed against anything reported later.
///
/// Each test drives a `MetadataTestCase` scope of its own through `setUp()` and `tearDown()`. That
/// scope opens and closes the mock-network scope itself, so this suite needs no enclosing one and is
/// a plain `XCTestCase`.
@MainActor
final class MetadataTestSupportTests: XCTestCase {
    func testTeardownRunsAQueuedPublicationBeforeClosingItsRecorder() throws {
        // WHY: A publication a request queued belongs to the test that made it. Teardown that skipped
        // its drain would let it land in a later test, and closing before the drain would count the
        // test's own work as late; a recorder never closed would keep fulfilling a finished test.
        let scope = MetadataTestCase()
        scope.setUp()
        var didTearDown = false
        defer {
            if !didTearDown { scope.tearDown() }
            scope.drainMainQueue()
        }
        let (manager, recorder) = scope.makeMetadataManager()
        let endpoint = "https://generativelanguage.googleapis.com/v1beta"
        manager.updateSettings(baseURL: endpoint, apiKey: "owned-key", model: "gemini-3.1-flash-tts-preview",
                               voice: "Aoede", selectedProvider: "Gemini")
        // Gemini's catalog needs no request, so its publication is queued to main before this returns.
        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "owned-key", selectedProvider: "Gemini")
        let token = try XCTUnwrap(manager.metadataTokenForTesting(for: .models))

        // No main-queue turn has run since the fetch queued its publication.
        scope.tearDown()
        didTearDown = true

        XCTAssertEqual(recorder.records.map(\.completion.outcome), [.published],
                       "Teardown must run the queued publication before it returns.")
        XCTAssertEqual(recorder.lateCompletionCount, 0, "Work queued before teardown must run before the recorder closes.")
        let recordsAtTeardown = recorder.records
        manager.publishMetadataForTesting(["late-model"], for: .models, token: token)
        scope.drainMainQueue()
        XCTAssertEqual(recorder.records, recordsAtTeardown, "Teardown must close the recorder against later reports.")
        XCTAssertEqual(recorder.lateCompletionCount, 1)
    }

    func testClosingTheMockScopeWaitsForADiscoveryCompletionAlreadyInFlight() {
        // WHY: Teardown drains the main queue once the mock scope has closed, which covers a
        // completion's publication only if closing the scope waited out every completion handler
        // its session still owed. A handler still running then could queue a publication after the
        // drain, into a later test.
        let scope = MetadataTestCase()
        scope.setUp()
        var didTearDown = false
        let entered = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let finished = LockedValue(false)
        let manager = TestNetworkFactory.makeManager(metadataCompletionObserver: { _ in
            entered.signal()
            // A bounded negative window, as in AudioPlayerOwnerTests: a scope that closed without
            // waiting returns at once, while a correct one waits out this held handler.
            _ = released.wait(timeout: .now() + 1.0)
            finished.withValue { $0 = true }
        })
        defer {
            released.signal()
            if !didTearDown { scope.tearDown() }
            manager.session.delegateQueue.waitUntilAllOperationsAreFinished()
        }
        let endpoint = "https://custom.example/v1/audio/speech"
        manager.updateSettings(baseURL: endpoint, apiKey: "owned-key", model: "model", voice: "voice", selectedProvider: "Custom")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("malformed".utf8))
        }
        manager.fetchAvailableModels(baseURL: endpoint, apiKey: "owned-key", selectedProvider: "Custom")
        XCTAssertEqual(entered.wait(timeout: .now() + 2.0), .success,
                       "Precondition: a discovery completion is held on the session's delegate queue.")

        scope.tearDown()
        didTearDown = true
        let completedAtReturn = finished.value
        released.signal()
        manager.session.delegateQueue.waitUntilAllOperationsAreFinished()

        XCTAssertTrue(completedAtReturn, "Closing the mock scope must wait out its discovery completion handler.")
    }
}
