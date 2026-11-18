import Foundation
import Testing
@testable import Readling

@Suite("Translation endpoints, fallback and caching") @MainActor
struct TranslationTests {
    /// Answers with a fixed text, or fails; counts how often it was asked.
    final class FakeEngine: TranslationEngine, @unchecked Sendable {
        let title: String
        let capabilities: Set<TranslationCapability>
        let answer: String?
        var failure: TranslationFailure = .failed("boom")
        var requests: [TranslationRequest] = []

        init(_ title: String, capabilities: Set<TranslationCapability> = [.translate], answer: String?,
             failure: TranslationFailure = .failed("boom")) {
            self.title = title
            self.capabilities = capabilities
            self.answer = answer
            self.failure = failure
        }

        func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
            requests.append(request)
            let answer = answer, failure = failure
            return AsyncThrowingStream { continuation in
                if let answer {
                    continuation.yield(String(answer.prefix(2)))
                    continuation.yield(answer)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: failure)
                }
            }
        }
    }

    private func cleanDefaults(_ name: String = UUID().uuidString) throws -> UserDefaults {
        let suite = "TranslationTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func cleanKeychain() -> TranslationKeychain {
        TranslationKeychain(service: "com.inp146.readling.tests.\(UUID().uuidString)")
    }

    private func results(_ service: TranslationService, _ request: TranslationRequest) async throws -> [TranslationService.Result] {
        var all: [TranslationService.Result] = []
        for try await result in service.run(request) { all.append(result) }
        return all
    }

    @Test func streamsThenFinishesAndCaches() async throws {
        let stub = FakeEngine("测试引擎", capabilities: [.translate, .explain], answer: "你好世界")
        let defaults = try cleanDefaults()
        defaults.set("stub", forKey: TranslationService.engineKey)
        let service = TranslationService(defaults: defaults, keychain: cleanKeychain(),
                                         engines: { $0 == .stub ? stub : FakeEngine("Apple 本机翻译", answer: nil) })
        let first = try await results(service, .translate("hello world"))
        #expect(first.map(\.text) == ["你好", "你好世界", "你好世界"])
        #expect(first.last?.isFinal == true && first.dropLast().allSatisfy { !$0.isFinal })
        let again = try await results(service, .translate("hello world"))
        #expect(again == [TranslationService.Result(text: "你好世界", provider: .stub, providerTitle: "测试引擎", canExplain: true, isFinal: true)])
        #expect(stub.requests.count == 1)
    }

    @Test func fallsBackToAppleWhenChosenEndpointFails() async throws {
        let defaults = try cleanDefaults()
        let keychain = cleanKeychain()
        let endpoint = TranslationEndpoint(name: "DeepSeek", format: .openAI, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        let apple = FakeEngine("Apple 本机翻译", answer: "苹果译文")
        let service = TranslationService(defaults: defaults, keychain: keychain, engines: {
            $0 == .apple ? apple : FakeEngine(endpoint.displayName, capabilities: [.translate, .explain], answer: nil)
        })
        try service.saveEndpoint(endpoint)
        let all = try await results(service, .translate("hello"))
        #expect(all.last == TranslationService.Result(text: "苹果译文", provider: .apple, providerTitle: "Apple 本机翻译",
                                                      canExplain: false, isFinal: true, notice: "DeepSeek：boom"))
    }

    @Test func fallsBackQuietlyWhenEndpointIsUnsetOrOffline() async throws {
        for failure in [TranslationFailure.notConfigured, .offline] {
            let defaults = try cleanDefaults()
            let endpoint = TranslationEndpoint(name: "Claude 中转", format: .claude, baseURL: "https://relay.example.com", model: "claude-sonnet")
            let apple = FakeEngine("Apple 本机翻译", answer: "苹果译文")
            let service = TranslationService(defaults: defaults, keychain: cleanKeychain(), engines: {
                $0 == .apple ? apple : FakeEngine(endpoint.displayName, answer: nil, failure: failure)
            })
            try service.saveEndpoint(endpoint)
            let all = try await results(service, .translate("hello"))
            #expect(all.last == TranslationService.Result(text: "苹果译文", provider: .apple, providerTitle: "Apple 本机翻译",
                                                          canExplain: false, isFinal: true))
        }
    }

    @Test func reportsChosenEndpointsFailureOverFallbacks() async throws {
        let defaults = try cleanDefaults()
        let endpoint = TranslationEndpoint(name: "Gemini", format: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash")
        let service = TranslationService(defaults: defaults, keychain: cleanKeychain(), engines: {
            $0 == .apple ? FakeEngine("Apple 本机翻译", answer: nil, failure: .needsLanguagePack)
                         : FakeEngine(endpoint.displayName, answer: nil, failure: .failed("API Key 无效。"))
        })
        try service.saveEndpoint(endpoint)
        await #expect(throws: TranslationFailure.failed("API Key 无效。")) { _ = try await results(service, .translate("hello")) }

        let offlineDefaults = try cleanDefaults()
        let offline = TranslationService(defaults: offlineDefaults, keychain: cleanKeychain(), engines: {
            $0 == .apple ? FakeEngine("Apple 本机翻译", answer: nil, failure: .needsLanguagePack)
                         : FakeEngine(endpoint.displayName, answer: nil, failure: .offline)
        })
        try offline.saveEndpoint(endpoint)
        await #expect(throws: TranslationFailure.needsLanguagePack) { _ = try await results(offline, .translate("hello")) }
    }

    @Test func enginesThatCannotExplainTranslateTheWordWithContext() async throws {
        let defaults = try cleanDefaults()
        let endpoint = TranslationEndpoint(name: "DeepL", format: .deepL, baseURL: "https://api-free.deepl.com/v2")
        let deepL = FakeEngine("DeepL", capabilities: [.translate], answer: "爱丽丝")
        let service = TranslationService(defaults: defaults, keychain: cleanKeychain(), engines: { _ in deepL })
        try service.saveEndpoint(endpoint)
        _ = try await results(service, .explain(word: "Alice", sentence: "Alice was tired."))
        _ = try await results(service, .explain(word: "Alice", sentence: ""))
        #expect(deepL.requests == [.translate("Alice", context: "Alice was tired."), .translate("Alice", context: nil)])
    }

    @Test func addsEditsAndRemovesEndpointsAndKeys() throws {
        let defaults = try cleanDefaults()
        let keychain = cleanKeychain()
        let service = TranslationService(defaults: defaults, keychain: keychain)
        #expect(service.selection == .apple)

        var first = TranslationEndpoint(name: "Ollama", format: .openAI, baseURL: "http://192.168.1.2:11434/v1", model: "qwen2.5:7b")
        try service.saveEndpoint(first, keyChange: .set("sk-one"))
        #expect(service.selection == .endpoint(first.id))
        #expect(service.key(for: first.id) == "sk-one")

        service.selection = .apple
        first.model = "qwen2.5:14b"
        try service.saveEndpoint(first, keyChange: .unchanged)
        #expect(service.selection == .apple)
        #expect(service.endpoints.first?.model == "qwen2.5:14b")
        #expect(service.key(for: first.id) == "sk-one")

        service.selection = .endpoint(first.id)
        let reloaded = TranslationService(defaults: defaults, keychain: keychain)
        #expect(reloaded.endpoints == [first])
        #expect(reloaded.selection == .endpoint(first.id))

        reloaded.removeEndpoint(first.id)
        #expect(reloaded.endpoints.isEmpty)
        #expect(reloaded.selection == .apple)
        #expect(keychain.key(for: first.id) == nil)
    }

    @Test func migratesLegacyOpenAISettingsIntoAnEndpoint() throws {
        let defaults = try cleanDefaults()
        let keychain = cleanKeychain()
        defaults.set("https://api.deepseek.com/v1", forKey: "translationOpenAIBaseURL")
        defaults.set("deepseek-chat", forKey: "translationOpenAIModel")
        defaults.set("openAI", forKey: TranslationService.engineKey)
        try keychain.setKey("sk-legacy", account: "openAI")

        let service = TranslationService(defaults: defaults, keychain: keychain)
        let migrated = try #require(service.endpoints.first)
        #expect(migrated.format == .openAI)
        #expect(migrated.baseURL == "https://api.deepseek.com/v1")
        #expect(migrated.model == "deepseek-chat")
        #expect(migrated.displayName == "OpenAI 兼容 (api.deepseek.com)")
        #expect(service.selection == .endpoint(migrated.id))
        #expect(service.key(for: migrated.id) == "sk-legacy")
        #expect(keychain.key(account: "openAI") == nil)
    }
}
