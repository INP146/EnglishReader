import Foundation
import Testing
@testable import Readling

/// Answers requests from a table keyed by host, so tests running in parallel don't share replies.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var received: [String: (request: URLRequest, body: Data)] = [:]

    /// A session whose requests to `host` get `reply`.
    static func session(host: String, reply: Reply) -> URLSession {
        lock.withLock { replies[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func request(host: String) -> (request: URLRequest, body: Data)? { lock.withLock { received[host] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let reply = Self.lock.withLock {
            Self.received[host] = (request, body)
            return Self.replies[host] ?? Reply(status: 500)
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Server-sent events")
struct ServerSentEventsTests {
    private func events(_ text: String) -> [ServerSentEvents.Event] {
        var parser = ServerSentEvents()
        var all = text.utf8.compactMap { parser.feed($0) }
        if let last = parser.finish() { all.append(last) }
        return all
    }

    @Test func splitsEventsOnBlankLines() {
        #expect(events("data: a\n\ndata: b\n\n") == [.init(data: "a"), .init(data: "b")])
    }

    @Test func handlesCRLFNamesCommentsAndMultilineData() {
        let text = ": keep-alive\r\nevent: delta\r\ndata: one\r\ndata:two\r\nid: 7\r\n\r\n"
        #expect(events(text) == [.init(name: "delta", data: "one\ntwo")])
    }

    @Test func flushesAnEventCutOffByTheEndOfTheStream() {
        #expect(events("data: [DONE]") == [.init(data: "[DONE]")])
    }

    @Test func keepsMultibyteTextIntact() {
        #expect(events("data: 你好\n\n") == [.init(data: "你好")])
    }
}

@Suite("OpenAI-compatible format")
struct OpenAICompatibleEngineTests {
    private func configuration(_ host: String, key: String? = "sk-test1234") -> OpenAICompatibleEngine.Configuration {
        .init(baseURL: URL(string: "https://\(host)/v1")!, key: key, model: "some-model")
    }

    private func sse(_ deltas: [String], done: Bool = true) -> Data {
        var text = deltas.map { delta -> String in
            let json = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": delta]]]])
            return "data: \(String(decoding: json, as: UTF8.self))\n\n"
        }.joined()
        if done { text += "data: [DONE]\n\n" }
        return Data(text.utf8)
    }

    private func run(_ engine: OpenAICompatibleEngine, _ request: TranslationRequest = .translate("Hello there.")) async throws -> [String] {
        var all: [String] = []
        for try await text in engine.run(request) { all.append(text) }
        return all
    }

    @Test func normalizesEndpointAddresses() {
        #expect(OpenAICompatibleEngine.endpointURL("https://api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(OpenAICompatibleEngine.endpointURL("http://192.168.1.5:11434")?.absoluteString == "http://192.168.1.5:11434/v1/chat/completions")
        #expect(OpenAICompatibleEngine.endpointURL("https://relay.example.com/v1/chat/completions/")?.absoluteString == "https://relay.example.com/v1/chat/completions")
        #expect(OpenAICompatibleEngine.endpointURL("https://ark.example.com/api/v3")?.absoluteString == "https://ark.example.com/api/v3/chat/completions")
        #expect(OpenAICompatibleEngine.endpointURL("api.example.com/v1") == nil)
    }

    @Test func buildsAStreamingChatRequest() async throws {
        let host = "build.test"
        let session = StubURLProtocol.session(host: host, reply: .init(body: sse(["好"])))
        _ = try await run(OpenAICompatibleEngine(configuration: configuration(host), session: session),
                          .explain(word: "hare", sentence: "The March Hare said."))
        let (request, body) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test1234")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "some-model")
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == "<word>hare</word>\n<sentence>The March Hare said.</sentence>")
    }

    @Test func sendsNoAuthorizationWithoutAKey() async throws {
        let host = "nokey.test"
        let session = StubURLProtocol.session(host: host, reply: .init(body: sse(["好"])))
        _ = try await run(OpenAICompatibleEngine(configuration: configuration(host, key: nil), session: session))
        #expect(StubURLProtocol.request(host: host)?.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func streamsTheGrowingTextAndStopsAtDone() async throws {
        let host = "stream.test"
        var body = sse(["你", "好"])
        body.append(Data("data: {\"choices\":[{\"delta\":{\"content\":\"after done\"}}]}\n\n".utf8))
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        #expect(try await run(OpenAICompatibleEngine(configuration: configuration(host), session: session)) == ["你", "你好"])
    }

    @Test func acceptsAStreamThatEndsWithoutDone() async throws {
        let host = "nodone.test"
        let session = StubURLProtocol.session(host: host, reply: .init(body: sse(["一", "二"], done: false)))
        #expect(try await run(OpenAICompatibleEngine(configuration: configuration(host), session: session)) == ["一", "一二"])
    }

    @Test(arguments: [
        (401, "API Key 无效。Incorrect API key"),
        (429, "额度用完或请求太频繁，稍后再试。Incorrect API key"),
        (503, "服务暂时不可用（503）。Incorrect API key"),
    ])
    func mapsHTTPFailures(status: Int, message: String) async throws {
        let host = "status\(status).test"
        let body = Data(#"{"error":{"message":"Incorrect API key","type":"invalid_request_error"}}"#.utf8)
        let session = StubURLProtocol.session(host: host, reply: .init(status: status, body: body))
        await #expect(throws: TranslationFailure.failed(message)) {
            _ = try await run(OpenAICompatibleEngine(configuration: configuration(host), session: session))
        }
    }

    @Test func reportsAnErrorSentMidStream() async throws {
        let host = "midstream.test"
        var body = sse(["半"], done: false)
        body.append(Data(#"data: {"error":{"message":"overloaded"}}"#.utf8 + Data("\n\n".utf8)))
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        await #expect(throws: TranslationFailure.failed("overloaded")) {
            _ = try await run(OpenAICompatibleEngine(configuration: configuration(host), session: session))
        }
    }

    @Test func mapsNoConnectionToOffline() async throws {
        let host = "offline.test"
        let session = StubURLProtocol.session(host: host, reply: .init(error: URLError(.notConnectedToInternet)))
        await #expect(throws: TranslationFailure.offline) {
            _ = try await run(OpenAICompatibleEngine(configuration: configuration(host), session: session))
        }
    }

    @Test func refusesToRunWithoutConfiguration() async throws {
        await #expect(throws: TranslationFailure.notConfigured) {
            _ = try await run(OpenAICompatibleEngine(configuration: nil))
        }
    }

    @Test func listsModelsSorted() async throws {
        let host = "models.test"
        let body = Data(#"{"object":"list","data":[{"id":"model-b"},{"id":"model-a"}]}"#.utf8)
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        #expect(try await OpenAICompatibleEngine.models(configuration(host), session: session) == ["model-a", "model-b"])
        let (request, _) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v1/models")
        #expect(request.httpMethod == "GET")
    }
}

@Suite("Claude format")
struct ClaudeEngineTests {
    private func configuration(_ host: String, key: String? = "sk-ant-test") -> ClaudeEngine.Configuration {
        .init(baseURL: URL(string: "https://\(host)/v1")!, key: key, model: "claude-sonnet-test")
    }

    private func sse(_ deltas: [String], stop: Bool = true) -> Data {
        var text = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
        text += "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}\n\n"
        for delta in deltas {
            let json = try! JSONSerialization.data(withJSONObject: [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": delta],
            ])
            text += "event: content_block_delta\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
        }
        if stop { text += "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n" }
        return Data(text.utf8)
    }

    private func run(_ engine: ClaudeEngine, _ request: TranslationRequest = .translate("Hello there.")) async throws -> [String] {
        var all: [String] = []
        for try await text in engine.run(request) { all.append(text) }
        return all
    }

    @Test func normalizesCustomAndOfficialAddresses() {
        #expect(ClaudeEngine.endpointURL("https://api.anthropic.com")?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(ClaudeEngine.endpointURL("https://api.anthropic.com/v1")?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(ClaudeEngine.endpointURL("https://relay.example.com/anthropic")?.absoluteString == "https://relay.example.com/anthropic/v1/messages")
        #expect(ClaudeEngine.endpointURL("https://relay.example.com/v1/messages")?.absoluteString == "https://relay.example.com/v1/messages")
    }

    @Test func buildsAStreamingMessagesRequest() async throws {
        let host = "claude-build.test"
        let session = StubURLProtocol.session(host: host, reply: .init(body: sse(["好"])))
        _ = try await run(ClaudeEngine(configuration: configuration(host), session: session),
                          .explain(word: "hare", sentence: "The March Hare said."))
        let (request, body) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-test")
        #expect(json["stream"] as? Bool == true)
        #expect((json["max_tokens"] as? Int ?? 0) > 0)
        #expect((json["system"] as? String)?.isEmpty == false)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "<word>hare</word>\n<sentence>The March Hare said.</sentence>"]])
    }

    @Test func streamsTextDeltasAndStopsAtMessageStop() async throws {
        let host = "claude-stream.test"
        var body = sse(["你", "好"])
        body.append(Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"extra\"}}\n\n".utf8))
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        #expect(try await run(ClaudeEngine(configuration: configuration(host), session: session)) == ["你", "你好"])
    }

    @Test func reportsMidStreamErrorEvent() async throws {
        let host = "claude-error.test"
        var body = sse(["半"], stop: false)
        body.append(Data("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n".utf8))
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        await #expect(throws: TranslationFailure.failed("Overloaded")) {
            _ = try await run(ClaudeEngine(configuration: configuration(host), session: session))
        }
    }

    @Test func listsModelsFromCustomEndpoint() async throws {
        let host = "claude-models.test"
        let body = Data(#"{"data":[{"id":"claude-opus"},{"id":"claude-haiku"}]}"#.utf8)
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        let models = try await ClaudeEngine.models(configuration(host), session: session)
        #expect(models == ["claude-haiku", "claude-opus"])
        let (request, _) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v1/models?limit=100")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    }
}

@Suite("Gemini format")
struct GeminiEngineTests {
    private func configuration(_ host: String, model: String = "gemini-2.5-flash") -> GeminiEngine.Configuration {
        .init(baseURL: URL(string: "https://\(host)/v1beta")!, key: "gem-key", model: model)
    }

    private func sse(_ chunks: [[[String: Any]]]) -> Data {
        let text = chunks.map { parts -> String in
            let json = try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["role": "model", "parts": parts]]]])
            return "data: \(String(decoding: json, as: UTF8.self))\n\n"
        }.joined()
        return Data(text.utf8)
    }

    private func run(_ engine: GeminiEngine, _ request: TranslationRequest = .translate("Hello there.")) async throws -> [String] {
        var all: [String] = []
        for try await text in engine.run(request) { all.append(text) }
        return all
    }

    @Test func normalizesCustomAndOfficialAddresses() {
        #expect(GeminiEngine.endpointURL("https://generativelanguage.googleapis.com", model: "gemini-2.5-flash")?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        #expect(GeminiEngine.endpointURL("https://relay.example.com/v1", model: "models/gemini-2.5-flash")?.absoluteString
                == "https://relay.example.com/v1/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
    }

    @Test func buildsAStreamGenerateContentRequestAndSkipsThoughts() async throws {
        let host = "gemini-build.test"
        let bodyData = sse([
            [["text": "internal reasoning", "thought": true]],
            [["text": "你"]],
            [["text": "好"]],
        ])
        let session = StubURLProtocol.session(host: host, reply: .init(body: bodyData))
        let streamed = try await run(GeminiEngine(configuration: configuration(host, model: "models/gemini-2.5-flash"), session: session))
        #expect(streamed == ["你", "你好"])
        let (request, body) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gem-key")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]])
        #expect(system.first?["text"]?.isEmpty == false)
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.first?["role"] as? String == "user")
        let parts = try #require(contents.first?["parts"] as? [[String: String]])
        #expect(parts == [["text": "<text>\nHello there.\n</text>"]])
    }

    @Test func listsGenerativeModelsWithoutPrefix() async throws {
        let host = "gemini-models.test"
        let body = Data("""
        {"models":[
          {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent","streamGenerateContent"]},
          {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}
        ]}
        """.utf8)
        let session = StubURLProtocol.session(host: host, reply: .init(body: body))
        let models = try await GeminiEngine.models(configuration(host), session: session)
        #expect(models == ["gemini-2.5-flash", "gemini-2.5-pro"])
        let (request, _) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v1beta/models?pageSize=1000")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gem-key")
    }
}

@Suite("DeepL format")
struct DeepLEngineTests {
    private func run(_ engine: DeepLEngine, _ request: TranslationRequest) async throws -> [String] {
        var all: [String] = []
        for try await text in engine.run(request) { all.append(text) }
        return all
    }

    @Test func picksFreeProOrCustomHost() {
        #expect(DeepLEngine.endpointURL("https://api.deepl.com/v2", key: "1234-abcd:fx")?.absoluteString == "https://api-free.deepl.com/v2/translate")
        #expect(DeepLEngine.endpointURL("https://api-free.deepl.com/v2", key: "1234-abcd")?.absoluteString == "https://api.deepl.com/v2/translate")
        #expect(DeepLEngine.endpointURL("http://192.168.1.5:1188", key: nil)?.absoluteString == "http://192.168.1.5:1188/v2/translate")
        #expect(DeepLEngine.configuration(endpoint: .init(name: "", format: .deepL, baseURL: "https://api-free.deepl.com/v2"), key: nil) == nil)
        #expect(DeepLEngine.configuration(endpoint: .init(name: "DeepLX", format: .deepL, baseURL: "http://192.168.1.5:1188/v2"), key: nil)
                == .init(baseURL: URL(string: "http://192.168.1.5:1188/v2")!, key: nil))
    }

    @Test func buildsTranslateRequestWithContext() async throws {
        let host = "deepl-translate.test"
        let reply = Data(#"{"translations":[{"detected_source_language":"EN","text":"野兔"}]}"#.utf8)
        let session = StubURLProtocol.session(host: host, reply: .init(body: reply))
        let engine = DeepLEngine(configuration: .init(baseURL: URL(string: "https://\(host)/v2")!, key: "dl-key:fx"), session: session)
        let out = try await run(engine, .translate("Hare", context: "The March Hare said."))
        #expect(out == ["野兔"])
        let (request, body) = try #require(StubURLProtocol.request(host: host))
        #expect(request.url?.absoluteString == "https://\(host)/v2/translate")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key dl-key:fx")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["text"] as? [String] == ["Hare"])
        #expect(json["source_lang"] as? String == "EN")
        #expect(json["target_lang"] as? String == "ZH-HANS")
        #expect(json["context"] as? String == "The March Hare said.")
    }

    @Test func omitsContextAndAuthWhenUnsetAndMapsQuotaStatus() async throws {
        let host = "deepl-quota.test"
        let errorBody = Data(#"{"message":"Quota exceeded."}"#.utf8)
        let session = StubURLProtocol.session(host: host, reply: .init(status: 456, body: errorBody))
        let engine = DeepLEngine(configuration: .init(baseURL: URL(string: "http://\(host)/v2")!, key: nil), session: session)
        await #expect(throws: TranslationFailure.failed("额度用完或请求太频繁，稍后再试。Quota exceeded.")) {
            _ = try await run(engine, .translate("Hello there."))
        }
        let (request, body) = try #require(StubURLProtocol.request(host: host))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["context"] == nil)
    }
}

@Suite("Translation keychain")
struct TranslationKeychainTests {
    @Test func savesReplacesAndDeletesEndpointKeysIndependently() throws {
        let keychain = TranslationKeychain(service: "com.inp146.readling.tests.\(UUID().uuidString)")
        let first = UUID(), second = UUID()
        #expect(keychain.key(for: first) == nil)
        try keychain.setKey("key-1", for: first)
        try keychain.setKey("key-1b", for: first)
        try keychain.setKey("key-2", for: second)
        #expect(keychain.key(for: first) == "key-1b")
        #expect(keychain.key(for: second) == "key-2")
        try keychain.deleteKey(for: first)
        #expect(keychain.key(for: first) == nil)
        #expect(keychain.key(for: second) == "key-2")
        try keychain.deleteKey(for: first)
    }
}
