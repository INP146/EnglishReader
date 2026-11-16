# EnglishReader

iOS 英文阅读器（SwiftUI，iOS 26，Xcode 26.3+）。离线 EPUB/TXT 导入、点词查释义（内置 ECDICT 子集）、生词本与间隔复习。

本项目最初在 AirBuild 中开发，已迁移为常规 Xcode 项目；功能现状与已知边界见 `IMPLEMENTATION-HANDOFF.md`，早期需求分析见 `intent-opportunities.md`（其中 `/run/airbuild/...` 路径为原环境路径，本地不存在）。

## 结构
- `EnglishReader/` 应用源码
  - `BookImporter.swift` EPUB/TXT 导入（依赖 SPM 包 ZIPFoundation）
  - `ChapterText.swift` 统一的“纯文本 + 样式区间”章节构建；`HTMLEntities.swift` 实体表
  - `LibraryStore.swift` 书库持久化（`library.json` v2 + `books/<uuid>.json`，含 v1 迁移）
  - `ReaderView.swift` / `ReadingSurface.swift` 阅读页；`WordsView.swift` 生词本与复习
  - `WordDictionary.swift` 读取 `Resources/dictionary.sqlite`
  - `Theme.swift` 颜色（自动适配深色）
- `EnglishReaderTests/` 单元测试（`Fixtures/alice.epub` 为真实 Gutenberg EPUB）
- `Tools/build-dictionary.py` 从 ECDICT CSV 重建词典：`python3 -I Tools/build-dictionary.py ecdict.csv EnglishReader/Resources/dictionary.sqlite`
- `docs/screenshots/` 模拟器截图

## 构建与测试
```sh
# 构建（模拟器，无需签名）
xcodebuild -project EnglishReader.xcodeproj -scheme EnglishReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 测试
xcodebuild -project EnglishReader.xcodeproj -scheme EnglishReader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
真机构建需在 Xcode 中为 target 设置 Development Team（项目未写死 Team）。Bundle ID：`com.inp146.reader-m7k2`。

## 约定
- 界面文案为中文，放在 `Localizable.xcstrings`。
- 改动后跑完整测试；涉及导入/渲染时注意“渲染字符串与正文逐字一致”的测试。
- `MadeWithAirBuild.swift` 及同名图片集是 AirBuild 署名（设置页底部）；如需移除，删除该文件、图片集及 `ReaderView.swift` 中的使用处。
