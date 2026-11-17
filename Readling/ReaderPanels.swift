import PhotosUI
import SwiftUI
import UIKit

/// The settings that sit above the reader's tab row: brightness, type, color,
/// background, page turning and the doors to finer settings.
struct ReaderSettingsPanel: View {
    var isNight: Bool
    var onFonts: () -> Void
    var onSpacing: () -> Void
    var onMore: () -> Void
    var onAutoRead: () -> Void

    @AppStorage("readerFont") private var fontSize = ReaderTypography.defaultSize
    @AppStorage("readerTypeface") private var typeface = ReaderTypeface.newYork
    @AppStorage("readerAppearance") private var appearance = "system"
    @AppStorage("readerDayTheme") private var dayTheme = ReaderTheme.defaultDay
    @AppStorage("readerNightTheme") private var nightTheme = ReaderTheme.defaultNight
    @AppStorage("readerBackdrop") private var backdrop = ReaderBackdrop.plain
    @AppStorage("readerBackdropVersion") private var backdropVersion = 0
    @AppStorage("readerPageTurn") private var pageTurn = PageTurn.scroll
    @AppStorage("readerEyeCare") private var eyeCare = false
    @State private var brightness = ScreenBrightness.current
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var photoError = false

    private var palette: ReaderPalette { ReaderPalette(day: dayTheme, night: nightTheme) }
    private var hasCustomImage: Bool { _ = backdropVersion; return ReaderBackdrop.customImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("亮度") {
                Slider(value: $brightness, in: 0...1)
                    .onChange(of: brightness) { _, value in ScreenBrightness.set(value) }
                    .accessibilityLabel("亮度")
                Button { eyeCare.toggle() } label: {
                    Label("护眼模式", systemImage: eyeCare ? "eye.fill" : "eye")
                        .labelStyle(TrailingIconLabelStyle())
                        .foregroundStyle(eyeCare ? Color.accent : .primary)
                }
                .accessibilityValue(eyeCare ? "开" : "关")
                .accessibilityIdentifier("eye-care")
            }
            row("字号") {
                Button { fontSize = max(ReaderTypography.sizeRange.lowerBound, fontSize - 1) } label: {
                    sizeGlyph("−").pill()
                }
                .disabled(fontSize <= ReaderTypography.sizeRange.lowerBound)
                .accessibilityLabel("字号减小")
                Text("\(Int(fontSize))").monospacedDigit().frame(minWidth: 28)
                Button { fontSize = min(ReaderTypography.sizeRange.upperBound, fontSize + 1) } label: {
                    sizeGlyph("+").pill()
                }
                .disabled(fontSize >= ReaderTypography.sizeRange.upperBound)
                .accessibilityLabel("字号增大")
                Button(action: onFonts) {
                    HStack(spacing: 4) {
                        Text(typeface.title).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .pill(expand: false)
                    .fixedSize()
                }
                .accessibilityIdentifier("choose-font")
            }
            row("颜色") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(ReaderTheme.all) { theme in themeSwatch(theme) }
                    }
                    .padding(2)
                }
            }
            row("背景") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(ReaderBackdrop.allCases) { item in backdropTile(item) }
                    }
                    .padding(2)
                }
            }
            row("翻页") {
                HStack(spacing: 0) {
                    ForEach(PageTurn.allCases) { item in
                        Button { pageTurn = item } label: {
                            Text(item.title)
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(pageTurn == item ? Color.primary.opacity(0.16) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .accessibilityAddTraits(pageTurn == item ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            row("其他") {
                Button(action: onSpacing) { Text("间距设置").pill() }
                Button(action: onMore) {
                    HStack(spacing: 4) {
                        Text("更多")
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .pill()
                }
            }
            Button(action: onAutoRead) {
                Label("开启自动阅读", systemImage: "play.circle")
                    .labelStyle(TrailingIconLabelStyle())
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("auto-read")
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    try await ReaderBackdrop.saveCustomImage(from: item)
                    backdropVersion += 1
                    backdrop = .custom
                } catch {
                    photoError = true
                }
                photo = nil
            }
        }
        .alert("无法使用这张图片", isPresented: $photoError) { Button("好", role: .cancel) {} }
        .onAppear { brightness = ScreenBrightness.current }
    }

    /// "A−" / "A+" drawn as text; the SF size symbols localize to 小/大.
    private func sizeGlyph(_ sign: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: "A").font(.body)
            Text(verbatim: sign).font(.caption.weight(.semibold)).baselineOffset(7)
        }
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            content()
        }
        .frame(minHeight: 40)
    }

    private func themeSwatch(_ theme: ReaderTheme) -> some View {
        let selected = theme.isDark == isNight && theme.id == (isNight ? nightTheme : dayTheme)
        return Button {
            if theme.isDark { nightTheme = theme.id; appearance = "dark" } else { dayTheme = theme.id; appearance = "light" }
        } label: {
            Text("Aa")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(hex: theme.ink))
                .frame(width: 40, height: 40)
                .background(Color(hex: theme.paper), in: Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1) }
        }
        .accessibilityLabel(theme.isDark ? "夜间配色" : "日间配色")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func backdropTile(_ item: ReaderBackdrop) -> some View {
        let selected = backdrop == item && (item != .custom || hasCustomImage)
        return Button {
            if item == .custom && (!hasCustomImage || backdrop == .custom) { choosingPhoto = true } else { backdrop = item }
        } label: {
            BackdropRepresentable(backdrop: item, palette: palette, version: backdropVersion)
                .frame(width: 64, height: 40)
                .overlay {
                    if item == .custom {
                        VStack(spacing: 0) {
                            if !hasCustomImage { Image(systemName: "plus") }
                            Text(backdrop == .custom ? "更换" : item.title).font(.caption2)
                        }
                    } else {
                        Text(item.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1)
                }
        }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

private extension View {
    func pill(expand: Bool = true) -> some View {
        frame(maxWidth: expand ? .infinity : nil, minHeight: 36)
            .padding(.horizontal, expand ? 0 : 14)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
    }
}

/// One item of the reader's bottom tab row.
struct ReaderTabButton: View {
    var title: LocalizedStringKey
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3).frame(height: 26)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Screen brightness

/// The reader may dim or brighten the screen; the system level comes back
/// whenever the reader closes or the app leaves the foreground.
@MainActor
enum ScreenBrightness {
    private static var original: CGFloat?
    private static var chosen: CGFloat?

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var current: Double { Double(chosen ?? screen?.brightness ?? 0.5) }

    static func set(_ value: Double) {
        guard let screen, abs(screen.brightness - value) > 0.001 else { return }
        if original == nil { original = screen.brightness }
        chosen = value
        screen.brightness = value
    }

    /// Back to the system level, remembering the reader's choice.
    static func restore() {
        if let original, let screen { screen.brightness = original }
        original = nil
    }

    static func reapply() {
        if let chosen { set(chosen) }
    }

    static func reset() {
        restore()
        chosen = nil
    }
}

// MARK: Sheets

struct ReaderFontPicker: View {
    @AppStorage("readerTypeface") private var typeface = ReaderTypeface.newYork
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ReaderTypeface.allCases) { item in
                Button { typeface = item } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline).foregroundStyle(.secondary)
                            Text(verbatim: "The pleasure of reading begins with a single page.")
                                .font(Font(ReaderTypography.font(item, size: 18) as CTFont))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        if item == typeface { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityAddTraits(item == typeface ? .isSelected : [])
            }
            .navigationTitle("字体").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ReaderSpacingSettings: View {
    @AppStorage("readerLineSpacing") private var lineSpacing = ReaderLayout.defaultLineSpacing
    @AppStorage("readerParagraphSpacing") private var paragraphSpacing = ReaderLayout.defaultParagraphSpacing
    @AppStorage("readerMargin") private var margin = ReaderLayout.defaultMargin
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ReaderSettingSlider(title: "行距", value: $lineSpacing, range: 1.0...2.2, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "段距", value: $paragraphSpacing, range: 0...1.5, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "页边距", value: $margin, range: 12...48, step: 2) { "\(Int($0))" }
                Button("恢复默认") {
                    lineSpacing = ReaderLayout.defaultLineSpacing
                    paragraphSpacing = ReaderLayout.defaultParagraphSpacing
                    margin = ReaderLayout.defaultMargin
                }
            }
            .navigationTitle("间距设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.height(380), .medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(380)))
    }
}

struct ReaderMoreSettings: View {
    @AppStorage("readerAppearance") private var appearance = "system"
    @AppStorage("readerKeepAwake") private var keepAwake = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("日间").tag("light")
                        Text("夜间").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("阅读时屏幕常亮", isOn: $keepAwake)
                } footer: {
                    Text("自动阅读时屏幕总是保持常亮。")
                }
            }
            .navigationTitle("更多设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Search

struct BookSearchHit: Identifiable, Sendable {
    var id: Int
    var chapter: Int
    var offset: Int
    var snippet: AttributedString
}

enum BookSearch {
    /// Case- and diacritic-insensitive matches across chapters, in reading order.
    nonisolated static func search(_ query: String, in chapters: [ReaderChapter], limit: Int = 300) -> (hits: [BookSearchHit], truncated: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ([], false) }
        var hits: [BookSearchHit] = []
        for (index, chapter) in chapters.enumerated() {
            let text = chapter.text as NSString
            var start = 0
            while start < text.length {
                let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: start, length: text.length - start))
                guard found.location != NSNotFound else { break }
                guard hits.count < limit else { return (hits, true) }
                hits.append(BookSearchHit(id: hits.count, chapter: index, offset: found.location, snippet: snippet(text, around: found)))
                start = NSMaxRange(found)
            }
        }
        return (hits, false)
    }

    nonisolated private static func snippet(_ text: NSString, around match: NSRange) -> AttributedString {
        // Start and end on composed-character boundaries so emoji never split.
        let lower = text.rangeOfComposedCharacterSequence(at: max(0, match.location - 30)).location
        let upperIndex = min(text.length - 1, NSMaxRange(match) + 60)
        let upper = upperIndex < NSMaxRange(match) ? NSMaxRange(match) : NSMaxRange(text.rangeOfComposedCharacterSequence(at: upperIndex))
        func clean(_ string: String) -> String {
            string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ChapterTextBuilder.lineSeparator, with: " ")
                .replacingOccurrences(of: ChapterTextBuilder.attachment, with: " ")
        }
        var result = AttributedString(lower > 0 ? "…" : "")
        result += AttributedString(clean(text.substring(with: NSRange(location: lower, length: match.location - lower))))
        var found = AttributedString(clean(text.substring(with: match)))
        found.inlinePresentationIntent = .stronglyEmphasized
        found.foregroundColor = Color.accent
        result += found
        result += AttributedString(clean(text.substring(with: NSRange(location: NSMaxRange(match), length: upper - NSMaxRange(match)))))
        if upper < text.length { result += AttributedString("…") }
        return result
    }
}

struct BookSearchView: View {
    let chapters: [ReaderChapter]
    var onSelect: (_ chapter: Int, _ offset: Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [BookSearchHit] = []
    @State private var truncated = false
    @State private var searchedQuery = ""

    var body: some View {
        NavigationStack {
            List {
                if !hits.isEmpty {
                    Section {
                        ForEach(hits) { hit in
                            Button { onSelect(hit.chapter, hit.offset); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapters.indices.contains(hit.chapter) ? chapters[hit.chapter].title : "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(hit.snippet).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                                }
                            }
                        }
                    } header: {
                        Text(truncated ? "显示前 \(hits.count) 条结果" : "共 \(hits.count) 条结果")
                    }
                }
            }
            .overlay {
                if !searchedQuery.isEmpty && hits.isEmpty { ContentUnavailableView.search(text: searchedQuery) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索本书")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let needle = query
                let chapters = chapters
                let result = await Task.detached(priority: .userInitiated) { BookSearch.search(needle, in: chapters) }.value
                guard !Task.isCancelled else { return }
                hits = result.hits
                truncated = result.truncated
                searchedQuery = needle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
