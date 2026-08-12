import Foundation

extension TTSNetworkManager {
    private struct TaskCompletionResult {
        let provider: ProviderKind?
        let requestGeneration: UInt64?
        let responseStatusCode: Int?
        let providerAudioByteCount: Int
        let hasGeminiStreamFailure: Bool
        let hasIncompleteGeminiEvent: Bool
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

        let failureMessage: String?
        if let statusCode = result.responseStatusCode, !(200...299).contains(statusCode) {
            failureMessage = userFacingHTTPError(statusCode: statusCode)
        } else if result.provider == .gemini && result.hasGeminiStreamFailure {
            failureMessage = "The TTS service returned no playable audio. Please try again."
        } else if error != nil {
            failureMessage = "Couldn't reach the TTS service. Check your connection and try again."
        } else if result.provider == .gemini && result.hasIncompleteGeminiEvent {
            failureMessage = "The TTS service returned no playable audio. Please try again."
        } else if result.provider == .gemini && !containsCompletePCMFrame(result.providerAudioByteCount) {
            failureMessage = "The TTS service returned no playable audio. Please try again."
        } else if (result.provider == .openAICompatible || result.provider == .custom)
                    && !containsCompletePCMFrame(result.providerAudioByteCount) {
            failureMessage = "The TTS service returned no playable audio. Please try again."
        } else {
            failureMessage = nil
        }

        if let failureMessage {
            publishFailure(failureMessage, requestGeneration: requestGeneration)
        } else {
            setStreaming(false, requestGeneration: requestGeneration)
        }
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
