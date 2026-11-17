import Foundation
import SQLite3

struct DictionaryEntry: Equatable, Sendable {
    struct Form: Equatable, Sendable {
        /// ECDICT's code: p past, d past participle, i -ing, 3 third person, r comparative, t superlative, s plural.
        var kind: String
        var word: String
    }

    /// The form the definition belongs to, e.g. "peep" for a tapped "peeped".
    var headword: String
    var phonetic: String
    /// Every Chinese sense line, web senses ("[网络]") included.
    var translation: String
    /// English senses; often empty.
    var englishDefinition: String = ""
    /// ECDICT exam tags: zk gk cet4 cet6 ky toefl ielts gre.
    var tags: [String] = []
    /// Collins frequency stars, 0–5.
    var collins = 0
    var isOxford3000 = false
    var forms: [Form] = []
    /// Set when the tapped text was an inflected form of `headword`.
    var inflectedFrom: String?
    /// What the tapped form means in its own right, e.g. "建立" for "found" beside "find".
    var ownSense: String?
    /// The title of the pack the entry came from.
    var source = ""

    /// The short definition for the card and the word list: up to four general sense lines;
    /// field ("[计]") and web ("[网络]") senses only when there is nothing else.
    var definition: String { brief.joined(separator: "\n") }

    /// The sense lines `definition` leaves out.
    var moreTranslation: String {
        let shown = Set(brief)
        return senseLines.filter { !shown.contains($0) }.joined(separator: "\n")
    }

    private var senseLines: [String] { translation.split(separator: "\n").map(String.init) }

    private var brief: [String] {
        let main = senseLines.filter { !$0.hasPrefix("[") }
        return Array((main.isEmpty ? senseLines : main).prefix(4))
    }
}

/// One dictionary pack: an SQLite file built by Tools/build-dictionary.py. Packs never
/// overlap except for entries in two field packs, so lookups take the first pack that has a word.
@MainActor
final class DictionaryPack {
    nonisolated static let schema = 2

    let url: URL
    let id: String
    let title: String
    let order: Int
    let entryCount: Int
    /// The dictionary release the pack was built for, e.g. "2026.11.18".
    let version: String
    private var database: OpaquePointer?

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        self.url = url
        let meta = Self.meta(of: database)
        guard meta["schema"] == String(Self.schema), let id = meta["id"] else {
            sqlite3_close(database)
            return nil
        }
        self.id = id
        title = meta["title"] ?? id
        order = Int(meta["order"] ?? "") ?? 100
        entryCount = Int(meta["entries"] ?? "") ?? 0
        version = meta["version"] ?? ""
    }

    /// The pack's metadata, or nil when the file isn't a readable pack.
    nonisolated static func meta(at url: URL) -> [String: String]? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        let meta = meta(of: database)
        return meta.isEmpty ? nil : meta
    }

    nonisolated private static func meta(of database: OpaquePointer?) -> [String: String] {
        var meta: [String: String] = [:]
        rows("SELECT key, value FROM meta", in: database, columns: 2) { meta[$0[0]] = $0[1] }
        return meta
    }

    func close() {
        sqlite3_close(database)
        database = nil
    }

    struct Row {
        var key, word, phonetic, translation, definition, tags: String
        var collins, oxford, rank: Int
        var forms: String
    }

    private static let rowColumns = "key, word, phonetic, translation, definition, tags, collins, oxford, rank, forms"

    func row(_ key: String) -> Row? {
        var found: Row?
        Self.rows("SELECT \(Self.rowColumns) FROM entry WHERE key = ?", [key], in: database, columns: 10) { found = Self.row($0) }
        return found
    }

    /// Phrases that start with `word`, shortest first.
    func phrases(startingWith word: String, limit: Int) -> [Row] {
        var result: [Row] = []
        // Keys between "word " and "word!" (the next character after a space) start with "word ".
        Self.rows("SELECT \(Self.rowColumns) FROM entry WHERE key > ? AND key < ? ORDER BY length(key), key LIMIT \(limit)",
                  [word + " ", word + "!"], in: database, columns: 10) { result.append(Self.row($0)) }
        return result
    }

    /// The base word an inflected form redirects to. Only the core pack carries the form table.
    func lemma(of form: String) -> String? {
        var found: String?
        Self.rows("SELECT lemma FROM form WHERE form = ?", [form], in: database, columns: 1) { found = $0[0] }
        return found
    }

    private static func row(_ values: [String]) -> Row {
        Row(key: values[0], word: values[1], phonetic: values[2], translation: values[3], definition: values[4], tags: values[5],
            collins: Int(values[6]) ?? 0, oxford: Int(values[7]) ?? 0, rank: Int(values[8]) ?? 0, forms: values[9])
    }

    nonisolated private static func rows(_ sql: String, _ arguments: [String] = [], in database: OpaquePointer?, columns: Int32,
                             _ body: ([String]) -> Void) {
        var statement: OpaquePointer?
        guard database != nil, sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            body((0..<columns).map { column in sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" })
        }
    }
}

/// Offline English–Chinese lookups across the installed packs: the bundled core
/// (Resources/dictionary-core.sqlite, from ECDICT, MIT licensed; see SOURCE.md) plus any
/// downloaded packs. Inflections resolve through the core's form table alone, so the
/// headword a word is saved under doesn't depend on which packs are installed.
/// Primary-key reads take microseconds, so lookups run synchronously.
@MainActor
final class WordDictionary {
    static let shared = WordDictionary()

    /// Where downloaded packs live.
    static let packsDirectory = URL.applicationSupportDirectory
        .appendingPathComponent("EnglishReader", isDirectory: true)
        .appendingPathComponent("Dictionaries", isDirectory: true)

    private let core: DictionaryPack?
    /// Where this dictionary looks for downloaded packs.
    let directory: URL?
    /// Core first, then downloaded packs in their catalog order.
    private(set) var packs: [DictionaryPack] = []

    init(core url: URL? = Bundle.main.url(forResource: "dictionary-core", withExtension: "sqlite"),
         directory: URL? = WordDictionary.packsDirectory) {
        core = url.flatMap(DictionaryPack.init(url:))
        self.directory = directory
        reload()
    }

    var isAvailable: Bool { core != nil }

    /// Re-reads the downloaded packs, e.g. after one is installed or removed.
    func reload() {
        for pack in packs where pack !== core { pack.close() }
        let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        let downloaded = files.filter { $0.pathExtension == "sqlite" }.compactMap(DictionaryPack.init(url:))
            .filter { $0.id != core?.id }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        packs = (core.map { [$0] } ?? []) + downloaded
    }

    /// The dictionary key for saving and de-duplicating: the base form when the
    /// dictionary knows it, otherwise the normalized selection itself.
    func headword(for text: String) -> String {
        lookup(text)?.headword.lowercased() ?? lemma(of: Self.normalize(text))
    }

    func lookup(_ raw: String) -> DictionaryEntry? {
        let query = Self.normalize(raw)
        guard !packs.isEmpty, !query.isEmpty, query.utf16.count <= 64 else { return nil }
        if let entry = resolve(query, original: raw) { return entry }
        // Possessives and contractions: "Alice's", "they'll", "wouldn't".
        for suffix in ["'s", "'ll", "'re", "'ve", "'d", "'m", "n't", "s'"] where query.hasSuffix(suffix) && query.count > suffix.count + 1 {
            let stem = String(query.dropLast(suffix == "s'" ? 1 : suffix.count))
            if let entry = resolve(stem, original: stem) { return entry }
        }
        return nil
    }

    /// Phrases that start with `headword` across the installed packs, for the card's expanded view:
    /// phrasal verbs first ("take after"), then listed or many-sensed phrases ahead of rare compounds.
    func phrases(startingWith headword: String, limit: Int = 30) -> [DictionaryEntry] {
        let key = Self.normalize(headword)
        guard !key.isEmpty, !key.contains(" ") else { return [] }
        var seen = Set<String>()
        var found: [(row: DictionaryPack.Row, pack: DictionaryPack)] = []
        for pack in packs {
            for row in pack.phrases(startingWith: key, limit: 400) where seen.insert(row.key).inserted {
                found.append((row, pack))
            }
        }
        func score(_ row: DictionaryPack.Row) -> (Int, Int, Int, Int) {
            let words = row.key.split(separator: " ")
            let phrasal = words.count <= 3 && Self.particles.contains(String(words[1]))
            let listed = !row.tags.isEmpty || row.collins > 0 || row.rank <= 60_000
            let senses = row.translation.split(separator: "\n").filter { !$0.hasPrefix("[网络]") }.count
            return (phrasal ? 0 : 1, listed ? 0 : 1, -min(senses, 3), row.key.count)
        }
        return found.sorted { score($0.row) < score($1.row) }.prefix(limit).map { entry($0.row, from: $0.pack) }
    }

    private static let particles: Set<String> = [
        "about", "across", "after", "against", "ahead", "along", "apart", "around", "aside", "at", "away", "back", "by",
        "down", "for", "forth", "forward", "in", "into", "off", "on", "onto", "out", "over", "round", "through", "to",
        "together", "under", "up", "upon", "with", "without",
    ]

    // MARK: Lemmas

    /// The base word for an inflected form ("went" → "go"); phrases lemmatize word by word ("gave up" → "give up").
    func lemma(of key: String) -> String {
        if let lemma = core?.lemma(of: key) { return lemma }
        guard key.contains(" ") else { return key }
        return key.split(separator: " ").map { core?.lemma(of: String($0)) ?? String($0) }.joined(separator: " ")
    }

    private func resolve(_ query: String, original: String) -> DictionaryEntry? {
        let lemma = lemma(of: query)
        if lemma != query {
            let own = row(query, original: original)
            if let base = row(lemma, original: lemma) {
                var result = entry(base.row, from: base.pack)
                result.inflectedFrom = query
                if let own = own?.row, own.rank <= 60_000 || own.collins > 0 || !own.tags.isEmpty {
                    let sense = Self.withoutInflectionNotes(own.translation)
                    result.ownSense = sense.isEmpty ? nil : sense
                }
                if result.phonetic.isEmpty { result.phonetic = own?.row.phonetic ?? "" }
                return result
            }
            // The base word's pack isn't installed: the form's own entry, under the base word.
            if let own {
                var result = entry(own.row, from: own.pack)
                result.headword = lemma
                result.inflectedFrom = query
                return result
            }
        }
        return row(query, original: original).map { entry($0.row, from: $0.pack) }
    }

    private func row(_ key: String, original: String) -> (row: DictionaryPack.Row, pack: DictionaryPack)? {
        for pack in packs {
            guard let row = pack.row(key) else { continue }
            // Never answer "Alice" with the acronym "ALICE".
            if row.word.count > 1, row.word == row.word.uppercased(), original != original.uppercased() { continue }
            return (row, pack)
        }
        return nil
    }

    private func entry(_ row: DictionaryPack.Row, from pack: DictionaryPack) -> DictionaryEntry {
        DictionaryEntry(
            headword: row.word, phonetic: row.phonetic, translation: row.translation, englishDefinition: row.definition,
            tags: row.tags.split(separator: " ").map(String.init), collins: row.collins, isOxford3000: row.oxford > 0,
            forms: row.forms.split(separator: "/").compactMap { part in
                let pair = part.split(separator: ":", maxSplits: 1)
                return pair.count == 2 ? DictionaryEntry.Form(kind: String(pair[0]), word: String(pair[1])) : nil
            },
            source: pack.title)
    }

    /// "v. 窥视( peep的过去式和过去分词 ); 偷看" → "v. 窥视; 偷看"; lines that are only such a note go.
    nonisolated static func withoutInflectionNotes(_ translation: String) -> String {
        let note = #"[A-Za-z'\- ]+的[^\n()（）;；]*?(过去式|过去分词|现在分词|第三人称单数|复数|比较级|最高级)[^\n()（）;；]*"#
        return translation.split(separator: "\n").compactMap { line -> String? in
            let cleaned = String(line).replacingOccurrences(of: #"\s*[(（]\s*"# + note + #"\s*[)）]"#, with: "", options: .regularExpression)
            return cleaned.range(of: note, options: .regularExpression) == nil ? cleaned : nil
        }
        .joined(separator: "\n")
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).subtracting(["'", "’", "-"]))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }
}
