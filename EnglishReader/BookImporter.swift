import Foundation
import CryptoKit
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// All parsing is synchronous and CPU/file-bound; LibraryStore calls it in a cancellable detached task.
/// Archive entries are read into bounded memory, never extracted onto the filesystem.
enum BookImporter {
    struct ImportedBook: Sendable {
        let book: ReaderBook
        let content: BookContent
        let fingerprint: String
    }

    enum ImportError: LocalizedError {
        case unsupported, fixedLayout, tooLarge, corrupt(String), encrypted, unsafePath, empty
        var errorDescription: String? {
            switch self {
            case .unsupported: "只支持 EPUB 和 TXT 文件。PDF、MOBI 等格式可以先用 Calibre 等工具转换成 EPUB。"
            case .fixedLayout: "这是固定版式（图片或漫画类）的 EPUB，没有可以逐词阅读的文字。"
            case .tooLarge: "这本书太大了：文件最大 40 MB，解压后最大 120 MB。"
            case .corrupt(let reason): "无法打开这本书。\(reason)"
            case .encrypted: "这本书受 DRM 保护，正文被加密，无法读取。请使用无 DRM 的版本。"
            case .unsafePath: "这个 EPUB 包含不安全或无效的文件路径。"
            case .empty: "这本书中没有找到可阅读的文字。"
            }
        }
    }

    private static let maximumFileBytes = 40 * 1_024 * 1_024
    private static let maximumTextBytes = 16 * 1_024 * 1_024
    private static let maximumExpandedBytes = 120 * 1_024 * 1_024
    private static let maximumChapterBytes = 8 * 1_024 * 1_024
    /// Font obfuscation is not DRM: the text itself stays readable.
    private static let obfuscationAlgorithms: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]

    static func load(url: URL) throws -> ImportedBook {
        do { return try loadFile(url: url) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ImportError { throw error }
        catch { throw ImportError.corrupt("无法读取所选文件，请确认文件已下载到本机。") }
    }

    private static func loadFile(url: URL) throws -> ImportedBook {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard ext == "epub" || ext == "txt" else { throw ImportError.unsupported }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.unsupported }
        if let size = values.fileSize, size > maximumFileBytes { throw ImportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= maximumFileBytes else { throw ImportError.tooLarge }
            data.append(chunk)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let title = url.deletingPathExtension().lastPathComponent
        var (book, content) = ext == "txt" ? try importText(data, title: title) : try importEPUB(data, fallbackTitle: title)
        book.chapters = content.chapterInfo
        return ImportedBook(book: book, content: content, fingerprint: hash)
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Older English texts are often Windows-1252 / Latin-1. Reject binaries.
        guard !data.prefix(4_096).contains(0) else { return nil }
        return String(data: data, encoding: .windowsCP1252)
    }

    private static func importText(_ data: Data, title: String) throws -> (ReaderBook, BookContent) {
        guard data.count <= maximumTextBytes else { throw ImportError.tooLarge }
        guard var text = decodeText(data), !text.contains("\0") else {
            throw ImportError.corrupt("无法识别 TXT 的文字编码，请另存为 UTF-8 后再试。")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let chapters = try PlainTextLayout.chapters(from: text)
        guard !chapters.isEmpty else { throw ImportError.empty }
        let book = ReaderBook(title: title.isEmpty ? "Untitled" : title, author: "", chapters: [])
        return (book, BookContent(chapters: chapters))
    }

    private static func importEPUB(_ data: Data, fallbackTitle: String) throws -> (ReaderBook, BookContent) {
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw ImportError.corrupt("文件不是有效的 EPUB（ZIP 压缩包损坏）。") }
        var entries: [String: Entry] = [:]
        var expanded: UInt64 = 0
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 4_096 else { throw ImportError.tooLarge }
            guard validArchivePath(entry.path) else { throw ImportError.unsafePath }
            guard entry.type == .file || entry.type == .directory else { throw ImportError.unsafePath }
            guard entries[entry.path] == nil else { throw ImportError.corrupt("ZIP 压缩包包含重复的文件名。") }
            guard entry.uncompressedSize <= UInt64(16 * 1_024 * 1_024) else { throw ImportError.tooLarge }
            expanded += entry.uncompressedSize
            guard expanded <= UInt64(maximumExpandedBytes) else { throw ImportError.tooLarge }
            entries[entry.path] = entry
        }

        func resource(_ path: String, limit: Int = 2 * 1_024 * 1_024) throws -> Data {
            try Task.checkCancellation()
            guard let entry = entries[path], entry.type == .file else {
                throw ImportError.corrupt("EPUB 缺少必要文件：\(path)")
            }
            guard entry.uncompressedSize <= UInt64(limit) else { throw ImportError.tooLarge }
            var output = Data()
            do {
                let checksum = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: false) { chunk in
                    try Task.checkCancellation()
                    guard output.count + chunk.count <= limit else { throw ImportError.tooLarge }
                    output.append(chunk)
                }
                guard checksum == entry.checksum, UInt64(output.count) == entry.uncompressedSize else {
                    throw ImportError.corrupt("ZIP 文件完整性校验失败。")
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as ImportError { throw error }
            catch { throw ImportError.corrupt("ZIP 中的文件已损坏。") }
            return output
        }

        let mime = try resource("mimetype", limit: 128)
        guard String(data: mime, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw ImportError.corrupt("文件不是有效的 EPUB。")
        }
        // Only content encrypted with a real cipher is DRM; font obfuscation is ignored.
        var encryptedPaths = Set<String>()
        if let encryptionPath = entries.keys.first(where: { $0.lowercased() == "meta-inf/encryption.xml" }) {
            guard let encryption = try? XMLTree.parse(resource(encryptionPath)) else { throw ImportError.encrypted }
            for item in encryption.descendants("EncryptedData") {
                let algorithm = item.descendants("EncryptionMethod").first?.attributes["Algorithm"] ?? ""
                guard !obfuscationAlgorithms.contains(algorithm) else { continue }
                for reference in item.descendants("CipherReference") {
                    guard let uri = reference.attributes["URI"] else { continue }
                    encryptedPaths.insert((try? resolve(uri, relativeTo: "")) ?? uri)
                }
            }
        }
        let container = try XMLTree.parse(resource("META-INF/container.xml"))
        guard let rootfile = container.descendants("rootfile").first(where: { $0.attributes["media-type"] == "application/oebps-package+xml" }),
              let packagePath = rootfile.attributes["full-path"] else {
            throw ImportError.corrupt("EPUB 缺少内容清单。")
        }
        let opfPath = try resolve(packagePath, relativeTo: "")
        let package = try XMLTree.parse(resource(opfPath))
        guard let metadata = package.descendants("metadata").first,
              let manifest = package.descendants("manifest").first,
              let spine = package.descendants("spine").first else {
            throw ImportError.corrupt("EPUB 缺少书籍信息或阅读顺序。")
        }
        for meta in metadata.descendants("meta") {
            if meta.attributes["property"] == "rendition:layout" && meta.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated" {
                throw ImportError.fixedLayout
            }
            if meta.attributes["name"]?.lowercased() == "fixed-layout" && meta.attributes["content"]?.lowercased() == "true" {
                throw ImportError.fixedLayout
            }
        }
        struct Item {
            let path: String
            let media: String
            let properties: Set<String>
        }
        var items: [String: Item] = [:]
        for node in manifest.children where node.name == "item" {
            guard let id = node.attributes["id"], let href = node.attributes["href"], items[id] == nil,
                  let path = try? resolve(href, relativeTo: opfPath) else { continue }
            items[id] = Item(path: path, media: node.attributes["media-type"] ?? "",
                             properties: Set((node.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)))
        }
        // Navigation only supplies titles; a broken table of contents must not block the book.
        var titles: [String: String] = [:]
        if let navigation = items.values.first(where: { $0.properties.contains("nav") }),
           let nav = try? XMLTree.parse(resource(navigation.path)) {
            let navigationNodes = nav.descendants("nav")
            let toc = navigationNodes.first(where: { ($0.attribute("type") ?? "").split(separator: " ").contains("toc") }) ?? navigationNodes.first
            for anchor in toc?.descendants("a") ?? [] {
                guard let href = anchor.attributes["href"], let path = try? resolve(href, relativeTo: navigation.path) else { continue }
                let title = PlainTextLayout.cleanLabel(anchor.plainText)
                if titles[path] == nil && !title.isEmpty { titles[path] = title }
            }
        } else if let tocID = spine.attributes["toc"], let ncx = items[tocID], let nav = try? XMLTree.parse(resource(ncx.path)) {
            for point in nav.descendants("navPoint") {
                guard let content = point.children.first(where: { $0.name == "content" }),
                      let href = content.attributes["src"], let label = point.children.first(where: { $0.name == "navLabel" }),
                      let path = try? resolve(href, relativeTo: ncx.path) else { continue }
                if titles[path] == nil { titles[path] = PlainTextLayout.cleanLabel(label.plainText) }
            }
        }
        var chapters: [ReaderChapter] = []
        var contentBytes = 0
        var visited = Set<String>()
        var readable = 0
        for reference in spine.children where reference.name == "itemref" {
            try Task.checkCancellation()
            if reference.attributes["linear"] == "no" { continue }
            guard let id = reference.attributes["idref"], let item = items[id] else { continue }
            guard ["application/xhtml+xml", "text/html", "application/xml", "text/xml"].contains(item.media) else { continue }
            guard visited.insert(item.path).inserted, entries[item.path] != nil else { continue }
            guard !encryptedPaths.contains(item.path) else { throw ImportError.encrypted }
            let bytes = try resource(item.path, limit: maximumChapterBytes)
            contentBytes += bytes.count
            guard contentBytes <= 32 * 1_024 * 1_024 else { throw ImportError.tooLarge }
            guard let extracted = try chapterText(bytes) else { continue }
            readable += 1
            if extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue } // Image-only pages.
            let title = [titles[item.path], extracted.heading, extracted.documentTitle].compactMap { $0 }.first(where: { !$0.isEmpty })
                ?? "Chapter \(chapters.count + 1)"
            chapters += ChapterLayout.split(ReaderChapter(id: item.path, title: title, text: extracted.text, styles: extracted.styles))
            guard chapters.count <= 2_000 else { throw ImportError.tooLarge }
        }
        guard !chapters.isEmpty else { throw readable == 0 && !visited.isEmpty ? ImportError.corrupt("书中的章节都无法解析。") : ImportError.empty }
        let title = metadata.descendants("title").first.map { PlainTextLayout.cleanLabel($0.plainText) } ?? ""
        let authors = metadata.descendants("creator").map { PlainTextLayout.cleanLabel($0.plainText) }.filter { !$0.isEmpty }
        let book = ReaderBook(title: title.isEmpty ? fallbackTitle : title, author: authors.joined(separator: ", "), chapters: [])
        return (book, BookContent(chapters: chapters))
    }

    /// Strict XHTML first; real-world tag soup falls back to the lenient scanner.
    /// Returns nil only when neither can read the chapter.
    private static func chapterText(_ bytes: Data) throws -> (text: String, styles: [TextStyleRun], heading: String?, documentTitle: String?)? {
        do {
            let document = try XMLTree.parse(bytes)
            let body = document.descendants("body").first ?? document
            var builder = ChapterTextBuilder()
            try body.render(into: &builder)
            let result = builder.finish()
            let heading = body.first(where: { ["h1", "h2", "h3"].contains($0.name) }).map { PlainTextLayout.cleanLabel($0.plainText) }
            let documentTitle = document.first(where: { $0.name == "title" }).map { PlainTextLayout.cleanLabel($0.plainText) }
            return (result.text, result.styles, heading, documentTitle)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as XMLTree.UnsafeDocument {
            throw ImportError.corrupt(error.reason)
        } catch {
            guard let source = decodeText(bytes) else { return nil }
            let result = try LenientHTML.extract(source)
            return (result.text, result.styles, nil, nil)
        }
    }

    private static func validArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 2_048, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, part in
            part != "." && part != ".." && (!part.isEmpty || index == components.count - 1)
        }
    }

    /// Resolve URI references without ever trusting URL/file normalization or writing a ZIP path to disk.
    private static func resolve(_ href: String, relativeTo base: String) throws -> String {
        guard href.utf8.count <= 4_096 else { throw ImportError.unsafePath }
        let raw = String(href.prefix { $0 != "#" && $0 != "?" })
        guard let decoded = raw.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("\0") else { throw ImportError.unsafePath }
        if decoded.isEmpty { return base }
        var components = base.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { throw ImportError.unsafePath }
                components.removeLast()
            } else { components.append(String(part)) }
        }
        guard !components.isEmpty else { throw ImportError.unsafePath }
        return components.joined(separator: "/")
    }
}

/// Strict XML parsing, no DTD entities, no network resolution, and bounded node/depth counts.
/// Rendering copies text and a few structural tags only; no source attributes survive.
private final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var content: [Content] = []
        enum Content { case text(String), node(Node) }
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
        var children: [Node] { content.compactMap { if case .node(let n) = $0 { return n }; return nil } }
        var plainText: String { content.map { switch $0 { case .text(let t): t; case .node(let n): n.plainText } }.joined() }
        func attribute(_ localName: String) -> String? {
            attributes[localName] ?? attributes.first(where: { $0.key.split(separator: ":").last.map(String.init) == localName })?.value
        }
        func descendants(_ name: String? = nil) -> [Node] {
            var result: [Node] = []
            func walk(_ node: Node) {
                for child in node.children {
                    if name == nil || child.name == name { result.append(child) }
                    walk(child)
                }
            }
            walk(self)
            return result
        }
        func first(where predicate: (Node) -> Bool) -> Node? {
            for child in children {
                if predicate(child) { return child }
                if let found = child.first(where: predicate) { return found }
            }
            return nil
        }
        func render(into builder: inout ChapterTextBuilder, preformatted: Bool = false) throws {
            let name = name.lowercased()
            if LenientHTML.hidden.contains(name) { return }
            let preformatted = preformatted || name == "pre"
            guard !content.isEmpty else {
                LenientHTML.apply(name, closing: false, selfClosing: true, to: &builder)
                return
            }
            LenientHTML.apply(name, closing: false, to: &builder)
            for part in content {
                switch part {
                case .text(let value):
                    if preformatted { builder.appendPreformatted(value) } else { builder.append(value) }
                case .node(let child):
                    try child.render(into: &builder, preformatted: preformatted)
                }
            }
            LenientHTML.apply(name, closing: true, to: &builder)
        }
    }

    /// Entity declarations and internal DTDs are refused outright, never retried leniently.
    struct UnsafeDocument: Error { let reason: String }

    private let root = Node(name: "#document", attributes: [:])
    private var stack: [Node] = []
    private var count = 0
    private var stopped = false

    private static func replacingXHTMLEntities(in source: String) throws -> String {
        // Treat CDATA, comments and processing instructions as opaque lexical spans.
        // Replacing inside CDATA would corrupt intentionally literal "&eacute;" text.
        let pattern = #"<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|&([A-Za-z][A-Za-z0-9]*);"#
        let expression = try NSRegularExpression(pattern: pattern)
        let input = source as NSString
        var output = ""
        output.reserveCapacity(source.utf8.count)
        var cursor = 0
        var cancelled = false
        expression.enumerateMatches(in: source, range: NSRange(location: 0, length: input.length)) { match, _, stop in
            if Task.isCancelled { cancelled = true; stop.pointee = true; return }
            guard let match, match.range(at: 1).location != NSNotFound,
                  let scalar = HTMLEntities.named[input.substring(with: match.range(at: 1))] else { return }
            output += input.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += "&#\(scalar);"
            cursor = NSMaxRange(match.range)
        }
        if cancelled { throw CancellationError() }
        output += input.substring(from: cursor)
        return output
    }

    static func parse(_ data: Data) throws -> Node {
        // EPUB XML is UTF-8 or UTF-16. Normalize before checking declarations so a UTF-16 DTD cannot bypass the check.
        let source: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { source = String(data: data, encoding: .utf16) }
        else { source = String(data: data, encoding: .utf8) }
        guard var source else { throw BookImporter.ImportError.corrupt("XML 文件的文字编码不受支持。") }
        guard source.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw UnsafeDocument(reason: "不支持 XML 实体声明。") }
        // Ordinary EPUB2 XHTML external doctypes are harmless once stripped. Internal subsets are rejected.
        while let start = source.range(of: "<!DOCTYPE", options: .caseInsensitive) {
            guard let end = source[start.lowerBound...].firstIndex(of: ">"),
                  !source[start.lowerBound...end].contains("[") else {
                throw UnsafeDocument(reason: "不支持带内部 DTD 的 XML 文件。")
            }
            source.removeSubrange(start.lowerBound...end)
        }
        // Resolve the complete standard XHTML entity set offline. Numeric references are
        // interpreted once by XMLParser; escaped ampersands are never decoded recursively.
        source = try replacingXHTMLEntities(in: source)
        // Re-encoding a UTF-16 XML document must also update its declaration.
        if let declaration = source.range(of: "<\\?xml[^?]*\\?>", options: .regularExpression) { source.removeSubrange(declaration) }
        let delegate = XMLTree()
        delegate.stack = [delegate.root]
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.stopped else {
            try Task.checkCancellation()
            throw BookImporter.ImportError.corrupt("EPUB 的 XML 文件格式错误，或超过安全限制。")
        }
        return delegate.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count <= 150_000, stack.count < 96, !Task.isCancelled else { stopped = true; parser.abortParsing(); return }
        let node = Node(name: elementName, attributes: attributeDict)
        stack.last?.content.append(.node(node))
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { stack.last?.content.append(.text(text)) }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
