import Foundation

struct ReadingPosition: Codable, Equatable, Sendable {
    var chapter: Int = 0
    /// UTF-16 offset in ReaderChapter.text (the same coordinate system as NSRange).
    var offset: Int = 0
}

/// A styled span of chapter text, in UTF-16 offsets.
struct TextStyleRun: Codable, Equatable, Sendable {
    enum Style: String, Codable, Sendable {
        // Inline.
        case italic, bold, sup, sub, code, strike
        /// A link; `value` is a web address or "path/inside/book.xhtml#id".
        case link
        /// One attachment character (U+FFFC); `value` names the stored image file and `alt` is its description.
        case image
        // Paragraph-level: the style applies to every paragraph the run touches.
        /// `value` is the level, "1" to "6"; absent for headings found in plain text.
        case heading
        case quote, list, center
    }
    var location: Int
    var length: Int
    var style: Style
    var value: String?
    var alt: String?
    var range: NSRange { NSRange(location: location, length: length) }
}

/// Chapter text is the single source of truth for rendering and for every
/// stored offset. Paragraphs end with "\n"; line breaks inside a paragraph
/// (verse, <br>) use U+2028 so they don't pick up paragraph spacing; an image
/// is one U+FFFC character.
struct ReaderChapter: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var text: String
    var styles: [TextStyleRun] = []
    /// The package path of the document this text came from. A long document is split
    /// into several chapters that share it; text imports have none.
    var source: String?
    /// Element ids and the offsets they point at, so links can jump inside the book.
    var anchors: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey { case id, title, text, styles, source, anchors }
}

extension ReaderChapter {
    /// Chapters saved before links and images existed have no `source` or `anchors`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        styles = try container.decodeIfPresent([TextStyleRun].self, forKey: .styles) ?? []
        source = try container.decodeIfPresent(String.self, forKey: .source)
        anchors = try container.decodeIfPresent([String: Int].self, forKey: .anchors) ?? [:]
    }
}

struct ChapterInfo: Codable, Equatable, Sendable {
    var title: String
    var length: Int
}

/// Library metadata. Chapter text lives in a separate per-book file
/// (see LibraryStore), so saving a position or a word never rewrites books.
struct ReaderBook: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var author: String
    var chapters: [ChapterInfo]
    var position: ReadingPosition = ReadingPosition()
    var isSample: Bool = false
    /// Width over height of the cover image saved beside the book's text; nil when the book has none.
    var coverAspectRatio: Double?
    /// True when the book was imported with everything needed to export it whole (see `BookPackage`).
    var hasPackage: Bool?

    var progress: Double {
        guard !chapters.isEmpty else { return 0 }
        let chapter = min(max(position.chapter, 0), chapters.count - 1)
        let total = chapters.reduce(0) { $0 + $1.length }
        let before = chapters.prefix(chapter).reduce(0) { $0 + $1.length }
        return min(1, Double(before + position.offset) / Double(max(total, 1)))
    }

    var canExport: Bool { hasPackage == true }
    var isStarted: Bool { position.chapter > 0 || position.offset > 0 }
    var isFinished: Bool { progress >= 0.995 }
    var percentRead: Int { Int(progress * 100) }
    /// Width over height for laying out the cover; generated covers use 2:3.
    var coverAspect: Double { coverAspectRatio ?? 2 / 3 }
}

struct BookContent: Codable, Sendable {
    var chapters: [ReaderChapter]

    /// Where a link into the book lands: the chapter that holds the fragment, else the start of the document.
    func location(ofPath path: String, fragment: String?) -> (chapter: Int, offset: Int)? {
        var first: Int?
        for (index, chapter) in chapters.enumerated() where chapter.source == path {
            first = first ?? index
            if let fragment, let offset = chapter.anchors[fragment] { return (index, offset) }
        }
        return first.map { ($0, 0) }
    }

    var chapterInfo: [ChapterInfo] {
        chapters.map { ChapterInfo(title: $0.title, length: $0.text.utf16.count) }
    }
}

struct SavedPassage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var bookID: UUID
    var bookTitle: String
    var chapterTitle: String
    var chapterIndex: Int
    var offset: Int
    var selection: String
    var sentence: String
    var mastered: Bool = false
    // Added in library version 2; optional so version 1 favorites still decode.
    var headword: String?
    var phonetic: String?
    var definition: String?
    var createdAt: Date?
    var reviewStage: Int?
    var dueAt: Date?

    var displayWord: String { headword ?? selection }
    var key: String { WordDictionary.normalize(headword ?? selection) }

    func isDue(at date: Date) -> Bool { !mastered && (dueAt ?? .distantPast) <= date }
}
