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

    private var featured: ReaderBook? {
        store.books.first { $0.id.uuidString == lastReadBookID } ?? store.books.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let failure = store.readFailure { failureCard(failure) }
                    if let featured {
                        featuredCard(featured)
                        let others = store.books.filter { $0.id != featured.id }
                        if !others.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("书架上的其他书").font(.title3.bold()).padding(.bottom, 8)
                                ForEach(others) { row($0) }
                            }
                        }
                    } else if store.readFailure == nil {
                        emptyState
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
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
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data, .plainText]) { result in
            if case .success(let url) = result { startImport(url) }
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

    private func featuredCard(_ book: ReaderBook) -> some View {
        let started = book.position.offset > 0 || book.position.chapter > 0
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                BookCover(book: book).frame(width: 84, height: 122)
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    if started {
                        ProgressView(value: book.progress).tint(.accent)
                        Text("已读 \(Int(book.progress * 100))% · \(book.chapters[min(book.position.chapter, book.chapters.count - 1)].title)")
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    } else if book.isSample {
                        Text("示例 · 前三章节选").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                bookMenu(book)
            }
            Button { open(ReaderRoute(bookID: book.id)) } label: {
                Text(started ? "继续阅读" : "开始阅读").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("continue-reading")
        }
        .padding(18)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ book: ReaderBook) -> some View {
        HStack(spacing: 14) {
            Button { open(ReaderRoute(bookID: book.id)) } label: {
                HStack(spacing: 14) {
                    BookCover(book: book).frame(width: 46, height: 66)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title).font(.headline).multilineTextAlignment(.leading).lineLimit(2)
                        if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                        Text(book.progress > 0 ? "已读 \(Int(book.progress * 100))%" : book.isSample ? "示例节选" : "未开始")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            bookMenu(book)
        }
        .padding(.vertical, 8)
        .contextMenu { Button("移除书籍", systemImage: "trash", role: .destructive) { removeID = book.id } }
        .accessibilityIdentifier("book-\(book.id.uuidString)")
    }

    private func bookMenu(_ book: ReaderBook) -> some View {
        Menu {
            Button("移除书籍", systemImage: "trash", role: .destructive) { removeID = book.id }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 36, height: 36).contentShape(Rectangle())
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
            defer { importTask = nil; importingName = nil }
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

struct BookCover: View {
    let book: ReaderBook

    var body: some View {
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
            .background(Color.cover, in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityHidden(true)
    }
}
