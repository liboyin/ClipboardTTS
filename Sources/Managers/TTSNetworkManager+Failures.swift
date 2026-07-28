import Foundation

extension TTSNetworkManager {
    private struct TaskCompletionResult {
        let audioData: Data?
        let handler: ((Data) -> Void)?
        let provider: ProviderKind?
        let requestGeneration: UInt64?
        let responseStatusCode: Int?
        let providerAudioByteCount: Int
        let isStale: Bool
    }

    private func processCompletedTask(_ task: URLSessionTask) -> TaskCompletionResult {
        stateQueue.sync {
            guard let context = activeRequest, task.taskIdentifier == context.taskIdentifier else {
                return TaskCompletionResult(
                    audioData: nil,
                    handler: nil,
                    provider: nil,
                    requestGeneration: nil,
                    responseStatusCode: nil,
                    providerAudioByteCount: 0,
                    isStale: true
                )
            }

            let audioData = context.provider == .gemini && !context.isErrorResponse
                ? extractGeminiAudioData(from: context.incrementalBuffer)
                : nil
            let result = TaskCompletionResult(
                audioData: audioData,
                handler: context.dataHandler,
                provider: context.provider,
                requestGeneration: context.requestGeneration,
                responseStatusCode: context.responseStatusCode,
                providerAudioByteCount: context.providerAudioByteCount,
                isStale: false
            )
            activeRequest = nil
            return result
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = processCompletedTask(task)
        if result.isStale { return }

        let failureMessage: String?
        if let statusCode = result.responseStatusCode, !(200...299).contains(statusCode) {
            failureMessage = userFacingHTTPError(statusCode: statusCode)
        } else if error != nil {
            failureMessage = "Couldn't reach the TTS service. Check your connection and try again."
        } else if result.provider == .gemini && !containsCompletePCMFrame(result.audioData) {
            failureMessage = "The TTS service returned no playable audio. Please try again."
        } else if (result.provider == .openAICompatible || result.provider == .custom)
                    && !containsCompletePCMFrame(result.providerAudioByteCount) {
            failureMessage = "The TTS service returned no playable audio. Please try again."
        } else {
            failureMessage = nil
        }

        if failureMessage == nil, let audioData = result.audioData {
            result.handler?(audioData)
        }

        if let failureMessage {
            publishFailure(failureMessage, requestGeneration: result.requestGeneration)
        } else {
            setStreaming(false, requestGeneration: result.requestGeneration)
        }
    }

    /// Returns whether the provider delivered at least one complete 16-bit PCM frame.
    private func containsCompletePCMFrame(_ audioData: Data?) -> Bool {
        guard let audioData else { return false }
        return containsCompletePCMFrame(audioData.count)
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
