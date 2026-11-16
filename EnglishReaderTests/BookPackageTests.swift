import Foundation
import Testing
import UIKit
@testable import EnglishReader

private final class ResourceMarker: NSObject {}

private func aliceURL() throws -> URL {
    let bundle = Bundle(for: ResourceMarker.self)
    return try #require(bundle.url(forResource: "alice", withExtension: "epub") ?? bundle.url(forResource: "alice", withExtension: "epub", subdirectory: "Fixtures"))
}

@Suite("Lossless book packages")
struct BookPackageTests {
    @Test func imagesLinksListsAndFootnotesBecomeChapterText() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("rich.epub")
        try storedZIP(richEntries()).write(to: source)
        let staging = folder.appendingPathComponent("staging", isDirectory: true)
        let result = try BookImporter.load(url: source, staging: staging)
        #expect(result.book.title == "Rich Book")
        #expect(result.book.chapters.map(\.title) == ["Chapter One", "Notes"])

        let chapter = result.content.chapters[0]
        let text = chapter.text as NSString
        #expect(chapter.text == "The Start\nSee note1 and the site.\n\u{FFFC}\nA caption\n•\u{00A0}One\n•\u{00A0}Two\nQuoted words")
        #expect(chapter.source == "OPS/text/one.xhtml")
        #expect(chapter.anchors["top"] == 0)
        func runs(_ style: TextStyleRun.Style) -> [TextStyleRun] { chapter.styles.filter { $0.style == style } }
        #expect(runs(.heading).map { text.substring(with: $0.range) } == ["The Start"])
        #expect(runs(.heading).first?.value == "2")
        #expect(runs(.link).map { text.substring(with: $0.range) } == ["note1", "the site"])
        #expect(runs(.link).map(\.value) == ["OPS/text/notes.xhtml#n1", "https://example.com/"])
        #expect(runs(.sup).map { text.substring(with: $0.range) } == ["1"])
        #expect(runs(.list).map { text.substring(with: $0.range) } == ["•\u{00A0}One", "•\u{00A0}Two"])
        #expect(runs(.quote).map { text.substring(with: $0.range) } == ["Quoted words"])

        // The picture points at its unpacked file, unchanged.
        let image = try #require(runs(.image).first)
        #expect(text.substring(with: image.range) == ChapterTextBuilder.attachment)
        #expect(image.alt == "A picture")
        let stored = try Data(contentsOf: BookDirectory(url: staging).resource(try #require(image.value)))
        #expect(stored == pngFixture())

        // The footnote link lands on the note.
        let notes = result.content.chapters[1]
        #expect(notes.text == "The note text.")
        #expect(notes.anchors["n1"] == 0)
        let place = try #require(result.content.location(ofPath: "OPS/text/notes.xhtml", fragment: "n1"))
        #expect(place.chapter == 1 && place.offset == 0)

        // Chapter documents are kept as trees, everything else as raw files.
        #expect(result.package.kind == .epub)
        #expect(result.package.entries.map(\.path) == richEntries().map(\.0).filter { $0 != "mimetype" })
        #expect(result.package.entries.filter(\.isDocument).map(\.path) == ["OPS/text/one.xhtml", "OPS/text/notes.xhtml"])
    }

    @Test @MainActor func exportedEPUBReimportsToTheSameBookAndFiles() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("rich.epub")
        try storedZIP(richEntries()).write(to: source)
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let id = try await store.importBook(url: source)
        let book = try #require(store.books.first { $0.id == id })
        #expect(book.canExport)
        let exported = try await store.exportFile(for: book)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        #expect(exported.lastPathComponent == "Rich Book.epub")
        try expectMimetypeFirst(in: Data(contentsOf: exported))

        let original = try BookImporter.load(url: source, staging: folder.appendingPathComponent("a", isDirectory: true))
        let again = try BookImporter.load(url: exported, staging: folder.appendingPathComponent("b", isDirectory: true))
        #expect(again.book.title == original.book.title && again.book.author == original.book.author)
        #expect(again.content.chapters == original.content.chapters)
        try expectSameFiles(original.package, BookDirectory(url: folder.appendingPathComponent("a")),
                            again.package, BookDirectory(url: folder.appendingPathComponent("b")))

        // The publisher's class attributes, ids and epub:type survive in the written document.
        let documentEntry = try #require(again.package.entries.first { $0.path == "OPS/text/one.xhtml" })
        let document = try JSONDecoder().decode(XMLDocumentFile.self, from: Data(contentsOf: BookDirectory(url: folder.appendingPathComponent("b")).document(documentEntry.file)))
        let xhtml = String(decoding: XMLTree.serialize(document), as: UTF8.self)
        for kept in [#"<p class="first">"#, #"epub:type="noteref""#, #"<link href="../style.css""#, "<!-- a comment -->", "<!DOCTYPE html>"] {
            #expect(xhtml.contains(kept), "\(kept)")
        }
    }

    @Test @MainActor func realEPUBExportsWhole() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let id = try await store.importBook(url: aliceURL())
        let book = try #require(store.books.first { $0.id == id })
        let exported = try await store.exportFile(for: book)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        try expectMimetypeFirst(in: Data(contentsOf: exported))
        let original = try BookImporter.load(url: aliceURL(), staging: folder.appendingPathComponent("a", isDirectory: true))
        let again = try BookImporter.load(url: exported, staging: folder.appendingPathComponent("b", isDirectory: true))
        #expect(again.content.chapters == original.content.chapters)
        #expect(again.cover == original.cover)
        try expectSameFiles(original.package, BookDirectory(url: folder.appendingPathComponent("a")),
                            again.package, BookDirectory(url: folder.appendingPathComponent("b")))
        // The OPF, styles and cover image are raw files, exactly as they were.
        let raw = Set(original.package.entries.filter { !$0.isDocument }.map(\.path))
        #expect(raw.isSuperset(of: ["OEBPS/content.opf", "OEBPS/0.css", "OEBPS/7981341119032183217_cover.jpg", "OEBPS/toc.ncx"]))
    }

    @Test @MainActor func textExportIsTheOriginalFile() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("notes.txt")
        let bytes = Data([0x43, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x0D, 0x0A, 0x2A, 0x2A, 0x2A, 0x20, 0x53, 0x54, 0x41, 0x52, 0x54, 0x20, 0x4F, 0x46])
        try bytes.write(to: source)
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let id = try await store.importBook(url: source)
        let exported = try await store.exportFile(for: try #require(store.books.first { $0.id == id }))
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        #expect(exported.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: exported) == bytes)
    }

    @Test @MainActor func booksWithoutAPackageCannotExport() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let sample = try #require(store.books.first { $0.isSample })
        #expect(!sample.canExport)
        await #expect(throws: BookExporter.ExportError.self) { _ = try await store.exportFile(for: sample) }
    }

    @Test func exportFileNamesAreSafe() {
        #expect(BookExporter.fileName(for: "A/B: C?", kind: .epub) == "A B C.epub")
        #expect(BookExporter.fileName(for: " ..", kind: .text) == "book.txt")
    }
}

@Suite("XML documents")
struct XMLTreeTests {
    @Test func serializingKeepsNamesNamespacesCommentsAndText() throws {
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en"><head><title>T</title></head><body><?page 3?><section epub:type="chapter" class="c1"><p>caf&eacute; &amp; &lt;tea&gt; “quoted”<br/>line</p><div></div><!-- note --><p title="a &quot;b&quot;"><![CDATA[x < y]]></p></section></body></html>
        """
        let tree = try XMLTree.parse(Data(source.utf8))
        let file = XMLDocumentFile(doctype: tree.doctype, root: tree)
        let written = XMLTree.serialize(file)
        let text = String(decoding: written, as: UTF8.self)
        for kept in ["<!DOCTYPE html>", #"xmlns:epub="http://www.idpf.org/2007/ops""#, #"xml:lang="en""#, #"<section class="c1" epub:type="chapter">"#,
                     "café &amp; &lt;tea&gt; “quoted”<br/>line", "<div></div>", "<!-- note -->", "<?page 3?>",
                     #"title="a &quot;b&quot;""#, "x &lt; y"] {
            #expect(text.contains(kept), "\(kept)")
        }
        // Stored as JSON and written again, the document is the same.
        let decoded = try JSONDecoder().decode(XMLDocumentFile.self, from: JSONEncoder().encode(file))
        #expect(XMLTree.serialize(decoded) == written)
        let reparsed = try XMLTree.parse(written)
        #expect(XMLTree.serialize(XMLDocumentFile(doctype: reparsed.doctype, root: reparsed)) == written)
    }

    @Test func chaptersSavedBeforeLinksAndImagesStillDecode() throws {
        let json = #"{"id":"a","title":"T","text":"Hi","styles":[{"location":0,"length":2,"style":"italic"}]}"#
        let chapter = try JSONDecoder().decode(ReaderChapter.self, from: Data(json.utf8))
        #expect(chapter.text == "Hi" && chapter.styles.first?.style == .italic)
        #expect(chapter.source == nil && chapter.anchors.isEmpty)
    }
}

@Suite("Pictures and links on the page") @MainActor
struct ReaderImageTests {
    @Test func imagesAndLinksRenderWithoutChangingTheText() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try pngFixture().write(to: folder.appendingPathComponent("7"))
        let chapter = ReaderChapter(id: "c", title: "T", text: "See note.\n\u{FFFC}\nAfter.",
                                    styles: [TextStyleRun(location: 4, length: 4, style: .link, value: "a.xhtml#n1"),
                                             TextStyleRun(location: 10, length: 1, style: .image, value: "7", alt: "Pic")])
        let rendered = ReadingSurface.attributedText(for: chapter, size: 20, resources: folder)
        #expect(rendered.string == chapter.text)
        #expect(rendered.attribute(.readerLink, at: 5, effectiveRange: nil) as? String == "a.xhtml#n1")
        let attachment = try #require(rendered.attribute(.attachment, at: 10, effectiveRange: nil) as? ReaderImageAttachment)
        #expect(attachment.url == folder.appendingPathComponent("7"))
        // Natural size when it fits, the line's width when it doesn't, never taller than a page.
        #expect(attachment.attachmentBounds(for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 20),
                                            glyphPosition: .zero, characterIndex: 10).size == CGSize(width: 40, height: 30))
        #expect(attachment.attachmentBounds(for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 20, height: 20),
                                            glyphPosition: .zero, characterIndex: 10).size == CGSize(width: 20, height: 15))
        let page = NSTextContainer(size: CGSize(width: 300, height: 16))
        #expect(attachment.attachmentBounds(for: page, proposedLineFragment: CGRect(x: 0, y: 0, width: 300, height: 20),
                                            glyphPosition: .zero, characterIndex: 10).size.height <= 15)
        let picture = rendered.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as? NSParagraphStyle
        #expect(picture?.alignment == .center)
        // Without the book's files the picture is left out but the text stays the same.
        let bare = ReadingSurface.attributedText(for: chapter, size: 20)
        #expect(bare.string == chapter.text)
        #expect(bare.attribute(.attachment, at: 10, effectiveRange: nil) == nil)
    }
}

// MARK: - Fixtures

/// A 40×30 PNG.
private func pngFixture() -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
}

private func richEntries() -> [(String, Data, UInt32?)] {
    let container = """
    <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:isbn:9780000000000</dc:identifier><dc:title>Rich Book</dc:title><dc:creator>B. Writer</dc:creator><dc:language>en</dc:language><dc:publisher>Test Press</dc:publisher><meta property="dcterms:modified">2026-01-01T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="text/one.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/><item id="pic" href="images/pic.png" media-type="image/png"/><item id="css" href="style.css" media-type="text/css"/><item id="font" href="fonts/serif.otf" media-type="font/otf"/></manifest><spine><itemref idref="one"/><itemref idref="notes"/></spine></package>
    """
    let nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="text/one.xhtml">Chapter One</a></li><li><a href="text/notes.xhtml">Notes</a></li></ol></nav></body></html>
    """
    let one = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>One</title><link rel="stylesheet" type="text/css" href="../style.css"/></head><body><h2 id="top">The Start</h2><p class="first">See <a href="notes.xhtml#n1" epub:type="noteref">note<sup>1</sup></a> and <a href="https://example.com/">the site</a>.</p><figure><img src="../images/pic.png" alt="A picture"/><figcaption>A caption</figcaption></figure><ul><li>One</li><li>Two</li></ul><blockquote><p>Quoted words</p></blockquote><!-- a comment --></body></html>
    """
    let notes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Notes</title></head><body><aside id="n1" epub:type="footnote"><p>The note text.</p></aside></body></html>
    """
    let css = "@font-face { font-family: Book; src: url(fonts/serif.otf); }\np.first { text-indent: 0; font-family: Book; }\n"
    return [("mimetype", Data("application/epub+zip".utf8), nil), ("META-INF/container.xml", Data(container.utf8), nil),
            ("OPS/book.opf", Data(opf.utf8), nil), ("OPS/nav.xhtml", Data(nav.utf8), nil), ("OPS/text/one.xhtml", Data(one.utf8), nil),
            ("OPS/text/notes.xhtml", Data(notes.utf8), nil), ("OPS/images/pic.png", pngFixture(), nil), ("OPS/style.css", Data(css.utf8), nil),
            ("OPS/fonts/serif.otf", Data((0..<256).map { UInt8($0) }), nil)]
}

/// The container format requires an uncompressed "mimetype" entry first.
private func expectMimetypeFirst(in data: Data) throws {
    let bytes = [UInt8](data.prefix(128))
    #expect(bytes.prefix(4) == [0x50, 0x4B, 0x03, 0x04])
    #expect(bytes[8] == 0 && bytes[9] == 0) // Stored, not deflated.
    let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
    let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
    #expect(String(decoding: bytes[30..<30 + nameLength], as: UTF8.self) == "mimetype")
    let start = 30 + nameLength + extraLength
    #expect(String(decoding: bytes[start..<start + 20], as: UTF8.self) == "application/epub+zip")
}

/// Same entries in the same order; raw files byte for byte, documents as the same trees.
private func expectSameFiles(_ a: BookPackage, _ aFiles: BookDirectory, _ b: BookPackage, _ bFiles: BookDirectory) throws {
    #expect(a.entries.map(\.path) == b.entries.map(\.path))
    #expect(a.entries.map(\.isDocument) == b.entries.map(\.isDocument))
    for (x, y) in zip(a.entries, b.entries) {
        if x.isDocument {
            let decoder = JSONDecoder()
            let left = try decoder.decode(XMLDocumentFile.self, from: Data(contentsOf: aFiles.document(x.file)))
            let right = try decoder.decode(XMLDocumentFile.self, from: Data(contentsOf: bFiles.document(y.file)))
            #expect(XMLTree.serialize(left) == XMLTree.serialize(right), "\(x.path)")
        } else {
            #expect(try Data(contentsOf: aFiles.resource(x.file)) == Data(contentsOf: bFiles.resource(y.file)), "\(x.path)")
        }
    }
}
