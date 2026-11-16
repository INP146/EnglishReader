import Foundation
import Testing
import UIKit
@testable import EnglishReader

private final class ResourceMarker: NSObject {}

private func aliceURL() throws -> URL {
    let bundle = Bundle(for: ResourceMarker.self)
    return try #require(bundle.url(forResource: "alice", withExtension: "epub") ?? bundle.url(forResource: "alice", withExtension: "epub", subdirectory: "Fixtures"))
}

struct RealEPUBTests {
    @Test func publicDomainGutenbergBookImports() throws {
        let result = try BookImporter.load(url: aliceURL())
        #expect(result.book.title.contains("Alice"))
        #expect(result.book.chapters.count >= 12)
        #expect(result.content.chapters.contains { $0.text.contains("Alice was beginning") })
        #expect(result.content.chapters.allSatisfy { !$0.text.isEmpty && !$0.text.contains("\n\n") })
        #expect(result.content.chapters.allSatisfy { $0.text.utf16.count <= ChapterLayout.maximumLength })
    }

    /// The Gutenberg cover is 800×1104 and marked both ways (EPUB 3 property and EPUB 2 meta).
    @Test func epubCoverIsExtractedAndDownscaled() throws {
        let result = try BookImporter.load(url: aliceURL())
        let image = try #require(result.cover.flatMap(UIImage.init(data:)))
        #expect(max(image.size.width, image.size.height) * image.scale <= CGFloat(BookImporter.Cover.maximumPixelSize))
        let ratio = try #require(result.book.coverAspectRatio)
        #expect(abs(ratio - 800.0 / 1104.0) < 0.01)
    }

    @Test @MainActor func coverFileIsSavedWithTheBookAndRemovedWithIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let id = try await store.importBook(url: aliceURL())
        let book = try #require(LibraryStore(fileURL: file).books.first { $0.id == id })
        let cover = try #require(store.coverURL(for: book))
        #expect(UIImage(contentsOfFile: cover.path) != nil)
        store.removeBook(id: id)
        #expect(!FileManager.default.fileExists(atPath: cover.path))
        let sample = try #require(store.books.first { $0.isSample })
        #expect(store.coverURL(for: sample) == nil)
    }
}
