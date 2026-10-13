import Combine
import XCTest
@testable import ClipboardTTSApp

/// Records every metadata completion one manager reports, so a test waits for the event that
/// handled a request rather than for elapsed time.
///
/// Each recorder belongs to the test that made it. `MetadataTestCase` closes it at teardown, once
/// the network scope has closed and the main queue has drained; a completion reported after that,
/// from a session that outlived a scope which did not quiesce, is only counted in
/// `lateCompletionCount`, so it can neither fulfil an expectation nor change what a test reads.
final class MetadataCompletionRecorder: Sendable {
    typealias Completion = TTSNetworkManager.MetadataCompletion

    /// One reported completion, with what the manager held at the moment it was reported.
    struct Record: Equatable, Sendable {
        let completion: Completion
        let onMainThread: Bool
        /// The manager's list of the completion's kind when a publication was reported on the main
        /// queue, which is how a test proves the report follows the publication; otherwise `nil`.
        let listAtReport: ProviderSuggestions?
    }

    private struct Waiter: Sendable {
        let matches: @Sendable (Completion) -> Bool
        var remaining: Int
        let expectation: XCTestExpectation
    }

    private struct State: Sendable {
        weak var manager: TTSNetworkManager?
        var records: [Record] = []
        var waiters: [Waiter] = []
        var isClosed = false
        var lateCompletionCount = 0
    }

    private let state = LockedValue(State())

    var records: [Record] { state.value.records }
    var lateCompletionCount: Int { state.value.lateCompletionCount }

    /// Names the manager whose lists a publication's report is checked against.
    func attach(_ manager: TTSNetworkManager) {
        state.withValue { $0.manager = manager }
    }

    /// Records `completion` and fulfils each waiter it completes; once closed, only counts it.
    func record(_ completion: Completion) {
        let onMainThread = Thread.isMainThread
        var listAtReport: ProviderSuggestions?
        // The lists are main-queue confined, so they are read only where a publication reports.
        if onMainThread, completion.outcome == .published, let manager = state.value.manager {
            listAtReport = completion.kind == .models ? manager.modelSuggestions : manager.voiceSuggestions
        }
        let record = Record(completion: completion, onMainThread: onMainThread, listAtReport: listAtReport)
        state.withValue { state in
            guard !state.isClosed else {
                state.lateCompletionCount += 1
                return
            }
            state.records.append(record)
            for index in state.waiters.indices where state.waiters[index].matches(completion) {
                state.waiters[index].remaining -= 1
                if state.waiters[index].remaining == 0 { state.waiters[index].expectation.fulfill() }
            }
            state.waiters.removeAll { $0.remaining == 0 }
        }
    }

    /// An expectation fulfilled once `count` recorded completions match, counting those already recorded.
    func expectation(_ description: String,
                     count: Int = 1,
                     where matches: @escaping @Sendable (Completion) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        state.withValue { state in
            let remaining = count - state.records.filter { matches($0.completion) }.count
            if remaining <= 0 {
                expectation.fulfill()
            } else if !state.isClosed {
                state.waiters.append(Waiter(matches: matches, remaining: remaining, expectation: expectation))
            }
        }
        return expectation
    }

    /// Stops recording: pending waiters are dropped unfulfilled, and later reports are only counted.
    func close() {
        state.withValue { state in
            state.isClosed = true
            state.waiters.removeAll()
        }
    }
}

/// A mock-network suite that waits for metadata publications and completions instead of elapsed
/// time, and whose teardown owns the publications its requests' completions queued.
class MetadataTestCase: MockURLProtocolTestCase {
    private var recorders: [MetadataCompletionRecorder] = []
    private var publicationObservations: [AnyCancellable] = []

    /// A mock-routed manager whose metadata completions report to a recorder this test owns.
    func makeMetadataManager() -> (TTSNetworkManager, MetadataCompletionRecorder) {
        let recorder = MetadataCompletionRecorder()
        let manager = TestNetworkFactory.makeManager(metadataCompletionObserver: { recorder.record($0) })
        recorder.attach(manager)
        recorders.append(recorder)
        return (manager, recorder)
    }

    /// Expects `publisher` to publish `expected` after this call. The value replayed on subscription
    /// is skipped, and the main queue is drained first, so neither the current list nor a
    /// publication an earlier action had already queued can satisfy it. Call it on the main thread
    /// before the action that should cause the publication.
    func expectPublication(_ publisher: Published<ProviderSuggestions>.Publisher,
                           of expected: ProviderSuggestions,
                           _ description: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) -> XCTestExpectation {
        drainMainQueue(file: file, line: line)
        let published = XCTestExpectation(description: description)
        publicationObservations.append(
            publisher.dropFirst().first { $0 == expected }.sink { _ in published.fulfill() }
        )
        return published
    }

    /// Waits until `recorder` holds `count` matching completions, then drains the main-queue turn a
    /// publication would take, so what follows reads state those completions have finished changing.
    func waitForCompletions(in recorder: MetadataCompletionRecorder,
                            count: Int = 1,
                            _ description: String,
                            file: StaticString = #filePath,
                            line: UInt = #line,
                            where matches: @escaping @Sendable (MetadataCompletionRecorder.Completion) -> Bool) {
        wait(for: [recorder.expectation(description, count: count, where: matches)], timeout: 2.0)
        drainMainQueue(file: file, line: line)
    }

    /// Runs every main-queue block queued before this call. It fails rather than proceeding when the
    /// queue cannot drain, because an undrained queue can still hold a publication the test reads.
    func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) {
        let drained = XCTestExpectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        if XCTWaiter().wait(for: [drained], timeout: 2.0) != .completed {
            XCTFail("The main queue did not drain.", file: file, line: line)
        }
    }

    override func tearDown() {
        publicationObservations.forEach { $0.cancel() }
        publicationObservations.removeAll()
        // Closing the scope runs every completion handler its sessions still owed, so each
        // publication those handlers queued is on the main queue once this returns. They run in the
        // drain below, while this test still owns its recorders, and the recorders close after it.
        super.tearDown()
        drainMainQueue()
        recorders.forEach { $0.close() }
        recorders.removeAll()
    }
}
