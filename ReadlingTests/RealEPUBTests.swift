import Foundation
import Testing
import UIKit
@testable import Readling

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

    /// Pages follow on from each other through the whole chapter, each shows exactly its own text, and selections on
    /// a page are reported in chapter coordinates.
    @Test @MainActor func pagesTileTheChapterAndSelectInChapterCoordinates() throws {
        let chapters = try BookImporter.load(url: aliceURL()).content.chapters
        for (font, typeface) in [(18.0, ReaderTypeface.georgia), (30.0, ReaderTypeface.system)] {
            let layout = ReaderLayout(fontSize: font, typeface: typeface, lineSpacing: 1.6, paragraphSpacing: 0.8, margin: 24)
            for (number, chapter) in chapters.enumerated() {
                let paged = PagedChapter(chapter, number: number, size: ReaderTypography.pointSize(layout.fontSize), layout: layout,
                                         ink: .black, accent: .blue, pageSize: CGSize(width: 354, height: 640), forms: [], resources: nil)
                var next = 0
                for (index, page) in paged.layouts.enumerated() {
                    #expect(page.range.location == next && page.range.length > 0, "chapter \(number) page \(index) at \(font) pt")
                    next = NSMaxRange(page.range)
                    let view = PageTextView(page: page, chapterText: paged.text, frame: CGRect(x: 0, y: 0, width: 354, height: 640))
                    let shown = view.layoutManager.characterRange(forGlyphRange: view.layoutManager.glyphRange(for: view.textContainer),
                                                                  actualGlyphRange: nil)
                    #expect(shown == NSRange(location: 0, length: page.range.length))
                    #expect((view.textStorage.string as NSString).substring(with: shown) == paged.text.substring(with: page.range))
                    guard let word = paged.wordRanges.first(where: { NSLocationInRange($0.location, page.range) && NSMaxRange($0) <= NSMaxRange(page.range) }),
                          let selection = ReaderTextTools.selection(for: try #require(page.local(word)), in: view)
                    else { continue }
                    #expect(selection.range == word)
                    #expect(selection.text == paged.text.substring(with: word))
                }
                #expect(next == paged.text.length, "chapter \(number) at \(font) pt ends early")
            }
        }
    }

    /// Paging the longest chapter a book can have stays quick, though every page lays itself out.
    @Test @MainActor func longChapterPagesQuickly() throws {
        let paragraph = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do. "
        let text = String(repeating: paragraph, count: ChapterLayout.maximumLength / paragraph.utf16.count)
        let chapter = ReaderChapter(id: "long", title: "Long", text: text)
        let clock = ContinuousClock()
        var paged: PagedChapter?
        let elapsed = clock.measure {
            paged = PagedChapter(chapter, number: 0, size: 18, layout: ReaderLayout(), ink: .black, accent: .blue,
                                 pageSize: CGSize(width: 354, height: 640), forms: [], resources: nil)
        }
        #expect(paged.map { NSMaxRange($0.pages.last!) } == (text as NSString).length)
        print("PAGINATION \(paged?.pages.count ?? 0) pages in \(elapsed)")
        #expect(elapsed < .seconds(1))
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
