import SwiftUI
import UIKit

/// Page-by-page reading. One layout manager lays a whole chapter into a
/// chain of page-sized text containers; each page's text view shows one
/// container, so offsets, hit-testing and the edit menu use the same chapter
/// coordinates as the scrolling surface. The neighbouring chapters are laid
/// out too, so turning across a chapter boundary is an ordinary page turn.
@MainActor
struct PagedSurface: UIViewControllerRepresentable {
    var chapter: ReaderChapter
    /// Zero-based, for the "chapter n of m" footer.
    var chapterIndex: Int
    var chapterCount: Int
    var previousChapter: ReaderChapter?
    var nextChapter: ReaderChapter?
    var layout: ReaderLayout
    var palette: ReaderPalette
    var backdrop: ReaderBackdrop
    var backdropVersion: Int
    var turn: PageTurn
    var initialOffset: Int
    var jump: JumpRequest?
    /// Words still being learned; every occurrence gets a dotted underline.
    var learningForms: Set<String>
    /// True while the lookup card is up; the looked-up word stays highlighted until it closes.
    var lookingUp: Bool
    /// False while the toolbars are up: taps only dismiss them, and words can't be looked up or selected.
    var interactive: Bool
    /// While the lookup card or toolbars are up, edge taps close them instead of turning.
    var edgeTapsTurnPages: Bool
    /// Seconds per page while auto reading.
    var autoTurnInterval: Double?
    var onPosition: (_ offset: Int, _ fraction: Double) -> Void
    var onTapWord: (ReadingSelection) -> Void
    var onTapBlank: () -> Void
    var onTurn: () -> Void
    var onLookup: (ReadingSelection) -> Void
    var onSave: (ReadingSelection) -> Void
    /// A page turn carried reading into the neighbouring chapter, which this surface now shows.
    var onChapterTurn: (_ forward: Bool) -> Void
    /// Tried to turn past the first or last page of the book.
    var onBoundary: (_ forward: Bool) -> Void
    /// Where the book's image files are; without it pictures are left out.
    var resources: URL?
    /// A link was tapped; the argument is its target as stored in the chapter.
    var onTapLink: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> PagerController { PagerController(self) }

    func updateUIViewController(_ controller: PagerController, context: Context) { controller.update(self) }

    static func dismantleUIViewController(_ controller: PagerController, coordinator: ()) { controller.stopAutoTurn() }
}

/// One chapter laid out into page-sized text containers.
@MainActor
final class PagedChapter {
    let chapter: ReaderChapter
    let number: Int
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    private(set) var containers: [NSTextContainer] = []
    private(set) var pages: [NSRange] = []
    let wordRanges: [NSRange]
    var marked: [NSRange] = []
    var cache: [Int: PageController] = [:]

    init(_ chapter: ReaderChapter, number: Int, size: CGFloat, layout: ReaderLayout, ink: UIColor, pageSize: CGSize, forms: Set<String>,
         resources: URL?) {
        self.chapter = chapter
        self.number = number
        storage = NSTextStorage(attributedString: ReadingSurface.attributedText(for: chapter, size: size, layout: layout, ink: ink,
                                                                                resources: resources))
        storage.addLayoutManager(manager)
        wordRanges = ReadingSurface.englishWordRanges(in: chapter.text)
        var end = 0
        repeat {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let glyphs = manager.glyphRange(for: container)
            // A line taller than the page can never be placed; stop rather than loop.
            guard glyphs.length > 0 || containers.isEmpty else { manager.removeTextContainer(at: containers.count); break }
            containers.append(container)
            pages.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            end = NSMaxRange(glyphs)
        } while end < manager.numberOfGlyphs
        applyMarks(forms)
    }

    func applyMarks(_ forms: Set<String>) {
        let ranges = ReaderTextTools.markedRanges(in: chapter.text, words: wordRanges, forms: forms)
        guard ranges != marked else { return }
        ReaderTextTools.applyMarks(ranges, replacing: marked, in: storage)
        marked = ranges
    }

    func pageIndex(containing offset: Int) -> Int {
        pages.firstIndex { offset < NSMaxRange($0) } ?? max(0, pages.count - 1)
    }
}

final class PagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UITextViewDelegate, UIGestureRecognizerDelegate {
    private var config: PagedSurface
    private var book: PagedChapter?
    private var previousLayout: PagedChapter?
    private var nextLayout: PagedChapter?
    private var current = 0
    private var renderedKey: RenderKey?
    private var anchor: Int
    private var pendingJump: JumpRequest?
    private var lastJumpID: UUID?
    private var lastReported: Int?
    private var tapFilter = TapFilter()
    private let flash = WordFlash()
    private var pager: UIPageViewController?
    /// Cover and no-animation modes show one page here and animate by hand.
    private let host = UIView()
    private var hosted: PageController?
    private var animating = false
    /// Set after crossing into a neighbouring chapter, until the pager has re-asked for the new neighbours.
    private var pagerNeedsRefresh = false
    private var autoTurn: (interval: Double, task: Task<Void, Never>)?

    private struct RenderKey: Equatable {
        var chapterID: String
        var size: CGFloat
        var layout: ReaderLayout
        var palette: ReaderPalette
        var bounds: CGSize
        var insets: UIEdgeInsets
    }

    init(_ config: PagedSurface) {
        self.config = config
        anchor = max(0, config.initialOffset)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = config.palette.paper
        view.accessibilityIdentifier = "reading-pages"
        if config.turn == .curl || config.turn == .slide {
            let pager = UIPageViewController(transitionStyle: config.turn == .curl ? .pageCurl : .scroll,
                                             navigationOrientation: .horizontal,
                                             options: config.turn == .curl ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil)
            pager.isDoubleSided = false
            pager.dataSource = self
            pager.delegate = self
            // Taps are ours: words get looked up, edges turn pages.
            pager.gestureRecognizers.filter { $0 is UITapGestureRecognizer }.forEach { $0.isEnabled = false }
            addChild(pager)
            pager.view.frame = view.bounds
            pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(pager.view)
            pager.didMove(toParent: self)
            self.pager = pager
        } else {
            host.frame = view.bounds
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.clipsToBounds = true
            view.addSubview(host)
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                host.addGestureRecognizer(swipe)
            }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        renderIfNeeded()
    }

    private var layouts: [PagedChapter] { [previousLayout, book, nextLayout].compactMap { $0 } }

    func update(_ value: PagedSurface) {
        let old = config
        config = value
        if old.lookingUp && !value.lookingUp { flash.cancel() }
        if old.backdrop != value.backdrop || old.backdropVersion != value.backdropVersion {
            for page in layouts.flatMap(\.cache.values) { page.backdrop.backdrop = value.backdrop; page.backdrop.refresh() }
        }
        if old.interactive != value.interactive {
            for page in layouts.flatMap(\.cache.values) { page.textView?.isSelectable = value.interactive }
        }
        if let jump = value.jump, jump.id != lastJumpID {
            lastJumpID = jump.id
            pendingJump = jump
        }
        // Neighbours laid out for another chapter (after a jump through the contents, say) are stale.
        if previousLayout?.chapter.id != value.previousChapter?.id { previousLayout = nil }
        if nextLayout?.chapter.id != value.nextChapter?.id { nextLayout = nil }
        renderIfNeeded()
        if old.learningForms != value.learningForms { layouts.forEach { $0.applyMarks(value.learningForms) } }
        if let jump = pendingJump, let book {
            pendingJump = nil
            show(book.pageIndex(containing: jump.offset), of: book, forward: true, animated: false)
            if jump.highlight {
                let range = ReaderTextTools.wordRange(containing: jump.offset, in: book.wordRanges)
                    ?? NSRange(location: min(jump.offset, max(0, book.storage.length - 1)), length: book.storage.length > 0 ? 1 : 0)
                flash.show(range, in: book.storage)
            }
        }
        if value.autoTurnInterval != autoTurn?.interval { restartAutoTurn() }
        refreshPagerIfNeeded()
    }

    /// Page view controllers cache "no page" past an end; once the new chapter's neighbours are known, ask again.
    private func refreshPagerIfNeeded() {
        guard pagerNeedsRefresh, !animating, let pager, let book, let page = book.cache[current] else { return }
        pagerNeedsRefresh = false
        pager.setViewControllers([page], direction: .forward, animated: false)
    }

    // MARK: Pagination

    private var safeInsets: UIEdgeInsets { view.window?.safeAreaInsets ?? view.safeAreaInsets }

    /// Blank space under the footer labels.
    private var footerBottomSpace: CGFloat { (max(safeInsets.bottom, 12) + 4) * 0.75 }

    /// Text keeps at least one line of 20 pt body text clear above the footer.
    private var footerGap: CGFloat {
        ReaderTypography.font(config.layout.typeface, size: 20).lineHeight * CGFloat(config.layout.lineSpacing)
    }

    /// Where text sits on every page; the header and footer use the bands outside it.
    fileprivate var textFrame: CGRect {
        let insets = safeInsets
        let margin = CGFloat(config.layout.margin)
        return CGRect(x: insets.left + margin, y: insets.top + 34,
                      width: max(1, view.bounds.width - insets.left - insets.right - margin * 2),
                      height: max(1, view.bounds.height - insets.top - 34 - footerBottomSpace - 16 - footerGap))
    }

    /// The page number and chapter progress, pinned above the bottom blank.
    fileprivate var footerFrame: CGRect {
        let text = textFrame
        return CGRect(x: text.minX, y: view.bounds.height - footerBottomSpace - 16, width: text.width, height: 16)
    }

    private func renderKey(for chapterID: String) -> RenderKey {
        RenderKey(chapterID: chapterID, size: ReaderTypography.pointSize(config.layout.fontSize), layout: config.layout,
                  palette: config.palette, bounds: view.bounds.size, insets: safeInsets)
    }

    private func renderIfNeeded() {
        guard isViewLoaded, view.bounds.width > 1, view.bounds.height > 1, view.window != nil else { return }
        let key = renderKey(for: config.chapter.id)
        guard key != renderedKey else { return }
        if let book, book.chapter.id == config.chapter.id, book.pages.indices.contains(current) {
            anchor = book.pages[current].location
        } else if renderedKey != nil {
            anchor = max(0, config.initialOffset) // Opened another chapter.
        }
        renderedKey = key
        view.backgroundColor = config.palette.paper
        flash.cancel()
        previousLayout = nil
        nextLayout = nil
        let book = makeLayout(for: config.chapter, number: config.chapterIndex)
        self.book = book
        current = -1
        lastReported = nil
        show(book.pageIndex(containing: anchor), of: book, forward: true, animated: false)
    }

    private func makeLayout(for chapter: ReaderChapter, number: Int) -> PagedChapter {
        PagedChapter(chapter, number: number, size: ReaderTypography.pointSize(config.layout.fontSize), layout: config.layout,
                     ink: config.palette.ink, pageSize: textFrame.size, forms: config.learningForms, resources: config.resources)
    }

    /// The neighbouring chapter, laid out on first use.
    private func neighbour(forward: Bool) -> PagedChapter? {
        if forward {
            guard let chapter = config.nextChapter else { return nil }
            if nextLayout == nil { nextLayout = makeLayout(for: chapter, number: config.chapterIndex + 1) }
            return nextLayout
        } else {
            guard let chapter = config.previousChapter else { return nil }
            if previousLayout == nil { previousLayout = makeLayout(for: chapter, number: config.chapterIndex - 1) }
            return previousLayout
        }
    }

    private func page(_ index: Int, of layout: PagedChapter) -> PageController {
        if let page = layout.cache[index] { return page }
        let page = PageController(index: index, layout: layout)
        page.textFrame = { [weak self] in self?.textFrame ?? .zero }
        page.footerFrame = { [weak self] in self?.footerFrame ?? .zero }
        page.backdrop.palette = config.palette
        page.backdrop.backdrop = config.backdrop
        let secondary = config.palette.secondaryInk
        page.header.textColor = secondary
        page.footer.textColor = secondary
        page.progress.textColor = secondary
        if layout.containers.indices.contains(index) {
            let text = UITextView(frame: textFrame, textContainer: layout.containers[index])
            text.isEditable = false
            text.isSelectable = config.interactive
            text.isScrollEnabled = false
            text.backgroundColor = .clear
            text.textContainerInset = .zero
            text.tintColor = .readerAccent
            text.dataDetectorTypes = []
            text.delegate = self
            text.accessibilityHint = "可用辅助功能操作选择单词、查词或收藏。"
            page.textView = text
            page.header.text = layout.chapter.title
            page.footer.text = "\(index + 1) / \(layout.pages.count)"
            let percent = Int(Double(index + 1) / Double(layout.pages.count) * 100)
            page.progress.text = String(localized: "第 \(layout.number + 1)/\(max(config.chapterCount, 1)) 章 · 本章 \(percent)%")
        }
        layout.cache[index] = page
        return page
    }

    // MARK: Turning

    private func turn(forward: Bool) {
        guard !animating, let book else { return }
        let target = current + (forward ? 1 : -1)
        if book.pages.indices.contains(target) {
            config.onTurn()
            show(target, of: book, forward: forward, animated: config.turn != .none)
        } else if let neighbour = neighbour(forward: forward) {
            config.onTurn()
            show(forward ? 0 : neighbour.pages.count - 1, of: neighbour, forward: forward, animated: config.turn != .none)
        } else {
            config.onBoundary(forward)
        }
    }

    private func show(_ index: Int, of layout: PagedChapter, forward: Bool, animated: Bool) {
        guard layout.pages.indices.contains(index) else { return }
        guard layout !== book || index != current else { reportPosition(); return }
        let next = page(index, of: layout)
        if let pager {
            let direction: UIPageViewController.NavigationDirection = forward ? .forward : .reverse
            animating = animated
            pager.setViewControllers([next], direction: direction, animated: animated) { [weak self, weak pager] _ in
                guard let self else { return }
                self.animating = false
                Task { @MainActor in self.refreshPagerIfNeeded() }
                // Scroll-style pagers keep stale neighbours after an animated set.
                if animated, self.config.turn == .slide, let pager {
                    Task { @MainActor in pager.setViewControllers([next], direction: direction, animated: false) }
                }
            }
        } else {
            showHosted(next, forward: forward, animated: animated)
        }
        arrive(at: next)
    }

    /// Makes the page current, adopting its chapter when the turn crossed into a neighbour.
    private func arrive(at page: PageController) {
        guard let layout = page.layout else { return }
        let crossed = layout !== book
        if crossed {
            let forward = layout === nextLayout
            if forward { previousLayout = book; nextLayout = nil } else { nextLayout = book; previousLayout = nil }
            // Until SwiftUI passes the new chapter's neighbours, only the one just left is known.
            config.chapter = layout.chapter
            config.chapterIndex = layout.number
            config.previousChapter = forward ? book?.chapter : nil
            config.nextChapter = forward ? nil : book?.chapter
            pagerNeedsRefresh = pager != nil
            book = layout
            renderedKey?.chapterID = layout.chapter.id
            lastReported = nil
            flash.cancel()
            config.onChapterTurn(forward)
        }
        current = page.index
        reportPosition()
    }

    private func showHosted(_ next: PageController, forward: Bool, animated: Bool) {
        let old = hosted
        guard old !== next else { return }
        addChild(next)
        next.view.frame = host.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosted = next
        let finish = {
            old?.willMove(toParent: nil)
            old?.view.removeFromSuperview()
            old?.removeFromParent()
            next.didMove(toParent: self)
        }
        guard animated, let old else {
            host.addSubview(next.view)
            finish()
            return
        }
        // Cover: the top page slides away to reveal the next, or slides back in over the current one.
        let width = host.bounds.width
        let moving = forward ? old.view! : next.view!
        if forward { host.insertSubview(next.view, belowSubview: old.view) } else { host.addSubview(next.view) }
        moving.layer.shadowColor = UIColor.black.cgColor
        moving.layer.shadowOpacity = 0.25
        moving.layer.shadowRadius = 8
        moving.layer.shadowOffset = CGSize(width: 2, height: 0)
        if !forward { moving.frame.origin.x = -width }
        animating = true
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            moving.frame.origin.x = forward ? -width : 0
        } completion: { [weak self] _ in
            moving.layer.shadowOpacity = 0
            moving.frame.origin.x = 0
            finish()
            self?.animating = false
        }
    }

    private func reportPosition() {
        guard let book, book.pages.indices.contains(current), lastReported != current else { return }
        lastReported = current
        let offset = book.pages[current].location
        let fraction = Double(current + 1) / Double(book.pages.count)
        // Never change SwiftUI state inside updateUIViewController.
        Task { @MainActor [weak self] in self?.config.onPosition(offset, fraction) }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        turn(forward: gesture.direction == .left)
    }

    // MARK: UIPageViewController

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PageController, let layout = page.layout else { return nil }
        if page.index > 0 { return self.page(page.index - 1, of: layout) }
        guard layout === book, let previous = neighbour(forward: false) else { return nil }
        return self.page(previous.pages.count - 1, of: previous)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PageController, let layout = page.layout else { return nil }
        if page.index + 1 < layout.pages.count { return self.page(page.index + 1, of: layout) }
        guard layout === book, let next = neighbour(forward: true) else { return nil }
        return self.page(0, of: next)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        config.onTurn()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = pageViewController.viewControllers?.first as? PageController else { return }
        arrive(at: page)
    }

    // MARK: Tapping

    private var currentTextView: UITextView? { book?.cache[current]?.textView }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let text = currentTextView else { return false }
        tapFilter.began(touch, in: text)
        return !animating && !UIAccessibility.isVoiceOverRunning
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let book, let text = currentTextView, tapFilter.isQuickTap(in: text) else { return }
        guard config.interactive else { config.onTapBlank(); return }
        let location = gesture.location(in: text)
        if text.bounds.contains(location) {
            if let target = ReaderTextTools.link(at: location, in: text) {
                config.onTapLink(target)
                return
            }
            if let range = ReaderTextTools.wordRange(at: location, in: text, words: book.wordRanges),
               let selection = ReaderTextTools.selection(for: range, in: text) {
                flash.show(range, in: book.storage, hold: true)
                config.onTapWord(selection)
                return
            }
        }
        let x = gesture.location(in: view).x / max(view.bounds.width, 1)
        if config.edgeTapsTurnPages, x < 0.3 || x > 0.7 {
            turn(forward: x > 0.7)
        } else {
            config.onTapBlank()
        }
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        ReaderTextTools.editMenu(for: range, in: textView, suggestedActions: suggestedActions,
                                 onLookup: { [weak self, weak textView] value in
                                     if let textView { self?.flash.show(value.range, in: textView.textStorage, hold: true) }
                                     self?.config.onLookup(value)
                                 },
                                 onSave: { [weak self] in self?.config.onSave($0) })
    }

    // MARK: Auto reading

    private func restartAutoTurn() {
        stopAutoTurn()
        guard let interval = config.autoTurnInterval else { return }
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.turn(forward: true)
            }
        }
        autoTurn = (interval, task)
    }

    func stopAutoTurn() {
        autoTurn?.task.cancel()
        autoTurn = nil
    }
}

/// One page: backdrop, chapter title, the page's text, chapter progress and page number.
final class PageController: UIViewController {
    let index: Int
    private(set) weak var layout: PagedChapter?
    /// The storage owns the layout manager and containers the text view draws from.
    private let storage: NSTextStorage
    let backdrop = BackdropView()
    let header = UILabel()
    let footer = UILabel()
    let progress = UILabel()
    var textView: UITextView?
    var textFrame: () -> CGRect = { .zero }
    var footerFrame: () -> CGRect = { .zero }

    init(index: Int, layout: PagedChapter) {
        self.index = index
        self.layout = layout
        storage = layout.storage
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(backdrop)
        for label in [header, footer, progress] {
            label.font = .systemFont(ofSize: 11)
            label.isAccessibilityElement = false
            view.addSubview(label)
        }
        footer.textAlignment = .right
        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if let textView { view.addSubview(textView) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        let frame = textFrame()
        textView?.frame = frame
        header.frame = CGRect(x: frame.minX, y: frame.minY - 26, width: frame.width, height: 16)
        footer.frame = footerFrame()
        progress.frame = footer.frame
    }
}
