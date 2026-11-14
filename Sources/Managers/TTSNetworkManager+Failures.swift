import Foundation

extension TTSNetworkManager {
    /// The single owner of the message shown when Gemini or OpenAI reports that it stopped before
    /// finishing.
    ///
    /// It names the early stop rather than reusing the no-playable-audio text, because this outcome
    /// leaves already delivered PCM playable and the user can hear the speech it describes.
    static let truncatedResponseFailure =
        "The TTS service stopped early. The speech that arrived is incomplete. Please try again."

    /// The single owner of the message shown when a request ends without a playable PCM frame, or
    /// with a provider stream the app cannot read.
    static let noPlayableAudioFailure = "The TTS service returned no playable audio. Please try again."

    /// The single owner of the message shown when the connection itself failed.
    static let unreachableServiceFailure = "Couldn't reach the TTS service. Check your connection and try again."

    /// The single owner of the message shown when a success response declared a body that is not audio.
    ///
    /// It points at the endpoint rather than inviting a retry, because a request that succeeded and
    /// returned something other than audio is answering correctly for whatever is at that address —
    /// most often one that is not a speech endpoint at all — and repeating it changes nothing. The
    /// declaration it refused is provider-controlled text and is not quoted.
    static let unplayableResponseFormatFailure =
        "The TTS endpoint returned a response that is not audio. Check the API endpoint in Settings and try again."

    /// Claims a finished task's request under `stateQueue`, or returns nil when the task is stale.
    ///
    /// The returned context is a value copy taken while `stateQueue` is held, so the caller can read
    /// it after the queue is released. The retry it earns is decided in that same visit, because
    /// whether it earned one decides whether ownership is released.
    private func processCompletedTask(_ task: URLSessionTask,
                                      error: Error?) -> (context: ActiveRequestContext, retryAttempt: RetryAttempt?)? {
        stateQueue.sync {
            guard let context = activeRequest, task.taskIdentifier == context.taskIdentifier else { return nil }
            let retryAttempt = context.hasGeminiStreamFailure ? nil : permittedRetryAttempt(for: context, error: error)
            // Ownership is released only when this logical request is finished, and a completion
            // that earned a retry is not: the retry continues this same request, inheriting its
            // generation and client. Releasing it here would leave a window in which nothing owns
            // the pipeline while a request is about to resume on it, so a stop or a format change
            // arriving in that window would find nothing to cancel and let the retry stream into a
            // session already torn down. `startRetryAttempt` replaces this context; a generation
            // that moved in the meantime has already cleared or replaced it, and refuses the retry.
            if !context.hasGeminiStreamFailure && retryAttempt == nil {
                activeRequest = nil
            }
            return (context, retryAttempt)
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
        guard let completion = processCompletedTask(task, error: error) else { return }
        let (context, retryAttempt) = completion
        // A retry that starts owns the rest of this logical request, including what it publishes.
        if let retryAttempt, startRetryAttempt(retryAttempt) { return }
        let requestGeneration: UInt64
        let client: SpeechStreamClient
        if context.hasGeminiStreamFailure {
            guard let dataTask = task as? URLSessionDataTask,
                  let revocation = revokeFailedGeminiRequest(for: dataTask) else {
                return
            }
            requestGeneration = revocation.requestGeneration
            client = revocation.client
        } else {
            requestGeneration = context.requestGeneration
            client = context.client
        }

        let failureMessage = userFacingFailure(for: context, error: error)
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
    ///
    /// The frame rule comes last, after Gemini's declared truncation, so a truncation that arrived
    /// with no audio at all still explains itself. It applies to every HTTP completion, which since
    /// D26 is only Gemini or Custom: a Realtime request has no task identifier for one to match.
    private func userFacingFailure(for context: ActiveRequestContext, error: Error?) -> String? {
        let noPlayableAudio = Self.noPlayableAudioFailure
        if let refusedRedirect = context.refusedRedirect {
            return refusedRedirect.failureMessage
        } else if let statusCode = context.responseStatusCode, !(200...299).contains(statusCode) {
            return userFacingHTTPError(statusCode: statusCode)
        } else if context.refusedResponseFormat {
            return Self.unplayableResponseFormatFailure
        } else if context.provider == .gemini && context.hasGeminiStreamFailure {
            return noPlayableAudio
        } else if error != nil {
            return Self.unreachableServiceFailure
        } else if context.provider == .gemini && context.geminiEventParser.hasIncompleteEvent {
            return noPlayableAudio
        } else if context.provider == .gemini && declaresProviderTruncation(context.geminiDeclaredFinishReason) {
            return Self.truncatedResponseFailure
        } else if !containsCompletePCMFrame(context.providerAudioByteCount) {
            return noPlayableAudio
        }
        return nil
    }

    /// Returns whether a byte count contains at least one whole 16-bit PCM frame.
    ///
    /// A response may end halfway through its next frame. The player retains only complete frames,
    /// so that final byte must not turn otherwise playable audio into a no-audio failure.
    func containsCompletePCMFrame(_ byteCount: Int) -> Bool {
        byteCount >= AudioPlayerManager.bytesPerPCMFrame
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
