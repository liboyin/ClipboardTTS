import Foundation

extension TTSNetworkManager {
    private struct TaskCompletionResult {
        let provider: ProviderKind?
        let requestGeneration: UInt64?
        let responseStatusCode: Int?
        let providerAudioByteCount: Int
        let hasGeminiStreamFailure: Bool
        let hasIncompleteGeminiEvent: Bool
        let didRefuseInsecureRedirect: Bool
        let retryAttempt: RetryAttempt?
        let isStale: Bool
    }

    private func processCompletedTask(_ task: URLSessionTask, error: Error?) -> TaskCompletionResult {
        stateQueue.sync {
            guard let context = activeRequest, task.taskIdentifier == context.taskIdentifier else {
                return TaskCompletionResult(
                    provider: nil,
                    requestGeneration: nil,
                    responseStatusCode: nil,
                    providerAudioByteCount: 0,
                    hasGeminiStreamFailure: false,
                    hasIncompleteGeminiEvent: false,
                    didRefuseInsecureRedirect: false,
                    retryAttempt: nil,
                    isStale: true
                )
            }

            let result = TaskCompletionResult(
                provider: context.provider,
                requestGeneration: context.requestGeneration,
                responseStatusCode: context.responseStatusCode,
                providerAudioByteCount: context.providerAudioByteCount,
                hasGeminiStreamFailure: context.hasGeminiStreamFailure,
                hasIncompleteGeminiEvent: context.geminiEventParser.hasIncompleteEvent,
                didRefuseInsecureRedirect: context.didRefuseInsecureRedirect,
                retryAttempt: context.hasGeminiStreamFailure ? nil : permittedRetryAttempt(for: context, error: error),
                isStale: false
            )
            if !context.hasGeminiStreamFailure {
                activeRequest = nil
            }
            return result
        }
    }

    /// Returns the inputs for the one automatic retry this completion earns, or nil when it earns none.
    ///
    /// Google documents that a Gemini TTS model rarely emits text tokens instead of audio, that the
    /// server then fails the request with HTTP 500, and that an application should retry those
    /// automatically. Only that failure qualifies. Another provider, another status, a transport
    /// error alongside the response, and an attempt that is already the retry all publish their
    /// failure instead, which is what keeps recovery bounded to one extra attempt and keeps every
    /// other error the user must act on immediately visible.
    private func permittedRetryAttempt(for context: ActiveRequestContext, error: Error?) -> RetryAttempt? {
        guard context.provider == .gemini,
              !context.isRetryAttempt,
              context.responseStatusCode == 500,
              error == nil else {
            return nil
        }
        return RetryAttempt(
            request: context.request,
            provider: context.provider,
            requestGeneration: context.requestGeneration,
            dataHandler: context.dataHandler
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = processCompletedTask(task, error: error)
        if result.isStale { return }
        // A retry that starts owns the rest of this logical request, including what it publishes.
        if let retryAttempt = result.retryAttempt, startRetryAttempt(retryAttempt) { return }
        let requestGeneration: UInt64?
        if result.hasGeminiStreamFailure {
            guard let dataTask = task as? URLSessionDataTask,
                  let revocation = revokeFailedGeminiRequest(for: dataTask) else {
                return
            }
            requestGeneration = revocation.requestGeneration
        } else {
            requestGeneration = result.requestGeneration
        }

        if let failureMessage = userFacingFailure(for: result, error: error) {
            publishFailure(failureMessage, requestGeneration: requestGeneration)
        } else {
            setStreaming(false, requestGeneration: requestGeneration)
        }
    }

    /// Returns the app-owned message a finished request must publish, or nil when it succeeded.
    ///
    /// The order is the order of what the user can act on: a refused redirect explains itself
    /// before the redirect status the provider happened to send, and an HTTP status explains
    /// itself before the transport error that may accompany it.
    private func userFacingFailure(for result: TaskCompletionResult, error: Error?) -> String? {
        let noPlayableAudio = "The TTS service returned no playable audio. Please try again."
        if result.didRefuseInsecureRedirect {
            return Self.insecureTransportFailure
        } else if let statusCode = result.responseStatusCode, !(200...299).contains(statusCode) {
            return userFacingHTTPError(statusCode: statusCode)
        } else if result.provider == .gemini && result.hasGeminiStreamFailure {
            return noPlayableAudio
        } else if error != nil {
            return "Couldn't reach the TTS service. Check your connection and try again."
        } else if result.provider == .gemini && result.hasIncompleteGeminiEvent {
            return noPlayableAudio
        } else if result.provider == .gemini && !containsCompletePCMFrame(result.providerAudioByteCount) {
            return noPlayableAudio
        } else if (result.provider == .openAICompatible || result.provider == .custom)
                    && !containsCompletePCMFrame(result.providerAudioByteCount) {
            return noPlayableAudio
        }
        return nil
    }

    /// Returns whether a byte count represents at least one whole 16-bit PCM frame.
    private func containsCompletePCMFrame(_ byteCount: Int) -> Bool {
        byteCount >= 2 && byteCount.isMultiple(of: 2)
    }

    /// Formats an HTTP failure without using any provider-controlled response text.
    private func userFacingHTTPError(statusCode: Int) -> String {
        if statusCode == 401 || statusCode == 403 {
            return "Authentication failed (HTTP \(statusCode)). Check your API key and try again."
        }
        return "Speech request failed (HTTP \(statusCode))."
    }
}
