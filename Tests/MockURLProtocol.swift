import Foundation

/// Intercepts every request made by a mock-routed session and answers it from its test's scope.
///
/// The per-test scope registry lives in `MockURLProtocolScope.swift`, which owns the scope state
/// and shutdown; this half reaches it only through `beginLoad` and `finishLoad`.
class MockURLProtocol: URLProtocol {
    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

    static let testIdentifierHeader = "X-ClipboardTTS-Mock-Test-Identifier"

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let claimedLoad = MockURLProtocol.beginLoad(
            requestedTestIdentifier: request.value(forHTTPHeaderField: MockURLProtocol.testIdentifierHeader)
        ) else {
            failLoading()
            return
        }

        defer { MockURLProtocol.finishLoad(forTestIdentifier: claimedLoad.testIdentifier) }

        guard let handler = claimedLoad.requestHandler else {
            failLoading()
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func failLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(
                .cannotLoadFromNetwork,
                userInfo: [NSLocalizedDescriptionKey: "No MockURLProtocol handler is installed."]
            )
        )
    }

    override func stopLoading() {}
}
