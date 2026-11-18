# Readling

iOS 英文阅读器（SwiftUI，iOS 26，Xcode 26.3+）。离线 EPUB/TXT 导入、点词查释义（内置 ECDICT 子集）、生词本与间隔复习。

功能现状与已知边界见 `IMPLEMENTATION-HANDOFF.md`。

## 结构
- `Readling/` 应用源码
  - `BookImporter.swift` EPUB/TXT 导入（依赖 SPM 包 ZIPFoundation）
  - `ChapterText.swift` 统一的“纯文本 + 样式区间”章节构建；`HTMLEntities.swift` 实体表
  - `LibraryStore.swift` 书库持久化（`library.json` v2 + `books/<uuid>.json`，含 v1 迁移）
  - `ReaderView.swift` 阅读页与底部工具栏；`ReadingSurface.swift` 上下滚动正文；`PagedSurface.swift` 分页正文（仿真/覆盖/平移/无动画；每页从上一页结束处起在页面大小的容器里单独排版，装下的就是这一页，显示的也正是这次排版）
  - `ReaderPanels.swift` 设置面板、字体/间距/更多设置、书内搜索；`ReaderStyle.swift` 排版、配色主题、背景纹理
  - `WordsView.swift` 生词本与复习
  - `SettingsView.swift` 设置标签页（原生分组列表布局，配色与书架、生词本一致，见 `SettingsList`）：阅读器设置（与阅读页内设置共用同一批 `@AppStorage` 键）、关于
  - `WordDictionary.swift` 词典：`DictionaryPack` 读取单个词典包（SQLite，schema 2），`WordDictionary` 以并集方式查询核心包（内置的 `Resources/dictionary-core.sqlite`，或已下载的更新版本，取较新者）与 Application Support/Readling/Dictionaries 下的已下载包。变形→原形只由核心包的 `form` 表决定，生词的 key 与安装了哪些包无关
  - `DictionaryDownloads.swift` 词典包下载：读取清单 `Dictionaries/manifest.json`（经 raw.githubusercontent），从本仓库 Releases 下载 zip，校验 sha256 后安装到 Application Support/Readling/Dictionaries。核心词典也在清单里，更新时核心与已下载的包整版一起更新，一批全部下载解压成功才替换；“设置 › 词典”页在 `SettingsView.swift`
  - `Theme.swift` 颜色（自动适配深色）
- `ReadlingTests/` 单元测试（`Fixtures/alice.epub` 为真实 Gutenberg EPUB）
- `ReadlingUITests/` UI 测试：`SelectionUITests.m` 在四种翻页模式下翻页前后长按选词，要求弹出单词卡、点按后关闭；`PagingUITests.m` 在仿真/平移/覆盖模式下连发快速滑动和点按（重叠的手势，跨章节），每轮后要求正常翻页逐页落地。用 XCUIAutomation 的私有事件合成（`XCSynthesizedEventRecord`），因为 XCUIElement 的手势会等应用空闲、无法重叠；该 API 不可用时测试会跳过。应用侧钩子：启动参数 `-freshLibrary` 使用临时空书库；`-dictionaryManifestURL <url>` 改用别的词典清单（可配合本地 `python3 -m http.server` 试下载）；分页正文的 `accessibilityIdentifier` 为 `page 章/总章 页/本章总页`
- `Tools/build-dictionary.py` 从 ECDICT CSV 生成词典包，每条只归入一个包（core/extended/八个学科/names），输出 `OUT_DIR/dictionary-<包>.sqlite`：`python3 -I Tools/build-dictionary.py ecdict.csv Readling/Resources core`（只重建内置核心包），不写包名则生成全部
- `Tools/dictionary_release.py` 词典发布（prepare / check / build / adopt），`Dictionaries/release.json` 记录版本与固定的 ECDICT 数据源，`docs/releases/` 放发布说明；推送 `dict-*` tag 后由 `.github/workflows/publish-dictionaries.yml` 构建并创建 Release。`.env` 的 `RELEASE_AI_PROVIDER=codex|claude` 让 prepare 调用本机 CLI 起草发布说明（`Tools/release_ai.py`，模板见 `.env.example`）。流程见 `docs/release.md`，脚本测试：`python3 -m unittest discover -s Tools/tests`
- `docs/screenshots/` 模拟器截图
- `docs/dictionary-design.md` 词典分包、单词卡、下载的设计与实施进度
- `docs/release.md` 发布流程（现在是词典包，以后的 app 发布也写在这里）；`docs/releases/` 各 tag 的发布说明

## 构建与测试
```sh
# 构建（模拟器，无需签名）
xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 测试（单元测试 + UI 测试，UI 测试约 4 分钟）
xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# 只跑单元测试（快速迭代时）
xcodebuild -project Readling.xcodeproj -scheme Readling \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test -only-testing:ReadlingTests
```
真机构建需在 Xcode 中为 target 设置 Development Team（项目未写死 Team）；没有开发者账号时，用外部工具 `iosign install`（`~/Projects/iosign`）以第三方证书重签安装。Bundle ID：`com.inp146.readling`。

## 约定
- 界面文案为中文，放在 `Localizable.xcstrings`。
- 测试按改动范围分级，提交前（或一组改动收尾时）跑一次完整测试：
  - 不碰正文的界面改动（文案、颜色、设置面板、生词本界面等）：构建或单元测试即可
  - 导入/章节构建/持久化/词典：单元测试（改了构建或发布脚本再加 `python3 -m unittest discover -s Tools/tests`）；涉及导入/渲染时注意“渲染字符串与正文逐字一致”的测试
  - 分页/翻页：单元测试 + `-only-testing:ReadlingUITests/PagingUITests`
  - 选词/查词：单元测试 + `-only-testing:ReadlingUITests/SelectionUITests`
  - 反复迭代时可先 `build-for-testing`，再用 `test-without-building -only-testing:...` 省去编译；修某个失败用例时先只跑该用例（如 `.../SelectionUITests/testCurl`）

## 设计原则（教训）
分页正文曾为求改动最小，让整章共享一条 `NSLayoutManager` 容器链、每页借一个容器显示；后来改为选中查词时才发现 UIKit 不允许这种页面被选择，只能层层打补丁。由此：
- 不追求最小实现。有成熟架构就直接采用成熟架构，有可用的开源库就优先评估并使用开源库，而不是自己从头实现。动核心机制（排版分页、文本选择、手势、持久化格式）之前，先查成熟阅读器、框架和开源库的做法（例如原生阅读器用 CoreText/TextKit 按页填充排版、`CTFrameGetVisibleStringRange` 定页；EPUB 阅读器用 WebView + CSS 分栏，如 Readium Swift Toolkit），偏离时要写明理由。不要因为改动最小就在不合适的地基上叠功能。
- 遇到与假设不符的平台限制时，先停下复查架构假设是否还站得住，而不是绕过限制继续堆特例；需要较大重构时先向用户说明取舍再动手。
- 同一件事只留一个事实来源：例如分页结果必须来自实际用于显示的那次排版，不能“一处测量、另一处重排显示”再靠测试保证两者一致。
- 测试通过不等于设计可靠：只覆盖了样例书和少数参数的测试，挡不住结构性隐患。

## 已知坑
- 一个 `NSLayoutManager` 挂多个 `NSTextContainer` 时，只有显示第一个容器的 `UITextView` 能被选择，其余的 `isSelectable` 会被强制为 false（设为 true 也无效）。
- `textViewDidChangeSelection`（iOS 26 模拟器实测）：拖选区手柄只在松手时回调一次；长按后不松手继续滑动会逐词回调，松手后约 7ms 还会再微调一次选区。
