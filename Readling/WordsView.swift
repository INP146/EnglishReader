import SwiftUI

struct WordsView: View {
    let store: LibraryStore
    var openSource: (ReaderRoute) -> Void

    @State private var showMastered = false
    @State private var search = ""
    @State private var bookFilter: UUID?
    @State private var detail: SavedPassage?
    @State private var sourceAfterDismiss: SavedPassage?
    @State private var reviewing = false
    @State private var undo: Undo?

    private struct Undo: Equatable {
        let id = UUID()
        var message: String
        var restore: SavedPassage
        var wasDeleted: Bool
    }

    private var due: [SavedPassage] {
        store.favorites.filter { $0.isDue(at: .now) }
    }

    private var visible: [SavedPassage] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.favorites.filter { item in
            item.mastered == showMastered
                && (bookFilter == nil || item.bookID == bookFilter)
                && (query.isEmpty || [item.displayWord, item.selection, item.definition ?? "", item.sentence]
                    .contains { $0.lowercased().contains(query) })
        }
    }

    private var bookTitles: [(UUID, String)] {
        var seen = Set<UUID>()
        return store.favorites.compactMap { seen.insert($0.bookID).inserted ? ($0.bookID, $0.bookTitle) : nil }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.favorites.isEmpty {
                    Section { reviewCard }
                        .listRowBackground(Color.card)
                }
                Section {
                    Picker("状态", selection: $showMastered) {
                        Text("学习中").tag(false)
                        Text("已掌握").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(visible) { item in
                        Button { detail = item } label: { WordRow(item: item) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("删除", systemImage: "trash", role: .destructive) { delete(item) }
                            }
                            .swipeActions(edge: .leading) {
                                Button(item.mastered ? "继续学" : "已掌握", systemImage: item.mastered ? "arrow.uturn.backward" : "checkmark") {
                                    toggleMastered(item)
                                }
                                .tint(.accent)
                            }
                    }
                }
                .listRowBackground(Color.card)
            }
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .overlay {
                if visible.isEmpty { emptyState }
            }
            .searchable(text: $search, prompt: "搜索单词、释义或原句")
            .navigationTitle("生词本")
            .toolbar {
                if bookTitles.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("书籍", selection: $bookFilter) {
                                Text("全部书籍").tag(UUID?.none)
                                ForEach(bookTitles, id: \.0) { Text($0.1).tag(UUID?.some($0.0)) }
                            }
                        } label: {
                            Label("按书筛选", systemImage: bookFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let undo {
                    HStack(spacing: 14) {
                        Text(undo.message)
                        Button("撤销") { restore(undo) }.fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: undo)
            .task(id: undo) {
                guard undo != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { undo = nil }
            }
        }
        .sheet(item: $detail, onDismiss: {
            if let item = sourceAfterDismiss {
                sourceAfterDismiss = nil
                openSource(ReaderRoute(bookID: item.bookID, chapter: item.chapterIndex, offset: item.offset))
            }
        }) { item in
            WordDetail(store: store, itemID: item.id) {
                sourceAfterDismiss = item
                detail = nil
            }
        }
        .fullScreenCover(isPresented: $reviewing) { ReviewView(store: store, queue: due.map(\.id)) }
    }

    private var reviewCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(due.isEmpty ? "今天的复习完成了" : "今天要复习 \(due.count) 个词").font(.headline)
                Text("学习中 \(store.favorites.filter { !$0.mastered }.count) · 已掌握 \(store.favorites.filter(\.mastered).count)")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("开始复习") { reviewing = true }
                .buttonStyle(.borderedProminent)
                .disabled(due.isEmpty)
                .accessibilityIdentifier("start-review")
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var emptyState: some View {
        if store.favorites.isEmpty {
            ContentUnavailableView("生词本还是空的", systemImage: "bookmark",
                                   description: Text("读书时点一个单词，点释义卡片右上角的星标。原句和出处会一起保存。"))
        } else if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ContentUnavailableView(showMastered ? "还没有已掌握的词" : "没有正在学习的词", systemImage: "checkmark.circle",
                                   description: Text(showMastered ? "复习时连续记住一个词，或在列表中向右滑，就会标为已掌握。" : "所有词都已掌握。"))
        }
    }

    private func toggleMastered(_ item: SavedPassage) {
        store.setMastered(id: item.id, !item.mastered)
        undo = Undo(message: item.mastered ? "已移回学习中" : "已标为掌握", restore: item, wasDeleted: false)
    }

    private func delete(_ item: SavedPassage) {
        store.deleteFavorite(id: item.id)
        undo = Undo(message: "已删除“\(item.displayWord)”", restore: item, wasDeleted: true)
    }

    private func restore(_ undo: Undo) {
        if undo.wasDeleted { store.restoreFavorite(undo.restore) } else { store.setMastered(id: undo.restore.id, undo.restore.mastered) }
        self.undo = nil
    }
}

/// The saved sentence with the saved word in bold.
func highlightedSentence(_ sentence: String, word: String) -> AttributedString {
    var result = AttributedString(sentence)
    guard !word.isEmpty else { return result }
    var searchStart = result.startIndex
    while let range = result[searchStart...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
        result[range].inlinePresentationIntent = .stronglyEmphasized
        searchStart = range.upperBound
    }
    return result
}

struct WordRow: View {
    let item: SavedPassage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.displayWord).font(.system(.headline, design: .serif)).lineLimit(2)
                if let phonetic = item.phonetic, !phonetic.isEmpty {
                    Text("/\(phonetic)/").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let definition = item.definition {
                Text(definition.replacingOccurrences(of: "\n", with: "  ")).font(.subheadline).lineLimit(1)
            }
            Text(highlightedSentence(item.sentence, word: item.selection))
                .font(.system(.footnote, design: .serif)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct WordDetail: View {
    let store: LibraryStore
    let itemID: UUID
    var openSource: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var item: SavedPassage? { store.favorites.first { $0.id == itemID } }

    var body: some View {
        NavigationStack {
            if let item {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.displayWord)
                                    .font(item.isExpression ? .system(.title3, design: .serif) : .system(.largeTitle, design: .serif).weight(.semibold))
                                if let phonetic = item.phonetic, !phonetic.isEmpty {
                                    Text("/\(phonetic)/").foregroundStyle(.secondary)
                                }
                            }
                            if item.selection.lowercased() != item.displayWord.lowercased() {
                                Text("书中的形式：\(item.selection)").font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(item.definition ?? "离线词典里没有这个词的释义。").textSelection(.enabled)
                            if let source = item.definitionSource {
                                Text(source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    Section("原句") {
                        Text(highlightedSentence(item.sentence, word: item.selection))
                            .font(.system(.body, design: .serif)).lineSpacing(5).textSelection(.enabled)
                        Text("\(item.bookTitle) · \(item.chapterTitle)").font(.footnote).foregroundStyle(.secondary)
                        if store.books.contains(where: { $0.id == item.bookID }) {
                            Button("回到原文", systemImage: "book", action: openSource)
                        } else {
                            Text("原书已从书架移除。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button(item.mastered ? "移回学习中" : "标为已掌握", systemImage: item.mastered ? "arrow.uturn.backward" : "checkmark") {
                            store.setMastered(id: item.id, !item.mastered)
                        }
                        Button("删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                            .tint(.red)
                    }
                }
                .navigationTitle("单词").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .confirmationDialog("从生词本删除“\(item.displayWord)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { store.deleteFavorite(id: item.id); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Flashcards over today's due words: recall first, then reveal the meaning.
struct ReviewView: View {
    let store: LibraryStore
    @State var queue: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false
    @State private var reviewed = 0
    @State private var retried = Set<UUID>()

    private var current: SavedPassage? {
        queue.first.flatMap { id in store.favorites.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let item = current {
                    ProgressView(value: Double(reviewed), total: Double(reviewed + queue.count)).tint(.accent)
                    Spacer()
                    VStack(spacing: 18) {
                        Text(item.displayWord)
                            .font(item.isExpression ? .system(.title2, design: .serif) : .system(size: 40, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.center)
                        Text(highlightedSentence(item.sentence, word: item.selection))
                            .font(.system(.title3, design: .serif)).lineSpacing(6)
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if revealed {
                            VStack(spacing: 6) {
                                if let phonetic = item.phonetic, !phonetic.isEmpty {
                                    Text("/\(phonetic)/").foregroundStyle(.secondary)
                                }
                                Text(item.definition ?? "离线词典里没有这个词的释义。").multilineTextAlignment(.center)
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 24))
                    Spacer()
                    if revealed {
                        HStack(spacing: 12) {
                            Button { answer(item, remembered: false) } label: { Text("还不熟").frame(maxWidth: .infinity, minHeight: 36) }
                                .buttonStyle(.bordered)
                            Button { answer(item, remembered: true) } label: { Text("记住了").frame(maxWidth: .infinity, minHeight: 36) }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button { withAnimation { revealed = true } } label: { Text("想好了，看释义").frame(maxWidth: .infinity, minHeight: 36) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("reveal-definition")
                    }
                } else {
                    Spacer()
                    ContentUnavailableView("复习完成", systemImage: "checkmark.circle",
                                           description: Text("今天复习了 \(reviewed) 个词。记住的词会隔几天再出现，越熟间隔越长。"))
                    Spacer()
                    Button { dismiss() } label: { Text("完成").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .background(Color.paper)
            .navigationTitle("复习").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("结束") { dismiss() } } }
        }
        .tint(.accent)
    }

    private func answer(_ item: SavedPassage, remembered: Bool) {
        queue.removeFirst()
        if remembered || retried.contains(item.id) {
            // A word missed once in this session is scheduled by its first answer.
            if !retried.contains(item.id) { store.review(id: item.id, remembered: true) }
            reviewed += 1
        } else {
            store.review(id: item.id, remembered: false)
            retried.insert(item.id)
            queue.append(item.id) // See it again at the end of this session.
        }
        revealed = false
    }
}
