import Foundation
import Translation

/// What the lookup card asks for when the dictionary has nothing.
enum TranslationRequest: Hashable, Sendable {
    /// A sentence or any run of words.
    case translate(String)
    /// A word the dictionary lacks, read in its sentence: what it means right here.
    case explain(word: String, sentence: String)
}

enum TranslationCapability: Sendable { case translate, explain }

enum TranslationEngineID: String, CaseIterable, Sendable {
    case apple
    case openAI
    /// Answers instantly with canned text; picked by UI tests with `-translationEngine stub`.
    case stub

    var title: String {
        switch self {
        case .apple: "Apple 本机翻译"
        case .openAI: "OpenAI 兼容"
        case .stub: "测试引擎"
        }
    }

    /// The engines the user can pick in Settings, in order.
    static let selectable: [TranslationEngineID] = [.apple, .openAI]
}

enum TranslationFailure: LocalizedError, Equatable {
    /// Apple's on-device model for English → Chinese isn't downloaded yet.
    case needsLanguagePack
    case unsupported
    /// An online engine without its address, key or model yet.
    case notConfigured
    case offline
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsLanguagePack: "需要先下载英语到简体中文的翻译语言包。"
        case .unsupported: "这台设备不支持英语到简体中文的本机翻译。"
        case .notConfigured: "还没有配置这个翻译引擎。"
        case .offline: "没有网络连接。"
        case .failed(let message): message
        }
    }
}

protocol TranslationEngine: Sendable {
    var id: TranslationEngineID { get }
    var capabilities: Set<TranslationCapability> { get }
    /// The result so far, growing with each element; engines that don't stream yield once.
    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}

/// Picks the engine from settings, falls back to Apple's on-device engine when
/// the chosen one fails, and remembers finished results for this launch.
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    struct Result: Equatable, Sendable {
        var text: String
        var engine: TranslationEngineID
        var isFinal: Bool
        /// Why the chosen engine didn't answer, when another one did.
        var notice: String?
    }

    static let engineKey = "translationEngine"
    static let automaticKey = "translationAutomatic"
    nonisolated static let source = Locale.Language(identifier: "en")
    nonisolated static let target = Locale.Language(identifier: "zh-Hans")

    private struct CacheKey: Hashable {
        var engine: TranslationEngineID
        var request: TranslationRequest
    }
    private var cache: [CacheKey: String] = [:]
    private let selection: () -> TranslationEngineID
    private let makeEngine: (TranslationEngineID) -> any TranslationEngine

    init(selection: @escaping () -> TranslationEngineID = {
             UserDefaults.standard.string(forKey: TranslationService.engineKey).flatMap(TranslationEngineID.init) ?? .apple
         },
         engines: @escaping (TranslationEngineID) -> any TranslationEngine = TranslationService.engine) {
        self.selection = selection
        self.makeEngine = engines
    }

    var selectedEngine: TranslationEngineID { selection() }

    func engine(_ id: TranslationEngineID) -> any TranslationEngine { makeEngine(id) }

    nonisolated static func engine(_ id: TranslationEngineID) -> any TranslationEngine {
        switch id {
        case .apple: AppleTranslationEngine()
        case .openAI: OpenAICompatibleEngine(configuration: OpenAICompatibleEngine.saved())
        case .stub: StubTranslationEngine()
        }
    }

    /// Forgets finished results, after an engine's settings change.
    func clearCache() { cache.removeAll() }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<Result, Error> {
        let chain = [selectedEngine, .apple].reduce(into: [TranslationEngineID]()) { if !$0.contains($1) { $0.append($1) } }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var errors: [(engine: TranslationEngineID, error: Error)] = []
                // Not configured or offline is expected, and says nothing a fallback answer needs to explain.
                func notice() -> String? {
                    guard let first = errors.first, !Self.isExpected(first.error) else { return nil }
                    return "\(first.engine.title)：\(first.error.localizedDescription)"
                }
                for id in chain {
                    let engine = engine(id)
                    let asked = Self.request(request, for: engine)
                    let key = CacheKey(engine: id, request: asked)
                    if let cached = cache[key] {
                        continuation.yield(Result(text: cached, engine: id, isFinal: true, notice: notice()))
                        continuation.finish()
                        return
                    }
                    var latest: String?
                    do {
                        for try await text in engine.run(asked) {
                            latest = text
                            continuation.yield(Result(text: text, engine: id, isFinal: false, notice: notice()))
                        }
                        let text = latest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !text.isEmpty else { throw TranslationFailure.failed("没有得到译文。") }
                        cache[key] = text
                        continuation.yield(Result(text: text, engine: id, isFinal: true, notice: notice()))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        // Once an engine has shown part of its answer, switching engines would replace it mid-read.
                        if latest != nil { continuation.finish(throwing: error); return }
                        errors.append((id, error))
                    }
                }
                // The chosen engine's own failure says more than the fallback's, unless it was only unset or offline.
                let reported = errors.first { !Self.isExpected($0.error) } ?? errors.last
                continuation.finish(throwing: reported?.error ?? TranslationFailure.failed("没有得到译文。"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func isExpected(_ error: Error) -> Bool {
        error as? TranslationFailure == .notConfigured || error as? TranslationFailure == .offline
    }

    /// Engines that can't explain a word in context translate the word alone.
    private static func request(_ request: TranslationRequest, for engine: any TranslationEngine) -> TranslationRequest {
        if case .explain(let word, _) = request, !engine.capabilities.contains(.explain) { return .translate(word) }
        return request
    }
}

/// Apple's Translation framework, on device. Never prompts for a download by
/// itself: that needs a view (`translationTask`) and the user's say-so.
struct AppleTranslationEngine: TranslationEngine {
    let id = TranslationEngineID.apple
    let capabilities: Set<TranslationCapability> = [.translate]

    static func status() async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: TranslationService.source, to: TranslationService.target)
    }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard case .translate(let text) = request else {
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
    let id = TranslationEngineID.stub
    let capabilities: Set<TranslationCapability> = [.translate, .explain]

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            switch request {
            case .translate(let text): continuation.yield("译文：\(text)")
            case .explain(let word, _): continuation.yield("释义：\(word)")
            }
            continuation.finish()
        }
    }
}
