import Foundation
import Observation

/// Library metadata and saved words live in one small JSON file; each book has
/// its own directory under `books/` (see `BookDirectory`), written once at
/// import. Saving a position or a word therefore rewrites kilobytes, never books.
@MainActor @Observable
final class LibraryStore {
    private(set) var books: [ReaderBook] = []
    private(set) var favorites: [SavedPassage] = []
    var errorMessage: String?
    /// Set when the saved library exists but cannot be read. Nothing is written
    /// until the reader chooses to retry or to set the unreadable file aside.
    private(set) var readFailure: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var fingerprints: [String: UUID] = [:]
    @ObservationIgnored private var pendingPositionSave: Task<Void, Never>?
    @ObservationIgnored private var contentCache: (id: UUID, content: BookContent)?

    static let reviewIntervals: [Double] = [1, 2, 4, 7, 15, 30] // days

    private struct Snapshot: Codable {
        var version: Int = 2
        var books: [ReaderBook]
        var favorites: [SavedPassage]
        var fingerprints: [String: UUID]
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.appData.appendingPathComponent("library.json")
        load()
        // An import that was interrupted leaves its unpacked files behind.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? [] where name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent(name))
        }
    }

    private var booksDirectory: URL { fileURL.deletingLastPathComponent().appendingPathComponent("books", isDirectory: true) }

    func directory(for id: UUID) -> BookDirectory { BookDirectory(url: booksDirectory.appendingPathComponent(id.uuidString, isDirectory: true)) }

    // Books imported before each had a directory kept text and cover beside it, in files named for the book.
    private func legacyContentURL(for id: UUID) -> URL { booksDirectory.appendingPathComponent("\(id.uuidString).json") }

    private func legacyCoverURL(for id: UUID) -> URL { booksDirectory.appendingPathComponent("\(id.uuidString)-cover.jpg") }

    func coverURL(for book: ReaderBook) -> URL? {
        guard book.coverAspectRatio != nil else { return nil }
        let current = directory(for: book.id).cover
        return FileManager.default.fileExists(atPath: current.path) ? current : legacyCoverURL(for: book.id)
    }

    /// Where the book's images are, for drawing them; nil for the sample.
    func resourcesURL(for book: ReaderBook) -> URL? { book.isSample ? nil : directory(for: book.id).resources }

    /// Runs blocking work off the main thread, cancelling it when the caller is cancelled.
    private func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    // MARK: Loading and recovery

    func retryLoading() {
        readFailure = nil
        errorMessage = nil
        books = []
        favorites = []
        fingerprints = [:]
        load()
    }

    /// Moves the unreadable file aside (never deletes it) and starts a fresh library.
    func setAsideUnreadableLibrary() {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("library-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
        } catch {
            errorMessage = "无法移动旧的书库文件，请检查储存空间后重试。"
            return
        }
        retryLoading()
    }

    private func load() {
        do {
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                addSample() // Seed only a genuinely new library; a saved empty library stays empty.
                return
            }
            struct Version: Decodable { var version: Int }
            switch try JSONDecoder().decode(Version.self, from: data).version {
            case 1:
                try migrate(from: JSONDecoder().decode(LegacyLibrary.self, from: data))
            case 2:
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard Set(snapshot.books.map(\.id)).count == snapshot.books.count else { throw LibraryError.invalidLibrary }
                books = snapshot.books
                favorites = snapshot.favorites
                fingerprints = snapshot.fingerprints
            default:
                throw LibraryError.invalidLibrary
            }
        } catch {
            readFailure = "无法读取已保存的书库。原文件没有被改动。"
        }
    }

    // MARK: Book content

    func content(for book: ReaderBook) async throws -> BookContent {
        if book.isSample { return SampleBook.content() }
        if let contentCache, contentCache.id == book.id { return contentCache.content }
        let current = directory(for: book.id).content
        let legacy = legacyContentURL(for: book.id)
        let content = try await detached {
            let url = FileManager.default.fileExists(atPath: current.path) ? current : legacy
            return try JSONDecoder().decode(BookContent.self, from: Data(contentsOf: url))
        }
        contentCache = (book.id, content)
        return content
    }

    func importBook(url: URL) async throws -> UUID {
        try ensureReadable()
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        // The same bytes are the same book under any name, so look before unpacking anything.
        let fingerprint = try await detached { try BookImporter.fingerprint(of: url) }
        try Task.checkCancellation()
        if let existingID = fingerprints[fingerprint], books.contains(where: { $0.id == existingID }) {
            throw LibraryError.duplicate(existingID)
        }
        let id = UUID()
        let staging = booksDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
        let destination = directory(for: id)
        defer { try? FileManager.default.removeItem(at: staging) }
        let imported = try await detached { try BookImporter.load(url: url, id: id, staging: staging, fingerprint: fingerprint) }
        try Task.checkCancellation()
        do {
            try await detached {
                let files = BookDirectory(url: staging)
                let encoder = JSONEncoder()
                let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                try encoder.encode(imported.content).write(to: files.content, options: options)
                try encoder.encode(imported.package).write(to: files.package, options: options)
                try imported.cover?.write(to: files.cover, options: options)
                // The book appears all at once or not at all.
                try FileManager.default.moveItem(at: staging, to: destination.url)
            }
            try commit(books: [imported.book] + books, favorites: favorites,
                       fingerprints: fingerprints.merging([imported.fingerprint: imported.book.id]) { _, new in new })
        } catch {
            try? FileManager.default.removeItem(at: destination.url)
            throw error
        }
        contentCache = (imported.book.id, imported.content)
        return imported.book.id
    }

    /// Writes the book to a temporary file, an EPUB for an EPUB import, and returns it.
    /// The caller removes the file's folder when it is done with it.
    func exportFile(for book: ReaderBook) async throws -> URL {
        guard book.canExport else { throw BookExporter.ExportError.incomplete }
        let files = directory(for: book.id)
        let title = book.title
        return try await detached {
            let package = try JSONDecoder().decode(BookPackage.self, from: Data(contentsOf: files.package))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let file = folder.appendingPathComponent(BookExporter.fileName(for: title, kind: package.kind))
                try BookExporter.export(files, package: package, to: file)
                return file
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    func addSample() {
        guard !books.contains(where: \.isSample) else { return }
        perform { try commit(books: books + [SampleBook.make()], favorites: favorites, fingerprints: fingerprints) }
    }

    /// Saved words keep their book and chapter labels after the book is removed.
    func removeBook(id: UUID) {
        perform {
            try commit(books: books.filter { $0.id != id }, favorites: favorites, fingerprints: fingerprints.filter { $0.value != id })
            try? FileManager.default.removeItem(at: directory(for: id).url)
            try? FileManager.default.removeItem(at: legacyContentURL(for: id))
            try? FileManager.default.removeItem(at: legacyCoverURL(for: id))
            if contentCache?.id == id { contentCache = nil }
        }
    }

    // MARK: Reading position

    func savePosition(bookID: UUID, chapter: Int, offset: Int, fraction: Double? = nil) {
        guard let index = books.firstIndex(where: { $0.id == bookID }), books[index].chapters.indices.contains(chapter) else { return }
        let position = ReadingPosition(chapter: chapter, offset: max(0, min(offset, books[index].chapters[chapter].length)),
                                       fraction: fraction.map { min(1, max(0, $0)) })
        guard books[index].position != position else { return }
        books[index].position = position
        pendingPositionSave?.cancel()
        pendingPositionSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.persist()
        }
    }

    /// Flushes pending position changes at reader exit or when the scene leaves the foreground.
    func persist() {
        pendingPositionSave?.cancel()
        pendingPositionSave = nil
        perform { try commit(books: books, favorites: favorites, fingerprints: fingerprints) }
    }

    // MARK: Saved words

    enum SaveResult: Equatable { case saved, alreadySaved, failed }

    func favorite(matching text: String) -> SavedPassage? {
        let key = WordDictionary.normalize(WordDictionary.shared.headword(for: text))
        return favorites.first { $0.key == key }
    }

    /// One card per headword: "peeped" and "peep" are the same word to learn.
    @discardableResult
    func savePassage(bookID: UUID, chapter: Int, offset: Int, selection: String, sentence: String) -> SaveResult {
        guard let book = books.first(where: { $0.id == bookID }), book.chapters.indices.contains(chapter) else { return .failed }
        let selection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return .failed }
        if favorite(matching: selection) != nil { return .alreadySaved }
        let entry = WordDictionary.shared.lookup(selection)
        let passage = SavedPassage(
            bookID: bookID, bookTitle: book.title, chapterTitle: book.chapters[chapter].title, chapterIndex: chapter,
            offset: max(0, min(offset, book.chapters[chapter].length)),
            selection: String(selection.prefix(500)), sentence: String(sentence.prefix(2_000)),
            headword: entry?.headword, phonetic: entry?.phonetic, definition: entry?.definition,
            createdAt: .now, reviewStage: 0, dueAt: .now)
        do {
            try commit(books: books, favorites: [passage] + favorites, fingerprints: fingerprints)
            return .saved
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    func setMastered(id: UUID, _ mastered: Bool) {
        update(id) { $0.mastered = mastered }
    }

    /// Simple spaced repetition: each "remembered" doubles roughly the gap; the
    /// last interval marks the word mastered. "Not yet" brings it back tomorrow.
    func review(id: UUID, remembered: Bool) {
        update(id) { item in
            let stage = remembered ? (item.reviewStage ?? 0) + 1 : 0
            item.reviewStage = stage
            if stage >= Self.reviewIntervals.count {
                item.mastered = true
                item.dueAt = nil
            } else {
                let days = remembered ? Self.reviewIntervals[stage - 1] : 0
                item.dueAt = Calendar.current.startOfDay(for: .now).addingTimeInterval(days * 86_400 + (remembered ? 0 : 86_400))
            }
        }
    }

    func deleteFavorite(id: UUID) {
        perform { try commit(books: books, favorites: favorites.filter { $0.id != id }, fingerprints: fingerprints) }
    }

    func restoreFavorite(_ passage: SavedPassage) {
        guard !favorites.contains(where: { $0.id == passage.id }) else { return }
        perform { try commit(books: books, favorites: (favorites + [passage]).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) },
                             fingerprints: fingerprints) }
    }

    private func update(_ id: UUID, _ change: (inout SavedPassage) -> Void) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        var updated = favorites
        change(&updated[index])
        perform { try commit(books: books, favorites: updated, fingerprints: fingerprints) }
    }

    // MARK: Persistence

    private func ensureReadable() throws {
        if let readFailure { throw LibraryError.unreadable(readFailure) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    /// Writes the entire candidate state atomically before publishing it, so a
    /// failed write never shows the reader a change that wasn't saved.
    private func commit(books: [ReaderBook], favorites: [SavedPassage], fingerprints: [String: UUID]) throws {
        try ensureReadable()
        do {
            let data = try JSONEncoder().encode(Snapshot(books: books, favorites: favorites, fingerprints: fingerprints))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw LibraryError.saveFailed
        }
        self.books = books
        self.favorites = favorites
        self.fingerprints = fingerprints
    }

    // MARK: Version 1 migration

    /// Version 1 stored every book's HTML and text inline. Text is rebuilt with
    /// today's paragraph rules and every saved offset is remapped onto it.
    private struct LegacyLibrary: Decodable {
        struct Chapter: Decodable { var id: String; var title: String; var html: String; var text: String }
        struct Book: Decodable {
            var id: UUID; var title: String; var author: String; var chapters: [Chapter]
            var position: ReadingPosition; var isSample: Bool
        }
        var books: [Book]
        var favorites: [SavedPassage]
        var fingerprints: [String: UUID]
    }

    private func migrate(from legacy: LegacyLibrary) throws {
        var migratedBooks: [ReaderBook] = []
        var migratedFavorites = legacy.favorites
        var mappings: [UUID: [(old: String, new: String)]] = [:]
        for old in legacy.books {
            let content: BookContent
            if old.isSample {
                content = SampleBook.content()
            } else {
                content = BookContent(chapters: old.chapters.map { chapter in
                    if let rebuilt = try? LenientHTML.extract(chapter.html),
                       OffsetMap.sameWords(chapter.text, rebuilt.text) {
                        return ReaderChapter(id: chapter.id, title: chapter.title, text: rebuilt.text, styles: rebuilt.styles)
                    }
                    let collapsed = chapter.text.replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\n", options: .regularExpression)
                    return ReaderChapter(id: chapter.id, title: chapter.title, text: collapsed)
                })
                let data = try JSONEncoder().encode(content)
                try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
                try data.write(to: legacyContentURL(for: old.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            let pairs = zip(old.chapters, content.chapters).map { ($0.text, $1.text) }
            mappings[old.id] = pairs
            var position = old.position
            if pairs.indices.contains(position.chapter) {
                position.offset = OffsetMap.map(position.offset, from: pairs[position.chapter].0, to: pairs[position.chapter].1)
            }
            migratedBooks.append(ReaderBook(id: old.id, title: old.title, author: old.author == "Unknown author" ? "" : old.author,
                                            chapters: content.chapterInfo, position: position, isSample: old.isSample))
        }
        for index in migratedFavorites.indices {
            var item = migratedFavorites[index]
            if let pairs = mappings[item.bookID], pairs.indices.contains(item.chapterIndex) {
                item.offset = OffsetMap.map(item.offset, from: pairs[item.chapterIndex].old, to: pairs[item.chapterIndex].new)
            }
            if item.definition == nil, let entry = WordDictionary.shared.lookup(item.selection) {
                item.headword = entry.headword
                item.phonetic = entry.phonetic
                item.definition = entry.definition
            }
            item.reviewStage = item.reviewStage ?? 0
            migratedFavorites[index] = item
        }
        try commit(books: migratedBooks, favorites: migratedFavorites, fingerprints: legacy.fingerprints)
    }
}

/// Maps offsets between two renderings of the same words that differ only in whitespace.
enum OffsetMap {
    static func sameWords(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .elementsEqual(b.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    static func map(_ offset: Int, from old: String, to new: String) -> Int {
        var visible = 0
        var position = 0
        for unit in old.utf16 {
            guard position < offset else { break }
            if !isSpace(unit) { visible += 1 }
            position += 1
        }
        var mapped = 0
        for unit in new.utf16 {
            if !isSpace(unit) {
                if visible == 0 { return mapped }
                visible -= 1
            }
            mapped += 1
        }
        return mapped
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
}

enum LibraryError: LocalizedError {
    case duplicate(UUID)
    case invalidLibrary
    case saveFailed
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .duplicate: "这本书已在书架中。"
        case .invalidLibrary: "书库文件已损坏，或来自更新版本的应用。"
        case .saveFailed: "无法保存到这台设备，原有数据没有被改动。请检查储存空间后重试。"
        case .unreadable(let message): message
        }
    }
}
