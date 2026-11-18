import Foundation
import Observation
import Translation

/// What the lookup card asks for when the dictionary has nothing.
enum TranslationRequest: Hashable, Sendable {
    /// A sentence or any run of words, optionally with the surrounding sentence for context.
    case translate(String, context: String? = nil)
    /// A word the dictionary lacks, read in its sentence: what it means right here.
    case explain(word: String, sentence: String)
}

enum TranslationCapability: Sendable { case translate, explain }

/// Which wire protocol a user-configured endpoint speaks.
enum TranslationAPIFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI
    case claude
    case gemini
    case deepL

    var id: Self { self }

    var title: String {
        switch self {
        case .openAI: "OpenAI 兼容"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .deepL: "DeepL"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: OpenAICompatibleEngine.defaultBaseURL
        case .claude: ClaudeEngine.defaultBaseURL
        case .gemini: GeminiEngine.defaultBaseURL
        case .deepL: DeepLEngine.defaultBaseURL
        }
    }

    var usesModel: Bool { self != .deepL }

    var capabilities: Set<TranslationCapability> {
        self == .deepL ? [.translate] : [.translate, .explain]
    }

    /// The full request URL an address resolves to, shown as a live preview when editing.
    func previewURL(address: String, model: String = "", key: String? = nil) -> URL? {
        switch self {
        case .openAI: OpenAICompatibleEngine.endpointURL(address)
        case .claude: ClaudeEngine.endpointURL(address)
        case .gemini: GeminiEngine.endpointURL(address, model: model)
        case .deepL: DeepLEngine.endpointURL(address, key: key)
        }
    }

    func engine(for endpoint: TranslationEndpoint, key: String?, session: URLSession = .shared) -> any TranslationEngine {
        let title = endpoint.displayName
        switch self {
        case .openAI:
            return OpenAICompatibleEngine(title: title, configuration: OpenAICompatibleEngine.configuration(endpoint: endpoint, key: key), session: session)
        case .claude:
            return ClaudeEngine(title: title, configuration: ClaudeEngine.configuration(endpoint: endpoint, key: key), session: session)
        case .gemini:
            return GeminiEngine(title: title, configuration: GeminiEngine.configuration(endpoint: endpoint, key: key), session: session)
        case .deepL:
            return DeepLEngine(title: title, configuration: DeepLEngine.configuration(endpoint: endpoint, key: key), session: session)
        }
    }

    func isConfigured(endpoint: TranslationEndpoint, key: String?) -> Bool {
        switch self {
        case .openAI: OpenAICompatibleEngine.configuration(endpoint: endpoint, key: key) != nil
        case .claude: ClaudeEngine.configuration(endpoint: endpoint, key: key) != nil
        case .gemini: GeminiEngine.configuration(endpoint: endpoint, key: key) != nil
        case .deepL: DeepLEngine.configuration(endpoint: endpoint, key: key) != nil
        }
    }

    func models(address: String, key: String?, session: URLSession = .shared) async throws -> [String] {
        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyKey = trimmedKey?.isEmpty == true ? nil : trimmedKey
        switch self {
        case .openAI:
            guard let base = OpenAICompatibleEngine.baseURL(address) else { throw TranslationFailure.notConfigured }
            return try await OpenAICompatibleEngine.models(.init(baseURL: base, key: nonEmptyKey, model: ""), session: session)
        case .claude:
            guard let base = ClaudeEngine.baseURL(address) else { throw TranslationFailure.notConfigured }
            return try await ClaudeEngine.models(.init(baseURL: base, key: nonEmptyKey, model: ""), session: session)
        case .gemini:
            guard let base = GeminiEngine.baseURL(address) else { throw TranslationFailure.notConfigured }
            return try await GeminiEngine.models(.init(baseURL: base, key: nonEmptyKey, model: ""), session: session)
        case .deepL:
            return []
        }
    }
}

/// A user-saved translation endpoint (cloud API, relay, or LAN server).
/// Its API key lives in `TranslationKeychain` under `id.uuidString`, never in UserDefaults.
struct TranslationEndpoint: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var format: TranslationAPIFormat
    var baseURL: String
    var model: String = ""

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host(), !host.isEmpty {
            return "\(format.title) (\(host))"
        }
        return format.title
    }

    var subtitle: String {
        guard format.usesModel else {
            if let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host(),
               !DeepLEngine.isOfficialHost(host) {
                return "\(format.title) · \(host)"
            }
            return format.title
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? format.title : "\(format.title) · \(trimmedModel)"
    }
}

/// Which service is chosen to answer translation requests.
enum TranslationProviderID: Hashable, Sendable {
    case apple
    case endpoint(UUID)
    /// Answers instantly with canned text; picked by UI tests with `-translationEngine stub`.
    case stub

    static let appleTitle = "Apple 本机翻译"
    static let stubTitle = "测试引擎"

    var rawValue: String {
        switch self {
        case .apple: "apple"
        case .endpoint(let id): id.uuidString
        case .stub: "stub"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "apple": self = .apple
        case "stub": self = .stub
        default:
            guard let id = UUID(uuidString: rawValue) else { return nil }
            self = .endpoint(id)
        }
    }
}

enum TranslationFailure: LocalizedError, Equatable {
    /// Apple's on-device model for English → Chinese isn't downloaded yet.
    case needsLanguagePack
    case unsupported
    /// An online endpoint without a usable address, key or model yet.
    case notConfigured
    case offline
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsLanguagePack: "需要先下载英语到简体中文的翻译语言包。"
        case .unsupported: "这台设备不支持英语到简体中文的本机翻译。"
        case .notConfigured: "这个翻译端点还没有配置完整。"
        case .offline: "没有网络连接。"
        case .failed(let message): message
        }
    }
}

protocol TranslationEngine: Sendable {
    var title: String { get }
    var capabilities: Set<TranslationCapability> { get }
    /// The result so far, growing with each element; engines that don't stream yield once.
    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}

/// Manages user-configured endpoints, picks the active service, falls back to
/// Apple's on-device engine when the chosen endpoint fails, and caches finished
/// results for this launch.
@Observable @MainActor
final class TranslationService {
    static let shared = TranslationService()

    struct Result: Equatable, Sendable {
        var text: String
        var provider: TranslationProviderID
        var providerTitle: String
        var canExplain = false
        var isFinal: Bool
        /// Why the chosen service didn't answer, when another one did.
        var notice: String?
    }

    enum KeyChange: Equatable, Sendable {
        case unchanged
        case set(String)
        case clear
    }

    static let engineKey = "translationEngine"
    static let endpointsKey = "translationEndpoints"
    static let automaticKey = "translationAutomatic"
    nonisolated static let source = Locale.Language(identifier: "en")
    nonisolated static let target = Locale.Language(identifier: "zh-Hans")

    private struct CacheKey: Hashable {
        var provider: TranslationProviderID
        var request: TranslationRequest
    }

    private(set) var endpoints: [TranslationEndpoint]
    var selection: TranslationProviderID {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: Self.engineKey)
        }
    }

    private let defaults: UserDefaults
    private let keychain: TranslationKeychain
    private let customEngine: ((TranslationProviderID) -> any TranslationEngine)?
    private var cache: [CacheKey: String] = [:]

    init(defaults: UserDefaults = .standard,
         keychain: TranslationKeychain = .shared,
         engines: ((TranslationProviderID) -> any TranslationEngine)? = nil) {
        self.defaults = defaults
        self.keychain = keychain
        self.customEngine = engines
        let loaded = Self.loadEndpoints(defaults: defaults, keychain: keychain)
        self.endpoints = loaded
        self.selection = Self.loadSelection(defaults: defaults, endpoints: loaded)
    }

    func key(for id: UUID) -> String? { keychain.key(for: id) }

    func saveEndpoint(_ endpoint: TranslationEndpoint, keyChange: KeyChange = .unchanged) throws {
        switch keyChange {
        case .unchanged: break
        case .set(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try keychain.deleteKey(for: endpoint.id)
            } else {
                try keychain.setKey(trimmed, for: endpoint.id)
            }
        case .clear:
            try keychain.deleteKey(for: endpoint.id)
        }
        let isNew: Bool
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
            isNew = false
        } else {
            endpoints.append(endpoint)
            isNew = true
        }
        persistEndpoints()
        clearCache()
        if isNew { selection = .endpoint(endpoint.id) }
    }

    func removeEndpoint(_ id: UUID) {
        endpoints.removeAll { $0.id == id }
        try? keychain.deleteKey(for: id)
        persistEndpoints()
        if selection == .endpoint(id) { selection = .apple }
        clearCache()
    }

    func clearCache() { cache.removeAll() }

    func engine(for provider: TranslationProviderID) -> any TranslationEngine {
        if let customEngine { return customEngine(provider) }
        switch provider {
        case .apple:
            return AppleTranslationEngine()
        case .stub:
            return StubTranslationEngine()
        case .endpoint(let id):
            guard let endpoint = endpoints.first(where: { $0.id == id }) else {
                return UnconfiguredEngine(title: "未找到端点")
            }
            return endpoint.format.engine(for: endpoint, key: keychain.key(for: id))
        }
    }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<Result, Error> {
        let chain = [selection, .apple].reduce(into: [TranslationProviderID]()) { if !$0.contains($1) { $0.append($1) } }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var errors: [(title: String, error: Error)] = []
                func notice() -> String? {
                    guard let first = errors.first, !Self.isExpected(first.error) else { return nil }
                    return "\(first.title)：\(first.error.localizedDescription)"
                }
                for provider in chain {
                    let instance = engine(for: provider)
                    let canExplain = instance.capabilities.contains(.explain)
                    let asked = Self.request(request, for: instance)
                    let key = CacheKey(provider: provider, request: asked)
                    if let cached = cache[key] {
                        continuation.yield(Result(text: cached, provider: provider, providerTitle: instance.title,
                                                  canExplain: canExplain, isFinal: true, notice: notice()))
                        continuation.finish()
                        return
                    }
                    var latest: String?
                    do {
                        for try await text in instance.run(asked) {
                            latest = text
                            continuation.yield(Result(text: text, provider: provider, providerTitle: instance.title,
                                                      canExplain: canExplain, isFinal: false, notice: notice()))
                        }
                        let text = latest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !text.isEmpty else { throw TranslationFailure.failed("没有得到译文。") }
                        cache[key] = text
                        continuation.yield(Result(text: text, provider: provider, providerTitle: instance.title,
                                                  canExplain: canExplain, isFinal: true, notice: notice()))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        // Once an engine has shown part of its answer, switching engines would replace it mid-read.
                        if latest != nil { continuation.finish(throwing: error); return }
                        errors.append((instance.title, error))
                    }
                }
                // The chosen service's own failure says more than the fallback's, unless it was only unset or offline.
                let reported = errors.first { !Self.isExpected($0.error) } ?? errors.last
                continuation.finish(throwing: reported?.error ?? TranslationFailure.failed("没有得到译文。"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func persistEndpoints() {
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: Self.endpointsKey)
        }
    }

    private static func loadEndpoints(defaults: UserDefaults, keychain: TranslationKeychain) -> [TranslationEndpoint] {
        if let data = defaults.data(forKey: endpointsKey),
           let decoded = try? JSONDecoder().decode([TranslationEndpoint].self, from: data) {
            return decoded
        }
        // Migrate the earlier single-slot OpenAI-compatible settings if present.
        let legacyModel = (defaults.string(forKey: "translationOpenAIModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyKey = keychain.key(account: "openAI")
        guard !legacyModel.isEmpty || legacyKey != nil else { return [] }
        let legacyAddress = defaults.string(forKey: "translationOpenAIBaseURL") ?? OpenAICompatibleEngine.defaultBaseURL
        let endpoint = TranslationEndpoint(name: "", format: .openAI, baseURL: legacyAddress, model: legacyModel)
        if let legacyKey, !legacyKey.isEmpty {
            try? keychain.setKey(legacyKey, for: endpoint.id)
            try? keychain.deleteKey(account: "openAI")
        }
        if let data = try? JSONEncoder().encode([endpoint]) {
            defaults.set(data, forKey: endpointsKey)
        }
        if defaults.string(forKey: engineKey) == "openAI" {
            defaults.set(endpoint.id.uuidString, forKey: engineKey)
        }
        defaults.removeObject(forKey: "translationOpenAIModel")
        defaults.removeObject(forKey: "translationOpenAIBaseURL")
        return [endpoint]
    }

    private static func loadSelection(defaults: UserDefaults, endpoints: [TranslationEndpoint]) -> TranslationProviderID {
        guard let raw = defaults.string(forKey: engineKey), let parsed = TranslationProviderID(rawValue: raw) else {
            return .apple
        }
        if case .endpoint(let id) = parsed, !endpoints.contains(where: { $0.id == id }) {
            return .apple
        }
        return parsed
    }

    private nonisolated static func isExpected(_ error: Error) -> Bool {
        error as? TranslationFailure == .notConfigured || error as? TranslationFailure == .offline
    }

    /// Engines that can't explain a word in context translate the word instead, keeping the sentence as context.
    private static func request(_ request: TranslationRequest, for engine: any TranslationEngine) -> TranslationRequest {
        guard case .explain(let word, let sentence) = request, !engine.capabilities.contains(.explain) else { return request }
        return .translate(word, context: sentence.isEmpty || sentence == word ? nil : sentence)
    }
}

private struct UnconfiguredEngine: TranslationEngine {
    var title: String
    let capabilities: Set<TranslationCapability> = []
    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: TranslationFailure.notConfigured) }
    }
}

/// Apple's Translation framework, on device. Never prompts for a download by
/// itself: that needs a view (`translationTask`) and the user's say-so.
struct AppleTranslationEngine: TranslationEngine {
    let title = TranslationProviderID.appleTitle
    let capabilities: Set<TranslationCapability> = [.translate]

    static func status() async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: TranslationService.source, to: TranslationService.target)
    }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard case .translate(let text, _) = request else {
                    continuation.finish(throwing: TranslationFailure.unsupported)
                    return
                }
                switch await Self.status() {
                case .installed: break
                case .supported: continuation.finish(throwing: TranslationFailure.needsLanguagePack); return
                default: continuation.finish(throwing: TranslationFailure.unsupported); return
                }
                do {
                    let session = TranslationSession(installedSource: TranslationService.source, target: TranslationService.target)
                    let response = try await session.translate(text)
                    continuation.yield(response.targetText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : TranslationFailure.failed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct StubTranslationEngine: TranslationEngine {
    let title = TranslationProviderID.stubTitle
    let capabilities: Set<TranslationCapability> = [.translate, .explain]

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            switch request {
            case .translate(let text, _): continuation.yield("译文：\(text)")
            case .explain(let word, _): continuation.yield("释义：\(word)")
            }
            continuation.finish()
        }
    }
}
