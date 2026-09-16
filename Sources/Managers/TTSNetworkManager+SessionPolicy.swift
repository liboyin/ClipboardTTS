import Foundation

extension TTSNetworkManager {
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
}
