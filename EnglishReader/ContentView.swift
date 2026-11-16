import SwiftUI
import UniformTypeIdentifiers

struct ReaderRoute: Identifiable {
    let id = UUID()
    var bookID: UUID
    var chapter: Int?
    var offset: Int?
}

struct ContentView: View {
    @State private var store = LibraryStore()
    @State private var tab = 0
    @State private var route: ReaderRoute?

    var body: some View {
        TabView(selection: $tab) {
            Tab("书架", systemImage: "books.vertical", value: 0) {
                LibraryView(store: store) { route = $0 }
            }
            Tab("生词本", systemImage: "bookmark", value: 1) {
                WordsView(store: store) { route = $0 }
            }
            .badge(store.favorites.filter { $0.isDue(at: .now) }.count)
        }
        .tint(.accent)
        .fullScreenCover(item: $route) { value in
            ReaderView(store: store, bookID: value.bookID, requestedChapter: value.chapter, requestedOffset: value.offset)
        }
        .alert("没有保存成功", isPresented: Binding(get: { store.errorMessage != nil && route == nil },
                                              set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct LibraryView: View {
    let store: LibraryStore
    var open: (ReaderRoute) -> Void

    @AppStorage("lastReadBookID") private var lastReadBookID = ""
    @State private var choosingFile = false
    @State private var importTask: Task<Void, Never>?
    @State private var importingName: String?
    @State private var importError: String?
    @State private var duplicateID: UUID?
    @State private var removeID: UUID?

    /// Started, unfinished books, the one read most recently first.
    private var reading: [ReaderBook] {
        let started = store.books.filter { $0.isStarted && !$0.isFinished }
        return started.filter { $0.id.uuidString == lastReadBookID } + started.filter { $0.id.uuidString != lastReadBookID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if let failure = store.readFailure { failureCard(failure).padding(.horizontal, 20) }
                    if !reading.isEmpty { continueShelf }
                    if !store.books.isEmpty {
                        grid
                    } else if store.readFailure == nil {
                        emptyState
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Color.paper)
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { choosingFile = true } label: { Label("导入书籍", systemImage: "plus") }
                        .disabled(importTask != nil || store.readFailure != nil)
                        .accessibilityIdentifier("import-book")
                }
            }
            .overlay(alignment: .bottom) { if let importingName { importProgress(importingName) } }
        }
        .sheet(isPresented: $choosingFile) {
            DocumentPicker { startImport($0) }.ignoresSafeArea()
        }
        .alert("没有导入成功", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .alert("这本书已在书架上", isPresented: Binding(get: { duplicateID != nil }, set: { if !$0 { duplicateID = nil } })) {
            Button("打开") { if let duplicateID { open(ReaderRoute(bookID: duplicateID)) } }
            Button("取消", role: .cancel) {}
        }
        .alert("从书架移除这本书？", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } })) {
            Button("移除", role: .destructive) { if let removeID { store.removeBook(id: removeID) } }
            Button("取消", role: .cancel) {}
        } message: { Text("书和阅读进度会被删除。生词本里的词会保留。") }
    }

    // MARK: Pieces

    /// Like Apple Books' "Continue": large covers in a horizontal row, progress underneath.
    private var continueShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("继续阅读").font(.title2.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 18) {
                    ForEach(reading) { book in
                        VStack(alignment: .leading, spacing: 8) {
                            coverButton(book).frame(height: 210)
                            ProgressView(value: book.progress).tint(.accent)
                            HStack {
                                Text("\(book.percentRead)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                bookMenu(book)
                            }
                        }
                        .frame(width: 210 * book.coverAspect)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    /// Like Apple Books' library: covers of their own proportions sitting on a common baseline.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("全部书籍").font(.title2.bold())
                Spacer()
                Text("\(store.books.count) 本").font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 22, alignment: .bottom)],
                      alignment: .leading, spacing: 26) {
                ForEach(store.books) { book in
                    VStack(alignment: .leading, spacing: 6) {
                        coverButton(book)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .aspectRatio(2 / 3, contentMode: .fit)
                        HStack {
                            status(book)
                            Spacer(minLength: 0)
                            bookMenu(book)
                        }
                    }
                    .accessibilityIdentifier("book-\(book.id.uuidString)")
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func coverButton(_ book: ReaderBook) -> some View {
        Button { open(ReaderRoute(bookID: book.id)) } label: {
            BookCover(book: book, url: store.coverURL(for: book))
        }
        .buttonStyle(.plain)
        .contextMenu { Button("移除书籍", systemImage: "trash", role: .destructive) { removeID = book.id } }
        .accessibilityLabel(book.author.isEmpty ? book.title : "\(book.title)，\(book.author)")
        .accessibilityValue(book.isStarted ? "已读 \(book.percentRead)%" : "未开始")
    }

    @ViewBuilder
    private func status(_ book: ReaderBook) -> some View {
        if book.isFinished {
            Text("已读完").font(.caption).foregroundStyle(.secondary)
        } else if book.isStarted {
            Text("\(book.percentRead)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(book.isSample ? "示例" : "新")
                .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.accent, in: Capsule())
        }
    }

    private func bookMenu(_ book: ReaderBook) -> some View {
        Menu {
            Button(book.isStarted ? "继续阅读" : "开始阅读", systemImage: "book") { open(ReaderRoute(bookID: book.id)) }
            Button("移除书籍", systemImage: "trash", role: .destructive) { removeID = book.id }
        } label: {
            Image(systemName: "ellipsis").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 32, height: 28).contentShape(Rectangle())
        }
        .accessibilityLabel("更多操作")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("把想读的英文书放进来", systemImage: "books.vertical")
        } description: {
            Text("支持没有 DRM 的 EPUB 和 TXT。读的时候点任何一个单词，就能看到中文释义。")
        } actions: {
            Button("导入书籍") { choosingFile = true }.buttonStyle(.borderedProminent)
            Button("读示例书") { store.addSample() }
        }
        .padding(.top, 40)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("书库读取失败", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text("\(message)可以重试；如果一直失败，可以把旧文件另存一份，然后从空书架重新开始。").font(.subheadline)
            HStack {
                Button("重试") { store.retryLoading() }.buttonStyle(.bordered)
                Button("另存旧文件并重新开始") { store.setAsideUnreadableLibrary() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func importProgress(_ name: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("正在导入《\(name)》").lineLimit(1)
            Button("取消") { importTask?.cancel() }
        }
        .font(.subheadline)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private func startImport(_ url: URL) {
        importingName = url.deletingPathExtension().lastPathComponent
        importTask = Task {
            defer {
                importTask = nil; importingName = nil
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let id = try await store.importBook(url: url)
                lastReadBookID = id.uuidString
                open(ReaderRoute(bookID: id))
            } catch LibraryError.duplicate(let id) {
                duplicateID = id
            } catch is CancellationError {
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// The EPUB's own cover when it has one, otherwise a generated title cover.
/// Sizes itself to the book's proportions within whatever frame it is offered.
struct BookCover: View {
    let book: ReaderBook
    var url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? url.flatMap(CoverImages.cached) {
                // Overlaying a clear box keeps an out-of-range image cropped to the cover's frame.
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                generated
            }
        }
        .aspectRatio(book.coverAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .task(id: url) { if let url { image = await CoverImages.load(url) } }
        .accessibilityHidden(true)
    }

    private var generated: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Size the title so its longest word fits on one line instead of breaking mid-word.
            let longest = book.title.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 1
            let titleSize = max(7, min(width * 0.17, width * 0.76 / (CGFloat(longest) * 0.56)))
            VStack(spacing: width * 0.06) {
                if !book.author.isEmpty {
                    Text(book.author).font(.system(size: max(6, width * 0.09))).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                Text(book.title)
                    .font(.system(size: titleSize, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Rectangle().frame(width: width * 0.4, height: 1).opacity(0.45)
            }
            .padding(width * 0.12)
            .foregroundStyle(Color(uiColor: .readerPaper).opacity(0.95))
            .environment(\.colorScheme, .light)
            .frame(width: width, height: proxy.size.height)
            .background(Color.cover)
        }
    }
}

/// Covers are small JPEGs written at import; decode them off the main thread once.
@MainActor
enum CoverImages {
    private static let cache = NSCache<NSURL, UIImage>()

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Picks in copy mode: the system hands over a private copy instead of a security-scoped URL.
/// Open-in-place needs a sandbox extension issued to the app's identity, which fails when
/// a re-signed app's bundle ID doesn't match its application-identifier entitlement.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType(filenameExtension: "epub") ?? .data, .plainText], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
