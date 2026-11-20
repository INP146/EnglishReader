import Foundation

/// Any endpoint speaking Anthropic's Messages API (`/v1/messages`), whether
/// Anthropic itself, a relay, or a local gateway.
struct ClaudeClient: AIClient {
    struct Configuration: Equatable, Sendable {
        var baseURL: URL
        var key: String?
        var model: String
    }

    static let defaultBaseURL = "https://api.anthropic.com/v1"
    static let apiVersion = "2023-06-01"

    var configuration: Configuration
    var session: URLSession = .shared

    static func configuration(endpoint: AIEndpoint, key: String?) -> Configuration? {
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = baseURL(endpoint.baseURL), !model.isEmpty else { return nil }
        return Configuration(baseURL: baseURL, key: OnlineService.nonEmptyKey(key), model: model)
    }

    /// Accepts either `https://host` (Anthropic SDK style) or `https://host/v1`.
    static func baseURL(_ address: String) -> URL? {
        guard let url = OnlineService.cleanBaseURL(address, strippingSuffixes: ["/messages"]) else { return nil }
        return url.path().hasSuffix("/v1") ? url : url.appending(path: "v1")
    }

    static func endpointURL(_ address: String) -> URL? {
        baseURL(address)?.appending(path: "messages")
    }

    private static func urlRequest(_ url: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        return request
    }

    static func messagesRequest(_ prompt: AIPrompt, _ configuration: Configuration) throws -> URLRequest {
        struct Message: Encodable { var role: String; var content: String }
        struct Body: Encodable {
            var model: String
            var max_tokens: Int
            var stream = true
            var system: String
            var messages: [Message]
        }
        var request = urlRequest(configuration.baseURL.appending(path: "messages"), key: configuration.key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(model: configuration.model, max_tokens: prompt.maxTokens,
                                                         system: prompt.system, messages: [
            Message(role: "user", content: prompt.user),
        ]))
        return request
    }

    static func step(_ event: ServerSentEvents.Event) throws -> OnlineService.StreamStep {
        struct Payload: Decodable {
            struct Delta: Decodable {
                var type: String?
                var text: String?
            }
            struct Failure: Decodable { var message: String? }
            var type: String?
            var delta: Delta?
            var error: Failure?
        }
        if event.name == "message_stop" { return .done }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(event.data.utf8)) else {
            if event.name == "error" { throw OnlineFailure.failed(String(localized: "服务返回了错误。")) }
            return .ignore
        }
        if payload.type == "message_stop" { return .done }
        if event.name == "error" || payload.type == "error" {
            throw OnlineFailure.failed(payload.error?.message ?? String(localized: "服务返回了错误。"))
        }
        if payload.type == "content_block_delta", payload.delta?.type == "text_delta", let text = payload.delta?.text {
            return .text(text)
        }
        return .ignore
    }

    func complete(_ prompt: AIPrompt) -> AsyncThrowingStream<String, Error> {
        let configuration = configuration
        return OnlineService.stream({ try Self.messagesRequest(prompt, configuration) }, session: session, step: Self.step)
    }

    static func models(_ configuration: Configuration, session: URLSession = .shared) async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        var components = URLComponents(url: configuration.baseURL.appending(path: "models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "100")]
        do {
            let url = components?.url ?? configuration.baseURL.appending(path: "models")
            let bytes = try await OnlineService.receive(urlRequest(url, key: configuration.key), session: session)
            guard let list = try? JSONDecoder().decode(List.self, from: bytes) else {
                throw OnlineFailure.failed(String(localized: "看不懂服务返回的模型列表。"))
            }
            return list.data.map(\.id).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            throw OnlineService.failure(error)
        }
    }
}
