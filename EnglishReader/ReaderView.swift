import SwiftUI
import UIKit

struct ReaderView: View {
    let store: LibraryStore
    let bookID: UUID
    var requestedChapter: Int?
    var requestedOffset: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastReadBookID") private var lastReadBookID = ""
    @AppStorage("readerFont") private var fontSize = ReaderTypography.defaultSize
    @AppStorage("readerAppearance") private var appearance = "system"
    @AppStorage("readerTipSeen") private var tipSeen = false

    @State private var content: BookContent?
    @State private var loadError: String?
    @State private var chapter = 0
    @State private var offset = 0
    @State private var fraction = 0.0
    @State private var jump: JumpRequest?
    @State private var lookup: ReadingSelection?
    @State private var chromeVisible = true
    @State private var showContents = false
    @State private var showSettings = false
    @State private var systemTerm: SystemTerm?
    @State private var toast: String?
    /// Set while visiting a saved word's source; the reader's own place is kept here.
    @State private var savedPlace: ReadingPosition?
    @State private var marks: [NSRange] = []

    private var book: ReaderBook? { store.books.first { $0.id == bookID } }
    private var current: ReaderChapter? {
        guard let content, content.chapters.indices.contains(chapter) else { return nil }
        return content.chapters[chapter]
    }
    private var chapterCount: Int { content?.chapters.count ?? book?.chapters.count ?? 0 }
    private var hasNext: Bool { chapter + 1 < chapterCount }
    private var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }

    /// Surface forms of words still being learned; every occurrence gets underlined.
    private var learningForms: Set<String> {
        Set(store.favorites.filter { !$0.mastered }.flatMap { [WordDictionary.normalize($0.selection), $0.key] })
    }

    var body: some View {
        NavigationStack {
            readingArea
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomInset }
            .overlay(alignment: lookup?.isInLowerHalf == true ? .top : .bottom) { lookupOverlay }
            .overlay(alignment: .top) {
                if let toast { ToastLabel(text: toast).padding(.top, 8) }
            }
            .animation(.default, value: toast)
            .animation(.spring(duration: 0.25), value: lookup?.id)
            .navigationTitle(current?.title ?? book?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.paper, for: .navigationBar)
            .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: { Label("书架", systemImage: "chevron.left") }
                        .accessibilityIdentifier("close-reader")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("阅读设置", systemImage: "textformat.size") }
                        .accessibilityIdentifier("reading-settings")
                }
            }
            .statusBarHidden(!chromeVisible)
        }
        .tint(.accent)
        .preferredColorScheme(colorScheme)
        .task { await open() }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
        .onChange(of: learningForms, initial: true) { updateMarks() }
        .onChange(of: current?.id) { updateMarks() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.persist() } }
        .sheet(isPresented: $showContents) { contents }
        .sheet(isPresented: $showSettings) { ReaderSettings(fontSize: $fontSize, appearance: $appearance) }
        .sheet(item: $systemTerm) { SystemDictionary(term: $0.text).ignoresSafeArea() }
        .alert("没有保存成功", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    // MARK: Pieces

    private var readingArea: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            if let current {
                ReadingSurface(
                    chapter: current, fontSize: fontSize, initialOffset: offset, jump: jump, markedRanges: marks,
                    onPosition: { value, fraction in
                        offset = value
                        self.fraction = fraction
                        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: value) }
                    },
                    onTapWord: { show($0) },
                    onTapBlank: { tappedBlank() },
                    onScroll: { lookup = nil },
                    onLookup: { show($0) },
                    onSave: { save($0) })
                .id(current.id)
                .ignoresSafeArea(edges: chromeVisible ? [] : .vertical)
            } else if let loadError {
                ContentUnavailableView("无法打开这本书", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("正在打开…")
            }
        }
    }

    private var bottomInset: some View {
        VStack(spacing: 0) {
            if !tipSeen && content != nil && lookup == nil { tip.padding(.bottom, 8) }
            if savedPlace != nil { returnBar }
            if chromeVisible {
                bottomBar
            } else if fraction >= 0.99 && hasNext {
                nextChapterButton.padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var lookupOverlay: some View {
        if let lookup {
            LookupCard(selection: lookup, entry: WordDictionary.shared.lookup(lookup.text),
                       isSaved: store.favorite(matching: lookup.text) != nil,
                       onSave: { save(lookup) },
                       onMore: { systemTerm = SystemTerm(text: lookup.text) },
                       onClose: { self.lookup = nil })
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .transition(.move(edge: lookup.isInLowerHalf ? .top : .bottom).combined(with: .opacity))
            .id(lookup.id)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button { showContents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("目录").accessibilityIdentifier("open-chapters")
            Button { go(to: chapter - 1) } label: { Image(systemName: "chevron.backward").frame(width: 44, height: 44) }
                .disabled(chapter == 0).accessibilityLabel("上一章")
            if fraction >= 0.99 && hasNext {
                nextChapterButton.frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 2) {
                    Text(current?.title ?? "").lineLimit(1)
                    Text("第 \(chapter + 1)/\(max(chapterCount, 1)) 章 · 本章 \(Int(fraction * 100))%")
                        .monospacedDigit().font(.caption2)
                }
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
            Button { go(to: chapter + 1) } label: { Image(systemName: "chevron.forward").frame(width: 44, height: 44) }
                .disabled(!hasNext).accessibilityLabel("下一章")
        }
        .padding(.horizontal, 8)
        .background(Color.paper)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                store.savePosition(bookID: bookID, chapter: chapter, offset: offset)
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
                    Button { go(to: index); showContents = false } label: {
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showContents = false } } }
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

    private func go(to index: Int) {
        guard index >= 0, index < chapterCount, index != chapter else { return }
        lookup = nil
        chapter = index
        offset = 0
        fraction = 0
        jump = nil
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: index, offset: 0) }
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
            jump = nil
        }
    }

    private func tappedBlank() {
        if lookup != nil {
            lookup = nil
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
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
        if savedPlace == nil { store.savePosition(bookID: bookID, chapter: chapter, offset: offset) }
        store.persist()
        dismiss()
    }

    private func updateMarks() {
        guard let current else { marks = []; return }
        let forms = learningForms
        guard !forms.isEmpty else { marks = []; return }
        let text = current.text as NSString
        marks = ReadingSurface.englishWordRanges(in: current.text).filter {
            forms.contains(WordDictionary.normalize(text.substring(with: $0)))
        }
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
    var onSave: () -> Void
    var onMore: () -> Void
    var onClose: () -> Void

    private var isLikelyName: Bool {
        guard let first = selection.text.first, first.isUppercase else { return false }
        return !selection.sentence.hasPrefix(selection.text)
    }

    var body: some View {
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
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .tint(.accent)
        .accessibilityIdentifier("lookup-card")
    }
}

struct ReaderSettings: View {
    @Binding var fontSize: Double
    @Binding var appearance: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    Stepper(value: $fontSize, in: ReaderTypography.sizeRange, step: 1) {
                        Text("\(Int(fontSize))").monospacedDigit()
                    }
                    Text("The pleasure of reading begins with a single page.")
                        .font(Font(ReaderTypography.serif(ReaderTypography.pointSize(fontSize)) as CTFont))
                        .lineSpacing(6)
                        .padding(.vertical, 4)
                }
                Section("外观") {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("书籍、阅读位置和生词都只保存在这台设备上，不会上传。删除应用会一并删除。")
                    Text("释义来自内置的离线英汉词典 ECDICT（MIT 许可）。示例书节选自 Project Gutenberg 的公版《爱丽丝梦游仙境》。")
                } header: { Text("关于") }
                    .font(.footnote).foregroundStyle(.secondary)
                Section { MadeWithAirBuild() }
            }
            .navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SystemDictionary: UIViewControllerRepresentable {
    var term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
