import Foundation

/// Incrementally separates Server-Sent Event `data` payloads while preserving an unfinished line.
struct GeminiSSEEventParser {
    private var incompleteLine = Data()
    private var eventDataLines: [Data] = []

    /// Reports whether end of stream would discard an incomplete Server-Sent Event.
    var hasIncompleteEvent: Bool {
        !incompleteLine.isEmpty || !eventDataLines.isEmpty
    }

    /// Appends bytes from one URL-session callback and returns only fully terminated event payloads.
    mutating func append(_ data: Data) -> [Data] {
        incompleteLine.append(data)
        var payloads: [Data] = []

        while let lineEnding = incompleteLine.firstIndex(of: 0x0A) {
            var line = Data(incompleteLine.prefix(upTo: lineEnding))
            incompleteLine.removeSubrange(...lineEnding)
            if line.last == 0x0D {
                line.removeLast()
            }

            if line.isEmpty {
                guard !eventDataLines.isEmpty else { continue }
                payloads.append(joinedDataLines())
                eventDataLines.removeAll(keepingCapacity: true)
            } else if line.starts(with: Data("data:".utf8)) {
                appendDataLine(from: line)
            }
        }

        return payloads
    }

    private mutating func appendDataLine(from line: Data) {
        var value = Data(line.dropFirst(5))
        if value.first == 0x20 {
            value.removeFirst()
        }
        eventDataLines.append(value)
    }

    private func joinedDataLines() -> Data {
        eventDataLines.dropFirst().reduce(eventDataLines.first ?? Data()) { partial, line in
            partial + Data([0x0A]) + line
        }
    }
}

extension TTSNetworkManager {
    private enum GeminiEventContent {
        case audio(Data)
        case noAudio
        case invalid
    }

    /// Queues PCM for a request generation and invokes its handler only while that generation
    /// still owns delivery. Completion deliberately leaves the generation intact so audio accepted
    /// before a normal URL-session completion remains playable.
    func enqueueAudioDelivery(_ data: Data,
                              dataHandler: @escaping @Sendable (Data) -> Void,
                              requestGeneration: UInt64) {
        audioDeliveryQueue.async { [weak self] in
            guard let self else { return }
            self.callbackAuthority.lock()
            defer { self.callbackAuthority.unlock() }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            dataHandler(data)
        }
    }

    /// Finishes revoking a malformed Gemini stream while holding the callback authority boundary.
    func revokeFailedGeminiRequest(for task: URLSessionDataTask) -> (task: URLSessionDataTask, requestGeneration: UInt64)? {
        callbackAuthority.lock()
        defer { callbackAuthority.unlock() }
        return stateQueue.sync {
            guard let context = activeRequest,
                  context.taskIdentifier == task.taskIdentifier,
                  context.hasGeminiStreamFailure else {
                return nil
            }
            activeRequest = nil
            return (context.task, requestGeneration)
        }
    }

    /// Validates an incoming task chunk and invokes its handler after releasing `stateQueue`.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failedGeminiTask = stateQueue.sync { () -> URLSessionDataTask? in
            guard var context = activeRequest, dataTask.taskIdentifier == context.taskIdentifier,
                  !context.isErrorResponse else { return nil }
            if context.provider == .gemini {
                guard !context.hasGeminiStreamFailure else { return nil }
                let events = context.geminiEventParser.append(data)
                guard !events.isEmpty else {
                    activeRequest = context
                    return nil
                }
                // Decode and account for events before completion can clear this request. Only
                // the user handler is deferred, so it remains outside stateQueue but retains the
                // order in which this request accepted delegate callbacks.
                if let failedRequest = enqueueGeminiEvents(events, into: &context, for: dataTask) {
                    // Invalidate queued delivery before it can acquire callback authority. A
                    // delivery already waiting on stateQueue will therefore observe the failed
                    // generation when it continues, while a running handler is awaited below.
                    requestGeneration &+= 1
                    // Leave the failed context in place until its revocation takes the callback
                    // authority lock. That preserves the lock order used by delivery.
                    activeRequest = context
                    return failedRequest.task
                }
                activeRequest = context
                return nil
            }
            guard !data.isEmpty else { return nil }
            context.providerAudioByteCount += data.count
            let dataHandler = context.dataHandler
            let deliveryGeneration = context.requestGeneration
            // Enqueue while stateQueue owns this context, rather than after its lock is released,
            // so a later concurrent delegate callback cannot overtake this PCM chunk.
            enqueueAudioDelivery(data, dataHandler: dataHandler, requestGeneration: deliveryGeneration)
            activeRequest = context
            return nil
        }
        guard let failedGeminiTask,
              let revocation = revokeFailedGeminiRequest(for: failedGeminiTask) else {
            return
        }
        revocation.task.cancel()
        publishFailure("The TTS service returned no playable audio. Please try again.", requestGeneration: revocation.requestGeneration)
    }

    /// Decodes complete SSE events while `stateQueue` owns their request context.
    private func enqueueGeminiEvents(_ events: [Data],
                                     into context: inout ActiveRequestContext,
                                     for task: URLSessionDataTask) -> (task: URLSessionDataTask, requestGeneration: UInt64)? {
        for event in events {
            switch extractGeminiEventContent(from: event) {
            case let .audio(audioData):
                guard let playableAudio = recordGeminiAudio(audioData, in: &context) else { continue }
                let dataHandler = context.dataHandler
                enqueueAudioDelivery(
                    playableAudio,
                    dataHandler: dataHandler,
                    requestGeneration: context.requestGeneration
                )
            case .noAudio:
                continue
            case .invalid:
                context.hasGeminiStreamFailure = true
                return (task, context.requestGeneration)
            }
        }
        return nil
    }

    /// Records one decoded Gemini payload under `stateQueue` and returns complete PCM for delivery.
    private func recordGeminiAudio(_ audioData: Data, in context: inout ActiveRequestContext) -> Data? {
        context.providerAudioByteCount += audioData.count
        context.geminiIncompletePCM.append(audioData)
        let playableByteCount = context.geminiIncompletePCM.count
            - context.geminiIncompletePCM.count % 2
        guard playableByteCount > 0 else { return nil }
        let playableAudio = Data(context.geminiIncompletePCM.prefix(playableByteCount))
        context.geminiIncompletePCM.removeFirst(playableByteCount)
        return playableAudio
    }

    /// Classifies one complete Gemini event without attempting to decode an absent audio payload.
    private func extractGeminiEventContent(from event: Data) -> GeminiEventContent {
        guard let json = try? JSONSerialization.jsonObject(with: event) as? [String: Any],
              json["error"] == nil else {
            return .invalid
        }
        guard let rawCandidates = json["candidates"] else {
            return .noAudio
        }
        guard let candidates = rawCandidates as? [[String: Any]] else {
            return .invalid
        }
        guard let candidate = candidates.first,
              let rawContent = candidate["content"] else {
            return .noAudio
        }
        guard let content = rawContent as? [String: Any] else {
            return .invalid
        }
        guard let rawParts = content["parts"] else {
            return .noAudio
        }
        guard let parts = rawParts as? [[String: Any]] else {
            return .invalid
        }
        for part in parts {
            guard let rawInlineData = part["inlineData"] else { continue }
            guard let inlineData = rawInlineData as? [String: Any],
                  let base64String = inlineData["data"] as? String,
                  let audioData = Data(base64Encoded: base64String) else {
                return .invalid
            }
            return .audio(audioData)
        }
        return .noAudio
    }

}
