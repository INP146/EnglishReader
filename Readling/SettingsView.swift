import PhotosUI
import SwiftUI
@preconcurrency import Translation

/// The app's own Settings tab, laid out like the system Settings app but in
/// the app's paper and card colors.
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            SettingsList {
                Section {
                    NavigationLink { ReaderPreferencesView() } label: {
                        SettingsIconLabel("阅读器设置", systemImage: "book.pages.fill", color: .orange)
                    }
                    NavigationLink { DictionarySettingsView() } label: {
                        HStack {
                            SettingsIconLabel("词典", systemImage: "character.book.closed.fill", color: .blue)
                            Spacer()
                            if !DictionaryDownloads.shared.updates.isEmpty { UpdateBadge() }
                        }
                    }
                    NavigationLink { TranslationSettingsView() } label: {
                        SettingsIconLabel("翻译", systemImage: "translate", color: .indigo)
                    }
                }
                Section {
                    NavigationLink { AboutView() } label: {
                        SettingsIconLabel("关于", systemImage: "info", color: .gray)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

/// A row title with a white glyph on a colored rounded square, as in the system Settings app.
private struct SettingsIconLabel: View {
    var title: LocalizedStringKey
    var systemImage: String
    var color: Color
    @ScaledMetric(relativeTo: .body) private var size = 29.0

    init(_ title: LocalizedStringKey, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.23))
        }
    }
}

/// The red "1" the system Settings app puts on a row with a pending update.
private struct UpdateBadge: View {
    @ScaledMetric(relativeTo: .body) private var size = 22.0

    var body: some View {
        Text(verbatim: "1")
            .font(.system(size: size * 0.68, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.red, in: Circle())
            .accessibilityLabel("有更新")
    }
}

// MARK: Reader settings

/// The same settings as the reader's own panel, sharing its stored values.
/// Screen brightness stays in the reader: it only lasts while a book is open.
struct ReaderPreferencesView: View {
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
    @State private var photo: PhotosPickerItem?
    @State private var photoError = false

    private var palette: ReaderPalette { ReaderPalette(day: dayTheme, night: nightTheme) }
    private var hasCustomImage: Bool { _ = backdropVersion; return ReaderBackdrop.customImage != nil }

    var body: some View {
        SettingsList {
            Section {
                preview
            }
            Section("文字") {
                Picker("字体", selection: $typeface) {
                    ForEach(ReaderTypeface.allCases) { item in
                        Text(item.title).font(Font(ReaderTypography.font(item, size: 17) as CTFont)).tag(item)
                    }
                }
                .pickerStyle(.navigationLink)
                Stepper(value: $fontSize, in: ReaderTypography.sizeRange, step: 1) {
                    LabeledContent("字号") { Text("\(Int(fontSize))").monospacedDigit() }
                }
            }
            Section {
                ReaderSettingSlider(title: "行距", value: $lineSpacing, range: 1.0...2.2, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "段距", value: $paragraphSpacing, range: 0...1.5, step: 0.05) { String(format: "%.2f", $0) }
                ReaderSettingSlider(title: "页边距", value: $margin, range: 12...48, step: 2) { "\(Int($0))" }
                Button("恢复默认间距") {
                    lineSpacing = ReaderLayout.defaultLineSpacing
                    paragraphSpacing = ReaderLayout.defaultParagraphSpacing
                    margin = ReaderLayout.defaultMargin
                }
                .disabled(lineSpacing == ReaderLayout.defaultLineSpacing && paragraphSpacing == ReaderLayout.defaultParagraphSpacing
                    && margin == ReaderLayout.defaultMargin)
            } header: { Text("间距") }
            Section("外观") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("日间").tag("light")
                    Text("夜间").tag("dark")
                }
                themePicker("日间配色", selection: $dayTheme, dark: false)
                themePicker("夜间配色", selection: $nightTheme, dark: true)
                Picker("背景", selection: $backdrop) {
                    ForEach(ReaderBackdrop.allCases.filter { $0 != .custom || hasCustomImage }) { item in
                        Text(item.title).tag(item)
                    }
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Text(hasCustomImage ? "更换背景图片" : "从相册选择背景图片")
                }
                Toggle("护眼模式", isOn: $eyeCare)
            }
            Section("翻页") {
                Picker("翻页方式", selection: $pageTurn) {
                    ForEach(PageTurn.allCases) { item in Text(item.title).tag(item) }
                }
                Stepper(value: $autoSpeed, in: 1...10) {
                    LabeledContent("自动阅读速度") { Text("\(autoSpeed)").monospacedDigit() }
                }
            }
            Section {
                Toggle("阅读时屏幕常亮", isOn: $keepAwake)
            } footer: {
                Text("自动阅读时屏幕总是保持常亮。")
            }
        }
        .navigationTitle("阅读器设置")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    /// A few lines set as the reader would set them, on the current day or night page.
    private var preview: some View {
        let font = ReaderTypography.font(typeface, size: fontSize)
        let theme = appearance == "dark" ? palette.night : appearance == "light" ? palette.day : nil
        return Text(verbatim: "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.")
            .font(Font(font as CTFont))
            .lineSpacing(max(0, font.lineHeight * (lineSpacing - 1)))
            .foregroundStyle(Color(uiColor: palette.ink))
            .padding(.horizontal, margin)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { BackdropRepresentable(backdrop: backdrop, palette: palette, version: backdropVersion) }
            .environment(\.colorScheme, theme.map { $0.isDark ? .dark : .light } ?? colorScheme)
            .listRowInsets(EdgeInsets())
            .accessibilityHidden(true)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func themePicker(_ title: LocalizedStringKey, selection: Binding<String>, dark: Bool) -> some View {
        NavigationLink {
            SettingsList {
                ForEach(ReaderTheme.all.filter { $0.isDark == dark }) { theme in
                    Button { selection.wrappedValue = theme.id } label: {
                        HStack(spacing: 12) {
                            ReaderThemeSwatch(theme: theme)
                            Text(theme.title).foregroundStyle(.primary)
                            Spacer()
                            if theme.id == ReaderTheme.named(selection.wrappedValue, dark: dark).id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(theme.id == selection.wrappedValue ? .isSelected : [])
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    ReaderThemeSwatch(theme: ReaderTheme.named(selection.wrappedValue, dark: dark), size: 24)
                    Text(ReaderTheme.named(selection.wrappedValue, dark: dark).title)
                }
            }
        }
    }
}

private struct ReaderThemeSwatch: View {
    var theme: ReaderTheme
    var size: CGFloat = 32

    var body: some View {
        Text(verbatim: "Aa")
            .font(.system(size: size * 0.38, weight: .medium))
            .foregroundStyle(Color(hex: theme.ink))
            .frame(width: size, height: size)
            .background(Color(hex: theme.paper), in: Circle())
            .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
            .accessibilityHidden(true)
    }
}

// MARK: Translation

struct TranslationSettingsView: View {
    @AppStorage(TranslationService.automaticKey) private var automatic = true
    @State private var status: LanguageAvailability.Status?
    @State private var download: TranslationSession.Configuration?
    @State private var editing: EndpointEditorView.Mode?
    private let service = TranslationService.shared

    var body: some View {
        SettingsList {
            Section {
                Button { service.selection = .apple } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TranslationProviderID.appleTitle).foregroundStyle(Color.primary)
                            Text("本机离线").font(.caption).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        if service.selection == .apple {
                            Image(systemName: "checkmark").fontWeight(.semibold)
                        }
                    }
                }
                ForEach(service.endpoints) { endpoint in
                    endpointRow(endpoint)
                }
                Button { editing = .new } label: {
                    Label("添加端点…", systemImage: "plus")
                }
                .accessibilityIdentifier("add-endpoint")
            } header: { Text("翻译服务") } footer: {
                Text("添加第三方 API、中转站或局域网服务作为端点，并选择由哪个服务翻译。使用自定义端点时，选中的文字和所在的句子会发给该端点，书的其余内容和生词本不会上传。所选端点请求失败或没有网络时，自动改用 Apple 本机翻译。")
            }
            Section {
                LabeledContent("英语 → 简体中文") {
                    switch status {
                    case nil: ProgressView()
                    case .installed: Text("已下载")
                    case .supported:
                        Button("下载语言包") { download = .init(source: TranslationService.source, target: TranslationService.target) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    default: Text("不支持")
                    }
                }
            } header: { Text("Apple 本机翻译") } footer: {
                Text("在本机翻译，不联网。语言包由系统管理，其他 app 也能使用。")
            }
            Section {
                Toggle("查不到时自动翻译", isOn: $automatic)
            } footer: {
                Text("词典里没有的词和选中的句子，在单词卡里直接显示译文。关闭后点“显示译文”才翻译。")
            }
        }
        .navigationTitle("翻译")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { mode in
            NavigationStack { EndpointEditorView(mode: mode) }
        }
        .task(id: download == nil) { status = await AppleTranslationEngine.status() }
        .translationTask(download) { session in
            try? await session.prepareTranslation()
            status = await AppleTranslationEngine.status()
            download = nil
        }
    }

    private func endpointRow(_ endpoint: TranslationEndpoint) -> some View {
        let isSelected = service.selection == .endpoint(endpoint.id)
        return HStack(spacing: 12) {
            Button { service.selection = .endpoint(endpoint.id) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: endpoint.displayName).foregroundStyle(Color.primary)
                        Text(verbatim: endpoint.subtitle).font(.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { editing = .existing(endpoint) } label: {
                Image(systemName: "info.circle").foregroundStyle(Color.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("编辑 \(endpoint.displayName)")
        }
        .swipeActions {
            Button("删除", role: .destructive) { service.removeEndpoint(endpoint.id) }
            Button("编辑") { editing = .existing(endpoint) }
        }
        .contextMenu {
            Button("编辑", systemImage: "pencil") { editing = .existing(endpoint) }
            Button("删除", systemImage: "trash", role: .destructive) { service.removeEndpoint(endpoint.id) }
        }
    }
}

/// Creates or edits a user-managed translation endpoint: API format, base URL,
/// optional API key, model name (for LLM formats), and a live test button.
struct EndpointEditorView: View {
    enum Mode: Identifiable {
        case new
        case existing(TranslationEndpoint)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let endpoint): endpoint.id.uuidString
            }
        }
    }

    private struct Preset {
        var name: String
        var format: TranslationAPIFormat
        var address: String
    }

    private static let presets: [Preset] = [
        .init(name: "OpenAI", format: .openAI, address: "https://api.openai.com/v1"),
        .init(name: "DeepSeek", format: .openAI, address: "https://api.deepseek.com/v1"),
        .init(name: "OpenRouter", format: .openAI, address: "https://openrouter.ai/api/v1"),
        .init(name: "通义千问", format: .openAI, address: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(name: "Kimi", format: .openAI, address: "https://api.moonshot.cn/v1"),
        .init(name: "Ollama（局域网）", format: .openAI, address: "http://192.168.1.2:11434/v1"),
        .init(name: "Claude", format: .claude, address: "https://api.anthropic.com/v1"),
        .init(name: "Gemini", format: .gemini, address: "https://generativelanguage.googleapis.com/v1beta"),
        .init(name: "DeepL", format: .deepL, address: "https://api-free.deepl.com/v2"),
    ]

    private enum Test { case running, passed(String), failed(String) }

    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var endpointID: UUID
    @State private var name: String
    @State private var format: TranslationAPIFormat
    @State private var address: String
    @State private var model: String
    @State private var savedKey: String?
    @State private var clearedSavedKey = false
    @State private var newKey = ""
    @State private var saveError: String?
    @State private var test: Test?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .new:
            _endpointID = State(initialValue: UUID())
            _name = State(initialValue: "")
            _format = State(initialValue: .openAI)
            _address = State(initialValue: TranslationAPIFormat.openAI.defaultBaseURL)
            _model = State(initialValue: "")
            _savedKey = State(initialValue: nil)
        case .existing(let endpoint):
            _endpointID = State(initialValue: endpoint.id)
            _name = State(initialValue: endpoint.name)
            _format = State(initialValue: endpoint.format)
            _address = State(initialValue: endpoint.baseURL)
            _model = State(initialValue: endpoint.model)
            _savedKey = State(initialValue: TranslationService.shared.key(for: endpoint.id))
        }
    }

    private var isEditingExisting: Bool { if case .existing = mode { true } else { false } }

    private var effectiveKey: String? {
        let typed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return clearedSavedKey ? nil : savedKey
    }

    private var draftEndpoint: TranslationEndpoint {
        TranslationEndpoint(id: endpointID, name: name, format: format, baseURL: address,
                            model: format.usesModel ? model : "")
    }

    private var canSave: Bool { format.isConfigured(endpoint: draftEndpoint, key: effectiveKey) }
    private var canFetchModels: Bool { format.usesModel && format.previewURL(address: address) != nil }
    private var isTesting: Bool { if case .running = test { true } else { false } }

    var body: some View {
        SettingsList {
            Section {
                TextField("名称（可选，如 DeepSeek、本机 Ollama）", text: $name)
                Picker("接口格式", selection: $format) {
                    ForEach(TranslationAPIFormat.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                Menu("填入常用预设") {
                    ForEach(Self.presets, id: \.name) { preset in
                        Button("\(preset.name)（\(preset.format.title)）") { apply(preset) }
                    }
                }
            } header: { Text("端点") } footer: {
                Text("许多第三方中转站和本地推理服务（Ollama、LM Studio、vLLM、OneAPI）使用 OpenAI 兼容、Claude 或 Gemini 接口格式，按服务商文档选择即可。")
            }
            Section {
                TextField("https://…", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: { Text("服务地址") } footer: {
                if let preview = format.previewURL(address: address, model: model, key: effectiveKey) {
                    Text(verbatim: "请求地址：\(preview.absoluteString)")
                } else {
                    Text("地址要以 https:// 或 http:// 开头。")
                }
            }
            Section {
                if let savedKey, !clearedSavedKey {
                    LabeledContent("已保存", value: "••••\(savedKey.suffix(4))")
                        .accessibilityIdentifier("saved-key")
                }
                SecureField(savedKey != nil && !clearedSavedKey ? "输入新 Key 以替换（不改可留空）" : "API Key（本地无鉴权服务可留空）", text: $newKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if savedKey != nil && !clearedSavedKey {
                    Button("清除已保存的 Key", role: .destructive) {
                        clearedSavedKey = true
                        test = nil
                    }
                }
            } header: { Text("API Key") } footer: {
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                } else if format == .deepL {
                    Text("Key 只存在本机钥匙串里，不同步也不进备份。官方免费版（以 :fx 结尾）和付费版 Key 会自动选用对应的官方地址；自建 DeepLX 可填自己的地址。")
                } else {
                    Text("Key 只存在本机钥匙串里，不随 iCloud 同步，也不进备份。建议单独创建一个设置了额度上限的 Key；局域网里的无鉴权服务可留空。")
                }
            }
            if format.usesModel {
                Section {
                    TextField("模型名", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    NavigationLink("从服务获取模型列表") {
                        TranslationModelList(format: format, address: address, key: effectiveKey, selection: $model)
                    }
                    .disabled(!canFetchModels)
                } header: { Text("模型") } footer: {
                    Text("从端点拉取可用模型列表，或直接填写模型 ID。")
                }
            }
            Section {
                Button("测试", action: runTest)
                    .disabled(!canSave || isTesting)
                switch test {
                case nil: EmptyView()
                case .running: ProgressView()
                case .passed(let text): Text(text).textSelection(.enabled)
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
            } footer: {
                Text("发送一句短英文，验证当前填写的地址、接口格式和认证信息可用。")
            }
            if isEditingExisting {
                Section {
                    Button("删除端点", role: .destructive) {
                        TranslationService.shared.removeEndpoint(endpointID)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isEditingExisting ? "编辑端点" : "添加端点")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(!canSave)
            }
        }
        .onChange(of: format) { oldFormat, newFormat in
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == oldFormat.defaultBaseURL {
                address = newFormat.defaultBaseURL
            }
            test = nil
        }
        .onChange(of: address) { test = nil }
        .onChange(of: model) { test = nil }
        .onChange(of: newKey) { test = nil }
    }

    private func apply(_ preset: Preset) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || Self.presets.contains(where: { $0.name == trimmedName }) {
            name = preset.name
        }
        format = preset.format
        address = preset.address
        test = nil
    }

    private func save() {
        let typed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyChange: TranslationService.KeyChange = if !typed.isEmpty {
            .set(typed)
        } else if clearedSavedKey {
            .clear
        } else {
            .unchanged
        }
        do {
            try TranslationService.shared.saveEndpoint(draftEndpoint, keyChange: keyChange)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func runTest() {
        test = .running
        let instance = format.engine(for: draftEndpoint, key: effectiveKey)
        Task {
            var latest = ""
            do {
                for try await text in instance.run(.translate("The quick brown fox jumps over the lazy dog.")) { latest = text }
                test = latest.isEmpty ? .failed(String(localized: "没有得到译文。")) : .passed(latest)
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

/// The models an endpoint lists, searchable; picking one fills in the model name.
private struct TranslationModelList: View {
    var format: TranslationAPIFormat
    var address: String
    var key: String?
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String]?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        SettingsList {
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if let models {
                let shown = query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
                ForEach(shown, id: \.self) { model in
                    Button { selection = model; dismiss() } label: {
                        HStack {
                            Text(verbatim: model).foregroundStyle(Color.primary)
                            Spacer()
                            if model == selection { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .task {
            do {
                let fetched = try await format.models(address: address, key: key)
                models = fetched
                if fetched.isEmpty { error = String(localized: "服务没有列出模型，请直接填写模型名。") }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: Dictionary

struct DictionarySettingsView: View {
    @AppStorage("dictionaryExpandByDefault") private var expandByDefault = false
    @AppStorage("dictionaryAccent") private var accent = "en-US"
    private let downloads = DictionaryDownloads.shared

    var body: some View {
        SettingsList {
            let updates = downloads.updates
            if !updates.isEmpty, let release = downloads.catalog?.release {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("词典 \(release) 可更新")
                            Text(ByteCountFormatter.string(fromByteCount: updates.reduce(0) { $0 + $1.size }, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if downloads.isUpdating {
                            ProgressView()
                        } else {
                            Button("更新") { Task { await downloads.updateAll() } }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                } footer: {
                    Text("核心词典和已下载的词典包一起更新，下载新词典包时也会顺带更新，以免各包收录的词条对不上。")
                }
            }
            Section {
                if let core = downloads.dictionary.core {
                    if let pack = downloads.packs.first(where: { $0.id == core.id }) {
                        row(pack)
                    } else {
                        packLabel(core.title, details: [Self.count(core.entryCount), core.version])
                    }
                }
            } header: { Text("已内置") } footer: {
                Text("常用词、它们的变形和通用短语（含短语动词），不联网也能用。")
            }
            if downloads.packs.isEmpty {
                Section {
                    if downloads.isRefreshing {
                        HStack { Text("正在获取词典列表…").foregroundStyle(.secondary); Spacer(); ProgressView() }
                    } else if let error = downloads.catalogError {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") { Task { await downloads.refresh() } }
                    }
                }
            } else {
                group("vocabulary", title: "词汇", footer: "其余的普通单词和短语，多为生僻词。")
                group("field", title: "学科",
                      footer: "只收全部义项都属于该学科的词条；常用词即使带学科义项，也已在核心词典里。")
                group("names", title: "专有名词", footer: "人名、地名、机构名和生物学名。")
            }
            Section("单词卡") {
                Toggle("默认展开", isOn: $expandByDefault)
                Picker("朗读口音", selection: $accent) {
                    Text("美音").tag("en-US")
                    Text("英音").tag("en-GB")
                }
            }
            Section {
            } footer: {
                Text("词典数据来自 ECDICT（MIT 许可），各词典包可以任意组合。应用每天最多自动检查一次词典更新，此外只有打开此页或下载词典时才会联网。")
            }
        }
        .navigationTitle("词典")
        .navigationBarTitleDisplayMode(.inline)
        .task { await downloads.refresh() }
        .refreshable { await downloads.refresh() }
    }

    @ViewBuilder
    private func group(_ group: String, title: LocalizedStringKey, footer: LocalizedStringKey) -> some View {
        let packs = downloads.packs.filter { $0.group == group }
        if !packs.isEmpty {
            Section {
                ForEach(packs) { pack in row(pack) }
            } header: { Text(title) } footer: { Text(footer) }
        }
    }

    private func row(_ pack: DictionaryCatalog.Pack) -> some View {
        let status = downloads.status(of: pack)
        let installed = downloads.installed(pack.id)
        let isCore = pack.id == DictionaryPack.coreID
        // The installed version's figures until it is updated.
        var details = [Self.count(installed?.entryCount ?? pack.entries)]
        if !isCore {
            details.append(ByteCountFormatter.string(fromByteCount: installed == nil ? pack.size : pack.installedSize, countStyle: .file))
        }
        details.append(installed?.version ?? pack.version)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                packLabel(pack.title, details: details)
                if case .failed(let message) = status {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch status {
            case .notInstalled, .failed:
                Button(status == .notInstalled ? "下载" : "重试") { Task { await downloads.download(pack) } }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            case .updateAvailable:
                Text("可更新").foregroundStyle(.secondary)
            case .downloading(let fraction):
                Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button { downloads.cancel(pack) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("取消下载")
            case .installing:
                ProgressView()
            case .installed:
                if !isCore { Text("已安装").foregroundStyle(.secondary) }
            }
        }
        .swipeActions {
            if installed != nil && !isCore {
                Button("删除", role: .destructive) { downloads.remove(pack) }
            }
        }
        .contextMenu {
            if installed != nil && !isCore {
                Button("删除", systemImage: "trash", role: .destructive) { downloads.remove(pack) }
            }
        }
    }

    private func packLabel(_ title: String, details: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(verbatim: details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "23.1 万条", "8,412 条".
    static func count(_ entries: Int) -> String {
        entries >= 10_000 ? String(localized: "\(Double(entries) / 10_000, format: .number.precision(.fractionLength(1))) 万条")
            : String(localized: "\(entries) 条")
    }
}

// MARK: About

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        SettingsList {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accent)
                        .padding(.bottom, 4)
                    Text(verbatim: "Readling").font(.title3.weight(.semibold))
                    Text("离线阅读英文书，点词即查，生词随读随记。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("版本", value: version)
            }
            Section {
                Text("书籍、阅读位置和生词都只保存在这台设备上，不会上传。删除应用会一并删除。")
                Text("应用每天最多自动检查一次词典更新；此外只有在打开“词典”设置或下载词典时才会联网。")
                Text("选用联网翻译引擎后，查不到的词和选中的句子（连同所在的句子）会发给你选择的服务商翻译；书的其余内容和生词本不会上传。默认的 Apple 本机翻译不联网。")
            } header: { Text("数据") }
            Section {
                Text("释义来自离线英汉词典 ECDICT（MIT 许可）。")
                Text("示例书节选自 Project Gutenberg 的公版《爱丽丝梦游仙境》。")
            } header: { Text("致谢") }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Shared pieces

/// A grouped settings list on the app's paper background with card rows, as in
/// the library and word list, instead of the system grays.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List { content.listRowBackground(Color.card) }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
    }
}

/// A titled slider with its value on the trailing side, for settings forms.
struct ReaderSettingSlider: View {
    var title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

extension ReaderTheme {
    var title: LocalizedStringKey {
        switch id {
        case "paper": "米白"
        case "white": "纯白"
        case "parchment": "羊皮纸"
        case "green": "豆沙绿"
        case "blue": "雾蓝"
        case "night": "墨绿夜"
        case "black": "纯黑"
        case "slate": "石板灰"
        default: LocalizedStringKey(id)
        }
    }
}

extension ReaderBackdrop {
    /// Loads a picture chosen in the photo picker and saves it as the custom background.
    @MainActor static func saveCustomImage(from item: PhotosPickerItem) async throws {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadUnknown) }
        try saveCustomImage(data)
    }
}
