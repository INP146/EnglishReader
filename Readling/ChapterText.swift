import Foundation

/// Builds canonical chapter text plus style runs. Every source format
/// (EPUB XHTML, tag-soup HTML, TXT, the bundled sample) goes through here, so
/// paragraph and whitespace rules are identical everywhere.
struct ChapterTextBuilder {
    static let lineSeparator = "\u{2028}"
    /// Stands for an inline image; a style run names the image itself.
    static let attachment = "\u{FFFC}"

    private struct StyleKey: Hashable {
        var style: TextStyleRun.Style
        var value: String?
    }

    private(set) var text = ""
    private var length = 0
    private var styles: [TextStyleRun] = []
    /// Index of the latest run for each open style, so a run can grow instead of restarting.
    private var lastRun: [StyleKey: Int] = [:]
    private var open: [StyleKey] = []
    private var atLineStart = true
    private var pendingSpace = false
    /// Ids waiting for the next character, which is where they point.
    private var pendingAnchors: [String] = []
    private var anchors: [String: Int] = [:]

    var isEmpty: Bool { length == 0 }

    /// Everything emitted until the matching `pop` carries this style.
    mutating func push(_ style: TextStyleRun.Style, value: String? = nil) {
        open.append(StyleKey(style: style, value: value))
    }

    mutating func pop(_ style: TextStyleRun.Style, value: String? = nil) {
        if let index = open.lastIndex(of: StyleKey(style: style, value: value)) { open.remove(at: index) }
    }

    /// Marks where an element with this id starts. The first definition of an id wins.
    mutating func anchor(_ id: String) {
        guard anchors[id] == nil, !pendingAnchors.contains(id) else { return }
        pendingAnchors.append(id)
    }

    /// Appends inline text, collapsing whitespace runs to one space.
    mutating func append(_ raw: String) {
        var word = ""
        for character in raw {
            if character.isWhitespace && character != "\u{00A0}" {
                if !word.isEmpty { emit(word); word = "" }
                pendingSpace = true
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { emit(word) }
    }

    /// Appends preformatted text, keeping spaces and turning newlines into line breaks.
    mutating func appendPreformatted(_ raw: String) {
        for (index, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { lineBreak() }
            if !line.isEmpty { emit(String(line), keepSpaces: true) }
        }
    }

    /// An image takes one character, like a very large word.
    mutating func image(file: String, alt: String?) {
        if pendingSpace && !atLineStart { raw(" ", styled: true, extendOnly: true) }
        pendingSpace = false
        atLineStart = false
        resolveAnchors()
        let start = length
        raw(Self.attachment, styled: true)
        // Images never merge with their neighbours, so each gets a run of its own.
        styles.append(TextStyleRun(location: start, length: 1, style: .image, value: file, alt: alt))
    }

    /// A list item's bullet or number. The item's text follows it directly.
    mutating func marker(_ string: String) {
        pendingSpace = false
        atLineStart = false
        resolveAnchors()
        raw(string, styled: true)
        atLineStart = true
    }

    mutating func lineBreak() {
        guard !isEmpty, !atLineStart else { return }
        raw(Self.lineSeparator)
        atLineStart = true
        pendingSpace = false
    }

    mutating func paragraphBreak() {
        pendingSpace = false
        guard !isEmpty else { return }
        var trimmed = false
        while text.hasSuffix(Self.lineSeparator) || text.hasSuffix("\t") {
            text.removeLast()
            length -= 1
            trimmed = true
        }
        if trimmed {
            while let last = styles.last, last.location >= length { styles.removeLast() }
            if let last = styles.last, last.location + last.length > length { styles[styles.count - 1].length = length - last.location }
        }
        if !text.hasSuffix("\n") { raw("\n") }
        atLineStart = true
    }

    mutating func tab() {
        guard !atLineStart else { return }
        raw("\t")
        pendingSpace = false
    }

    func finish() -> (text: String, styles: [TextStyleRun], anchors: [String: Int]) {
        var text = text
        var length = length
        while let last = text.last, last == "\n" || last == "\u{2028}" || last == "\t" {
            text.removeLast()
            length -= 1
        }
        let styles = styles.compactMap { run -> TextStyleRun? in
            var run = run
            run.length = min(run.length, length - run.location)
            return run.length > 0 ? run : nil
        }
        var anchors = anchors
        for id in pendingAnchors where anchors[id] == nil { anchors[id] = length }
        return (text, styles, anchors.mapValues { min($0, length) })
    }

    private mutating func emit(_ word: String, keepSpaces: Bool = false) {
        // A space continues runs that are already open but never starts one,
        // so "The <em>second</em>" styles "second", not " second".
        if pendingSpace && !atLineStart && !keepSpaces { raw(" ", styled: true, extendOnly: true) }
        pendingSpace = false
        atLineStart = false
        resolveAnchors()
        raw(word, styled: true)
    }

    private mutating func resolveAnchors() {
        guard !pendingAnchors.isEmpty else { return }
        for id in pendingAnchors where anchors[id] == nil { anchors[id] = length }
        pendingAnchors.removeAll()
    }

    private mutating func raw(_ string: String, styled: Bool = false, extendOnly: Bool = false) {
        let count = string.utf16.count
        if styled {
            for index in open.indices where !open[..<index].contains(open[index]) {
                let key = open[index]
                if let last = lastRun[key], last < styles.count, styles[last].style == key.style, styles[last].value == key.value,
                   styles[last].location + styles[last].length == length {
                    styles[last].length += count
                } else if !extendOnly {
                    lastRun[key] = styles.count
                    styles.append(TextStyleRun(location: length, length: count, style: key.style, value: key.value))
                }
            }
        }
        text += string
        length += count
    }
}

/// Turns HTML elements into text and styles. The strict (XML tree) and lenient
/// (tag soup) readers both drive it, so an element means the same thing in both.
/// It copies text, a few structural tags, links and image references; the rest
/// of a document is kept elsewhere (see `BookPackage`), not drawn.
struct ChapterRenderer {
    struct Context {
        /// Package path of the document being read; links and images are relative to it.
        var documentPath = ""
        /// Stored file name of the image at a package path, if the book has one this app can draw.
        var imageFile: (String) -> String? = { _ in nil }
        /// A reference relative to a package path, resolved to a package path; nil when it is unusable.
        var resolve: (_ reference: String, _ base: String) -> String? = { _, _ in nil }
    }

    static let hidden: Set<String> = ["script", "style", "head", "title", "iframe", "object", "embed", "svg", "math",
                                      "audio", "video", "canvas", "form", "noscript", "template", "button", "select"]
    static let blocks: Set<String> = ["p", "div", "section", "article", "aside", "header", "footer", "blockquote", "li",
                                      "ul", "ol", "dl", "dt", "dd", "table", "tr", "caption", "figure", "figcaption",
                                      "h1", "h2", "h3", "h4", "h5", "h6", "hr", "pre", "body", "nav", "main",
                                      "center", "address", "details", "summary"]

    private(set) var builder = ChapterTextBuilder()
    private let context: Context
    private var elements: [Open] = []
    private var lists: [(ordered: Bool, counter: Int)] = []
    private var preformatted = 0

    private struct Open {
        var name: String
        var pushed: [(style: TextStyleRun.Style, value: String?)] = []
        var isList = false
        var isPre = false
    }

    init(context: Context = Context()) { self.context = context }

    /// Opens an element. Returns false when it and everything inside it stay out of the
    /// text; the caller then skips the content and does not call `leave`.
    mutating func enter(_ rawName: String, _ attributes: [String: String] = [:]) -> Bool {
        let name = rawName.lowercased()
        let css = Self.declarations(attributes["style"])
        if Self.hidden.contains(name) || attributes["hidden"] != nil || css["display"] == "none" { return false }
        var element = Open(name: name)
        if let id = attributes["id"] ?? (name == "a" ? attributes["name"] : nil), !id.isEmpty { builder.anchor(id) }
        if Self.blocks.contains(name) { builder.paragraphBreak() }
        switch name {
        case "br": builder.lineBreak()
        case "img": image(attributes)
        case "em", "i", "cite", "var", "dfn": push(.italic, into: &element)
        case "strong", "b": push(.bold, into: &element)
        case "sup": push(.sup, into: &element)
        case "sub": push(.sub, into: &element)
        case "code", "kbd", "samp", "tt": push(.code, into: &element)
        case "s", "strike", "del": push(.strike, into: &element)
        case "pre":
            push(.code, into: &element)
            preformatted += 1
            element.isPre = true
        case "h1", "h2", "h3", "h4", "h5", "h6": push(.heading, value: String(name.dropFirst()), into: &element)
        case "blockquote", "dd": push(.quote, into: &element)
        case "center": push(.center, into: &element)
        case "ul", "ol":
            lists.append((name == "ol", (attributes["start"].flatMap { Int($0) } ?? 1) - 1))
            element.isList = true
        case "li":
            push(.list, into: &element)
            let marker = listMarker(value: attributes["value"].flatMap { Int($0) })
            builder.marker(marker)
        case "a":
            if let target = link(attributes) { push(.link, value: target, into: &element) }
        default: break
        }
        // Inline CSS and the old align attribute cover most of what books say about emphasis and alignment.
        if css["font-style"] == "italic" || css["font-style"] == "oblique" { push(.italic, into: &element) }
        if let weight = css["font-weight"], weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600 { push(.bold, into: &element) }
        if css["vertical-align"] == "super" { push(.sup, into: &element) }
        if css["vertical-align"] == "sub" { push(.sub, into: &element) }
        if Self.blocks.contains(name), name != "center", css["text-align"] == "center" || attributes["align"]?.lowercased() == "center" {
            push(.center, into: &element)
        }
        elements.append(element)
        return true
    }

    /// Closes the nearest open element with this name, and any left open inside it.
    mutating func leave(_ rawName: String) {
        let name = rawName.lowercased()
        guard let index = elements.lastIndex(where: { $0.name == name }) else { return }
        while elements.count > index { close(elements.removeLast()) }
    }

    mutating func text(_ string: String) {
        if preformatted > 0 { builder.appendPreformatted(string) } else { builder.append(string) }
    }

    /// A picture the document draws without an `img` element, such as a cover inside an `svg`.
    mutating func image(reference: String, alt: String?) {
        guard let path = context.resolve(reference, context.documentPath), let file = context.imageFile(path) else { return }
        builder.image(file: file, alt: alt?.isEmpty == false ? alt : nil)
    }

    func finish() -> (text: String, styles: [TextStyleRun], anchors: [String: Int]) { builder.finish() }

    // MARK: Elements

    private mutating func push(_ style: TextStyleRun.Style, value: String? = nil, into element: inout Open) {
        element.pushed.append((style, value))
        builder.push(style, value: value)
    }

    private mutating func close(_ element: Open) {
        for (style, value) in element.pushed.reversed() { builder.pop(style, value: value) }
        if element.isPre { preformatted = max(0, preformatted - 1) }
        if element.isList, !lists.isEmpty { lists.removeLast() }
        if Self.blocks.contains(element.name) { builder.paragraphBreak() }
        if element.name == "td" || element.name == "th" { builder.tab() }
    }

    private mutating func image(_ attributes: [String: String]) {
        guard let source = attributes["src"] else { return }
        image(reference: source, alt: attributes["alt"])
    }

    private mutating func listMarker(value: Int?) -> String {
        guard !lists.isEmpty else { return "•\u{00A0}" }
        let last = lists.count - 1
        if let value { lists[last].counter = value - 1 }
        lists[last].counter += 1
        if lists[last].ordered { return "\(lists[last].counter).\u{00A0}" }
        return (lists.count == 1 ? "•" : lists.count == 2 ? "◦" : "▪") + "\u{00A0}"
    }

    /// The target of a link: a web address, or "package/path.xhtml#id" for somewhere in the book.
    private func link(_ attributes: [String: String]) -> String? {
        guard let href = attributes["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else { return nil }
        if let scheme = href.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) {
            return ["http", "https", "mailto"].contains(href[scheme].dropLast().lowercased()) ? href : nil
        }
        guard let path = context.resolve(href, context.documentPath) else { return nil }
        guard let hash = href.firstIndex(of: "#") else { return path }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? path : "\(path)#\(fragment.removingPercentEncoding ?? fragment)"
    }

    /// `font-style: italic; text-align: center` as ["font-style": "italic", …], values lowercased.
    private static func declarations(_ style: String?) -> [String: String] {
        guard let style, style.contains(":") else { return [:] }
        var result: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return result
    }
}

/// A forgiving scanner for HTML that strict XML parsing rejects (unclosed
/// tags, HTML entities, text/html spine items). It never resolves URLs or
/// embeds resources.
enum LenientHTML {
    private static let tagPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<[!?][^>]*>|<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)[^>]*>"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)
    /// Elements HTML writes without a closing tag.
    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                                    "param", "source", "track", "wbr"]

    static func extract(_ html: String, context: ChapterRenderer.Context = .init()) throws -> (text: String, styles: [TextStyleRun], anchors: [String: Int]) {
        var renderer = ChapterRenderer(context: context)
        let source = html as NSString
        let body = source.range(of: "<body", options: .caseInsensitive)
        var cursor = body.location == NSNotFound ? 0 : body.location
        var skipping: [String] = []
        let matches = tagPattern.matches(in: html, range: NSRange(location: cursor, length: source.length - cursor))
        for (index, match) in matches.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            if skipping.isEmpty {
                renderer.text(HTMLEntities.decode(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            cursor = NSMaxRange(match.range)
            if match.range(at: 1).location != NSNotFound, skipping.isEmpty {
                renderer.text(source.substring(with: match.range(at: 1)))
                continue
            }
            guard match.range(at: 3).location != NSNotFound else { continue }
            let name = source.substring(with: match.range(at: 3)).lowercased().split(separator: ":").last.map(String.init) ?? ""
            let closing = match.range(at: 2).length > 0
            let tag = source.substring(with: match.range)
            let selfClosing = tag.hasSuffix("/>") || voidElements.contains(name)
            if let open = skipping.last {
                if closing && name == open { skipping.removeLast() }
                else if !closing && !selfClosing && name == open { skipping.append(name) }
                continue
            }
            if closing {
                renderer.leave(name)
            } else if renderer.enter(name, attributes(in: tag)) {
                if selfClosing { renderer.leave(name) }
            } else if !selfClosing {
                skipping.append(name)
            }
        }
        if skipping.isEmpty {
            renderer.text(HTMLEntities.decode(source.substring(from: min(cursor, source.length))))
        }
        return renderer.finish()
    }

    /// Attributes of an opening tag, names lowercased, values with entities decoded.
    private static func attributes(in tag: String) -> [String: String] {
        guard tag.contains("="), let nameEnd = tag.firstIndex(where: { $0.isWhitespace }) else { return [:] }
        let rest = String(tag[nameEnd...]) as NSString
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
            let key = rest.substring(with: match.range(at: 1)).lowercased()
            let value = [2, 3, 4].map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { rest.substring(with: $0) } ?? key
            result[key] = HTMLEntities.decode(value)
        }
        return result
    }
}

enum ChapterLayout {
    /// TextKit lays out a whole chapter at once; keep each piece comfortably small.
    static let maximumLength = 60_000

    /// Splits long chapters at paragraph boundaries, keeping style runs aligned.
    static func split(_ chapter: ReaderChapter, maximumLength: Int = maximumLength) -> [ReaderChapter] {
        let text = chapter.text as NSString
        guard text.length > maximumLength else { return [chapter] }
        var ranges: [NSRange] = []
        var start = 0
        while start < text.length {
            var end = min(text.length, start + maximumLength)
            if end < text.length {
                let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: start, length: end - start))
                if newline.location != NSNotFound, newline.location > start + maximumLength / 3 {
                    end = newline.location + 1
                } else {
                    let space = text.range(of: " ", options: .backwards, range: NSRange(location: start, length: end - start))
                    if space.location != NSNotFound, space.location > start { end = space.location + 1 }
                }
                end = text.rangeOfComposedCharacterSequence(at: end - 1).upperBound
            }
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        return ranges.enumerated().map { index, range in
            var piece = text.substring(with: range)
            while piece.hasSuffix("\n") { piece.removeLast() }
            let length = piece.utf16.count
            let styles = chapter.styles.compactMap { run -> TextStyleRun? in
                let overlap = NSIntersectionRange(run.range, range)
                guard overlap.length > 0 else { return nil }
                var part = run
                part.location = overlap.location - range.location
                part.length = overlap.length
                return part
            }
            // An anchor belongs to the piece that holds its first character.
            let anchors = chapter.anchors.compactMapValues { offset -> Int? in
                let last = index == ranges.count - 1
                guard offset >= range.location, offset < NSMaxRange(range) || (last && offset == NSMaxRange(range)) else { return nil }
                return min(offset - range.location, length)
            }
            return ReaderChapter(id: "\(chapter.id)#\(index + 1)", title: "\(chapter.title)（\(index + 1)/\(ranges.count)）",
                                 text: piece, styles: styles.filter { NSMaxRange($0.range) <= length },
                                 source: chapter.source, anchors: anchors)
        }
    }
}

enum PlainTextLayout {
    private static let chapterHeading = try! NSRegularExpression(
        pattern: #"^(chapter|book|part|letter|stave|canto|volume)\s+([0-9]+|[ivxlcdm]+|(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(-[a-z]+)?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|first|second|third|fourth|fifth|last)\b[.:]?.{0,60}$"#,
        options: [.caseInsensitive])

    static func chapters(from source: String) throws -> [ReaderChapter] {
        let text = stripGutenbergBoilerplate(source)
        let paragraphs = try self.paragraphs(text)
        guard !paragraphs.isEmpty else { return [] }

        // Chapter headings such as "CHAPTER I." with an optional short subtitle line.
        // A table of contents is one long block of heading-like lines, so headings
        // are limited to a line or two.
        var starts: [(index: Int, title: String, paragraphs: Int)] = []
        for (index, paragraph) in paragraphs.enumerated() where paragraph.utf16.count <= 120 {
            let lines = paragraph.components(separatedBy: ChapterTextBuilder.lineSeparator).map(cleanLabel)
            guard lines.count <= 2, let first = lines.first,
                  chapterHeading.firstMatch(in: first, range: NSRange(location: 0, length: first.utf16.count)) != nil else { continue }
            var title = lines.joined(separator: " · ")
            var used = 1
            if lines.count == 1, index + 1 < paragraphs.count {
                let next = paragraphs[index + 1]
                if next.count <= 60, !next.contains(ChapterTextBuilder.lineSeparator),
                   next.rangeOfCharacter(from: CharacterSet(charactersIn: ",;?!“”\"")) == nil {
                    title += " · " + cleanLabel(next)
                    used = 2
                }
            }
            starts.append((index, title, used))
        }

        var chapters: [ReaderChapter] = []
        func make(_ slice: ArraySlice<String>, title: String, headingCount: Int) {
            var builder = ChapterTextBuilder()
            for (offset, paragraph) in slice.enumerated() {
                if offset < headingCount { builder.push(.heading) }
                for (lineIndex, line) in paragraph.components(separatedBy: ChapterTextBuilder.lineSeparator).enumerated() {
                    if lineIndex > 0 { builder.lineBreak() }
                    builder.append(line)
                }
                if offset < headingCount { builder.pop(.heading) }
                builder.paragraphBreak()
            }
            let result = builder.finish()
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            chapters.append(ReaderChapter(id: "text-\(chapters.count + 1)", title: title, text: result.text, styles: result.styles))
        }

        if starts.count >= 2 {
            if starts[0].index > 0 {
                let opening = paragraphs[..<starts[0].index]
                if opening.reduce(0, { $0 + $1.count }) > 200 { make(opening, title: "开篇", headingCount: 0) }
            }
            for (number, start) in starts.enumerated() {
                let end = number + 1 < starts.count ? starts[number + 1].index : paragraphs.count
                make(paragraphs[start.index..<end], title: start.title, headingCount: start.paragraphs)
            }
        } else {
            make(paragraphs[...], title: "正文", headingCount: 0)
        }
        let split = chapters.flatMap { ChapterLayout.split($0) }
        // Untitled long text reads better as numbered parts than "正文（3/12）".
        if starts.count < 2 && split.count > 1 {
            return split.enumerated().map { index, chapter in
                var chapter = chapter
                chapter.title = "第 \(index + 1) 部分"
                return chapter
            }
        }
        return split
    }

    /// Hard-wrapped files (Project Gutenberg) separate paragraphs with blank
    /// lines; others use one paragraph per line. Short wrapped lines are verse.
    static func paragraphs(_ text: String) throws -> [String] {
        let lines = text.components(separatedBy: "\n")
        let blank = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let hardWrapped = blank * 6 >= lines.count && lines.count > 3
        guard hardWrapped else {
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var result: [String] = []
        var block: [String] = []
        func flush() {
            guard !block.isEmpty else { return }
            let verse = block.count > 1 && block.allSatisfy { $0.count < 48 }
                || block.contains { $0.hasPrefix("  ") }
            let trimmed = block.map { $0.trimmingCharacters(in: .whitespaces) }
            result.append(trimmed.joined(separator: verse ? ChapterTextBuilder.lineSeparator : " "))
            block = []
        }
        for (index, line) in lines.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(line) }
        }
        flush()
        return result
    }

    static func cleanLabel(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    static func stripGutenbergBoilerplate(_ text: String) -> String {
        var result = text
        if let start = result.range(of: "*** START OF", options: .caseInsensitive),
           let lineEnd = result[start.upperBound...].firstIndex(of: "\n") {
            result = String(result[result.index(after: lineEnd)...])
        }
        if let end = result.range(of: "*** END OF", options: [.caseInsensitive, .backwards]) {
            result = String(result[..<end.lowerBound])
        }
        return result
    }
}
