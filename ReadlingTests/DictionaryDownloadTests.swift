import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import Readling

@Suite("Dictionary pack downloads") @MainActor
struct DictionaryDownloadTests {
    @Test func installerChecksTheArchiveBeforeInstalling() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = folder.appendingPathComponent("packs", isDirectory: true)
        let (archive, pack) = try makeArchive(in: folder, id: "extended", entries: [("abdicate", "vt. 退位")])

        var tampered = pack
        tampered.sha256 = String(repeating: "0", count: 64)
        #expect(throws: DictionaryInstaller.Failure.checksum) {
            try DictionaryInstaller.install(archive: archive, as: tampered, into: installed)
        }
        var renamed = pack
        renamed.id = "names"
        #expect(throws: DictionaryInstaller.Failure.archive) {
            try DictionaryInstaller.install(archive: archive, as: renamed, into: installed)
        }
        #expect(!FileManager.default.fileExists(atPath: installed.path))

        let file = try DictionaryInstaller.install(archive: archive, as: pack, into: installed)
        #expect(file.lastPathComponent == "extended.sqlite")
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let dictionary = WordDictionary(core: nil, directory: installed)
        #expect(dictionary.packs.map(\.id) == ["extended"])
        #expect(dictionary.lookup("abdicate")?.definition == "vt. 退位")
    }

    @Test func downloadsInstallUpdateAndRemovePacks() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = folder.appendingPathComponent("packs", isDirectory: true)
        let core = folder.appendingPathComponent("core.sqlite")
        try makePack(at: core, id: "core", order: 0, entries: [("abdicates", "abdicate的第三人称单数")], forms: [("abdicates", "abdicate")])
        let (_, old) = try makeArchive(in: folder, id: "extended", entries: [("abdicate", "旧")], version: "2026.01.01")
        let manifest = folder.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(DictionaryCatalog(format: 1, release: "2026.01.01", packs: [old])).write(to: manifest)

        let dictionary = WordDictionary(core: core, directory: installed)
        let downloads = DictionaryDownloads(manifestURL: manifest, cacheURL: folder.appendingPathComponent("catalog.json"),
                                            dictionary: dictionary)
        #expect(downloads.hasMoreToDownload)
        await downloads.refresh()
        let pack = try #require(downloads.packs.first)
        #expect(downloads.status(of: pack) == .notInstalled)

        await downloads.download(pack)
        #expect(downloads.status(of: pack) == .installed)
        #expect(!downloads.hasMoreToDownload)
        #expect(dictionary.lookup("abdicates")?.definition == "旧")

        // A newer version in the catalog offers an update that replaces the installed pack.
        let (_, new) = try makeArchive(in: folder, id: "extended", entries: [("abdicate", "vt. 退位")], version: "2026.11.18.10", name: "new")
        try JSONEncoder().encode(DictionaryCatalog(format: 1, release: "2026.11.18.10", packs: [new])).write(to: manifest)
        await downloads.refresh()
        let update = try #require(downloads.packs.first)
        #expect(downloads.status(of: update) == .updateAvailable)
        await downloads.download(update)
        #expect(downloads.status(of: update) == .installed)
        #expect(dictionary.lookup("abdicates")?.definition == "vt. 退位")

        // The catalog stays available offline.
        try FileManager.default.removeItem(at: manifest)
        let offline = DictionaryDownloads(manifestURL: manifest, cacheURL: folder.appendingPathComponent("catalog.json"),
                                          dictionary: dictionary)
        await offline.refresh()
        #expect(offline.catalogError != nil && offline.packs.map(\.id) == ["extended"])

        downloads.remove(update)
        #expect(downloads.status(of: update) == .notInstalled)
        #expect(dictionary.packs.map(\.id) == ["core"])
        #expect(dictionary.lookup("abdicates")?.headword == "abdicate") // The key stays the same.
    }

    @Test func aFailedDownloadReportsAndCanBeRetried() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (archive, pack) = try makeArchive(in: folder, id: "law", entries: [("tort", "n. 侵权行为")])
        var missing = pack
        missing.url = folder.appendingPathComponent("missing.zip")
        let dictionary = WordDictionary(core: nil, directory: folder.appendingPathComponent("packs", isDirectory: true))
        let downloads = DictionaryDownloads(manifestURL: folder.appendingPathComponent("none.json"),
                                            cacheURL: folder.appendingPathComponent("catalog.json"), dictionary: dictionary)
        await downloads.download(missing)
        guard case .failed = downloads.status(of: missing) else { Issue.record("expected a failure"); return }
        missing.url = archive
        await downloads.download(missing)
        #expect(downloads.status(of: missing) == .installed)
    }

    @Test func releaseVersionsCompareNumerically() {
        #expect(DictionaryCatalog.isNewer("2026.11.18.10", than: "2026.11.18.9"))
        #expect(DictionaryCatalog.isNewer("2026.11.18.1", than: "2026.11.18"))
        #expect(DictionaryCatalog.isNewer("2027.01.01", than: "2026.12.31.3"))
        #expect(!DictionaryCatalog.isNewer("2026.11.18", than: "2026.11.18"))
        #expect(!DictionaryCatalog.isNewer("2026.11.17", than: "2026.11.18"))
    }

    /// A zipped pack as the release would carry it, with its catalog entry.
    private func makeArchive(in folder: URL, id: String, entries: [(String, String)], version: String = "2026.11.18",
                             name: String = "") throws -> (URL, DictionaryCatalog.Pack) {
        let work = folder.appendingPathComponent("build-\(id)\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let sqlite = work.appendingPathComponent("dictionary-\(id).sqlite")
        try makePack(at: sqlite, id: id, order: 10, entries: entries, version: version)
        let archive = work.appendingPathComponent("dictionary-\(id).zip")
        let zip = try Archive(url: archive, accessMode: .create)
        try zip.addEntry(with: sqlite.lastPathComponent, fileURL: sqlite, compressionMethod: .deflate)
        let size = Int64(try Data(contentsOf: archive).count)
        let pack = DictionaryCatalog.Pack(
            id: id, title: id, group: "vocabulary", order: 10, schema: DictionaryPack.schema, version: version,
            entries: entries.count, size: size, installedSize: Int64(try Data(contentsOf: sqlite).count),
            sha256: try DictionaryInstaller.sha256(of: archive), url: archive)
        return (archive, pack)
    }
}

/// A minimal pack in the app's schema.
func makePack(at url: URL, id: String, order: Int, entries: [(String, String)], forms: [(String, String)] = [],
              schema: Int = DictionaryPack.schema, version: String = "2026.11.18") throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_close(database) }
    var sql = """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE entry(key TEXT PRIMARY KEY, word TEXT, phonetic TEXT, translation TEXT, definition TEXT, tags TEXT,
                           collins INTEGER, oxford INTEGER, rank INTEGER, forms TEXT);
        CREATE TABLE form(form TEXT PRIMARY KEY, lemma TEXT);
        INSERT INTO meta VALUES ('schema', '\(schema)'), ('id', '\(id)'), ('title', '\(id)'), ('order', '\(order)'),
                                ('version', '\(version)');
        """
    for (word, translation) in entries {
        sql += "INSERT INTO entry VALUES ('\(word)', '\(word)', '', '\(translation)', '', '', 0, 0, 10000000, '');"
    }
    for (form, lemma) in forms { sql += "INSERT INTO form VALUES ('\(form)', '\(lemma)');" }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
}
