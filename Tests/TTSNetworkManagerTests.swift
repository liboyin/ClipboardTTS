import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerTests: MockURLProtocolTestCase {

    func testNetworkManagerFormatsRequestCorrectly() {
        // WHY: We must ensure that the app sends the exactly correct JSON payload, headers, and URL
        // when triggering a TTS request, so that the API accepts it without error.

        let manager = TestNetworkFactory.makeManager()

        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "secret_token", model: "tts-test", voice: "test-voice", selectedProvider: "Custom")

        let expectation = XCTestExpectation(description: "Wait for request to be formed")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mock.api/v1/audio/speech")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret_token")

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 {
                        data.append(buffer, count: bytesRead)
                    } else {
                        break
                    }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData, !bodyData.isEmpty {
                let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                XCTAssertEqual(json?["model"] as? String, "tts-test")
                XCTAssertEqual(json?["input"] as? String, "Hello world")
                XCTAssertEqual(json?["voice"] as? String, "test-voice")
                XCTAssertEqual(json?["response_format"] as? String, "pcm")
            } else {
                XCTFail("No request body found")
            }

            expectation.fulfill()
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Hello world") { _ in }

        wait(for: [expectation], timeout: 2.0)
    }

    func testCustomRequestRequiresConfiguredModelAndVoiceBeforeStartingANetworkTask() {
        // WHY: Custom servers follow the OpenAI-compatible payload contract, so accepting blank
        // model or voice values would send a request the server cannot interpret. The validation
        // must fail through the menu's normal error state before a request reaches the endpoint.
        let manager = TestNetworkFactory.makeManager()
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("Invalid Custom configuration must not contact the endpoint")
            return (HTTPURLResponse(), Data())
        }

        let invalidConfigurations = [
            (model: "", voice: "custom-voice", description: "missing model"),
            (model: " \n\t ", voice: "custom-voice", description: "whitespace model"),
            (model: "custom-model", voice: "", description: "missing voice"),
            (model: "custom-model", voice: " \n\t ", description: "whitespace voice")
        ]

        for configuration in invalidConfigurations {
            manager.updateSettings(
                baseURL: "https://custom.api/v1/audio/speech",
                apiKey: "custom-token",
                model: configuration.model,
                voice: configuration.voice,
                selectedProvider: "Custom"
            )
            manager.streamTTS(text: configuration.description) { _ in
                XCTFail("Invalid Custom configuration must not deliver audio")
            }

            XCTAssertEqual(manager.lastError, "Custom TTS requires a model and voice. Update Settings and try again.")
            XCTAssertFalse(manager.isStreaming)
        }
    }

    func testNetworkManagerInitUsesPersistedCustomModelAndVoice() {
        // WHY: Custom model and voice are required request fields, so a cold launch must restore
        // them before Settings is opened. Falling back to empty values would make clipboard and
        // Services speech fail despite the user having already configured the provider.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.legacyCustomAPIKey: "persisted-custom-key",
            SettingsKeys.customModel: "persisted-custom-model",
            SettingsKeys.customVoice: "persisted-custom-voice"
        ])

        let manager = TestNetworkFactory.makeManager(defaults: defaults)
        let requestEmitted = expectation(description: "Persisted Custom values form a request")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer persisted-custom-key")
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
            XCTAssertEqual(body["model"], "persisted-custom-model")
            XCTAssertEqual(body["voice"], "persisted-custom-voice")
            requestEmitted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        manager.streamTTS(text: "Use persisted Custom settings") { _ in }
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testNetworkManagerStreamsDataChunks() {
        // WHY: The UI depends on receiving audio data quickly. This test ensures that when the server
        // sends data, the network manager relays it to the completion handler properly.

        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "Custom")

        let expectation = XCTestExpectation(description: "Wait for data chunk")

        MockURLProtocol.installRequestHandler { _ in
            let mockData = Data("audiochunk".utf8)
            return (HTTPURLResponse(), mockData)
        }

        manager.streamTTS(text: "Test streaming") { data in
            XCTAssertEqual(String(data: data, encoding: .utf8), "audiochunk")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkManagerStopsStreaming() throws {
        // WHY: Users might interrupt TTS playback. The network manager must cancel the ongoing network request
        // to save bandwidth and instantly transition the state. Both effects are synchronous on the main
        // thread, where stop publishes `isStreaming` directly and cancels the task before it returns, so
        // they are asserted straight after the call rather than after a delay.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "Custom")

        let requestStarted = XCTestExpectation(description: "Mock request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        // Teardown waits for the held handler, so releasing it is all that is left to do.
        defer { releaseResponse.signal() }
        MockURLProtocol.installRequestHandler { _ in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Test cancel") { _ in }
        let task = try XCTUnwrap(manager.activeTaskForTesting)
        wait(for: [requestStarted], timeout: 1.0)
        XCTAssertTrue(manager.isStreaming)
        XCTAssertEqual(task.state, .running)

        manager.stopStreaming()

        XCTAssertFalse(manager.isStreaming, "Stopping must publish the idle state before it returns.")
        XCTAssertTrue(
            [.canceling, .completed].contains(task.state),
            "Stopping must cancel the in-flight request rather than let it run to completion."
        )
        XCTAssertNil(manager.activeTaskForTesting, "A stopped request must no longer own the pipeline.")
    }

    func testNetworkManagerIgnoresDataAfterStop() throws {
        // WHY: A delegate callback for a task that is no longer active (e.g. one cancelled by
        // stopStreaming) must not invoke dataHandler, or a stale chunk resurrects audio after a stop.
        // We drive the delegate method directly with the task stopStreaming cancelled, because
        // URLSession suppresses callbacks for a cancelled task, so the real network path can never
        // exercise the stale-callback guard. A chunk the manager accepts is queued on its delivery
        // queue before the delegate call returns, so a barrier on that queue, which this test owns,
        // proves that no delivery is pending rather than that none arrived within a delay.
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.data-after-stop")
        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "Custom")

        let dataReceived = LockedValue(false)
        let requestStarted = XCTestExpectation(description: "Mock request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        // Teardown waits for the held handler, so releasing it is all that is left to do.
        defer { releaseResponse.signal() }
        MockURLProtocol.installRequestHandler { _ in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (HTTPURLResponse(), Data())
        }
        manager.streamTTS(text: "Test cancel data") { _ in
            dataReceived.withValue { $0 = true }
        }
        let cancelledTask = try XCTUnwrap(manager.activeTaskForTesting)
        wait(for: [requestStarted], timeout: 1.0)

        manager.stopStreaming()

        // Simulate a late chunk, and the completion URLSession would send behind it, arriving for the
        // task stop cancelled, which no longer owns the pipeline.
        manager.urlSession(manager.session, dataTask: cancelledTask, didReceive: Data("late chunk".utf8))
        manager.urlSession(manager.session, task: cancelledTask, didCompleteWithError: nil)
        audioDeliveryQueue.sync {}

        XCTAssertFalse(dataReceived.value, "A chunk for a stopped request must not reach its data handler.")
    }

    func testNetworkManagerFormatsGeminiRequestCorrectly() {
        let manager = TestNetworkFactory.makeManager()

        let geminiKey = "test-gemini-api-key"
        manager.updateSettings(baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: geminiKey, model: "gemini-tts", voice: "Aoede", selectedProvider: "Gemini")

        let expectation = XCTestExpectation(description: "Wait for Gemini request")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-tts:streamGenerateContent?alt=sse")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), geminiKey)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.url?.absoluteString.contains(geminiKey) ?? true)
            XCTAssertEqual(request.httpMethod, "POST")

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 { data.append(buffer, count: bytesRead) } else { break }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData, !bodyData.isEmpty {
                let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                let contents = json?["contents"] as? [[String: Any]]
                let parts = contents?.first?["parts"] as? [[String: Any]]
                XCTAssertEqual(parts?.first?["text"] as? String, "Hello Gemini")
            } else {
                XCTFail("No request body")
            }

            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        manager.streamTTS(text: "Hello Gemini") { _ in }
        wait(for: [expectation], timeout: 2.0)
    }

    func testAManagerBuiltOverRetiredSpeechSettingsSpeaksWithTheRealtimeDefaults() throws {
        // WHY: The rewrite has to run before construction reads the settings, and has to persist, or
        // the first launch after the update would still request a speech model the Realtime API
        // rejects, and Settings would show it as configured.
        let defaults = makeOwnedDefaults([SettingsKeys.openAIModel: "tts-1", SettingsKeys.openAIVoice: "nova"])
        let connections = ScriptedRealtimeConnections()
        let manager = TestNetworkFactory.makeManager(defaults: defaults, realtimeConnections: connections)

        manager.streamTTS(text: "test") { _ in }

        let connection = try XCTUnwrap(connections.all.first)
        addTeardownBlock { connection.cancel(); connection.drain() }
        XCTAssertEqual(connection.request.url?.query, "model=gpt-realtime-2.1-mini")
        let session = connection.sentEvents.first?["session"] as? [String: Any]
        let output = (session?["audio"] as? [String: Any])?["output"] as? [String: Any]
        XCTAssertEqual(output?["voice"] as? String, "alloy")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAIModel), "gpt-realtime-2.1-mini")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.openAIVoice), "alloy")
    }

    func testNetworkManagerInitReadsProviderSpecificDefaults() throws {
        // WHY: SettingsView persists model/voice under provider-specific UserDefaults keys
        // (openaiModel/openaiVoice, geminiModel/geminiVoice). The manager's init must read the
        // same keys so user-chosen settings survive an app restart even before the settings
        // window is opened. A regression here would silently fall back to hardcoded defaults
        // (gpt-realtime-2.1-mini/alloy) on every cold start until the user re-opens settings.
        // OpenAI: persisted model/voice/key should drive the Realtime connection. Each provider gets
        // its own store because each manager reads its settings once, when it is constructed.
        let openaiDefaults = makeOwnedDefaults([
            SettingsKeys.openAIModel: "persisted-openai-model",
            SettingsKeys.openAIVoice: "persisted-openai-voice",
            SettingsKeys.legacyOpenAIAPIKey: "persisted-openai-key"
        ])
        let geminiDefaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini",
            SettingsKeys.geminiModel: "persisted-gemini-model",
            SettingsKeys.geminiVoice: "persisted-gemini-voice",
            SettingsKeys.legacyGeminiAPIKey: "persisted-gemini-key"
        ])

        let connections = ScriptedRealtimeConnections()
        let openaiManager = TestNetworkFactory.makeManager(defaults: openaiDefaults, realtimeConnections: connections)
        openaiManager.streamTTS(text: "test") { _ in }
        let connection = try XCTUnwrap(connections.all.first)
        addTeardownBlock { connection.cancel(); connection.drain() }
        XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Authorization"), "Bearer persisted-openai-key")
        XCTAssertEqual(connection.request.url?.query, "model=persisted-openai-model")
        let session = connection.sentEvents.first?["session"] as? [String: Any]
        let output = (session?["audio"] as? [String: Any])?["output"] as? [String: Any]
        XCTAssertEqual(output?["voice"] as? String, "persisted-openai-voice")

        // Gemini: persisted model embeds in URL path, voice embeds in request body.

        let geminiManager = TestNetworkFactory.makeManager(defaults: geminiDefaults)
        let geminiExpectation = XCTestExpectation(description: "Gemini request uses persisted values")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://generativelanguage.googleapis.com/v1beta/models/persisted-gemini-model:streamGenerateContent?alt=sse")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "persisted-gemini-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 1024)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: 1024)
                    if bytesRead > 0 { data.append(buffer, count: bytesRead) } else { break }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData,
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                let cfg = json["generationConfig"] as? [String: Any]
                let speech = cfg?["speechConfig"] as? [String: Any]
                let voiceCfg = speech?["voiceConfig"] as? [String: Any]
                let prebuilt = voiceCfg?["prebuiltVoiceConfig"] as? [String: Any]
                XCTAssertEqual(prebuilt?["voiceName"] as? String, "persisted-gemini-voice")
            } else {
                XCTFail("Gemini request body missing")
            }

            geminiExpectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        geminiManager.streamTTS(text: "test") { _ in }
        wait(for: [geminiExpectation], timeout: 2.0)
    }

}
