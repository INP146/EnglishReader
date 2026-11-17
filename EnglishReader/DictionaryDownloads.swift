import CryptoKit
import Foundation
import Observation
import ZIPFoundation

/// The list of downloadable packs, published as Dictionaries/manifest.json by
/// Tools/build-dictionary.py --package. See docs/dictionary-design.md.
struct DictionaryCatalog: Codable, Equatable, Sendable {
    struct Pack: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        /// "vocabulary", "field" or "names".
        var group: String
        var order: Int
        var schema: Int
        /// The dictionary release, e.g. "2026.11.18" or "2026.11.18.1".
        var version: String
        var entries: Int
        /// Bytes to download.
        var size: Int64
        /// Bytes on disk once installed.
        var installedSize: Int64
        var sha256: String
        var url: URL
    }

    var format: Int
    /// The dictionary release this catalog lists.
    var release: String
    var packs: [Pack]

    /// Release versions compare part by part as numbers: "2026.11.18.10" is newer than "2026.11.18.9".
    static func isNewer(_ version: String, than other: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        return parts(other).lexicographicallyPrecedes(parts(version))
    }
}

/// Checks a downloaded archive and moves the pack inside it into place.
enum DictionaryInstaller {
    enum Failure: LocalizedError {
        case checksum, archive, pack

        var errorDescription: String? {
            switch self {
            case .checksum: String(localized: "下载的文件不完整或已损坏。")
            case .archive: String(localized: "词典压缩包无法解开。")
            case .pack: String(localized: "词典文件与列表不符。")
            }
        }
    }

    /// Verifies `archive` against the catalog, unpacks it and installs the pack as
    /// `directory/<id>.sqlite`, replacing an older version. Returns the installed file.
    @discardableResult
    nonisolated static func install(archive: URL, as pack: DictionaryCatalog.Pack, into directory: URL) throws -> URL {
        guard try sha256(of: archive) == pack.sha256.lowercased() else { throw Failure.checksum }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("dictionary-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let unpacked = staging.appendingPathComponent("\(pack.id).sqlite")
        do {
            let zip = try Archive(url: archive, accessMode: .read)
            guard let entry = zip["dictionary-\(pack.id).sqlite"], entry.type == .file else { throw Failure.archive }
            _ = try zip.extract(entry, to: unpacked, skipCRC32: false)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.archive
        }
        let meta = DictionaryPack.meta(at: unpacked)
        guard meta?["id"] == pack.id, meta?["schema"] == String(pack.schema) else { throw Failure.pack }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed = directory.appendingPathComponent("\(pack.id).sqlite")
        if fileManager.fileExists(atPath: installed.path) {
            _ = try fileManager.replaceItemAt(installed, withItemAt: unpacked)
        } else {
            try fileManager.moveItem(at: unpacked, to: installed)
        }
        // It can always be downloaded again.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try installed.setResourceValues(values)
        return installed
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Fetches the catalog and downloads, updates and removes packs for Settings › 词典.
@Observable @MainActor
final class DictionaryDownloads {
    static let shared = DictionaryDownloads()

    /// UI tests and local trials launch with `-dictionaryManifestURL <url>` to use another catalog.
    static let manifestURL = UserDefaults.standard.string(forKey: "dictionaryManifestURL").flatMap(URL.init(string:))
        ?? URL(string: "https://raw.githubusercontent.com/INP146/EnglishReader/main/Dictionaries/manifest.json")!

    enum Status: Equatable {
        case notInstalled, installed, updateAvailable, installing
        case downloading(Double)
        case failed(String)
    }

    private(set) var catalog: DictionaryCatalog?
    private(set) var catalogError: String?
    private(set) var isRefreshing = false
    private var active: [String: Status] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    /// Bumped whenever the installed packs change, so views reading `status` refresh.
    private var changes = 0

    private let manifestURL: URL
    private let cacheURL: URL
    let dictionary: WordDictionary

    init(manifestURL: URL = DictionaryDownloads.manifestURL,
         cacheURL: URL = WordDictionary.packsDirectory.deletingLastPathComponent().appendingPathComponent("dictionary-catalog.json"),
         dictionary: WordDictionary = .shared) {
        self.manifestURL = manifestURL
        self.cacheURL = cacheURL
        self.dictionary = dictionary
        catalog = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(DictionaryCatalog.self, from: $0) }
    }

    /// Packs this version of the app can read, in display order.
    var packs: [DictionaryCatalog.Pack] {
        guard catalog?.format == 1 else { return [] }
        return (catalog?.packs ?? []).filter { $0.schema == DictionaryPack.schema }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Whether some pack in the catalog (or, before it has been fetched, any pack at all) could still add words.
    var hasMoreToDownload: Bool {
        _ = changes
        guard catalog != nil else { return true }
        return packs.contains { installedVersion(of: $0.id) == nil }
    }

    func status(of pack: DictionaryCatalog.Pack) -> Status {
        _ = changes
        if let status = active[pack.id] { return status }
        guard let version = installedVersion(of: pack.id) else { return .notInstalled }
        return DictionaryCatalog.isNewer(pack.version, than: version) ? .updateAvailable : .installed
    }

    private func installedVersion(of id: String) -> String? {
        downloaded(id)?.version
    }

    /// The installed download for `id`; the bundled core never counts.
    private func downloaded(_ id: String) -> DictionaryPack? {
        let directory = dictionary.directory?.standardizedFileURL
        return dictionary.packs.first { $0.id == id && $0.url.deletingLastPathComponent().standardizedFileURL == directory }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var request = URLRequest(url: manifestURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
            let fetched = try JSONDecoder().decode(DictionaryCatalog.self, from: data)
            catalog = fetched
            catalogError = nil
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            catalogError = String(localized: "无法获取词典列表，请检查网络后重试。")
        }
    }

    /// Downloads and installs `pack`, resuming an earlier interrupted download when possible.
    func download(_ pack: DictionaryCatalog.Pack) async {
        guard tasks[pack.id] == nil, let directory = dictionary.directory else { return }
        active[pack.id] = .downloading(0)
        let delegate = DownloadDelegate(expectedSize: pack.size) { [weak self] fraction in
            Task { @MainActor in
                if case .downloading = self?.active[pack.id] { self?.active[pack.id] = .downloading(fraction) }
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.removeValue(forKey: pack.id).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: pack.url)
        tasks[pack.id] = task
        do {
            let archive = try await delegate.run(task)
            tasks[pack.id] = nil
            active[pack.id] = .installing
            defer { try? FileManager.default.removeItem(at: archive) }
            try await Task.detached(priority: .userInitiated) {
                try DictionaryInstaller.install(archive: archive, as: pack, into: directory)
            }.value
            dictionary.reload()
            changes += 1
            active[pack.id] = nil
        } catch {
            tasks[pack.id] = nil
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[pack.id] = data }
            if (error as? URLError)?.code == .cancelled {
                active[pack.id] = nil
            } else {
                active[pack.id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ pack: DictionaryCatalog.Pack) {
        tasks[pack.id]?.cancel()
        resumeData[pack.id] = nil
    }

    func remove(_ pack: DictionaryCatalog.Pack) {
        guard let installed = downloaded(pack.id) else { return }
        let url = installed.url
        installed.close()
        try? FileManager.default.removeItem(at: url)
        dictionary.reload()
        changes += 1
        active[pack.id] = nil
    }
}

/// Reports a download's progress and hands over the finished file, moved out of
/// URLSession's temporary location before it disappears.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: Result<URL, Error>?

    init(expectedSize: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(_ task: URLSessionDownloadTask) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            result = .failure(URLError(.badServerResponse))
        } else {
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                result = .success(kept)
            } catch {
                result = .failure(error)
            }
        }
        lock.withLock { file = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: lock.withLock { file } ?? .failure(URLError(.unknown)))
        }
    }
}
