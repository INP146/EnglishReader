import Foundation
import Translation

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
