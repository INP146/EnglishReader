import Foundation

/// Any service speaking OpenAI's Chat Completions API: OpenAI itself, DeepSeek,
/// Qwen, Kimi, OpenRouter, a local Ollama… The user brings the address, key and model.
struct OpenAICompatibleEngine: TranslationEngine {
    struct Configuration: Equatable, Sendable {
        var baseURL: URL
        /// Optional: a local server may not want one.
        var key: String?
        var model: String
    }

    static let baseURLKey = "translationOpenAIBaseURL"
    static let modelKey = "translationOpenAIModel"
    static let defaultBaseURL = "https://api.openai.com/v1"

    let id = TranslationEngineID.openAI
    let capabilities: Set<TranslationCapability> = [.translate, .explain]
    /// Nil until the user has set an address and a model.
    var configuration: Configuration?
    var session: URLSession = .shared

    /// The settings the user saved, or nil when the engine isn't usable yet.
    static func saved(defaults: UserDefaults = .standard, keychain: TranslationKeychain = .shared) -> Configuration? {
        let address = defaults.string(forKey: baseURLKey) ?? defaultBaseURL
        let model = (defaults.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard let baseURL = baseURL(address), !model.isEmpty else { return nil }
        return Configuration(baseURL: baseURL, key: keychain.key(for: .openAI), model: model)
    }

    /// An http(s) address with a host, as typed; nil otherwise.
    static func baseURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    private static func urlRequest(_ path: String, _ configuration: Configuration) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        if let key = configuration.key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 60
        return request
    }

    static func chatRequest(_ translation: TranslationRequest, _ configuration: Configuration) throws -> URLRequest {
        struct Message: Encodable { var role: String; var content: String }
        struct Body: Encodable { var model: String; var stream = true; var messages: [Message] }
        let prompt = OnlineTranslation.prompt(for: translation)
        var request = urlRequest("chat/completions", configuration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, messages: [
            Message(role: "system", content: prompt.system),
            Message(role: "user", content: prompt.user),
        ]))
        return request
    }

    /// The text one streamed chunk adds; throws when the service reports an error mid-stream.
    static func delta(in data: String) throws -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { var content: String? }
                var delta: Delta?
            }
            struct Failure: Decodable { var message: String? }
            var choices: [Choice]?
            var error: Failure?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(data.utf8)) else { return nil }
        if let error = chunk.error { throw TranslationFailure.failed(error.message ?? String(localized: "服务返回了错误。")) }
        return chunk.choices?.first?.delta?.content
    }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        let configuration = configuration
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let configuration else { throw TranslationFailure.notConfigured }
                    let bytes = try await OnlineTranslation.send(Self.chatRequest(request, configuration), session: session)
                    var events = ServerSentEvents()
                    var text = ""
                    func handle(_ event: ServerSentEvents.Event) throws -> Bool {
                        if event.data == "[DONE]" { return true }
                        if let delta = try Self.delta(in: event.data), !delta.isEmpty {
                            text += delta
                            continuation.yield(text)
                        }
                        return false
                    }
                    reading: for try await byte in bytes {
                        if let event = events.feed(byte), try handle(event) { break reading }
                    }
                    if let event = events.finish() { _ = try handle(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : OnlineTranslation.failure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The model ids the service offers, for the settings page to pick from.
    static func models(_ configuration: Configuration, session: URLSession = .shared) async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        do {
            var bytes = Data()
            for try await byte in try await OnlineTranslation.send(urlRequest("models", configuration), session: session) { bytes.append(byte) }
            guard let list = try? JSONDecoder().decode(List.self, from: bytes) else {
                throw TranslationFailure.failed(String(localized: "看不懂服务返回的模型列表。"))
            }
            return list.data.map(\.id).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            throw OnlineTranslation.failure(error)
        }
    }
}
