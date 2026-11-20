import Foundation

/// Any endpoint speaking Google's Gemini REST API (`:streamGenerateContent?alt=sse`),
/// whether `generativelanguage.googleapis.com` or a custom gateway.
struct GeminiClient: AIClient {
    struct Configuration: Equatable, Sendable {
        var baseURL: URL
        var key: String?
        var model: String
    }

    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    var configuration: Configuration
    var session: URLSession = .shared

    static func configuration(endpoint: AIEndpoint, key: String?) -> Configuration? {
        let model = normalizedModel(endpoint.model)
        guard let baseURL = baseURL(endpoint.baseURL), !model.isEmpty else { return nil }
        return Configuration(baseURL: baseURL, key: OnlineService.nonEmptyKey(key), model: model)
    }

    /// Accepts `https://host`, `https://host/v1beta` or `https://host/v1`.
    static func baseURL(_ address: String) -> URL? {
        guard let url = OnlineService.cleanBaseURL(address) else { return nil }
        let path = url.path()
        return path.hasSuffix("/v1beta") || path.hasSuffix("/v1") ? url : url.appending(path: "v1beta")
    }

    /// Strips the `models/` prefix Gemini's list endpoint puts on model ids.
    static func normalizedModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("models/") ? String(trimmed.dropFirst("models/".count)) : trimmed
    }

    static func endpointURL(_ address: String, model: String) -> URL? {
        guard let base = baseURL(address) else { return nil }
        let id = normalizedModel(model)
        return streamURL(base, model: id.isEmpty ? "{model}" : id)
    }

    private static func streamURL(_ base: URL, model: String) -> URL {
        let path = "models/\(model):streamGenerateContent"
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return components?.url ?? base.appending(path: path)
    }

    private static func urlRequest(_ url: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        request.timeoutInterval = 60
        return request
    }

    static func streamRequest(_ prompt: AIPrompt, _ configuration: Configuration) throws -> URLRequest {
        struct Part: Encodable { var text: String }
        struct Content: Encodable {
            var role: String?
            var parts: [Part]
        }
        struct Body: Encodable {
            var systemInstruction: Content
            var contents: [Content]
        }
        let url = streamURL(configuration.baseURL, model: normalizedModel(configuration.model))
        var request = urlRequest(url, key: configuration.key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(
            systemInstruction: Content(parts: [Part(text: prompt.system)]),
            contents: [Content(role: "user", parts: [Part(text: prompt.user)])]
        ))
        return request
    }

    static func step(_ event: ServerSentEvents.Event) throws -> OnlineService.StreamStep {
        struct Chunk: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        var text: String?
                        var thought: Bool?
                    }
                    var parts: [Part]?
                }
                var content: Content?
            }
            struct Failure: Decodable { var message: String? }
            var candidates: [Candidate]?
            var error: Failure?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(event.data.utf8)) else { return .ignore }
        if let error = chunk.error { throw OnlineFailure.failed(error.message ?? String(localized: "服务返回了错误。")) }
        let parts = chunk.candidates?.first?.content?.parts ?? []
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        return text.isEmpty ? .ignore : .text(text)
    }

    func complete(_ prompt: AIPrompt) -> AsyncThrowingStream<String, Error> {
        let configuration = configuration
        return OnlineService.stream({ try Self.streamRequest(prompt, configuration) }, session: session, step: Self.step)
    }

    static func models(_ configuration: Configuration, session: URLSession = .shared) async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable {
                var name: String
                var supportedGenerationMethods: [String]?
            }
            var models: [Model]?
        }
        var components = URLComponents(url: configuration.baseURL.appending(path: "models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        do {
            let url = components?.url ?? configuration.baseURL.appending(path: "models")
            let bytes = try await OnlineService.receive(urlRequest(url, key: configuration.key), session: session)
            guard let list = try? JSONDecoder().decode(List.self, from: bytes) else {
                throw OnlineFailure.failed(String(localized: "看不懂服务返回的模型列表。"))
            }
            let names = (list.models ?? [])
                .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
                .map { normalizedModel($0.name) }
            return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            throw OnlineService.failure(error)
        }
    }
}
