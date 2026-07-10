import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerTests: XCTestCase {

    func testNetworkManagerFormatsRequestCorrectly() {
        // WHY: We must ensure that the app sends the exactly correct JSON payload, headers, and URL
        // when triggering a TTS request, so that the API accepts it without error.

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)

        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "secret_token", model: "tts-test", voice: "test-voice")

        let expectation = XCTestExpectation(description: "Wait for request to be formed")

        MockURLProtocol.requestHandler = { request in
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

    func testNetworkManagerStreamsDataChunks() {
        // WHY: The UI depends on receiving audio data quickly. This test ensures that when the server
        // sends data, the network manager relays it to the completion handler properly.

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

        let expectation = XCTestExpectation(description: "Wait for data chunk")

        MockURLProtocol.requestHandler = { _ in
            let mockData = Data("audiochunk".utf8)
            return (HTTPURLResponse(), mockData)
        }

        manager.streamTTS(text: "Test streaming") { data in
            XCTAssertEqual(String(data: data, encoding: .utf8), "audiochunk")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkManagerStopsStreaming() {
        // WHY: Users might interrupt TTS playback. The network manager must cancel the ongoing network request
        // to save bandwidth and instantly transition the state.

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Test cancel") { _ in }

        // Wait briefly for the async state change
        let expectation1 = XCTestExpectation(description: "Wait for stream to start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(manager.isStreaming)
            expectation1.fulfill()
        }
        wait(for: [expectation1], timeout: 1.0)

        manager.stopStreaming()

        let expectation2 = XCTestExpectation(description: "Wait for stream to stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(manager.isStreaming)
            expectation2.fulfill()
        }
        wait(for: [expectation2], timeout: 1.0)
    }

    func testNetworkManagerIgnoresDataAfterStop() {
        // WHY: Stale delegate callbacks from a cancelled URLSessionTask should not invoke dataHandler.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

        var dataReceived = false
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return (HTTPURLResponse(), Data("audiochunk".utf8))
        }

        manager.streamTTS(text: "Test cancel data") { _ in
            dataReceived = true
        }

        manager.stopStreaming()

        let expectation = XCTestExpectation(description: "Wait to ensure no data is received")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(dataReceived)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testNetworkManagerFormatsGeminiRequestCorrectly() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)

        manager.updateSettings(baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: "gemini_token", model: "gemini-tts", voice: "Aoede")

        let expectation = XCTestExpectation(description: "Wait for Gemini request")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-tts:generateContent?key=gemini_token")
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

    func testNetworkManagerHandlesAPIError() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)

        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test")

        let expectation = XCTestExpectation(description: "Wait for error completion")

        MockURLProtocol.requestHandler = { request in
            let errorData = Data("{\"error\": \"Unauthorized\"}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, errorData)
        }

        manager.streamTTS(text: "Test error") { _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(manager.isStreaming)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testFetchAvailableModels() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)

        // Test Gemini (returns hardcoded instantly)
        manager.fetchAvailableModels(baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: "gemini_token")
        XCTAssertEqual(manager.availableModels.first, "gemini-3.1-flash-tts-preview")

        // Test OpenAI (requires mock request)
        let expectation = XCTestExpectation(description: "Wait for models fetch")
        MockURLProtocol.requestHandler = { request in
            let mockResponse = Data("""
            { "data": [ {"id": "tts-1"}, {"id": "tts-1-hd"}, {"id": "gpt-4"} ] }
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, mockResponse)
        }

        manager.fetchAvailableModels(baseURL: "https://api.openai.com/v1/audio/speech", apiKey: "test")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertTrue(manager.availableModels.contains("tts-1"))
            XCTAssertTrue(manager.availableModels.contains("tts-1-hd"))
            XCTAssertFalse(manager.availableModels.contains("gpt-4"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkManagerInitReadsProviderSpecificDefaults() {
        // WHY: SettingsView persists model/voice under provider-specific UserDefaults keys
        // (openaiModel/openaiVoice, geminiModel/geminiVoice). The manager's init must read the
        // same keys so user-chosen settings survive an app restart even before the settings
        // window is opened. A regression here would silently fall back to hardcoded defaults
        // (tts-1/alloy) on every cold start until the user re-opens settings.
        isolateAppSettingsDefaults()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        // OpenAI: persisted model/voice/key should drive the outgoing request
        UserDefaults.standard.set("OpenAI", forKey: "ttsProvider")
        UserDefaults.standard.set("persisted-openai-model", forKey: "openaiModel")
        UserDefaults.standard.set("persisted-openai-voice", forKey: "openaiVoice")
        UserDefaults.standard.set("persisted-openai-key", forKey: "apiKey")

        let openaiManager = TTSNetworkManager(configuration: config)
        let openaiExpectation = XCTestExpectation(description: "OpenAI request uses persisted values")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer persisted-openai-key")

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
                XCTAssertEqual(json["model"] as? String, "persisted-openai-model")
                XCTAssertEqual(json["voice"] as? String, "persisted-openai-voice")
            } else {
                XCTFail("OpenAI request body missing")
            }

            openaiExpectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        openaiManager.streamTTS(text: "test") { _ in }
        wait(for: [openaiExpectation], timeout: 2.0)

        // Gemini: persisted model embeds in URL path, voice embeds in request body
        UserDefaults.standard.set("Gemini", forKey: "ttsProvider")
        UserDefaults.standard.set("persisted-gemini-model", forKey: "geminiModel")
        UserDefaults.standard.set("persisted-gemini-voice", forKey: "geminiVoice")
        UserDefaults.standard.set("persisted-gemini-key", forKey: "geminiAPIKey")

        let geminiManager = TTSNetworkManager(configuration: config)
        let geminiExpectation = XCTestExpectation(description: "Gemini request uses persisted values")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://generativelanguage.googleapis.com/v1beta/models/persisted-gemini-model:generateContent?key=persisted-gemini-key")

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

    func testFetchAvailableVoices() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let manager = TTSNetworkManager(configuration: config)

        // Test OpenAI (hardcoded)
        manager.fetchAvailableVoices(baseURL: "https://api.openai.com/v1/audio/speech", apiKey: "test")
        XCTAssertTrue(manager.availableVoices.contains("alloy"))

        // Test Gemini (hardcoded)
        manager.fetchAvailableVoices(baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: "test")
        XCTAssertTrue(manager.availableVoices.contains("Aoede"))

        // Test Custom (requires mock request)
        let expectation = XCTestExpectation(description: "Wait for voices fetch")
        MockURLProtocol.requestHandler = { request in
            let mockResponse = Data("""
            { "voices": ["custom-voice-1", "custom-voice-2"] }
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, mockResponse)
        }

        manager.fetchAvailableVoices(baseURL: "https://custom.api/v1/audio/speech", apiKey: "test")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertTrue(manager.availableVoices.contains("custom-voice-1"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
