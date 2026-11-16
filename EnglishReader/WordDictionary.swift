import Foundation
import SQLite3

struct DictionaryEntry: Equatable, Sendable {
    /// The form the definition belongs to, e.g. "peep" for a tapped "peeped".
    var headword: String
    var phonetic: String
    var definition: String
    /// Set when the tapped text was an inflected form of `headword`.
    var inflectedFrom: String?
}

/// Offline English–Chinese lookups against the bundled ECDICT subset
/// (Resources/dictionary.sqlite, MIT licensed; see SOURCE.md).
/// Primary-key reads take microseconds, so lookups run synchronously.
@MainActor
final class WordDictionary {
    static let shared = WordDictionary()

    private var database: OpaquePointer?
    private var opened = false

    init(url: URL? = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite")) {
        guard let url else { return }
        opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    }

    var isAvailable: Bool { opened }

    /// The dictionary key for saving and de-duplicating: the base form when the
    /// dictionary knows it, otherwise the normalized selection itself.
    func headword(for text: String) -> String {
        lookup(text)?.headword.lowercased() ?? Self.normalize(text)
    }

    func lookup(_ raw: String) -> DictionaryEntry? {
        let query = Self.normalize(raw)
        guard opened, !query.isEmpty, query.utf16.count <= 64 else { return nil }
        if let entry = resolve(query, original: raw) { return entry }
        // Possessives and contractions: "Alice's", "they'll", "wouldn't".
        for suffix in ["'s", "'ll", "'re", "'ve", "'d", "'m", "n't", "s'"] where query.hasSuffix(suffix) && query.count > suffix.count + 1 {
            let stem = String(query.dropLast(suffix == "s'" ? 1 : suffix.count))
            if let entry = resolve(stem, original: stem) { return entry }
        }
        return nil
    }

    private func resolve(_ query: String, original: String) -> DictionaryEntry? {
        if let row = row(query, original: original) {
            // Entries like "went" only say "go的过去式"; show the base form's meaning too.
            if !row.lemma.isEmpty, row.lemma != query, let base = self.row(row.lemma, original: row.lemma) {
                return DictionaryEntry(headword: base.word, phonetic: base.phonetic.isEmpty ? row.phonetic : base.phonetic,
                                       definition: base.translation, inflectedFrom: row.word)
            }
            return DictionaryEntry(headword: row.word, phonetic: row.phonetic, definition: row.translation)
        }
        if let lemma = form(query), let base = row(lemma, original: lemma) {
            return DictionaryEntry(headword: base.word, phonetic: base.phonetic, definition: base.translation, inflectedFrom: query)
        }
        return nil
    }

    private struct Row { var word, phonetic, translation, lemma: String }

    private func row(_ key: String, original: String) -> Row? {
        let values = query("SELECT word, phonetic, translation, lemma FROM entry WHERE key = ?", key, columns: 4)
        guard let values else { return nil }
        let row = Row(word: values[0], phonetic: values[1], translation: values[2], lemma: values[3])
        // Never answer "Alice" with the acronym "ALICE".
        if row.word.count > 1, row.word == row.word.uppercased(), original != original.uppercased() { return nil }
        return row
    }

    private func form(_ key: String) -> String? {
        query("SELECT lemma FROM form WHERE form = ?", key, columns: 1)?.first
    }

    private func query(_ sql: String, _ key: String, columns: Int32) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (0..<columns).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).subtracting(["'", "’", "-"]))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }
}
