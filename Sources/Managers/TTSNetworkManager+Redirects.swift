import Foundation

/// Decides where a started request may be redirected, and what it carries when it goes.
///
/// URLSession follows redirects itself, and a 307 or 308 replays the original method and body — the
/// user's clipboard text — at whatever endpoint the response names, so the endpoint checked before
/// the request started does not decide where it ends up. Two rules answer that here, in the order
/// the user can act on them: the target's transport must protect what the request carries, and the
/// target must be the origin that request was built for. Following one is not passing it on
/// unchanged either, because the credentials URLSession leaves on a redirect it builds are not the
/// ones the app authorized.
extension TTSNetworkManager {
    /// Why a redirect target was refused, retained on the request so its completion explains the
    /// refusal rather than the redirect status the provider happened to send alongside it.
    enum RefusedRedirect {
        /// The target would put the saved key and the clipboard text on cleartext.
        case insecureTransport
        /// The target is not the origin this request was given its credential for.
        case foreignOrigin

        /// The app-owned message a request publishes when this refusal is what ended it.
        var failureMessage: String {
            switch self {
            case .insecureTransport:
                return TTSNetworkManager.insecureTransportFailure
            case .foreignOrigin:
                return TTSNetworkManager.foreignOriginRedirectFailure
            }
        }
    }

    /// Applies both redirect rules to a redirect the provider asks the app to follow.
    ///
    /// This runs for metadata tasks as well, which URLSession consults here even though they carry
    /// their own completion handler. A refused target records itself on the active speech request so
    /// completion reports that refusal instead of the redirect status; a discovery task is not that
    /// request, so its refusal stays silent, as every other metadata failure is.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let refusal = refusedRedirect(to: request.url, authorizedBy: task.originalRequest?.url) {
            recordRefusedRedirect(refusal, for: task)
            completionHandler(nil)
            return
        }
        completionHandler(requestCarryingAuthorizedCredentials(request, of: task.originalRequest))
    }

    /// Returns why a redirect target may not be followed, or nil when it may.
    ///
    /// Transport is decided first, so a cleartext target reports the refusal the user has a
    /// documented remedy for even when it is a foreign origin as well. A target this cannot read,
    /// and a task whose own request cannot say which origin authorized it, fail closed.
    private func refusedRedirect(to target: URL?, authorizedBy authorizedOrigin: URL?) -> RefusedRedirect? {
        guard let target, EndpointTransportPolicy.permitsCredentials(target) else {
            return .insecureTransport
        }
        guard let authorizedOrigin, EndpointTransportPolicy.isSameOrigin(target, as: authorizedOrigin) else {
            return .foreignOrigin
        }
        return nil
    }

    /// Records a refusal against the active speech request, when the refused task is that request.
    private func recordRefusedRedirect(_ refusal: RefusedRedirect, for task: URLSessionTask) {
        stateQueue.sync {
            guard var context = activeRequest, task.taskIdentifier == context.taskIdentifier else { return }
            context.refusedRedirect = refusal
            activeRequest = context
        }
    }

    /// Returns the redirect request carrying exactly the credentials its own request authorized.
    ///
    /// URLSession builds this request itself and strips `Authorization` from it — from a
    /// same-origin redirect too — while leaving other headers, `x-goog-api-key` among them, in
    /// place; both were probed against this toolchain. Restoring every credential field from the
    /// request the app created therefore puts back the one this request authenticates with and
    /// removes any other the response introduced, rather than trusting the subset URLSession
    /// happens to preserve. The request is copied instead of rebuilt because the body URLSession
    /// replays is not visible on it: `httpBody` is nil here even for the 307 that resends it.
    private func requestCarryingAuthorizedCredentials(_ request: URLRequest,
                                                      of originalRequest: URLRequest?) -> URLRequest {
        var authorized = request
        for field in CredentialHeaderField.all {
            authorized.setValue(originalRequest?.value(forHTTPHeaderField: field), forHTTPHeaderField: field)
        }
        return authorized
    }
}
