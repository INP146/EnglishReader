import Foundation
import ZIPFoundation

/// Writes an imported book back out as a file: an EPUB for an EPUB import, the
/// original text file for a text import.
///
/// Chapter documents are serialized from their stored trees; every other file of
/// the original container is copied byte for byte, at its original path and in
/// its original order. The package files (container, OPF, navigation, styles,
/// fonts, images) therefore come back exactly as they went in.
enum BookExporter {
    enum ExportError: LocalizedError {
        case incomplete
        var errorDescription: String? { "这本书的文件不完整，无法导出。可以从书架移除后重新导入。" }
    }

    /// Formats that are already compressed; deflating them again only costs time.
    private static let storedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "mp3", "mp4", "m4a", "m4v", "mov",
                                                        "ogg", "ogv", "oga", "woff", "woff2", "zip", "epub", "pdf"]

    /// A file name for the book: its title, safe to use on any file system.
    static func fileName(for title: String, kind: BookPackage.Kind) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let words = title.components(separatedBy: unsafe).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        var name = String(words.joined(separator: " ").prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "book" }
        return name + (kind == .epub ? ".epub" : ".txt")
    }

    /// `destination` must not exist yet.
    static func export(_ directory: BookDirectory, package: BookPackage, to destination: URL) throws {
        switch package.kind {
        case .text:
            guard let entry = package.entries.first, FileManager.default.fileExists(atPath: directory.resource(entry.file).path) else {
                throw ExportError.incomplete
            }
            try FileManager.default.copyItem(at: directory.resource(entry.file), to: destination)
        case .epub:
            do { try writeEPUB(directory, package: package, to: destination) }
            catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    private static func writeEPUB(_ directory: BookDirectory, package: BookPackage, to destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        // The container format wants the mimetype first and stored, so a reader can recognize the file by its first bytes.
        try add("mimetype", Data("application/epub+zip".utf8), compressed: false, to: archive)
        let decoder = JSONDecoder()
        for entry in package.entries {
            try Task.checkCancellation()
            if entry.isDocument {
                guard let data = try? Data(contentsOf: directory.document(entry.file)),
                      let document = try? decoder.decode(XMLDocumentFile.self, from: data) else { throw ExportError.incomplete }
                try add(entry.path, XMLTree.serialize(document), compressed: true, to: archive)
            } else {
                let source = directory.resource(entry.file)
                guard FileManager.default.fileExists(atPath: source.path) else { throw ExportError.incomplete }
                let ext = (entry.path as NSString).pathExtension.lowercased()
                try archive.addEntry(with: entry.path, fileURL: source, compressionMethod: storedExtensions.contains(ext) ? .none : .deflate)
            }
        }
    }

    private static func add(_ path: String, _ data: Data, compressed: Bool, to archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: compressed ? .deflate : .none) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(data.count, start + size))
        }
    }
}
