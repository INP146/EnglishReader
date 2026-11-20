import Foundation

/// One request to a large language model: instructions plus the user's message.
/// Features (translation, dictionary, …) write their own prompts; the AI layer
/// only carries them to whichever endpoint the feature picked.
struct AIPrompt: Hashable, Sendable {
    var system: String
    var user: String
    var maxTokens = 2048

    /// A short, harmless request for the endpoint editor's “test” button.
    static let connectionTest = AIPrompt(
        system: "把用户给出的英文翻译成简体中文。只输出译文。",
        user: "The quick brown fox jumps over the lazy dog."
    )
}

/// A connection to one LLM endpoint.
protocol AIClient: Sendable {
    /// The answer so far, growing with each element.
    func complete(_ prompt: AIPrompt) -> AsyncThrowingStream<String, Error>
}

/// Which wire protocol an AI endpoint speaks.
enum AIFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI
    case claude
    case gemini

    var id: Self { self }

    var title: String {
        switch self {
        case .openAI: "OpenAI 兼容"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: OpenAIClient.defaultBaseURL
        case .claude: ClaudeClient.defaultBaseURL
        case .gemini: GeminiClient.defaultBaseURL
        }
    }

    /// The full request URL an address resolves to, shown as a live preview when editing.
    func previewURL(address: String, model: String = "") -> URL? {
        switch self {
        case .openAI: OpenAIClient.endpointURL(address)
        case .claude: ClaudeClient.endpointURL(address)
        case .gemini: GeminiClient.endpointURL(address, model: model)
        }
    }

    /// Nil until the endpoint has a usable address and model.
    func client(for endpoint: AIEndpoint, key: String?, session: URLSession = .shared) -> (any AIClient)? {
        switch self {
        case .openAI: OpenAIClient.configuration(endpoint: endpoint, key: key).map { OpenAIClient(configuration: $0, session: session) }
        case .claude: ClaudeClient.configuration(endpoint: endpoint, key: key).map { ClaudeClient(configuration: $0, session: session) }
        case .gemini: GeminiClient.configuration(endpoint: endpoint, key: key).map { GeminiClient(configuration: $0, session: session) }
        }
    }

    /// The model ids the endpoint offers, for the editor to pick from.
    func models(address: String, key: String?, session: URLSession = .shared) async throws -> [String] {
        let key = OnlineService.nonEmptyKey(key)
        switch self {
        case .openAI:
            guard let base = OpenAIClient.baseURL(address) else { throw OnlineFailure.notConfigured }
            return try await OpenAIClient.models(.init(baseURL: base, key: key, model: ""), session: session)
        case .claude:
            guard let base = ClaudeClient.baseURL(address) else { throw OnlineFailure.notConfigured }
            return try await ClaudeClient.models(.init(baseURL: base, key: key, model: ""), session: session)
        case .gemini:
            guard let base = GeminiClient.baseURL(address) else { throw OnlineFailure.notConfigured }
            return try await GeminiClient.models(.init(baseURL: base, key: key, model: ""), session: session)
        }
    }
}

/// A user-saved LLM endpoint (cloud API, relay, or LAN server).
/// Its API key lives in `APIKeychain.ai` under `id.uuidString`, never in UserDefaults.
struct AIEndpoint: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var format: AIFormat
    var baseURL: String
    var model: String

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host(), !host.isEmpty {
            return "\(format.title) (\(host))"
        }
        return format.title
    }

    var subtitle: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? format.title : "\(format.title) · \(trimmedModel)"
    }
}
