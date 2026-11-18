import Foundation

/// Any endpoint speaking OpenAI's Chat Completions API: OpenAI, DeepSeek, Qwen,
/// Kimi, OpenRouter, OneAPI relays, or a local Ollama / LM Studio / vLLM server.
struct OpenAICompatibleEngine: TranslationEngine {
    struct Configuration: Equatable, Sendable {
        var baseURL: URL
        /// Optional: a local server may not want one.
        var key: String?
        var model: String
    }

    static let defaultBaseURL = "https://api.openai.com/v1"

    var title = TranslationAPIFormat.openAI.title
    let capabilities: Set<TranslationCapability> = [.translate, .explain]
    var configuration: Configuration?
    var session: URLSession = .shared

    static func configuration(endpoint: TranslationEndpoint, key: String?) -> Configuration? {
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = baseURL(endpoint.baseURL), !model.isEmpty else { return nil }
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Configuration(baseURL: baseURL, key: trimmedKey?.isEmpty == true ? nil : trimmedKey, model: model)
    }

    /// Normalizes the endpoint root; bare `http(s)://host` gets `/v1`, explicit paths stay as typed.
    static func baseURL(_ address: String) -> URL? {
        guard let url = OnlineTranslation.cleanBaseURL(address, strippingSuffixes: ["/chat/completions"]) else { return nil }
        let path = url.path()
        return path.isEmpty || path == "/" ? url.appending(path: "v1") : url
    }

    static func endpointURL(_ address: String) -> URL? {
        baseURL(address)?.appending(path: "chat/completions")
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
        return OnlineTranslation.stream({
            guard let configuration else { throw TranslationFailure.notConfigured }
            return try Self.chatRequest(request, configuration)
        }, session: session) { event in
            if event.data == "[DONE]" { return .done }
            guard let delta = try Self.delta(in: event.data) else { return .ignore }
            return .text(delta)
        }
    }

    /// The model ids the endpoint offers, for the endpoint editor to pick from.
    static func models(_ configuration: Configuration, session: URLSession = .shared) async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        do {
            let bytes = try await OnlineTranslation.receive(urlRequest("models", configuration), session: session)
            guard let list = try? JSONDecoder().decode(List.self, from: bytes) else {
                throw TranslationFailure.failed(String(localized: "看不懂服务返回的模型列表。"))
            }
            return list.data.map(\.id).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            throw OnlineTranslation.failure(error)
        }
    }
}
