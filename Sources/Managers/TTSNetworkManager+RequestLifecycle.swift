import Foundation

/// Starts, replaces, and stops the one speech request this manager owns at a time.
///
/// The endpoint and request-body helpers each attempt calls live in `TTSNetworkManager+Requests`;
/// this file owns the state machine that decides when to call them. Every attempt begins by
/// advancing the request generation under callback authority, so a stream that has been superseded
/// can no longer authorize delivery, and each attempt captures its settings once rather than
/// reading them again as it proceeds.
extension TTSNetworkManager {
    private func replaceActiveRequest(with task: URLSessionDataTask,
                                      provider: ProviderKind,
                                      requestGeneration: UInt64,
                                      dataHandler: @escaping @Sendable (Data) -> Void) -> Bool {
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
                dataHandler: dataHandler
            )
            return true
        }
    }

    /// Cancels the active stream and advances the generation, revoking every queued delivery.
    ///
    /// Each request attempt begins here, and the returned generation is the one that attempt owns.
    /// It publishes no request state, so a caller that must not queue work to the main queue — a
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
