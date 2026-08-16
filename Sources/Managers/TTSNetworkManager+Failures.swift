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
        let isStale: Bool
    }

    private func processCompletedTask(_ task: URLSessionTask) -> TaskCompletionResult {
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
                isStale: false
            )
            if !context.hasGeminiStreamFailure {
                activeRequest = nil
            }
            return result
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = processCompletedTask(task)
        if result.isStale { return }
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
