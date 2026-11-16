import Foundation

/// Builds canonical chapter text plus style runs. Every source format
/// (EPUB XHTML, tag-soup HTML, TXT, the bundled sample) goes through here, so
/// paragraph and whitespace rules are identical everywhere.
struct ChapterTextBuilder {
    static let lineSeparator = "\u{2028}"

    private(set) var text = ""
    private var length = 0
    private var styles: [TextStyleRun] = []
    private var atLineStart = true
    private var pendingSpace = false
    var italic = 0
    var bold = 0
    var heading = 0

    var isEmpty: Bool { length == 0 }

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

    mutating func lineBreak() {
        guard !isEmpty, !atLineStart else { return }
        raw(Self.lineSeparator)
        atLineStart = true
        pendingSpace = false
    }

    mutating func paragraphBreak() {
        pendingSpace = false
        guard !isEmpty else { return }
        while text.hasSuffix(Self.lineSeparator) || text.hasSuffix("\t") {
            text.removeLast()
            length -= 1
            styles = styles.compactMap { run in
                var run = run
                run.length = min(run.length, length - run.location)
                return run.length > 0 ? run : nil
            }
        }
        if !text.hasSuffix("\n") { raw("\n") }
        atLineStart = true
    }

    mutating func tab() {
        guard !atLineStart else { return }
        raw("\t")
        pendingSpace = false
    }

    func finish() -> (text: String, styles: [TextStyleRun]) {
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
        return (text, styles)
    }

    private mutating func emit(_ word: String, keepSpaces: Bool = false) {
        // A space continues runs that are already open but never starts one,
        // so "The <em>second</em>" styles "second", not " second".
        if pendingSpace && !atLineStart && !keepSpaces { raw(" ", styled: true, extendOnly: true) }
        pendingSpace = false
        atLineStart = false
        raw(word, styled: true)
    }

    private mutating func raw(_ string: String, styled: Bool = false, extendOnly: Bool = false) {
        let count = string.utf16.count
        if styled {
            for (active, style) in [(italic > 0, TextStyleRun.Style.italic), (bold > 0, .bold), (heading > 0, .heading)] where active {
                if let index = styles.lastIndex(where: { $0.style == style }), styles[index].location + styles[index].length == length {
                    styles[index].length += count
                } else if !extendOnly {
                    styles.append(TextStyleRun(location: length, length: count, style: style))
                }
            }
        }
        text += string
        length += count
    }
}

/// A forgiving scanner for HTML that strict XML parsing rejects (unclosed
/// tags, HTML entities, text/html spine items). It reads text and a handful
/// of structural tags only; it never resolves URLs or embeds resources.
enum LenientHTML {
    private static let tagPattern = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<[!?][^>]*>|<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)[^>]*>"#)
    static let hidden: Set<String> = ["script", "style", "head", "title", "iframe", "object", "embed", "svg", "math",
                                      "audio", "video", "canvas", "form", "noscript", "template", "button", "select"]
    static let blocks: Set<String> = ["p", "div", "section", "article", "aside", "header", "footer", "blockquote", "li",
                                      "ul", "ol", "dl", "dt", "dd", "table", "tr", "caption", "figure", "figcaption",
                                      "h1", "h2", "h3", "h4", "h5", "h6", "hr", "pre", "body", "nav", "main"]

    static func extract(_ html: String) throws -> (text: String, styles: [TextStyleRun]) {
        var builder = ChapterTextBuilder()
        let source = html as NSString
        let body = source.range(of: "<body", options: .caseInsensitive)
        var cursor = body.location == NSNotFound ? 0 : body.location
        var skipping: [String] = []
        var preformatted = 0
        let matches = tagPattern.matches(in: html, range: NSRange(location: cursor, length: source.length - cursor))
        for (index, match) in matches.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            if skipping.isEmpty {
                let between = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let decoded = HTMLEntities.decode(between)
                if preformatted > 0 { builder.appendPreformatted(decoded) } else { builder.append(decoded) }
            }
            cursor = NSMaxRange(match.range)
            if match.range(at: 1).location != NSNotFound, skipping.isEmpty {
                builder.append(source.substring(with: match.range(at: 1)))
                continue
            }
            guard match.range(at: 3).location != NSNotFound else { continue }
            let name = source.substring(with: match.range(at: 3)).lowercased().split(separator: ":").last.map(String.init) ?? ""
            let closing = match.range(at: 2).length > 0
            let selfClosing = source.substring(with: match.range).hasSuffix("/>")
            if let open = skipping.last {
                if closing && name == open { skipping.removeLast() }
                else if !closing && !selfClosing && name == open { skipping.append(name) }
                continue
            }
            if hidden.contains(name) {
                if !closing && !selfClosing { skipping.append(name) }
                continue
            }
            if name == "pre" { preformatted = max(0, preformatted + (closing ? -1 : 1)) }
            apply(name, closing: closing, selfClosing: selfClosing, to: &builder)
        }
        if skipping.isEmpty {
            let rest = HTMLEntities.decode(source.substring(from: min(cursor, source.length)))
            if preformatted > 0 { builder.appendPreformatted(rest) } else { builder.append(rest) }
        }
        return builder.finish()
    }

    /// Shared tag semantics for the strict and lenient paths.
    static func apply(_ name: String, closing: Bool, selfClosing: Bool = false, to builder: inout ChapterTextBuilder) {
        let delta = closing ? -1 : 1
        switch name {
        case "br": builder.lineBreak()
        case "em", "i", "cite", "var", "dfn": if !selfClosing { builder.italic = max(0, builder.italic + delta) }
        case "strong", "b": if !selfClosing { builder.bold = max(0, builder.bold + delta) }
        case "td", "th": if closing { builder.tab() }
        default:
            guard blocks.contains(name) else { return }
            builder.paragraphBreak()
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(name), !selfClosing {
                builder.heading = max(0, builder.heading + delta)
            }
        }
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
            let styles = chapter.styles.compactMap { run -> TextStyleRun? in
                let overlap = NSIntersectionRange(run.range, range)
                guard overlap.length > 0 else { return nil }
                return TextStyleRun(location: overlap.location - range.location, length: overlap.length, style: run.style)
            }
            var piece = text.substring(with: range)
            while piece.hasSuffix("\n") { piece.removeLast() }
            return ReaderChapter(id: "\(chapter.id)#\(index + 1)", title: "\(chapter.title)（\(index + 1)/\(ranges.count)）",
                                 text: piece, styles: styles.filter { NSMaxRange($0.range) <= piece.utf16.count })
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
                if offset < headingCount { builder.heading += 1 }
                for (lineIndex, line) in paragraph.components(separatedBy: ChapterTextBuilder.lineSeparator).enumerated() {
                    if lineIndex > 0 { builder.lineBreak() }
                    builder.append(line)
                }
                if offset < headingCount { builder.heading -= 1 }
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
