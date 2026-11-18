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

@Suite("OpenAI-compatible engine")
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

    @Test func readsSavedSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "OpenAICompatibleEngineTests"))
        defaults.removePersistentDomain(forName: "OpenAICompatibleEngineTests")
        let keychain = TranslationKeychain(service: "com.inp146.readling.tests.\(UUID().uuidString)")
        #expect(OpenAICompatibleEngine.saved(defaults: defaults, keychain: keychain) == nil)
        defaults.set("some-model", forKey: OpenAICompatibleEngine.modelKey)
        #expect(OpenAICompatibleEngine.saved(defaults: defaults, keychain: keychain)
                == .init(baseURL: URL(string: OpenAICompatibleEngine.defaultBaseURL)!, key: nil, model: "some-model"))
        defaults.set("api.example.com/v1", forKey: OpenAICompatibleEngine.baseURLKey)
        #expect(OpenAICompatibleEngine.saved(defaults: defaults, keychain: keychain) == nil)
    }
}

@Suite("Translation keychain")
struct TranslationKeychainTests {
    @Test func savesReplacesAndDeletesAKey() throws {
        let keychain = TranslationKeychain(service: "com.inp146.readling.tests.\(UUID().uuidString)")
        #expect(keychain.key(for: .openAI) == nil)
        try keychain.setKey("first", for: .openAI)
        try keychain.setKey("second", for: .openAI)
        #expect(keychain.key(for: .openAI) == "second")
        #expect(keychain.key(for: .apple) == nil)
        try keychain.deleteKey(for: .openAI)
        #expect(keychain.key(for: .openAI) == nil)
        try keychain.deleteKey(for: .openAI)
    }
}
