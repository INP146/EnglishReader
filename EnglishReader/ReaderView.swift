import SwiftUI
import UIKit

struct ReaderView: View {
    let store: LibraryStore
    let bookID: UUID
    var requestedChapter: Int?
    var requestedOffset: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("lastReadBookID") private var lastReadBookID = ""
    @AppStorage("readerFont") private var fontSize = ReaderTypography.defaultSize
    @AppStorage("readerTypeface") private var typeface = ReaderTypeface.newYork
    @AppStorage("readerLineSpacing") private var lineSpacing = ReaderLayout.defaultLineSpacing
    @AppStorage("readerParagraphSpacing") private var paragraphSpacing = ReaderLayout.defaultParagraphSpacing
    @AppStorage("readerMargin") private var margin = ReaderLayout.defaultMargin
    @AppStorage("readerAppearance") private var appearance = "system"
    @AppStorage("readerDayTheme") private var dayTheme = ReaderTheme.defaultDay
    @AppStorage("readerNightTheme") private var nightTheme = ReaderTheme.defaultNight
    @AppStorage("readerBackdrop") private var backdrop = ReaderBackdrop.plain
    @AppStorage("readerBackdropVersion") private var backdropVersion = 0
    @AppStorage("readerPageTurn") private var pageTurn = PageTurn.scroll
    @AppStorage("readerEyeCare") private var eyeCare = false
    @AppStorage("readerAutoSpeed") private var autoSpeed = 3
    @AppStorage("readerKeepAwake") private var keepAwake = false
    @AppStorage("readerTipSeen") private var tipSeen = false

    @State private var content: BookContent?
    @State private var loadError: String?
    @State private var chapter = 0
    @State private var offset = 0
    @State private var fraction = 0.0
    @State private var jump: JumpRequest?
    @State private var lookup: ReadingSelection?
    /// Where the lookup bubble may go, in global coordinates: inside the safe area and above the bottom bars.
    @State private var lookupArea: CGRect = .zero
    @State private var chromeVisible = true
    @State private var bottomSafeArea: CGFloat = 0
    @State private var showPanel = false
    @State private var sliderChapter: Double?
    @State private var autoReading = false
    @State private var sheet: ReaderSheet?
    @State private var systemTerm: SystemTerm?
    @State private var toast: String?
    /// Set while visiting a saved word's source or a search result; the reader's own place is kept here.
    @State private var savedPlace: ReadingPosition?
    @State private var marks: [NSRange] = []

    private enum ReaderSheet: String, Identifiable {
        case contents, search, fonts, spacing, more
        var id: String { rawValue }
    }

    private var book: ReaderBook? { store.books.first { $0.id == bookID } }
    private var current: ReaderChapter? {
        guard let content, content.chapters.indices.contains(chapter) else { return nil }
        return content.chapters[chapter]
    }
    private var chapterCount: Int { content?.chapters.count ?? book?.chapters.count ?? 0 }
    private var resources: URL? { book.flatMap { store.resourcesURL(for: $0) } }
    private var hasNext: Bool { chapter + 1 < chapterCount }
    private var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    private var isNight: Bool { appearance == "dark" || (appearance != "light" && systemScheme == .dark) }
    private var palette: ReaderPalette { ReaderPalette(day: dayTheme, night: nightTheme) }
    private var chrome: Color { Color(uiColor: palette.chrome) }
    private var layout: ReaderLayout {
        ReaderLayout(fontSize: fontSize, typeface: typeface, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, margin: margin)
    }
    /// Auto reading pauses while the toolbars or the lookup card are up.
    private var autoRunning: Bool { autoReading && !chromeVisible && lookup == nil && sheet == nil }

    /// Surface forms of words still being learned; every occurrence gets underlined.
    private var learningForms: Set<String> {
        Set(store.favorites.filter { !$0.mastered }.flatMap { [WordDictionary.normalize($0.selection), $0.key] })
    }

    var body: some View {
        NavigationStack {
            readingArea
            // Chrome floats over the text instead of resizing it; the lookup bubble stays clear of the bottom bar.
            .overlay {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { lookupArea = $0 }
                    .overlay { lookupOverlay }
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomInset }
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
                    .overlay(alignment: .top) { topBar }
                    .overlay(alignment: .top) {
                        if let toast { ToastLabel(text: toast).padding(.top, 8) }
                    }
            }
            .animation(.default, value: toast)
            .animation(.spring(duration: 0.25), value: lookup?.id)
            // Our own top bar: the system one slides in under the status bar and Dynamic Island.
            .toolbar(.hidden, for: .navigationBar)
            .statusBarHidden(!chromeVisible)
        }
        .tint(.accent)
        .overlay {
            if eyeCare {
                // A warm multiply wash cuts blue light over the page and the toolbars alike.
                Color(red: 1, green: 0.72, blue: 0.38).opacity(0.22).blendMode(.multiply)
                    .ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .preferredColorScheme(colorScheme)
        .task { await open() }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
        .onChange(of: learningForms, initial: true) { updateMarks() }
        .onChange(of: current?.id) { updateMarks() }
        .onChange(of: pageTurn) { jump = nil } // A rebuilt surface must not replay an old jump.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.persist(); ScreenBrightness.restore() } else { ScreenBrightness.reapply() }
        }
        .onChange(of: keepAwake || autoReading, initial: true) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            ScreenBrightness.reset()
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .contents: contents
            case .search: BookSearchView(chapters: content?.chapters ?? []) { visit(chapter: $0, offset: $1) }
            case .fonts: ReaderFontPicker()
            case .spacing: ReaderSpacingSettings()
            case .more: ReaderMoreSettings()
            }
        }
        .sheet(item: $systemTerm) { SystemDictionary(term: $0.text).ignoresSafeArea() }
        .alert("没有保存成功", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    // MARK: Pieces

    private var readingArea: some View {
        ZStack {
            Color(uiColor: palette.paper).ignoresSafeArea()
            if let current {
                surface(for: current)
                    // The pager turns into neighbouring chapters itself, so only scrolling rebuilds per chapter.
                    .id(pageTurn.isPaged ? pageTurn.rawValue : "\(current.id)|\(pageTurn.rawValue)")
                    .ignoresSafeArea()
            } else if let loadError {
                ContentUnavailableView("无法打开这本书", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("正在打开…")
            }
        }
    }

    @ViewBuilder private func surface(for current: ReaderChapter) -> some View {
        if pageTurn.isPaged {
            PagedSurface(
                chapter: current, chapterIndex: chapter, chapterCount: chapterCount,
                chapters: content?.chapters ?? [],
                layout: layout, palette: palette, backdrop: backdrop, backdropVersion: backdropVersion,
                turn: pageTurn, initialOffset: offset, jump: jump, learningForms: learningForms,
                lookingUp: lookup != nil,
                interactive: !chromeVisible,
                autoTurnInterval: autoRunning ? Double(34 - 3 * autoSpeed) : nil,
                onPosition: positionChanged,
                onTapWord: { show($0) },
                onTapBlank: { tappedBlank() },
                onTurn: { lookup = nil; hideChrome() },
                onLookup: { show($0) },
                onSave: { save($0) },
                onChapterTurn: { index in
                    // The surface already shows the new chapter; its position report follows.
                    chapter = index
                    jump = nil
                },
                onBoundary: { forward in
                    if forward { reachedChapterEnd() }
                },
                resources: resources,
                onTapLink: { openLink($0) })
        } else {
            ZStack {
                BackdropRepresentable(backdrop: backdrop, palette: palette, version: backdropVersion)
                ReadingSurface(
                    chapter: current, layout: layout, palette: palette, initialOffset: offset, jump: jump, markedRanges: marks,
                    autoScrollSpeed: autoRunning ? Double(8 + 8 * autoSpeed) : nil,
                    onPosition: positionChanged,
                    onTapWord: { show($0) },
                    onTapBlank: { tappedBlank() },
                    onScroll: { lookup = nil },
                    onLookup: { show($0) },
                    onSave: { save($0) },
                    lookingUp: lookup != nil,
                    interactive: !chromeVisible,
                    onReachEnd: { reachedChapterEnd() },
                    resources: resources,
                    onTapLink: { openLink($0) })
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("书架")
            .accessibilityIdentifier("close-reader")
            Text(current?.title ?? book?.title ?? "")
                .font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(chrome.ignoresSafeArea(edges: .top))
        // Always in place and only slid away: inserting it anew sometimes animated from a stale frame.
        .visualEffect { [chromeVisible] content, proxy in
            content.offset(y: chromeVisible ? 0 : -proxy.frame(in: .global).maxY)
        }
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .accessibilityHidden(!chromeVisible)
    }

    private var bottomInset: some View {
        VStack(spacing: 0) {
            if !tipSeen && content != nil && lookup == nil { tip.padding(.bottom, 8) }
            if savedPlace != nil { returnBar }
            if chromeVisible {
                bottomBar
            } else if fraction >= 0.99 && hasNext && !pageTurn.isPaged && !autoReading {
                nextChapterButton.padding(.bottom, 8)
            }
        }
    }

    /// The card pops out of the looked-up word, so the eyes stay where they were reading.
    @ViewBuilder private var lookupOverlay: some View {
        if let lookup {
            // Without a known position (e.g. VoiceOver), the bubble hangs from the top edge.
            let anchor = lookup.anchor.map { $0.offsetBy(dx: -lookupArea.minX, dy: -lookupArea.minY) }
            let size = lookupArea.size
            let point = anchor.map { UnitPoint(x: size.width > 0 ? $0.midX / size.width : 0.5,
                                               y: size.height > 0 ? $0.midY / size.height : 0) } ?? .top
            LookupBubbleLayout(anchor: anchor) {
                Rectangle()
                    .fill(Color(uiColor: palette.chrome))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(45))
                    .opacity(anchor == nil ? 0 : 1)
                    .accessibilityHidden(true)
                LookupCard(selection: lookup, entry: WordDictionary.shared.lookup(lookup.text),
                           isSaved: store.favorite(matching: lookup.text) != nil,
                           palette: palette,
                           onSave: { save(lookup) },
                           onMore: { systemTerm = SystemTerm(text: lookup.text) },
                           onClose: { self.lookup = nil })
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.14), radius: 16, y: 4)
            .transition(.scale(scale: 0.85, anchor: point).combined(with: .opacity))
            .id(lookup.id)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            // The panel unfolds from the tabs' top edge, sliding over the chapter bar, which stays put underneath.
            ZStack(alignment: .bottom) {
                Group {
                    if autoReading { autoReadingBar } else { chapterBar }
                }
                .background(chrome)
                .allowsHitTesting(!showPanel)
                .accessibilityHidden(showPanel)
                if showPanel {
                    VStack(spacing: 0) {
                        ReaderSettingsPanel(isNight: isNight,
                                            onFonts: { sheet = .fonts },
                                            onSpacing: { sheet = .spacing },
                                            onMore: { sheet = .more },
                                            onAutoRead: startAutoReading)
                        Divider()
                    }
                    .background(chrome)
                    .transition(.move(edge: .bottom))
                    // A view being removed from a ZStack loses its implicit order; pin it above the chapter bar.
                    .zIndex(1)
                }
            }
            .clipped()
            HStack(spacing: 0) {
                ReaderTabButton(title: "目录", systemImage: "list.bullet.rectangle.portrait") { sheet = .contents }
                    .accessibilityIdentifier("open-chapters")
                ReaderTabButton(title: isNight ? "日间" : "夜间", systemImage: isNight ? "sun.max" : "moon") {
                    appearance = isNight ? "light" : "dark"
                }
                .accessibilityIdentifier("toggle-night")
                ReaderTabButton(title: "设置", systemImage: showPanel ? "gearshape.fill" : "gearshape") {
                    withAnimation(.easeInOut(duration: 0.28)) { showPanel.toggle() }
                }
                .accessibilityAddTraits(showPanel ? .isSelected : [])
                .accessibilityIdentifier("reading-settings")
                ReaderTabButton(title: "搜索", systemImage: "magnifyingglass") { sheet = .search }
                    .accessibilityIdentifier("search-book")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // Sinks a quarter of the blank under the tabs into the home indicator area.
            .padding(.bottom, -(bottomSafeArea + 6) / 4)
            .background(chrome.ignoresSafeArea(edges: .bottom))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var chapterBar: some View {
        let last = max(chapterCount - 1, 0)
        let shown = min(Int(sliderChapter ?? Double(chapter)), last)
        let preview: String? = if sliderChapter != nil, let chapters = content?.chapters, chapters.indices.contains(shown) {
            "\(chapters[shown].title) · \(shown + 1)/\(chapterCount)"
        } else { nil }
        return VStack(spacing: 6) {
            // Paged reading shows progress in each page's footer; the bar only previews a slider drag.
            if !pageTurn.isPaged {
                Text(preview ?? "第 \(chapter + 1)/\(max(chapterCount, 1)) 章 · 本章 \(Int(fraction * 100))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 14) {
                Button("上一章") { go(to: chapter - 1) }
                    .disabled(chapter == 0)
                Slider(value: Binding(get: { sliderChapter ?? Double(chapter) }, set: { sliderChapter = $0.rounded() }),
                       in: 0...Double(max(last, 1)), step: 1) { editing in
                    if !editing, let target = sliderChapter {
                        sliderChapter = nil
                        go(to: Int(target))
                    }
                }
                .disabled(last == 0)
                .accessibilityLabel("章节")
                .accessibilityValue("第 \(shown + 1) 章，共 \(chapterCount) 章")
                Button("下一章") { go(to: chapter + 1) }
                    .disabled(!hasNext)
                    .accessibilityIdentifier("next-chapter-bar")
            }
            .font(.subheadline)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            if pageTurn.isPaged, let preview {
                Text(preview)
                    .font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .padding(.horizontal, 20)
            }
        }
    }

    private var autoReadingBar: some View {
        HStack(spacing: 14) {
            Label("自动阅读", systemImage: "play.circle").font(.subheadline.weight(.medium))
            Spacer()
            Button { autoSpeed = max(1, autoSpeed - 1) } label: { Image(systemName: "minus").frame(width: 36, height: 32) }
                .disabled(autoSpeed <= 1).accessibilityLabel("减速")
            Text("速度 \(autoSpeed)").monospacedDigit().font(.subheadline)
            Button { autoSpeed = min(10, autoSpeed + 1) } label: { Image(systemName: "plus").frame(width: 36, height: 32) }
                .disabled(autoSpeed >= 10).accessibilityLabel("加速")
            Button("退出") { autoReading = false }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("stop-auto-read")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var nextChapterButton: some View {
        Button { go(to: chapter + 1) } label: {
            Label("下一章", systemImage: "arrow.down.circle").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .accessibilityIdentifier("next-chapter")
    }

    private var returnBar: some View {
        HStack {
            Button { returnToSavedPlace() } label: { Label("回到我读到的地方", systemImage: "arrow.uturn.backward") }
            Spacer()
            Button("从这里继续读") {
                savedPlace = nil
                store.savePosition(bookID: bookID, chapter: chapter, offset: offset, fraction: fraction)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.card)
    }

    private var tip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.tap").foregroundStyle(Color.accent)
            Text("点单词看释义，长按可选词组。点空白处隐藏工具栏。").font(.footnote)
            Button { tipSeen = true } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }

    private var contents: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array((content?.chapters ?? []).enumerated()), id: \.element.id) { index, item in
                    Button { go(to: index); sheet = nil } label: {
                        HStack {
                            Text(item.title).foregroundStyle(index == chapter ? Color.accent : .primary)
                            Spacer()
                            if index == chapter { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                        }
                        .frame(minHeight: 36)
                    }
                    .id(index)
                }
                .onAppear { proxy.scrollTo(chapter, anchor: .center) }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { sheet = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private func open() async {
        guard content == nil, let book else { return }
        lastReadBookID = book.id.uuidString
        do {
            let loaded = try await store.content(for: book)
            let last = max(loaded.chapters.count - 1, 0)
            if let requestedOffset {
                savedPlace = book.position
                chapter = min(max(requestedChapter ?? 0, 0), last)
                offset = max(0, requestedOffset)
                jump = JumpRequest(offset: offset, highlight: true)
            } else {
                chapter = min(max(book.position.chapter, 0), last)
                offset = book.position.offset
            }
            content = loaded
        } catch {
            loadError = "书籍文件丢失或已损坏。可以从书架移除后重新导入。"
        }
    }

    private func positionChanged(_ value: Int, _ fraction: Double) {
        offset = value
        self.fraction = fraction
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: value, fraction: fraction) }
    }

    /// `atEnd` opens the chapter at its last page, for turning back across a chapter boundary.
    private func go(to index: Int, atEnd: Bool = false) {
        guard index >= 0, index < chapterCount, index != chapter else { return }
        lookup = nil
        chapter = index
        offset = atEnd ? max(0, (current?.text.utf16.count ?? 1) - 1) : 0
        fraction = atEnd ? 1 : 0
        jump = nil
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: index, offset: offset, fraction: fraction) }
    }

    /// Opens a search result, keeping the reader's own place to come back to.
    private func visit(chapter index: Int, offset value: Int) {
        guard content?.chapters.indices.contains(index) == true else { return }
        if savedPlace == nil { savedPlace = ReadingPosition(chapter: chapter, offset: offset, fraction: fraction) }
        lookup = nil
        chapter = index
        offset = value
        jump = JumpRequest(offset: value, highlight: true)
    }

    /// A tapped link: web addresses open in the browser, places in the book are visited like a search result,
    /// so "回到我读到的地方" brings the reader back from a footnote.
    private func openLink(_ target: String) {
        lookup = nil
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            UIApplication.shared.open(url)
            return
        }
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let place = content?.location(ofPath: parts[0], fragment: parts.count > 1 ? parts[1] : nil) else {
            toast = "这个链接指向的内容不在书里"
            return
        }
        visit(chapter: place.chapter, offset: place.offset)
    }

    private func reachedChapterEnd() {
        if hasNext {
            go(to: chapter + 1)
        } else if autoReading {
            autoReading = false
            toast = "已经读到最后了"
        }
    }

    private func startAutoReading() {
        lookup = nil
        autoReading = true
        withAnimation(.easeInOut(duration: 0.2)) {
            showPanel = false
            chromeVisible = false
        }
    }

    private func returnToSavedPlace() {
        guard let place = savedPlace else { return }
        savedPlace = nil
        lookup = nil
        if place.chapter == chapter {
            jump = JumpRequest(offset: place.offset, highlight: false)
        } else {
            chapter = place.chapter
            offset = place.offset
            fraction = place.fraction ?? 0
            jump = nil
        }
    }

    private func tappedBlank() {
        if lookup != nil {
            lookup = nil
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeVisible.toggle()
                showPanel = false
            }
        }
    }

    /// Turning a page puts the toolbars away instead of leaving them over the new page.
    private func hideChrome() {
        guard chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible = false
            showPanel = false
        }
    }

    private func show(_ selection: ReadingSelection) {
        tipSeen = true
        lookup = selection
    }

    private func save(_ selection: ReadingSelection) {
        let result = store.savePassage(bookID: bookID, chapter: chapter, offset: selection.offset,
                                       selection: selection.text, sentence: selection.sentence)
        switch result {
        case .saved: toast = "已加入生词本"
        case .alreadySaved: toast = "生词本里已经有这个词"
        case .failed: break // The store's error alert explains.
        }
    }

    private func close() {
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: offset, fraction: fraction) }
        store.persist()
        dismiss()
    }

    private func updateMarks() {
        guard let current else { marks = []; return }
        let forms = learningForms
        guard !forms.isEmpty else { marks = []; return }
        marks = ReaderTextTools.markedRanges(in: current.text, words: ReadingSurface.englishWordRanges(in: current.text), forms: forms)
    }
}

private struct SystemTerm: Identifiable {
    let id = UUID()
    var text: String
}

struct ToastLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("toast")
    }
}

/// The definition appears next to the text instead of in a modal sheet, so the
/// sentence stays visible while reading the meaning.
struct LookupCard: View {
    let selection: ReadingSelection
    let entry: DictionaryEntry?
    let isSaved: Bool
    /// The card takes the reading theme's toolbar shade and ink, like the bars around the page.
    var palette = ReaderPalette(day: ReaderTheme.defaultDay, night: ReaderTheme.defaultNight)
    var onSave: () -> Void
    var onMore: () -> Void
    var onClose: () -> Void

    private var isLikelyName: Bool {
        guard let first = selection.text.first, first.isUppercase else { return false }
        return !selection.sentence.hasPrefix(selection.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry?.headword ?? selection.text)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .lineLimit(2).minimumScaleFactor(0.7)
                    if let phonetic = entry?.phonetic, !phonetic.isEmpty {
                        Text("/\(phonetic)/").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("关闭释义")
                }
                if let inflected = entry?.inflectedFrom, inflected.lowercased() != entry?.headword.lowercased() {
                    Text("\(inflected) 是 \(entry?.headword ?? "") 的变形").font(.caption).foregroundStyle(.secondary)
                }
                if let entry {
                    ScrollView {
                        Text(entry.definition).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 132)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(selection.text.contains(" ") ? "离线词典只收录单词。可以用系统词典查这个词组。"
                         : isLikelyName ? "离线词典里没有这个词，它可能是人名或地名。" : "离线词典里没有这个词。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(Color(uiColor: palette.ink))
            HStack(spacing: 10) {
                Button(action: onSave) {
                    Label(isSaved ? "已在生词本" : "加入生词本", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(isSaved)
                .accessibilityIdentifier("save-selection")
                Button(action: onMore) {
                    Label("系统词典", systemImage: "character.book.closed").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lookup-dictionary")
            }
            .controlSize(.regular)
        }
        .padding(16)
        .background(Color(uiColor: palette.chrome), in: RoundedRectangle(cornerRadius: 20))
        .tint(.accent)
        .accessibilityIdentifier("lookup-card")
    }
}

/// Places the lookup card just below the word, or above it when there's no room below,
/// with the pointer (the first subview, drawn behind the card) poking out at the word.
struct LookupBubbleLayout: Layout {
    /// The word's frame in the layout's coordinates; nil puts the card at the top.
    var anchor: CGRect?
    var margin: CGFloat = 12
    var gap: CGFloat = 10
    var maxWidth: CGFloat = 440

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let pointer = subviews[0], card = subviews[1]
        let width = max(0, min(bounds.width - 2 * margin, maxWidth))
        let height = card.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let top = bounds.minY + margin, bottom = bounds.maxY - margin

        guard let anchor = anchor?.offsetBy(dx: bounds.minX, dy: bounds.minY) else {
            card.place(at: CGPoint(x: bounds.midX - width / 2, y: top), proposal: ProposedViewSize(width: width, height: height))
            pointer.place(at: CGPoint(x: bounds.midX, y: top), anchor: .center, proposal: .unspecified)
            return
        }
        let roomBelow = bottom - (anchor.maxY + gap), roomAbove = (anchor.minY - gap) - top
        let below = roomBelow >= height || roomBelow >= roomAbove
        let y = min(max(below ? anchor.maxY + gap : anchor.minY - gap - height, top), max(top, bottom - height))
        let x = min(max(anchor.midX - width / 2, bounds.minX + margin), bounds.maxX - margin - width)
        card.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
        // Kept clear of the rounded corners.
        let pointerX = min(max(anchor.midX, x + 28), x + width - 28)
        pointer.place(at: CGPoint(x: pointerX, y: below ? y : y + height), anchor: .center, proposal: .unspecified)
    }
}

struct SystemDictionary: UIViewControllerRepresentable {
    var term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
