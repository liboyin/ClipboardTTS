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
    private enum StreamDataDelivery {
        case audio(Data, (Data) -> Void)
        case geminiEvents([Data])
    }

    private enum GeminiEventContent {
        case audio(Data)
        case noAudio
        case invalid
    }

    /// Validates an incoming task chunk and invokes its handler after releasing `stateQueue`.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let delivery = streamDataDelivery(for: data, task: dataTask) else { return }
        switch delivery {
        case let .audio(audioData, dataHandler):
            dataHandler(audioData)
        case let .geminiEvents(events):
            deliverGeminiEvents(events, for: dataTask)
        }
    }

    private func streamDataDelivery(for data: Data, task: URLSessionDataTask) -> StreamDataDelivery? {
        stateQueue.sync {
            guard var context = activeRequest, task.taskIdentifier == context.taskIdentifier,
                  !context.isErrorResponse else { return nil }
            defer { activeRequest = context }
            if context.provider == .gemini {
                guard !context.hasGeminiStreamFailure else { return nil }
                return .geminiEvents(context.geminiEventParser.append(data))
            }
            guard !data.isEmpty else { return nil }
            context.providerAudioByteCount += data.count
            return .audio(data, context.dataHandler)
        }
    }

    private func deliverGeminiEvents(_ events: [Data], for task: URLSessionDataTask) {
        for event in events {
            switch extractGeminiEventContent(from: event) {
            case let .audio(audioData):
                recordAndDeliverGeminiAudio(audioData, for: task)
            case .noAudio:
                continue
            case .invalid:
                failGeminiStream(for: task)
                return
            }
        }
    }

    private func recordAndDeliverGeminiAudio(_ audioData: Data, for task: URLSessionDataTask) {
        let delivery: (Data, (Data) -> Void)? = stateQueue.sync { () -> (Data, (Data) -> Void)? in
            guard var context = activeRequest, task.taskIdentifier == context.taskIdentifier,
                  !context.isErrorResponse, !context.hasGeminiStreamFailure else { return nil }
            context.providerAudioByteCount += audioData.count
            context.geminiIncompletePCM.append(audioData)
            let playableByteCount = context.geminiIncompletePCM.count
                - context.geminiIncompletePCM.count % 2
            guard playableByteCount > 0 else {
                activeRequest = context
                return nil
            }
            let playableAudio = Data(context.geminiIncompletePCM.prefix(playableByteCount))
            context.geminiIncompletePCM.removeFirst(playableByteCount)
            activeRequest = context
            return (playableAudio, context.dataHandler)
        }
        guard let delivery else { return }
        delivery.1(delivery.0)
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

    /// Marks the matching Gemini request terminal after a complete provider event cannot yield audio.
    private func failGeminiStream(for dataTask: URLSessionDataTask) {
        let failure = stateQueue.sync { () -> (URLSessionDataTask, UInt64)? in
            guard var context = activeRequest, dataTask.taskIdentifier == context.taskIdentifier,
                  !context.hasGeminiStreamFailure else { return nil }
            context.hasGeminiStreamFailure = true
            activeRequest = context
            return (context.task, context.requestGeneration)
        }
        guard let failure else { return }
        failure.0.cancel()
        publishFailure("The TTS service returned no playable audio. Please try again.", requestGeneration: failure.1)
    }
}
