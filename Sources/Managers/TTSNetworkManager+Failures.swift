import Foundation

extension TTSNetworkManager {
    /// The single owner of the message shown when Gemini reports that it stopped before finishing.
    ///
    /// It names the early stop rather than reusing the no-playable-audio text, because this outcome
    /// leaves already delivered PCM playable and the user can hear the speech it describes.
    static let truncatedGeminiResponseFailure =
        "The TTS service stopped early. The speech that arrived is incomplete. Please try again."

    /// The single owner of the message shown when a success response declared a body that is not audio.
    ///
    /// It points at the endpoint rather than inviting a retry, because a request that succeeded and
    /// returned something other than audio is answering correctly for whatever is at that address —
    /// most often one that is not a speech endpoint at all — and repeating it changes nothing. The
    /// declaration it refused is provider-controlled text and is not quoted.
    static let unplayableResponseFormatFailure =
        "The TTS endpoint returned a response that is not audio. Check the API endpoint in Settings and try again."

    private struct TaskCompletionResult {
        let provider: ProviderKind?
        let requestGeneration: UInt64?
        let responseStatusCode: Int?
        let providerAudioByteCount: Int
        let refusedResponseFormat: Bool
        let hasGeminiStreamFailure: Bool
        let hasIncompleteGeminiEvent: Bool
        let geminiDeclaredFinishReason: String?
        let refusedRedirect: RefusedRedirect?
        let retryAttempt: RetryAttempt?
        /// The client to terminate. A stale completion carries an inert one: its task is not the
        /// active request, so it owns no session and returns before this is read.
        let client: SpeechStreamClient
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
                    refusedResponseFormat: false,
                    hasGeminiStreamFailure: false,
                    hasIncompleteGeminiEvent: false,
                    geminiDeclaredFinishReason: nil,
                    refusedRedirect: nil,
                    retryAttempt: nil,
                    client: SpeechStreamClient(didReceiveAudio: { _ in }, didTerminate: { _ in }),
                    isStale: true
                )
            }

            let result = TaskCompletionResult(
                provider: context.provider,
                requestGeneration: context.requestGeneration,
                responseStatusCode: context.responseStatusCode,
                providerAudioByteCount: context.providerAudioByteCount,
                refusedResponseFormat: context.refusedResponseFormat,
                hasGeminiStreamFailure: context.hasGeminiStreamFailure,
                hasIncompleteGeminiEvent: context.geminiEventParser.hasIncompleteEvent,
                geminiDeclaredFinishReason: context.geminiDeclaredFinishReason,
                refusedRedirect: context.refusedRedirect,
                retryAttempt: context.hasGeminiStreamFailure ? nil : permittedRetryAttempt(for: context, error: error),
                client: context.client,
                isStale: false
            )
            // Ownership is released only when this logical request is finished, and a completion
            // that earned a retry is not: the retry continues this same request, inheriting its
            // generation and client. Releasing it here would leave a window in which nothing owns
            // the pipeline while a request is about to resume on it, so a stop or a format change
            // arriving in that window would find nothing to cancel and let the retry stream into a
            // session already torn down. `startRetryAttempt` replaces this context; a generation
            // that moved in the meantime has already cleared or replaced it, and refuses the retry.
            if !context.hasGeminiStreamFailure && result.retryAttempt == nil {
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
            client: context.client
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = processCompletedTask(task, error: error)
        if result.isStale { return }
        // A retry that starts owns the rest of this logical request, including what it publishes.
        if let retryAttempt = result.retryAttempt, startRetryAttempt(retryAttempt) { return }
        let requestGeneration: UInt64?
        let client: SpeechStreamClient
        if result.hasGeminiStreamFailure {
            guard let dataTask = task as? URLSessionDataTask,
                  let revocation = revokeFailedGeminiRequest(for: dataTask) else {
                return
            }
            requestGeneration = revocation.requestGeneration
            client = revocation.client
        } else {
            requestGeneration = result.requestGeneration
            client = result.client
        }

        let failureMessage = userFacingFailure(for: result, error: error)
        if let failureMessage {
            publishFailure(failureMessage, requestGeneration: requestGeneration)
        } else {
            setStreaming(false, requestGeneration: requestGeneration)
        }
        // Queued after the request's terminal state is published, and behind every byte of PCM this
        // task delivered, because both reach the client through the same guarded delivery queue.
        enqueueStreamTermination(
            failureMessage == nil ? .finished : .failed,
            client: client,
            requestGeneration: requestGeneration
        )
    }

    /// Returns the app-owned message a finished request must publish, or nil when it succeeded.
    ///
    /// The order is the order of what the user can act on: a refused redirect explains itself
    /// before the redirect status the provider happened to send, an HTTP status explains itself
    /// before the body that status was sent with, and both explain themselves before the transport
    /// error that may accompany them. A refused response format sits between the two: it is the
    /// definite reason this request delivered nothing, where a transport error that arrived
    /// afterwards only says the body the app had already decided to discard stopped arriving.
    private func userFacingFailure(for result: TaskCompletionResult, error: Error?) -> String? {
        let noPlayableAudio = "The TTS service returned no playable audio. Please try again."
        if let refusedRedirect = result.refusedRedirect {
            return refusedRedirect.failureMessage
        } else if let statusCode = result.responseStatusCode, !(200...299).contains(statusCode) {
            return userFacingHTTPError(statusCode: statusCode)
        } else if result.refusedResponseFormat {
            return Self.unplayableResponseFormatFailure
        } else if result.provider == .gemini && result.hasGeminiStreamFailure {
            return noPlayableAudio
        } else if error != nil {
            return "Couldn't reach the TTS service. Check your connection and try again."
        } else if result.provider == .gemini && result.hasIncompleteGeminiEvent {
            return noPlayableAudio
        } else if result.provider == .gemini && declaresProviderTruncation(result.geminiDeclaredFinishReason) {
            return Self.truncatedGeminiResponseFailure
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

    /// Returns whether a Gemini candidate explicitly reported ending for a reason other than `STOP`.
    ///
    /// Only an explicit reason counts. A stream that declared none may simply have ended without
    /// final metadata, so treating its absence as an early stop would fail ordinary successful
    /// reads; the remaining completion checks continue to govern that case.
    private func declaresProviderTruncation(_ declaredFinishReason: String?) -> Bool {
        guard let declaredFinishReason else { return false }
        return declaredFinishReason != "STOP"
    }

    /// Formats an HTTP failure without using any provider-controlled response text.
    private func userFacingHTTPError(statusCode: Int) -> String {
        if statusCode == 401 || statusCode == 403 {
            return "Authentication failed (HTTP \(statusCode)). Check your API key and try again."
        }
        return "Speech request failed (HTTP \(statusCode))."
    }
}
