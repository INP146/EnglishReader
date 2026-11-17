import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Strict XML parsing, no DTD entities, no network resolution, and bounded node/depth counts.
///
/// The tree keeps everything needed to write a document back out: names as written
/// (prefix included), namespace declarations (they arrive as ordinary attributes),
/// comments, processing instructions and every text node. Named HTML entities are
/// already resolved to characters, so serializing escapes only what XML requires.
final class XMLTree: NSObject, XMLParserDelegate {
    final class Node {
        /// The name as written, prefix included ("dc:title").
        let qualifiedName: String
        /// Local name without a prefix; every lookup by name uses this one.
        let name: String
        var attributes: [String: String]
        var content: [Content] = []
        /// The document's `<!DOCTYPE …>` declaration; only set on the document root.
        var doctype: String?

        enum Content {
            case text(String)
            case comment(String)
            case instruction(target: String, data: String)
            case node(Node)
        }

        init(qualifiedName: String, attributes: [String: String]) {
            self.qualifiedName = qualifiedName
            name = qualifiedName.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? qualifiedName
            self.attributes = attributes
        }

        var children: [Node] { content.compactMap { if case .node(let n) = $0 { return n }; return nil } }
        var plainText: String {
            content.map { part -> String in
                switch part {
                case .text(let t): t
                case .node(let n): n.plainText
                case .comment, .instruction: ""
                }
            }.joined()
        }

        /// An attribute by local name: "href" finds "xlink:href" too.
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
    }

    /// Entity declarations and internal DTDs are refused outright, never retried leniently.
    struct UnsafeDocument: Error { let reason: String }

    private let root = Node(qualifiedName: "#document", attributes: [:])
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
        else if data.starts(with: [0xEF, 0xBB, 0xBF]) { source = String(data: data.dropFirst(3), encoding: .utf8) }
        else { source = String(data: data, encoding: .utf8) }
        guard var source else { throw BookImporter.ImportError.corrupt("XML 文件的文字编码不受支持。") }
        guard source.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw UnsafeDocument(reason: "不支持 XML 实体声明。") }
        // Ordinary EPUB2 XHTML external doctypes are harmless once stripped. Internal subsets are rejected.
        var doctype: String?
        while let start = source.range(of: "<!DOCTYPE", options: .caseInsensitive) {
            guard let end = source[start.lowerBound...].firstIndex(of: ">"),
                  !source[start.lowerBound...end].contains("[") else {
                throw UnsafeDocument(reason: "不支持带内部 DTD 的 XML 文件。")
            }
            if doctype == nil { doctype = String(source[start.lowerBound...end]) }
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
        // Without namespace processing the xmlns declarations stay ordinary attributes
        // and names keep their prefixes, which is exactly what writing the tree back needs.
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.stopped else {
            try Task.checkCancellation()
            throw BookImporter.ImportError.corrupt("EPUB 的 XML 文件格式错误，或超过安全限制。")
        }
        delegate.root.doctype = doctype
        return delegate.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count <= 150_000, stack.count < 96, !Task.isCancelled else { stopped = true; parser.abortParsing(); return }
        let node = Node(qualifiedName: elementName, attributes: attributeDict)
        stack.last?.content.append(.node(node))
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { appendText(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { appendText(text) }
    }

    func parser(_ parser: XMLParser, foundComment comment: String) { stack.last?.content.append(.comment(comment)) }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        stack.last?.content.append(.instruction(target: target, data: data ?? ""))
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }

    /// The parser delivers one text run in several pieces; keep them as one node.
    private func appendText(_ string: String) {
        guard let node = stack.last else { return }
        if case .text(let existing)? = node.content.last {
            node.content[node.content.count - 1] = .text(existing + string)
        } else {
            node.content.append(.text(string))
        }
    }
}

// MARK: - Storage

/// A parsed document as written to disk: the tree plus its doctype.
struct XMLDocumentFile: Codable {
    var doctype: String?
    var root: XMLTree.Node
}

/// Compact JSON: an element is `[name, {attributes}, child…]`, text is a plain
/// string, a comment is `{"!": text}` and a processing instruction `{"?": target, "d": data}`.
extension XMLTree.Node: Codable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(qualifiedName)
        try container.encode(attributes)
        for part in content {
            switch part {
            case .text(let text): try container.encode(text)
            case .node(let node): try container.encode(node)
            case .comment(let text): try container.encode(["!": text])
            case .instruction(let target, let data): try container.encode(["?": target, "d": data])
            }
        }
    }

    convenience init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let name = try container.decode(String.self)
        let attributes = try container.decode([String: String].self)
        self.init(qualifiedName: name, attributes: attributes)
        while !container.isAtEnd {
            if let text = try? container.decode(String.self) {
                content.append(.text(text))
            } else if let marker = try? container.decode([String: String].self) {
                if let comment = marker["!"] { content.append(.comment(comment)) }
                else if let target = marker["?"] { content.append(.instruction(target: target, data: marker["d"] ?? "")) }
                else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown XML child") }
            } else {
                content.append(.node(try container.decode(XMLTree.Node.self)))
            }
        }
    }
}

// MARK: - Writing

extension XMLTree {
    /// Elements that XHTML writes as a single tag.
    private static let voidElements: Set<String> = ["area", "base", "br", "col", "command", "embed", "hr", "img", "input",
                                                    "keygen", "link", "meta", "param", "source", "track", "wbr"]
    /// Other HTML elements are written with an explicit closing tag when empty, so a lenient
    /// reader that treats the file as HTML never sees `<div/>` open a box that never closes.
    private static let htmlElements: Set<String> = [
        "a", "abbr", "address", "article", "aside", "audio", "b", "bdi", "bdo", "blockquote", "body", "button", "canvas",
        "caption", "cite", "code", "colgroup", "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl",
        "dt", "em", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hgroup", "html", "i", "iframe", "ins", "kbd", "label", "legend", "li", "main", "map", "mark", "menu",
        "meter", "nav", "noscript", "object", "ol", "optgroup", "option", "output", "p", "picture", "pre", "progress",
        "q", "rp", "rt", "ruby", "s", "samp", "script", "section", "select", "slot", "small", "span", "strong", "style",
        "sub", "summary", "sup", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time",
        "title", "tr", "u", "ul", "var", "video"
    ]

    /// Serializes a document as UTF-8 XML.
    static func serialize(_ file: XMLDocumentFile) -> Data {
        var output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if let doctype = file.doctype { output += doctype + "\n" }
        for part in file.root.content { write(part, into: &output) }
        output += "\n"
        return Data(output.utf8)
    }

    private static func write(_ part: Node.Content, into output: inout String) {
        switch part {
        case .text(let text):
            escape(text, attribute: false, into: &output)
        case .comment(let text):
            output += "<!--" + text + "-->"
        case .instruction(let target, let data):
            output += data.isEmpty ? "<?\(target)?>" : "<?\(target) \(data)?>"
        case .node(let node):
            write(node, into: &output)
        }
    }

    private static func write(_ node: Node, into output: inout String) {
        output += "<" + node.qualifiedName
        // Namespace declarations first, then the rest in a stable order.
        for key in node.attributes.keys.sorted(by: { a, b in
            let (ax, bx) = (a.hasPrefix("xmlns"), b.hasPrefix("xmlns"))
            return ax != bx ? ax : a < b
        }) {
            output += " " + key + "=\""
            escape(node.attributes[key] ?? "", attribute: true, into: &output)
            output += "\""
        }
        if node.content.isEmpty {
            let local = node.name.lowercased()
            let selfClosing = voidElements.contains(local) || !(htmlElements.contains(local) && !node.qualifiedName.contains(":"))
            output += selfClosing ? "/>" : "></" + node.qualifiedName + ">"
            return
        }
        output += ">"
        for part in node.content { write(part, into: &output) }
        output += "</" + node.qualifiedName + ">"
    }

    private static func escape(_ string: String, attribute: Bool, into output: inout String) {
        let needsEscaping = string.utf8.contains { byte in
            byte == 38 || byte == 60 || byte == 62 || byte == 13 || (attribute && (byte == 34 || byte == 9 || byte == 10))
        }
        guard needsEscaping else { output += string; return }
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\r": output += "&#13;"
            case "\"" where attribute: output += "&quot;"
            case "\t" where attribute: output += "&#9;"
            case "\n" where attribute: output += "&#10;"
            default: output.unicodeScalars.append(scalar)
            }
        }
    }
}
