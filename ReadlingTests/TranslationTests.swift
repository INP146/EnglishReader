import Foundation
import Testing
@testable import Readling

@Suite("Translation fallback and caching") @MainActor
struct TranslationTests {
    /// Answers with a fixed text, or fails; counts how often it was asked.
    final class FakeEngine: TranslationEngine, @unchecked Sendable {
        let id: TranslationEngineID
        let capabilities: Set<TranslationCapability>
        let answer: String?
        var requests: [TranslationRequest] = []

        init(_ id: TranslationEngineID, capabilities: Set<TranslationCapability> = [.translate], answer: String?) {
            self.id = id
            self.capabilities = capabilities
            self.answer = answer
        }

        func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
            requests.append(request)
            let answer = answer
            return AsyncThrowingStream { continuation in
                if let answer {
                    continuation.yield(String(answer.prefix(2)))
                    continuation.yield(answer)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: TranslationFailure.failed("boom"))
                }
            }
        }
    }

    private func results(_ service: TranslationService, _ request: TranslationRequest) async throws -> [TranslationService.Result] {
        var all: [TranslationService.Result] = []
        for try await result in service.run(request) { all.append(result) }
        return all
    }

    @Test func streamsThenFinishesAndCaches() async throws {
        let stub = FakeEngine(.stub, capabilities: [.translate, .explain], answer: "你好世界")
        let service = TranslationService(selection: { .stub }, engines: { $0 == .stub ? stub : FakeEngine(.apple, answer: nil) })
        let first = try await results(service, .translate("hello world"))
        #expect(first.map(\.text) == ["你好", "你好世界", "你好世界"])
        #expect(first.last?.isFinal == true && first.dropLast().allSatisfy { !$0.isFinal })
        let again = try await results(service, .translate("hello world"))
        #expect(again == [TranslationService.Result(text: "你好世界", engine: .stub, isFinal: true)])
        #expect(stub.requests.count == 1)
    }

    @Test func fallsBackToAppleWhenTheChosenEngineFails() async throws {
        let apple = FakeEngine(.apple, answer: "苹果译文")
        let service = TranslationService(selection: { .stub }, engines: { $0 == .apple ? apple : FakeEngine(.stub, answer: nil) })
        let all = try await results(service, .translate("hello"))
        #expect(all.last == TranslationService.Result(text: "苹果译文", engine: .apple, isFinal: true))
    }

    @Test func enginesThatCannotExplainTranslateTheWordAlone() async throws {
        let apple = FakeEngine(.apple, answer: "爱丽丝")
        let service = TranslationService(selection: { .apple }, engines: { _ in apple })
        _ = try await results(service, .explain(word: "Alice", sentence: "Alice was tired."))
        #expect(apple.requests == [.translate("Alice")])
    }

    @Test func reportsTheLastFailure() async throws {
        let service = TranslationService(selection: { .apple }, engines: { FakeEngine($0, answer: nil) })
        await #expect(throws: TranslationFailure.failed("boom")) { _ = try await results(service, .translate("hello")) }
    }
}
