import Foundation

/// Starts, retries, replaces, and stops the one speech request this manager owns at a time.
///
/// The endpoint and request-body helpers each attempt calls live in `TTSNetworkManager+Requests`;
/// this file owns the state machine that decides when to call them. Every request the user starts
/// begins by advancing the request generation under callback authority, so a stream that has been
/// superseded can no longer authorize delivery, and it captures its settings once rather than
/// reading them again as it proceeds. Its automatic retry is the exception that proves the rule:
/// the retry continues that same request, so it inherits the generation and captured request
/// instead of claiming new ones.
extension TTSNetworkManager {
    /// The inputs a finished attempt hands to the one automatic retry it is allowed.
    ///
    /// It carries the request that was actually sent rather than a way to rebuild one, so the retry
    /// replays the same endpoint, credentials, model, voice, and text even when Settings changed
    /// while the first attempt was in flight, and it keeps the handler and cancellation generation
    /// of the logical request the user started.
    struct RetryAttempt {
        let request: URLRequest
        let provider: ProviderKind
        let requestGeneration: UInt64
        let dataHandler: @Sendable (Data) -> Void
    }

    private func replaceActiveRequest(with task: URLSessionDataTask,
                                      request: URLRequest,
                                      provider: ProviderKind,
                                      requestGeneration: UInt64,
                                      dataHandler: @escaping @Sendable (Data) -> Void,
                                      isRetryAttempt: Bool = false) -> Bool {
        stateQueue.sync {
            // Swap all task-owned state together so a previous task cannot deliver its data to
            // the new handler in the window between cancellation and context replacement.
            guard self.requestGeneration == requestGeneration else { return false }
            activeRequest?.task.cancel()
            activeRequest = ActiveRequestContext(
                task: task,
                taskIdentifier: task.taskIdentifier,
                requestGeneration: requestGeneration,
                provider: provider,
                request: request,
                dataHandler: dataHandler,
                isRetryAttempt: isRetryAttempt
            )
            return true
        }
    }

    /// Starts the single automatic retry a completed attempt earned, reporting whether it began.
    ///
    /// The retry continues the same logical request instead of starting a new one: it reuses the
    /// captured request and cancellation generation rather than advancing one, so it publishes no
    /// state of its own and `isStreaming` stays truthfully active across the handoff. A stop, Clear
    /// Buffer, or replacement in the meantime has already advanced that generation, so installation
    /// fails here and the caller publishes nothing — the generation guard that rejects the retry is
    /// the same one that suppresses this request's now-stale failure. It takes no callback
    /// authority because it neither revokes a generation nor authorizes a delivery.
    func startRetryAttempt(_ attempt: RetryAttempt) -> Bool {
        let task = session.dataTask(with: attempt.request)
        guard replaceActiveRequest(
            with: task,
            request: attempt.request,
            provider: attempt.provider,
            requestGeneration: attempt.requestGeneration,
            dataHandler: attempt.dataHandler,
            isRetryAttempt: true
        ) else {
            task.cancel()
            return false
        }
        task.resume()
        return true
    }

    /// Cancels the active stream and advances the generation, revoking every queued delivery.
    ///
    /// Every user-started request begins here, and the returned generation is the one it owns until
    /// something supersedes it; its automatic retry continues that generation rather than taking a
    /// new one. It publishes no request state, so a caller that must not queue work to the main queue — a
    /// test tearing a manager down off-main — can revoke delivery through it directly.
    @discardableResult
    func revokeActiveRequest() -> UInt64 {
        callbackAuthority.lock()
        defer { callbackAuthority.unlock() }
        return stateQueue.sync {
            activeRequest?.task.cancel()
            activeRequest = nil
            requestGeneration &+= 1
            return requestGeneration
        }
    }

    func streamTTS(text: String, dataHandler: @escaping @Sendable (Data) -> Void) {
        if deferRequestStartIfPublishingState({ [weak self] in
            self?.streamTTS(text: text, dataHandler: dataHandler)
        }) {
            return
        }
        let requestGeneration = revokeActiveRequest()
        clearLastError(requestGeneration: requestGeneration)
        let settings = requestSettingsSnapshot()
        guard settings.provider != .custom || hasNonWhitespaceModelAndVoice(settings) else {
            publishFailure("Custom TTS requires a model and voice. Update Settings and try again.", requestGeneration: requestGeneration)
            return
        }
        let url: URL
        switch requestEndpoint(for: settings) {
        case .allowed(let endpoint):
            url = endpoint
        case .malformed:
            publishFailure("TTS configuration is invalid. Check the API endpoint and try again.", requestGeneration: requestGeneration)
            return
        case .insecureTransport:
            publishFailure(Self.insecureTransportFailure, requestGeneration: requestGeneration)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if settings.provider == .gemini {
            request.setValue(settings.apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try encodedRequestBody(text: text, settings: settings)
        } catch {
            publishFailure("Couldn't prepare the speech request. Check the settings and try again.", requestGeneration: requestGeneration)
            return
        }

        let task = session.dataTask(with: request)
        guard replaceActiveRequest(
            with: task,
            request: request,
            provider: settings.provider,
            requestGeneration: requestGeneration,
            dataHandler: dataHandler
        ) else {
            task.cancel()
            return
        }

        setStreaming(true, requestGeneration: requestGeneration)
        task.resume()
    }

    func stopStreaming() {
        let requestGeneration = revokeActiveRequest()
        clearLastError(requestGeneration: requestGeneration)
        setStreaming(false, requestGeneration: requestGeneration)
    }
}
