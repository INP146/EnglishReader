import SwiftUI
import UIKit

/// Page-by-page reading. One layout manager lays the whole chapter into a
/// chain of page-sized text containers; each page's text view shows one
/// container, so offsets, hit-testing and the edit menu use the same chapter
/// coordinates as the scrolling surface.
@MainActor
struct PagedSurface: UIViewControllerRepresentable {
    var chapter: ReaderChapter
    var layout: ReaderLayout
    var palette: ReaderPalette
    var backdrop: ReaderBackdrop
    var backdropVersion: Int
    var turn: PageTurn
    var initialOffset: Int
    var jump: JumpRequest?
    var markedRanges: [NSRange]
    var hasPrevious: Bool
    var hasNext: Bool
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
    /// Turned past the first or last page.
    var onBoundary: (_ forward: Bool) -> Void

    func makeUIViewController(context: Context) -> PagerController { PagerController(self) }

    func updateUIViewController(_ controller: PagerController, context: Context) { controller.update(self) }

    static func dismantleUIViewController(_ controller: PagerController, coordinator: ()) { controller.stopAutoTurn() }
}

final class PagerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UITextViewDelegate, UIGestureRecognizerDelegate {
    private var config: PagedSurface
    private var storage = NSTextStorage()
    private var manager = NSLayoutManager()
    private var containers: [NSTextContainer] = []
    private var pages: [NSRange] = []
    private var wordRanges: [NSRange] = []
    private var marked: [NSRange] = []
    private var current = 0
    private var cache: [Int: PageController] = [:]
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
        wordRanges = ReadingSurface.englishWordRanges(in: config.chapter.text)
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

    func update(_ value: PagedSurface) {
        let old = config
        config = value
        if old.backdrop != value.backdrop || old.backdropVersion != value.backdropVersion {
            for page in cache.values { page.backdrop.backdrop = value.backdrop; page.backdrop.refresh() }
        }
        if let jump = value.jump, jump.id != lastJumpID {
            lastJumpID = jump.id
            pendingJump = jump
        }
        renderIfNeeded()
        if marked != value.markedRanges, !pages.isEmpty {
            ReaderTextTools.applyMarks(value.markedRanges, replacing: marked, in: storage)
            marked = value.markedRanges
        }
        if let jump = pendingJump, !pages.isEmpty {
            pendingJump = nil
            show(pageIndex(containing: jump.offset), forward: true, animated: false)
            if jump.highlight {
                let range = ReaderTextTools.wordRange(containing: jump.offset, in: wordRanges)
                    ?? NSRange(location: min(jump.offset, max(0, storage.length - 1)), length: storage.length > 0 ? 1 : 0)
                flash.show(range, in: storage)
            }
        }
        if value.autoTurnInterval != autoTurn?.interval { restartAutoTurn() }
    }

    // MARK: Pagination

    private var safeInsets: UIEdgeInsets { view.window?.safeAreaInsets ?? view.safeAreaInsets }

    /// Where text sits on every page; the header and footer use the bands outside it.
    fileprivate var textFrame: CGRect {
        let insets = safeInsets
        let margin = CGFloat(config.layout.margin)
        return CGRect(x: insets.left + margin, y: insets.top + 34,
                      width: max(1, view.bounds.width - insets.left - insets.right - margin * 2),
                      height: max(1, view.bounds.height - insets.top - 34 - max(insets.bottom, 12) - 30))
    }

    private func renderIfNeeded() {
        guard isViewLoaded, view.bounds.width > 1, view.bounds.height > 1, view.window != nil else { return }
        let size = ReaderTypography.pointSize(config.layout.fontSize)
        let key = RenderKey(chapterID: config.chapter.id, size: size, layout: config.layout, palette: config.palette,
                            bounds: view.bounds.size, insets: safeInsets)
        guard key != renderedKey else { return }
        if renderedKey != nil, pages.indices.contains(current) { anchor = pages[current].location }
        renderedKey = key
        view.backgroundColor = config.palette.paper
        paginate(size: size)
        marked = []
        if !config.markedRanges.isEmpty {
            ReaderTextTools.applyMarks(config.markedRanges, replacing: [], in: storage)
            marked = config.markedRanges
        }
        current = -1
        lastReported = nil
        show(pageIndex(containing: anchor), forward: true, animated: false)
    }

    private func paginate(size: CGFloat) {
        flash.cancel()
        cache.removeAll()
        let attributed = ReadingSurface.attributedText(for: config.chapter, size: size, layout: config.layout, ink: config.palette.ink)
        storage = NSTextStorage(attributedString: attributed)
        manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        containers = []
        pages = []
        let pageSize = textFrame.size
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
    }

    private func pageIndex(containing offset: Int) -> Int {
        pages.firstIndex { offset < NSMaxRange($0) } ?? max(0, pages.count - 1)
    }

    private func page(_ index: Int) -> PageController {
        if let page = cache[index] { return page }
        let page = PageController(index: index)
        page.textFrame = { [weak self] in self?.textFrame ?? .zero }
        page.backdrop.palette = config.palette
        page.backdrop.backdrop = config.backdrop
        let secondary = config.palette.secondaryInk
        page.header.textColor = secondary
        page.footer.textColor = secondary
        page.boundaryLabel.textColor = secondary
        if containers.indices.contains(index) {
            let text = UITextView(frame: textFrame, textContainer: containers[index])
            text.isEditable = false
            text.isSelectable = true
            text.isScrollEnabled = false
            text.backgroundColor = .clear
            text.textContainerInset = .zero
            text.tintColor = .readerAccent
            text.dataDetectorTypes = []
            text.delegate = self
            text.accessibilityHint = "可用辅助功能操作选择单词、查词或收藏。"
            page.textView = text
            page.header.text = config.chapter.title
            page.footer.text = "\(index + 1) / \(pages.count)"
        } else {
            page.boundaryLabel.text = index < 0 ? String(localized: "上一章") : String(localized: "下一章")
        }
        cache[index] = page
        return page
    }

    // MARK: Turning

    private func turn(forward: Bool) {
        guard !animating else { return }
        let target = current + (forward ? 1 : -1)
        guard pages.indices.contains(target) else {
            if forward ? config.hasNext : config.hasPrevious { config.onBoundary(forward) }
            return
        }
        config.onTurn()
        show(target, forward: forward, animated: config.turn != .none)
    }

    private func show(_ index: Int, forward: Bool, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        guard index != current else { reportPosition(); return }
        current = index
        let next = page(index)
        if let pager {
            let direction: UIPageViewController.NavigationDirection = forward ? .forward : .reverse
            animating = animated
            pager.setViewControllers([next], direction: direction, animated: animated) { [weak self, weak pager] _ in
                guard let self else { return }
                self.animating = false
                // Scroll-style pagers keep stale neighbours after an animated set.
                if animated, self.config.turn == .slide, let pager {
                    Task { @MainActor in pager.setViewControllers([next], direction: direction, animated: false) }
                }
            }
        } else {
            showHosted(next, forward: forward, animated: animated)
        }
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
        guard pages.indices.contains(current), lastReported != current else { return }
        lastReported = current
        let offset = pages[current].location
        let fraction = Double(current + 1) / Double(pages.count)
        // Never change SwiftUI state inside updateUIViewController.
        Task { @MainActor [weak self] in self?.config.onPosition(offset, fraction) }
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        turn(forward: gesture.direction == .left)
    }

    // MARK: UIPageViewController

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? PageController)?.index, index > 0 || (index == 0 && config.hasPrevious) else { return nil }
        return page(index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let index = (viewController as? PageController)?.index,
              index + 1 < pages.count || (index + 1 == pages.count && config.hasNext) else { return nil }
        return page(index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        config.onTurn()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let index = (pageViewController.viewControllers?.first as? PageController)?.index else { return }
        if index < 0 { config.onBoundary(false); return }
        if index >= pages.count { config.onBoundary(true); return }
        current = index
        reportPosition()
    }

    // MARK: Tapping

    private var currentTextView: UITextView? { cache[current]?.textView }

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
        guard gesture.state == .ended, let text = currentTextView, tapFilter.isQuickTap(in: text) else { return }
        let location = gesture.location(in: text)
        if text.bounds.contains(location),
           let range = ReaderTextTools.wordRange(at: location, in: text, words: wordRanges),
           let selection = ReaderTextTools.selection(for: range, in: text) {
            flash.show(range, in: storage)
            config.onTapWord(selection)
            return
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
                                 onLookup: { [weak self] in self?.config.onLookup($0) },
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

/// One page: backdrop, chapter title, the page's text and its number.
final class PageController: UIViewController {
    let index: Int
    let backdrop = BackdropView()
    let header = UILabel()
    let footer = UILabel()
    let boundaryLabel = UILabel()
    var textView: UITextView?
    var textFrame: () -> CGRect = { .zero }

    init(index: Int) {
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(backdrop)
        for label in [header, footer] {
            label.font = .systemFont(ofSize: 11)
            label.isAccessibilityElement = false
            view.addSubview(label)
        }
        footer.textAlignment = .right
        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        boundaryLabel.font = .preferredFont(forTextStyle: .headline)
        boundaryLabel.textAlignment = .center
        view.addSubview(boundaryLabel)
        if let textView { view.addSubview(textView) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        boundaryLabel.frame = view.bounds
        let frame = textFrame()
        textView?.frame = frame
        header.frame = CGRect(x: frame.minX, y: frame.minY - 26, width: frame.width, height: 16)
        footer.frame = CGRect(x: frame.minX, y: frame.maxY + 10, width: frame.width, height: 16)
    }
}
