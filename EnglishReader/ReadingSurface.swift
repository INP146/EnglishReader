import SwiftUI
import UIKit

/// What the reader picked: a tapped word or a selected phrase, with its sentence.
/// Offsets use UTF-16 positions in ReaderChapter.text.
struct ReadingSelection: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var sentence: String
    var offset: Int
    var length: Int
    /// Where the word sits on screen, so the lookup card can avoid covering it.
    var isInLowerHalf: Bool
}

struct JumpRequest: Equatable {
    let id = UUID()
    var offset: Int
    var highlight: Bool
}

@MainActor
struct ReadingSurface: UIViewRepresentable {
    var chapter: ReaderChapter
    var layout: ReaderLayout
    var palette: ReaderPalette
    var initialOffset: Int
    var jump: JumpRequest?
    /// Saved words in this chapter, drawn with a dotted underline.
    var markedRanges: [NSRange]
    /// Points per second while auto reading; nil when not scrolling by itself.
    var autoScrollSpeed: Double?
    var onPosition: (_ offset: Int, _ fraction: Double) -> Void
    var onTapWord: (ReadingSelection) -> Void
    var onTapBlank: () -> Void
    var onScroll: () -> Void
    var onLookup: (ReadingSelection) -> Void
    var onSave: (ReadingSelection) -> Void
    /// Auto reading reached the end of the chapter.
    var onReachEnd: () -> Void = {}

    nonisolated private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:['’‐‑-][A-Za-z]+)*"#)

    nonisolated static func englishWordRanges(in string: String) -> [NSRange] {
        wordPattern.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)).map(\.range)
    }

    /// The exact string the view displays is chapter.text, so stored offsets never drift.
    static func attributedText(for chapter: ReaderChapter, size: CGFloat, layout: ReaderLayout = ReaderLayout(),
                               ink: UIColor = .readerInk) -> NSAttributedString {
        let result = NSMutableAttributedString(string: chapter.text)
        let full = NSRange(location: 0, length: result.length)
        let face = layout.typeface
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = layout.lineSpacing
        paragraph.paragraphSpacing = size * layout.paragraphSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.hyphenationFactor = 0.2
        paragraph.baseWritingDirection = .leftToRight
        result.addAttributes([.font: ReaderTypography.font(face, size: size), .foregroundColor: ink,
                              .paragraphStyle: paragraph, .accessibilitySpeechLanguage: "en-US"], range: full)
        let text = chapter.text as NSString
        for run in chapter.styles where run.location >= 0 && NSMaxRange(run.range) <= result.length {
            switch run.style {
            case .italic, .bold:
                let trait: UIFontDescriptor.SymbolicTraits = run.style == .italic ? .traitItalic : .traitBold
                result.enumerateAttribute(.font, in: run.range) { value, range, _ in
                    guard let font = value as? UIFont else { return }
                    let traits = font.fontDescriptor.symbolicTraits.union(trait).intersection([.traitItalic, .traitBold])
                    result.addAttribute(.font, value: ReaderTypography.font(face, size: font.pointSize, traits: traits), range: range)
                }
            case .heading:
                let heading = NSMutableParagraphStyle()
                heading.setParagraphStyle(paragraph)
                heading.paragraphSpacingBefore = run.location == 0 ? 0 : size
                heading.paragraphSpacing = max(size, paragraph.paragraphSpacing)
                heading.hyphenationFactor = 0
                result.addAttribute(.font, value: ReaderTypography.font(face, size: size * 1.25, traits: .traitBold), range: run.range)
                result.addAttribute(.paragraphStyle, value: heading, range: text.paragraphRange(for: run.range))
            }
        }
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReaderTextView {
        // TextKit 1 gives reliable character/glyph anchors and temporary attributes.
        let view = ReaderTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear // The backdrop behind shows paper and texture.
        view.tintColor = .readerAccent
        view.textContainer.lineFragmentPadding = 0
        // Insets follow the window, not the bars, so showing/hiding chrome never moves the text.
        view.contentInsetAdjustmentBehavior = .never
        view.dataDetectorTypes = []
        view.accessibilityIdentifier = "reading-text"
        view.accessibilityHint = "可用辅助功能操作选择单词、查词或收藏。"
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        context.coordinator.update(self, in: view)
        return view
    }

    func updateUIView(_ uiView: ReaderTextView, context: Context) {
        context.coordinator.update(self, in: uiView)
    }

    static func dismantleUIView(_ uiView: ReaderTextView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
    }

    final class ReaderTextView: UITextView {
        var didLayout: (() -> Void)?
        var willChangeWidth: (() -> Void)?
        private var laidOutWidth: CGFloat = 0

        override func layoutSubviews() {
            if laidOutWidth > 0, abs(bounds.width - laidOutWidth) > 0.5 { willChangeWidth?() }
            laidOutWidth = bounds.width
            updateWindowInsets()
            super.layoutSubviews()
            didLayout?()
        }

        private func updateWindowInsets() {
            guard let window else { return }
            let insets = UIEdgeInsets(top: window.safeAreaInsets.top, left: 0, bottom: window.safeAreaInsets.bottom, right: 0)
            guard insets != contentInset else { return }
            let shift = insets.top - contentInset.top
            contentInset = insets
            verticalScrollIndicatorInsets = insets
            contentOffset.y -= shift
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        private var parent: ReadingSurface
        private weak var textView: ReaderTextView?
        private var renderedChapterID: String?
        private var renderedStyle: (size: CGFloat, layout: ReaderLayout, palette: ReaderPalette)?
        private var wordRanges: [NSRange] = []
        private var marked: [NSRange] = []
        private var pendingAnchor: Int?
        private var pendingHighlight: Int?
        private var lastVisibleOffset = 0
        private var lastReported: (offset: Int, fraction: Double)?
        private var lastJumpID: UUID?
        private var restoring = false
        private var positionScheduled = false
        private var tapFilter = TapFilter()
        private let flash = WordFlash()
        private var displayLink: CADisplayLink?
        private var lastTick: CFTimeInterval?
        private var autoScrollCarry: CGFloat = 0
        private var reachedEnd = false

        init(_ parent: ReadingSurface) { self.parent = parent }

        func attach(to view: ReaderTextView) {
            textView = view
            view.didLayout = { [weak self, weak view] in
                guard let self, let view, self.textView === view else { return }
                self.finishLayout()
            }
            view.willChangeWidth = { [weak self, weak view] in
                guard let self, let view, self.textView === view, self.pendingAnchor == nil else { return }
                self.pendingAnchor = self.lastVisibleOffset
            }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            view.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "选择下一个单词", target: self, selector: #selector(selectNextWord)),
                UIAccessibilityCustomAction(name: "选择上一个单词", target: self, selector: #selector(selectPreviousWord)),
                UIAccessibilityCustomAction(name: "查词", target: self, selector: #selector(accessibleLookup)),
                UIAccessibilityCustomAction(name: "收藏", target: self, selector: #selector(accessibleSave))
            ]
        }

        func detach(from view: ReaderTextView) {
            guard textView === view else { return } // A superseded view must not clear the current one.
            flash.cancel()
            stopAutoScroll()
            view.delegate = nil
            view.didLayout = nil
            view.willChangeWidth = nil
            textView = nil
        }

        func update(_ value: ReadingSurface, in view: ReaderTextView) {
            parent = value // Refresh callbacks even when the document is unchanged.
            let size = ReaderTypography.pointSize(value.layout.fontSize)
            let chapterChanged = renderedChapterID != value.chapter.id
            let styleChanged = renderedStyle.map { $0.size != size || $0.layout != value.layout || $0.palette != value.palette } ?? true
            if chapterChanged || styleChanged {
                let anchor = pendingAnchor ?? (chapterChanged ? value.initialOffset : visibleOffset(in: view))
                let margin = value.layout.margin
                view.textContainerInset = UIEdgeInsets(top: 24, left: margin, bottom: 96, right: margin)
                view.attributedText = ReadingSurface.attributedText(for: value.chapter, size: size, layout: value.layout,
                                                                    ink: value.palette.ink)
                if chapterChanged {
                    wordRanges = ReadingSurface.englishWordRanges(in: value.chapter.text)
                    lastReported = nil
                    lastVisibleOffset = max(0, value.initialOffset)
                }
                renderedChapterID = value.chapter.id
                renderedStyle = (size, value.layout, value.palette)
                marked = []
                flash.forget()
                pendingAnchor = anchor
                view.setNeedsLayout()
            }
            if marked != value.markedRanges {
                ReaderTextTools.applyMarks(value.markedRanges, replacing: marked, in: view.textStorage)
                marked = value.markedRanges
            }
            if let jump = value.jump, jump.id != lastJumpID {
                lastJumpID = jump.id
                pendingAnchor = jump.offset
                pendingHighlight = jump.highlight ? jump.offset : nil
                view.setNeedsLayout()
            }
            if value.autoScrollSpeed != nil { startAutoScroll() } else { stopAutoScroll() }
        }

        // MARK: Layout and position

        private func finishLayout() {
            guard !restoring, let view = textView, view.bounds.width > 1, view.bounds.height > 1 else { return }
            if let anchor = pendingAnchor {
                restoring = true
                pendingAnchor = nil
                let length = view.textStorage.length
                if length > 0 {
                    let offset = min(max(0, anchor), length - 1)
                    let manager = view.layoutManager
                    manager.ensureLayout(for: view.textContainer) // Chapters are bounded by ChapterLayout.maximumLength.
                    let glyph = manager.glyphIndexForCharacter(at: offset)
                    let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let y = rect.minY + view.textContainerInset.top - view.adjustedContentInset.top - 16
                    view.setContentOffset(CGPoint(x: 0, y: min(maximumY(in: view), max(minimumY(in: view), y))), animated: false)
                }
                restoring = false
                if let offset = pendingHighlight {
                    pendingHighlight = nil
                    let range = ReaderTextTools.wordRange(containing: offset, in: wordRanges)
                        ?? NSRange(location: min(offset, max(0, length - 1)), length: length > 0 ? 1 : 0)
                    flash.show(range, in: view.textStorage)
                }
            }
            schedulePositionReport()
        }

        private func minimumY(in view: UIScrollView) -> CGFloat { -view.adjustedContentInset.top }

        private func maximumY(in view: UIScrollView) -> CGFloat {
            max(minimumY(in: view), view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        }

        private func visibleOffset(in view: UITextView) -> Int {
            guard view.textStorage.length > 0, view.bounds.width > 1 else { return 0 }
            let manager = view.layoutManager
            let y = max(0, view.contentOffset.y + view.adjustedContentInset.top + 16 - view.textContainerInset.top)
            let glyph = manager.glyphIndex(for: CGPoint(x: 0, y: y), in: view.textContainer)
            guard glyph < manager.numberOfGlyphs else { return max(0, view.textStorage.length - 1) }
            var line = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            return manager.characterIndexForGlyph(at: line.location)
        }

        private func fraction(in view: UITextView) -> Double {
            let scrollable = view.contentSize.height + view.adjustedContentInset.top + view.adjustedContentInset.bottom - view.bounds.height
            guard scrollable > 1 else { return 1 }
            return min(1, max(0, (view.contentOffset.y + view.adjustedContentInset.top) / scrollable))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !restoring, pendingAnchor == nil, let view = textView else { return }
            lastVisibleOffset = visibleOffset(in: view)
            schedulePositionReport()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onScroll()
        }

        private func schedulePositionReport() {
            guard !positionScheduled else { return }
            positionScheduled = true
            // Coalesce scrolling and never change SwiftUI state inside updateUIView.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.positionScheduled = false
                guard self.pendingAnchor == nil, let view = self.textView else { return }
                let offset = self.visibleOffset(in: view)
                let fraction = (self.fraction(in: view) * 100).rounded() / 100
                self.lastVisibleOffset = offset
                guard self.lastReported?.offset != offset || self.lastReported?.fraction != fraction else { return }
                self.lastReported = (offset, fraction)
                self.parent.onPosition(offset, fraction)
            }
        }

        // MARK: Auto reading

        private func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = nil
            reachedEnd = false
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick(_ link: CADisplayLink) {
            defer { lastTick = link.timestamp }
            guard let view = textView, let speed = parent.autoScrollSpeed, let last = lastTick,
                  !view.isDragging, !view.isDecelerating, pendingAnchor == nil else { return }
            // Whole pixels only, so text never renders between pixel rows.
            let scale = view.traitCollection.displayScale
            autoScrollCarry += CGFloat(speed * (link.timestamp - last)) * scale
            let step = autoScrollCarry.rounded(.down)
            guard step >= 1 else { return }
            autoScrollCarry -= step
            let limit = maximumY(in: view)
            if view.contentOffset.y >= limit - 0.5 {
                guard !reachedEnd else { return }
                reachedEnd = true
                parent.onReachEnd()
                return
            }
            view.contentOffset.y = min(limit, view.contentOffset.y + step / scale)
        }

        // MARK: Tapping

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = textView else { return false }
            tapFilter.began(touch, in: view)
            // A tap that stops a fling is not a lookup.
            return !view.isDragging && !view.isDecelerating && !UIAccessibility.isVoiceOverRunning
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true // UITextView's own selection recognizers keep working.
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = textView, tapFilter.isQuickTap(in: view) else { return }
            if let range = ReaderTextTools.wordRange(at: gesture.location(in: view), in: view, words: wordRanges),
               let selection = ReaderTextTools.selection(for: range, in: view) {
                flash.show(range, in: view.textStorage)
                parent.onTapWord(selection)
            } else {
                parent.onTapBlank()
            }
        }

        // Native long-press selection handles and Copy remain intact; the menu adds lookup and save.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            ReaderTextTools.editMenu(for: range, in: textView, suggestedActions: suggestedActions,
                                     onLookup: { [weak self] in self?.parent.onLookup($0) },
                                     onSave: { [weak self] in self?.parent.onSave($0) })
        }

        // MARK: Accessibility

        private func accessibleSelection() -> ReadingSelection? {
            guard let view = textView else { return nil }
            if view.selectedRange.length > 0 { return ReaderTextTools.selection(for: view.selectedRange, in: view) }
            let offset = visibleOffset(in: view)
            guard let range = ReaderTextTools.wordRange(containing: offset, in: wordRanges)
                    ?? wordRanges.first(where: { $0.location >= offset }) else { return nil }
            return ReaderTextTools.selection(for: range, in: view)
        }

        @objc private func accessibleLookup() -> Bool {
            guard let value = accessibleSelection() else { return false }
            parent.onLookup(value)
            return true
        }

        @objc private func accessibleSave() -> Bool {
            guard let value = accessibleSelection() else { return false }
            parent.onSave(value)
            return true
        }

        @objc private func selectNextWord() -> Bool { moveAccessibleSelection(forward: true) }
        @objc private func selectPreviousWord() -> Bool { moveAccessibleSelection(forward: false) }

        private func moveAccessibleSelection(forward: Bool) -> Bool {
            guard let view = textView else { return false }
            let selected = view.selectedRange
            let start = selected.length > 0 ? selected.location : visibleOffset(in: view)
            let range = forward
                ? wordRanges.first { $0.location >= (selected.length > 0 ? NSMaxRange(selected) : start) }
                : wordRanges.last { $0.location < start }
            guard let range, let value = ReaderTextTools.selection(for: range, in: view) else { return false }
            view.selectedRange = range
            view.scrollRangeToVisible(range)
            UIAccessibility.post(notification: .announcement, argument: value.text)
            return true
        }
    }
}

// MARK: - Shared by the scrolling and paged surfaces

/// Hit-testing, sentence context and the edit menu work the same on any text
/// view whose storage holds the whole chapter text.
@MainActor
enum ReaderTextTools {
    static func wordRange(at location: CGPoint, in view: UITextView, words: [NSRange]) -> NSRange? {
        guard view.textStorage.length > 0 else { return nil }
        let point = CGPoint(x: location.x - view.textContainerInset.left, y: location.y - view.textContainerInset.top)
        let manager = view.layoutManager
        let glyph = manager.glyphIndex(for: point, in: view.textContainer)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer)
        // Margins, paragraph gaps and space below the last line are not words.
        guard rect.insetBy(dx: -3, dy: -2).contains(point) else { return nil }
        return wordRange(containing: manager.characterIndexForGlyph(at: glyph), in: words)
    }

    static func wordRange(containing offset: Int, in words: [NSRange]) -> NSRange? {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            let range = words[middle]
            if offset < range.location { high = middle }
            else if offset >= NSMaxRange(range) { low = middle + 1 }
            else { return range }
        }
        return nil
    }

    static func selection(for proposedRange: NSRange, in view: UITextView) -> ReadingSelection? {
        let string = view.textStorage.string as NSString
        guard proposedRange.location != NSNotFound, proposedRange.length > 0, NSMaxRange(proposedRange) <= string.length else { return nil }
        let raw = string.substring(with: proposedRange)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let leading = (raw as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location
        let range = NSRange(location: proposedRange.location + leading, length: (trimmed as NSString).length)
        // Sentence boundaries are searched within the paragraph only.
        let paragraphRange = string.paragraphRange(for: range)
        let paragraph = string.substring(with: paragraphRange)
        var context: NSRange?
        paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: [.bySentences, .substringNotRequired]) { _, substringRange, _, stop in
            let local = NSRange(substringRange, in: paragraph)
            let sentence = NSRange(location: local.location + paragraphRange.location, length: local.length)
            if NSIntersectionRange(sentence, range).length > 0 {
                context = context.map { NSUnionRange($0, sentence) } ?? sentence
            }
            if sentence.location >= NSMaxRange(range) { stop = true }
        }
        let sentence = string.substring(with: context ?? paragraphRange)
            .replacingOccurrences(of: ChapterTextBuilder.lineSeparator, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let glyphs = view.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
            .offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
        let onScreen = view.convert(rect, to: nil)
        let height = view.window?.bounds.height ?? view.bounds.height
        return ReadingSelection(text: trimmed, sentence: sentence, offset: range.location, length: range.length,
                                isInLowerHalf: onScreen.midY > height * 0.5)
    }

    static func editMenu(for range: NSRange, in view: UITextView, suggestedActions: [UIMenuElement],
                         onLookup: @escaping (ReadingSelection) -> Void, onSave: @escaping (ReadingSelection) -> Void) -> UIMenu? {
        guard selection(for: range, in: view) != nil else { return nil }
        let lookup = UIAction(title: "查词", image: UIImage(systemName: "character.book.closed")) { [weak view] _ in
            guard let view, let value = selection(for: range, in: view) else { return }
            onLookup(value)
        }
        let save = UIAction(title: "收藏", image: UIImage(systemName: "bookmark")) { [weak view] _ in
            guard let view, let value = selection(for: range, in: view) else { return }
            onSave(value)
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: [lookup, save])] + suggestedActions)
    }

    /// Attribute-only edits; the string never changes.
    static func applyMarks(_ ranges: [NSRange], replacing old: [NSRange], in storage: NSTextStorage) {
        let length = storage.length
        storage.beginEditing()
        for range in old where NSMaxRange(range) <= length {
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.underlineColor, range: range)
        }
        for range in ranges where NSMaxRange(range) <= length {
            storage.addAttributes([.underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                                   .underlineColor: UIColor.readerAccent], range: range)
        }
        storage.endEditing()
    }
}

/// Separates a quick tap from a press that became a native selection, or a tap that dismisses one.
@MainActor
struct TapFilter {
    private var beganAt: TimeInterval = 0
    private var beganWithSelection = false

    mutating func began(_ touch: UITouch, in view: UITextView) {
        beganAt = touch.timestamp
        beganWithSelection = view.selectedRange.length > 0
    }

    func isQuickTap(in view: UITextView) -> Bool {
        !beganWithSelection && ProcessInfo.processInfo.systemUptime - beganAt < 0.35 && view.selectedRange.length == 0
    }
}

/// Briefly highlights a tapped or jumped-to word.
@MainActor
final class WordFlash {
    private var range: NSRange?
    private weak var storage: NSTextStorage?
    private var task: Task<Void, Never>?

    func show(_ range: NSRange, in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length else { return }
        cancel()
        self.range = range
        self.storage = storage
        storage.addAttribute(.backgroundColor, value: UIColor.readerHighlight, range: range)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    /// Removes the highlight now.
    func cancel() {
        task?.cancel()
        task = nil
        if let range, let storage, NSMaxRange(range) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        forget()
    }

    /// The text was replaced, so the old range no longer means anything.
    func forget() {
        range = nil
        storage = nil
    }
}
