import Foundation
import Testing
@testable import EnglishReader

private final class ResourceMarker: NSObject {}

struct RealEPUBTests {
    @Test func publicDomainGutenbergBookImports() throws {
        let bundle = Bundle(for: ResourceMarker.self)
        let url = try #require(bundle.url(forResource: "alice", withExtension: "epub") ?? bundle.url(forResource: "alice", withExtension: "epub", subdirectory: "Fixtures"))
        let result = try BookImporter.load(url: url)
        #expect(result.book.title.contains("Alice"))
        #expect(result.book.chapters.count >= 12)
        #expect(result.content.chapters.contains { $0.text.contains("Alice was beginning") })
        #expect(result.content.chapters.allSatisfy { !$0.text.isEmpty && !$0.text.contains("\n\n") })
        #expect(result.content.chapters.allSatisfy { $0.text.utf16.count <= ChapterLayout.maximumLength })
    }
}
