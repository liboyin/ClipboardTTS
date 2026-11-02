import Foundation

/// Runs an OpenAI speech request over the Realtime API's WebSocket.
///
/// A Realtime request owns the pipeline exactly as an HTTP one does: it is installed under the
/// generation `streamTTS` took, cancelled by the same revocations, and its PCM and one terminal event
/// reach the client through the same guarded, ordered delivery. What differs is only where its end
/// comes from. An HTTP request ends when URLSession completes its task; a Realtime request ends at
/// the first event that finishes or fails the response, or at the receive error that ends the
/// connection, and it closes its own connection then.
///
/// Every received frame is classified and accounted for while `stateQueue` owns the request, so a
/// revocation either precedes it, and the frame finds no owner and is dropped, or follows it, and
/// the PCM it accepted is withdrawn with the rest of that generation. The next frame is asked for
/// only after this one is accounted for, so frames are handled one at a time and in order.
extension TTSNetworkManager {
    /// How one received frame left the request that owned the connection.
    private enum RealtimeProgress {
        /// The response continues, so the next frame is wanted.
        case awaitingMore
        /// The response ended; the request no longer owns the pipeline.
        case ended(RealtimeEnding)
    }

    /// What an ended Realtime request still has to publish once `stateQueue` is released.
    private struct RealtimeEnding {
        /// The app-owned failure to publish, or nil when the request finished.
        let failureMessage: String?
        let requestGeneration: UInt64
        let client: SpeechStreamClient
    }

    /// Starts `text` on a new Realtime connection, which then owns the pipeline for `requestGeneration`.
    ///
    /// The client events are queued as soon as the connection is opened: WebSocket frames are sent in
    /// order, and the server reads the session settings before the message and the response request
    /// that follow them. A failed send is not reported on its own, because it fails the connection,
    /// and the receive waiting on that connection then reports it.
    func startRealtimeRequest(_ request: URLRequest,
                              text: String,
                              voice: String,
                              requestGeneration: UInt64,
                              client: SpeechStreamClient) {
        let events: [String]
        do {
            events = try OpenAIRealtimeSpeech.clientEvents(text: text, voice: voice)
        } catch {
            failRequestBeforeItStarts("Couldn't prepare the speech request. Check the settings and try again.",
                                      requestGeneration: requestGeneration, client: client)
            return
        }
        let connection = realtimeConnectionFactory(session, request)
        guard replaceActiveRequest(
            with: .realtime(connection),
            request: request,
            provider: .openAI,
            requestGeneration: requestGeneration,
            client: client
        ) else {
            connection.cancel()
            return
        }

        setStreaming(true, requestGeneration: requestGeneration)
        connection.resume()
        for event in events {
            connection.send(event) { _ in }
        }
        receiveRealtimeFrame(from: connection)
    }

    private func receiveRealtimeFrame(from connection: RealtimeSpeechConnection) {
        connection.receive { [weak self] result in
            self?.handleRealtimeFrame(result, from: connection)
        }
    }

    /// Accounts for one received frame, then asks for the next or finishes the request.
    private func handleRealtimeFrame(_ result: Result<URLSessionWebSocketTask.Message, Error>,
                                     from connection: RealtimeSpeechConnection) {
        switch advanceRealtimeRequest(with: result, from: connection) {
        case nil:
            // Revoked or replaced: whatever revoked it already cancelled this connection.
            return
        case .awaitingMore:
            receiveRealtimeFrame(from: connection)
        case .ended(let ending):
            connection.cancel()
            if let failureMessage = ending.failureMessage {
                publishFailure(failureMessage, requestGeneration: ending.requestGeneration)
            } else {
                setStreaming(false, requestGeneration: ending.requestGeneration)
            }
            enqueueStreamTermination(
                ending.failureMessage == nil ? .finished : .failed,
                client: ending.client,
                requestGeneration: ending.requestGeneration
            )
        }
    }

    /// Applies one frame to the request that owns `connection`, or returns nil when none does.
    private func advanceRealtimeRequest(with result: Result<URLSessionWebSocketTask.Message, Error>,
                                        from connection: RealtimeSpeechConnection) -> RealtimeProgress? {
        stateQueue.sync {
            guard var context = activeRequest, context.owns(connection) else { return nil }
            let event = realtimeEvent(from: result)
            switch event {
            case .audio(let pcm)?:
                if !pcm.isEmpty {
                    context.providerAudioByteCount += pcm.count
                    // Enqueued while stateQueue owns this context, as an HTTP chunk is, so a later
                    // frame cannot overtake it.
                    enqueueAudioDelivery(pcm, dataHandler: context.client.didReceiveAudio,
                                         requestGeneration: context.requestGeneration)
                    activeRequest = context
                }
                return .awaitingMore
            case .ignored?:
                return .awaitingMore
            case nil, .finished?, .stoppedEarly?, .failed?:
                activeRequest = nil
                return .ended(RealtimeEnding(
                    failureMessage: realtimeFailureMessage(endingWith: event,
                                                           audioByteCount: context.providerAudioByteCount),
                    requestGeneration: context.requestGeneration,
                    client: context.client
                ))
            }
        }
    }

    /// The app-owned message an ending event publishes, or nil when the request finished with
    /// playable audio. None repeats provider text. A nil event is a connection that ended first.
    private func realtimeFailureMessage(endingWith event: OpenAIRealtimeSpeech.ServerEvent?,
                                        audioByteCount: Int) -> String? {
        switch event {
        case nil:
            return Self.unreachableServiceFailure
        case .finished?:
            return containsCompletePCMFrame(audioByteCount) ? nil : Self.noPlayableAudioFailure
        case .stoppedEarly?:
            return Self.truncatedResponseFailure
        case .failed(.authentication)?:
            return "Authentication failed. Check your API key and try again."
        case .failed(.quota)?:
            return "OpenAI reports no remaining quota for this API key. Check the account's billing and usage limits, then try again."
        case .failed(.invalidRequest)?:
            return "The TTS service rejected the request. Check the model and voice in Settings and try again."
        case .failed(.provider)?:
            return "The TTS service reported an error. Please try again."
        case .failed(.malformed)?:
            return Self.noPlayableAudioFailure
        case .audio?, .ignored?:
            return nil
        }
    }

    /// What a received frame means for the request, or nil when the connection ended before the
    /// response did.
    ///
    /// That end is a transport failure even after audio arrived, as a URLSession error is for an
    /// HTTP request: the speech it carried is incomplete. A binary frame is malformed, because the
    /// API documents only JSON text events.
    private func realtimeEvent(from result: Result<URLSessionWebSocketTask.Message, Error>)
        -> OpenAIRealtimeSpeech.ServerEvent? {
        switch result {
        case .failure:
            return nil
        case .success(.string(let text)):
            return OpenAIRealtimeSpeech.classify(Data(text.utf8))
        case .success:
            return .failed(.malformed)
        }
    }
}

extension TTSNetworkManager.ActiveRequestContext {
    /// Whether this attempt is the Realtime request carried by `connection`.
    func owns(_ connection: RealtimeSpeechConnection) -> Bool {
        guard case .realtime(let ownConnection) = transport else { return false }
        return ownConnection === connection
    }
}
