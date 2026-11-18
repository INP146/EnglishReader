import Foundation

/// Any endpoint speaking DeepL's `/v2/translate` JSON API: official DeepL Free
/// (`:fx` keys) / Pro, a relay, or a self-hosted DeepLX server on the LAN.
struct DeepLEngine: TranslationEngine {
    struct Configuration: Equatable, Sendable {
        var baseURL: URL
        var key: String?
    }

    static let defaultBaseURL = "https://api-free.deepl.com/v2"
    static let freeBaseURL = URL(string: "https://api-free.deepl.com/v2")!
    static let proBaseURL = URL(string: "https://api.deepl.com/v2")!

    var title = TranslationAPIFormat.deepL.title
    let capabilities: Set<TranslationCapability> = [.translate]
    var configuration: Configuration?
    var session: URLSession = .shared

    static func isOfficialHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "api.deepl.com" || lower == "api-free.deepl.com"
    }

    static func baseURL(forKey key: String) -> URL {
        key.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":fx") ? freeBaseURL : proBaseURL
    }

    /// Official DeepL hosts automatically pick free vs pro from the `:fx` key
    /// suffix; custom endpoints keep their own host (adding `/v2` when bare).
    static func baseURL(_ address: String, key: String? = nil) -> URL? {
        guard let url = OnlineTranslation.cleanBaseURL(address, strippingSuffixes: ["/translate"]) else { return nil }
        if let host = url.host(), isOfficialHost(host) {
            return baseURL(forKey: key ?? "")
        }
        let path = url.path()
        return path.isEmpty || path == "/" ? url.appending(path: "v2") : url
    }

    static func endpointURL(_ address: String, key: String? = nil) -> URL? {
        baseURL(address, key: key)?.appending(path: "translate")
    }

    static func configuration(endpoint: TranslationEndpoint, key: String?) -> Configuration? {
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyKey = trimmedKey?.isEmpty == true ? nil : trimmedKey
        guard let base = baseURL(endpoint.baseURL, key: nonEmptyKey) else { return nil }
        if let host = base.host(), isOfficialHost(host), nonEmptyKey == nil { return nil }
        return Configuration(baseURL: base, key: nonEmptyKey)
    }

    static func translateRequest(_ translation: TranslationRequest, _ configuration: Configuration) throws -> URLRequest {
        struct Body: Encodable {
            var text: [String]
            var source_lang = "EN"
            var target_lang = "ZH-HANS"
            var context: String?
        }
        let text: String, context: String?
        switch translation {
        case .translate(let value, let surrounding):
            text = value
            context = surrounding
        case .explain(let word, let sentence):
            text = word
            context = sentence.isEmpty || sentence == word ? nil : sentence
        }
        var request = URLRequest(url: configuration.baseURL.appending(path: "translate"))
        request.httpMethod = "POST"
        if let key = configuration.key, !key.isEmpty {
            request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(Body(text: [text], context: context))
        return request
    }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        let configuration = configuration
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                struct Response: Decodable {
                    struct Item: Decodable { var text: String }
                    var translations: [Item]
                }
                do {
                    guard let configuration else { throw TranslationFailure.notConfigured }
                    let data = try await OnlineTranslation.receive(Self.translateRequest(request, configuration), session: session)
                    guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                        throw TranslationFailure.failed(String(localized: "看不懂服务返回的译文。"))
                    }
                    continuation.yield(response.translations.map(\.text).joined(separator: "\n"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : OnlineTranslation.failure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
