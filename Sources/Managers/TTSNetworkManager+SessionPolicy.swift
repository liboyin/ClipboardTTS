import Foundation

extension TTSNetworkManager {
    /// Request routing a caller may layer onto the production session policy, and nothing else.
    ///
    /// The manager always builds its session from `productionSessionConfiguration()`; this type
    /// can name only where requests are loaded and which headers they carry, so no caller can
    /// substitute or alter that policy's cache, cookie, or credential settings. Production passes
    /// no routing. Installing protocol classes does not remove the system's own HTTP loader, so a
    /// request that no installed protocol claims still reaches the network: a layer meant to keep
    /// requests on the machine must claim every one of them.
    struct SessionRouting {
        /// The URL-loading protocols that replace the configuration's own list, tried in order.
        let protocolClasses: [AnyClass]
        /// Headers added to every request the session sends.
        let additionalHeaders: [String: String]

        init(protocolClasses: [AnyClass], additionalHeaders: [String: String] = [:]) {
            self.protocolClasses = protocolClasses
            self.additionalHeaders = additionalHeaders
        }

        /// Fails every request locally, before any connection is attempted.
        static var refusingEveryRequest: SessionRouting {
            SessionRouting(protocolClasses: [RefusingURLProtocol.self])
        }
    }

    /// Builds the app's non-persistent transport policy before a session is created.
    ///
    /// Speech requests contain a credential and user-selected text, so the session neither retains
    /// responses nor participates in cookie or credential stores shared with other sessions.
    static func productionSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Returns the configuration every manager session is built from: the production policy, with
    /// the caller's routing, if any, applied on top of it.
    static func sessionConfiguration(routing: SessionRouting?) -> URLSessionConfiguration {
        let configuration = productionSessionConfiguration()
        if let routing {
            configuration.protocolClasses = routing.protocolClasses
            configuration.httpAdditionalHeaders = routing.additionalHeaders
        }
        return configuration
    }
}

/// Claims every request and fails it with a URL-loading error, performing no I/O.
///
/// The hosted XCTest app's own startup graph routes through this, so a manager that graph returns
/// cannot send anything off the machine whatever a test, or a notification posted in the test
/// process, asks of it. It must claim every request: one it declined would fall through to the
/// system's HTTP loader.
final class RefusingURLProtocol: URLProtocol {
    /// Identifies this protocol's refusal among other URL-loading failures.
    static let refusalDescription = "This session refuses every request."

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(
                .cannotLoadFromNetwork,
                userInfo: [NSLocalizedDescriptionKey: Self.refusalDescription]
            )
        )
    }

    override func stopLoading() {}
}
