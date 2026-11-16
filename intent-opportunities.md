# 英文阅读器：App Intents 机会发现

## 现有 App Intents 清单

**当前代码声明的 App Intents 动作为 0；未发现已声明的快捷指令、App Shortcuts、Spotlight、Siri、组件或控制入口，也没有采用 Apple Intelligence schema。**

| 业务动作 | Intent / shortcut / entity / query 路径与符号 | 当前接线 | 证据边界 |
| --- | --- | --- | --- |
| 无 | 在 `EnglishReader/`、`EnglishReaderTests/` 搜索 `AppIntent`、`AppShortcut`、`AppShortcutsProvider`、`AppEntity`、`EntityQuery`、`@Assistant`、`import AppIntents` 均无匹配 | 未接入 | 同时未发现 `onAppIntentExecution`、`onOpenURL`、`NSUserActivity`、`CSSearchable`；这是源码清单，不代表已检查系统入口或设备 |

`EnglishReader.xcodeproj/project.pbxproj` 仅有主应用和单元测试两个 target，没有相关扩展；主应用通过文件系统同步组纳入 `EnglishReader/` 源码。

## 项目与分析范围

- **日期：**2026-11-06；本报告最初为首次分析；本次复核保留原报告结构与候选身份，主要更新已经过时的“继续阅读只取第一本”结论。
- **产品边界：**按任务提供的 brief，属于新建、离线、自用英文阅读器；此次仅发现机会，不授权增加功能。真实业务是本机 EPUB/TXT 导入、阅读位置恢复、系统词典与词句收藏，不是云端书库或 AI 阅读服务。
- **代码基线：**Git HEAD 为 `913cf951acfdd3dbeec96232dd10c256c2938162`（`Initial untouched iOS starter`），**不能把它当作本次应用实现版本**。检查时工作区删除了原 `AirbuildApp*` 模板，并存在未跟踪的 `EnglishReader/`、`EnglishReader.xcodeproj/`、`EnglishReaderTests/`；结论基于这份未提交新应用源码快照。
- **实际阅读：**原分析读取 `EnglishReader/EnglishReaderApp.swift`、`ContentView.swift`、`LibraryStore.swift`、`ReaderView.swift`、`BookImporter.swift`、`ReadingSurface.swift` 的相关实现，`SampleBook.swift`、`SOURCE.md`，以及 `EnglishReaderTests/LibraryTests.swift`、项目配置和 `.airbuild/airbuild.yaml`。本次重点复核当前 `ContentView` / `ReaderView` 的最近阅读选择与收藏导航、store 和 target 配置。测试源码仅作为设计证据，未运行。
- 原分析未在项目根目录发现独立 brief；本次读到工作区外定稿 `/run/airbuild/team/state/team/developer/.engine/downloads/2eed3a9a-2327-4c20-bce0-db0f7036104a/brief.md`，确认本机、无 AI/服务器/网站/商店的产品边界。未发现额外 `.xcconfig`、entitlements 或项目级说明覆盖上述范围。未运行应用、未实例化 store、未导入/删除数据、未构建或测试。

| Target / 配置 | 源码归属 | 最低系统 | SDK / 工具链证据 | 未知项 |
| --- | --- | --- | --- | --- |
| `EnglishReader` / Debug、Release | `EnglishReader/` 同步组；入口 `EnglishReader.body → ContentView()` | 项目级 `IPHONEOS_DEPLOYMENT_TARGET = 26.0`；target 无覆盖 | 项目 `SDKROOT = iphoneos`、Swift 6.0；构建脚本选择 `EnglishReader` scheme；本轮已有日志实际使用 Xcode 27.2 / iPhoneSimulator27.2.sdk | 具体 AppIntents / SwiftUI SDK 声明未读；未验证未来 Intent 编译 |
| `EnglishReaderTests` / Debug、Release | `EnglishReaderTests/` 同步组；依赖主应用 | 继承项目级 iOS 26.0；target 无覆盖 | `TEST_HOST` 指向 `EnglishReader.app/EnglishReader` | 未执行测试；不是系统入口 target |

**构建环境与运行环境分开记账：**本轮已有 `/run/airbuild/build-output/runbuild-00374bf1-ae24-437e-bfb8-1f754bd28155.log` 第 29 行使用 `/Applications/Xcode_27.2.app/.../xcodebuild`，第 87 行读取 `iPhoneSimulator27.2.sdk`；build **`46cce4a4-b17c-4174-982c-f78c96ce19b3`** 第 1028 行为 `ARCHIVE SUCCEEDED`。旧报告引用的成功 build `1d62d20a-54a7-4599-9566-b7513c546d24` 亦有保存日志。保存会话 `/run/airbuild/team/state/team/developer/.engine/session-store/bot.developer.f5e349073aebf74d.jsonl` 第 78 行的模拟器列表记录默认 iPhone 18 Pro，runtime 为 `com.apple.CoreSimulator.SimRuntime.iOS-27-2`，即 **iOS 27.2**。这些分别证明此前构建工具/SDK 与模拟器 runtime，不证明尚不存在的 Intents 编译、元数据导出或任何 Siri 调用成功，也不保证 artifact 与当前所有未提交文件完全一致。本次只读既有日志，未重跑、未联系模拟器。本分析 shell 为 Linux，`xcrun`、`xcodebuild` 不在 PATH，未读取 builder 的 SDK 声明；真机系统及 Siri 可用性未核验。参考指南记录的机器版本不作为本项目证据。

## 决策摘要

**当前实施首批为 0（用户明确不新增功能）；可直接进入实施的技术就绪首批也为 0。保留少量有业务依据的待验证机会，不等于否定其价值。**

| 顺序 | 候选 | 业务实现 | 普通 Intent 路径结论 | 首批状态 |
| --- | --- | --- | --- | --- |
| 1 | 继续阅读（Continue Reading） | 已实现：优先有效 `lastReadBookID`，否则书架第一本，并恢复其正常阅读位置 | **待验证**：最近打开身份已存在；前台导航 API 的完整声明/重载与冷启动接线尚缺 | 暂不计入就绪首批，亦未授权实施 |
| 2 | 打开书籍（Open Book，保留旧报告候选身份） | 已实现按 UUID 打开书籍并恢复位置 | **待验证**：同样缺完整导航证据，另需实体参数、查询与重名消歧的设计和 API 核验 | 本次不扩展该旧候选，暂不计入就绪首批 |

优先讨论“继续阅读”，因为无参数、可少一步进入原文；若用户以后需要固定内容入口，再按真实需求选择具体书籍或收藏。没有使用量统计，排序是基于任务价值、接入依赖和风险的定性判断。**不为自用离线工具凑满入口数量，不推荐本轮 schema、全文索引或 AI 功能。**即使部分基础协议已有官方文档支持（A1–A9），也不足以补齐完整执行链（G1–G4），不能标为已就绪。本次明确关注的“打开收藏”机会补充在现有收藏条目中，不授权实现或新增第三项首批。

## 候选动作

### 1. 继续阅读——从系统入口回到最近打开书籍的正常阅读位置

- **业务状态：已实现。**当前 `EnglishReader/ContentView.swift: ContentView.lastReadBookID` 使用 `@AppStorage("lastReadBookID")`；`ContentView.body` 用 `store.books.first(where: { $0.id.uuidString == lastReadBookID }) ?? store.books.first` 选择首页推荐书，再经 `featured(_:)` 进入阅读。`EnglishReader/ReaderView.swift: ReaderView.body.onAppear` 首次显示时写入当前 `book.id.uuidString`。因此旧报告“没有最后打开书籍 ID、总是只取第一本”的结论已过时。实际语义是**最近打开阅读器且仍存在的书**；没有有效 ID 才取书架第一本。查看收藏原文也会更新该 ID，即使引用预览没有改变正常阅读位置；不是按滚动时间排序。
- **代码链：**`EnglishReader/ContentView.swift: ContentView.body → featured(_:)` 按钮设置 `ReaderRoute(bookID:)` → 同文件 `.fullScreenCover(item: $route)` 在 `store.books` 按 UUID 查找 → `EnglishReader/ReaderView.swift: ReaderView.onAppear` 读取 `ReaderBook.position`，限制章节范围并传入 `ReadingSurface`，同时记录最近打开身份 → `EnglishReader/ReadingSurface.swift: Coordinator.finishLayout()` 按 UTF-16 锚点恢复可视位置。滚动经 `ReaderView` 回调调用 `LibraryStore.savePosition`；退出/场景离开前台调用 `persist()`。没有现有 Intent 环节。
- **结论：待验证。**值得以后产品选择；最近打开身份不再是新增业务依赖，但外部前台导航与系统调用仍未实现，不能声称已有系统接入。
- **拟议行为：**无参数；与当前首页一致，执行时优先按有效 `lastReadBookID` 选书，找不到才用 `books.first`，前台打开该书正常保存的位置。首次未读则从开头读。重复调用不翻页、不清零、不新增书；已读到末尾也保留位置，不自动重读。书库为空时提示先在应用中导入，不偷偷添加示例。沿用首页回退规则完成选书后，若该具体 UUID 在导航前又被删除，应提示不可用，不再次偷偷换书。以上执行期失败提示与系统调用守卫均是拟议接入工作，不是现有 Intent 行为。
- **语义边界：**沿用已经实现的“最近打开”规则，无需再新增最近阅读 ID/时间。若以后要求“只有正常阅读才更新，查看引用不更新”或按最后滚动时间选择，则是新的业务变更，需独立批准，不混入最小适配。
- **数据可达性：**`ContentView` 内 `@State private var store = LibraryStore()` 与私有 `route` 持有应用状态，目前无供系统动作调用的导航入口。store 可脱离 view 构造，但构造时会读取全量 JSON，缺文件还会 `addSample()` 并落盘；不能把“新建另一个 store”当作无副作用查询。应让前台动作使用当前视图拥有的 store 与导航状态，设计冷启动交付和重复打开处理；不得让独立实例覆盖尚未持久化的滚动位置。若同一书已打开，拟议复用当前 reader，避免以磁盘旧值覆盖活跃位置；正在查看引用时回到正常进度的系统接线尚需设计。
- **访问与安全：**只涉及当前设备应用沙盒；代码无账户、登录或跨用户所有权。`LibraryStore.commit` 原子写入并使用 `completeFileProtectionUntilFirstUserAuthentication`；这不等于动作具备设备认证策略。拟议仅前台展示，不输出正文/收藏到语音或自动化结果，不需破坏性确认；锁屏访问、系统认证策略仍需核验。读取损坏时保留原文件、不当作空书库修复；不得清掉错误后误报成功。
- **普通路径：**拟议名称 `ContinueReadingIntent`（尚不存在），使用前台导航方向；`AppIntent`、`TargetContentProvidingIntent`、`supportedModes` 的文档见 A1/A3/A4，模式类型见 A5。精确前台成员和 SwiftUI 消费回调仍缺 G1，结果/元数据依赖见 G2。无需为此更改 iOS 26 deployment target；但完整方案兼容性尚不能确认。
- **可选 schema：待验证且不建议本轮采用。**未确认任何精确 domain.member；未核对所需参数、结果、依赖实体或整组动作条件。不能从“阅读器”名称推断 schema 适配，也不能用宏的最低版本推断成员最低版本。
- **系统入口：**优先只评估快捷指令手动配置入口；App Shortcuts 自动入口、Siri 短语和 Spotlight 动作曝光单独延后（G3）。普通 Siri 快捷指令调用与 Apple Intelligence schema 增强不是同一结论，均未验证；不承诺离线阅读会使系统语音服务也离线可用。
- **优先级 / 成本：**P1；**S–M**，假设沿用当前已实现选书规则且只做前台路径。主要依赖是导航接线、启动时序、已打开阅读器时复用/安全切换的规则，以及空库/读失败处理；不再把新增最近阅读身份计为当前必要成本。
- **后续验证：**先补 G1/G2，再在获授权的实施任务中检查冷启动、热启动、阅读器已打开、引用预览、最近打开书籍已移除后的现有首页回退、空库、损坏文件、持久化失败与首次解锁前访问。当前无 Intent 编译、入口可见性、模拟器执行或真机 Siri 执行证据。

### 2. 打开书籍——指定书架中某一本书，直接进入原文（保留旧报告评估）

- **业务状态：已实现。**不是只存在按钮：`ContentView.body` 的 `ForEach(store.books)` 每行使用书籍 UUID 设置 `ReaderRoute`，实际经 full-screen cover 进入 `ReaderView` 并恢复位置。导入重复文件时，`ImportBookView` 也可用已有 ID 打开原书。
- **代码链：**`EnglishReader/ContentView.swift: ContentView.body` 书架行 / `ImportBookView` 重复导入提示 → `ReaderRoute.bookID` → `.fullScreenCover` 的 `store.books.first(where:)` → `EnglishReader/ReaderView.swift: ReaderView.onAppear` → `ReadingSurface` 锚点恢复；数据为 `EnglishReader/LibraryStore.swift: ReaderBook.id/title/author/position`，`Snapshot.books` 由 `commit` 写入 `Application Support/EnglishReader/library.json`。没有现有实体查询或 Intent。
- **结论：待验证。**适合固定书籍快捷入口，但实体解析比无参数方案多一层成本；不是授权新增搜索界面。本次保留旧动作身份，不进一步扩展研究或实施范围。
- **拟议参数 / 身份：**一个必填书籍实体参数，拟议名 `BookEntity`、`BookQuery`，均尚未实现。使用持久化的 `ReaderBook.id`（UUID），不用易重名的书名，不用每次新建的 `ReaderRoute.id`。ID 随 JSON 重启恢复；删除后重导同一本会产生新 UUID，旧快捷指令应报书籍已移除，不按标题偷偷重连。ID 仅承诺本设备当前安装的数据，不承诺重装或跨设备有效。
- **拟议查询与消歧：**按 ID 精确回查当前可读书库；如提供名称输入，则用标题/作者辅助匹配，标题相同不得自动取第一本，必须选择具体 UUID；展示标题与作者，仍有同名同作者时提供本地标识区分。建议列表也只展示当前存在的书籍。执行时再按同一 UUID 校验，已删除或不可读则给明确失败；不重新导入、不重建示例、不改变书架排序。查询与消歧是新适配工作，现有 UI 选书不等于已有系统查询能力。
- **拟议结果 / 重复执行：**前台打开指定书的当前保存位置；重复调用不重置、不自动翻页，无完成状态切换。阅读器已展示同一书时应复用或安全更新导航，具体接线待设计；读到末尾仍停留末尾，不许诺“重新开始”。
- **数据、访问与安全：**与候选 1 共用同一沙盒数据和导航限制；不新增文件权限、网络、账户或后台阅读。书籍导入完成后正文已保存在应用 JSON，打开已导入书不应再次访问原始外部文件。独立后台实体查询尚无无副作用只读接口，不能直接构造会播种示例的 `LibraryStore`；需拟议只读快照或受控共享读模型，处理与活跃 store 不一致的问题，严禁多个实例写回覆盖。仅向系统暴露用户选书所需的标题/作者/ID，不输出正文与收藏；查询隐私、锁屏可见性和认证条件须核验，不假定“自用”消除信息曝光风险。
- **普通路径：**拟议 `OpenBookIntent`，前台打开而不是后台返回全文。协议层文档为 A1–A8；参数包装器、实体显示/查询方法、结果类型和精确回调证据尚缺 G1/G2。普通路径因此仍为待验证，不能因为 `AppEntity` 文档提到 Siri 就声称可被语音正确解析。
- **可选 schema：待验证、不纳入本轮。**同候选 1，没有已验证的精确 domain.member 与实体依赖；不为追求 schema 建立新业务或抬高 deployment target。若以后确有收益，须先逐一核对成员的最低系统、选定 SDK 声明、参数/结果和必要动作组，再决定 runtime gate 与 iOS 26 普通路径回退。
- **系统入口：**优先快捷指令中的书籍选择；App Shortcuts 参数化短语、Spotlight 书籍内容索引、Siri 指定书名、Apple Intelligence 语义发现均属独立待验证范围（G3/G4），不随普通参数实体自动获得。
- **优先级 / 成本：**原报告 P2；**M**，假设复用候选 1 的前台接线，新增实体/只读查询、重名选择及失效 ID 处理。不含全文索引、跨设备同步或 schema。
- **后续验证：**先补 G1/G2，再另行授权实体实现；随后验证同名书、同名同作者、删除后旧 ID、删除后重导、空库、冷/热启动和文件保护。当前仅有源码证据，没有上述场景的运行结果。

## API 与可用性证据

**以下证据日期均为 2026-11-06。**A 行保留原报告实际读取的 Apple 官方 DocC JSON 证据，记录其中各符号自身的声明及 `metadata.platforms`；不是仅凭其他类型的引用。本次另行重新读取了 A1/A3/A4/A6/A7/A8 的自身声明与 availability；A2/A5 是沿用原报告的同日核验记录，未声称本次重新读取。线上文档可访问，但文档没有证明 builder 选定 SDK 实际声明了所有依赖，也没有给出读取结果之外的精确最低 Xcode 版本。因此“SDK/工具链”一栏不从记忆填版本。所有 A 行的选定 SDK 声明核验均尚缺；它们也不独立证明系统曝光。

| ID | 精确符号 / 读取声明 | 文档最低 iOS | SDK / 工具链与适用范围 | 实际读取来源 |
| --- | --- | --- | --- | --- |
| A1 | `AppIntent`：`protocol AppIntent : PersistentlyIdentifiable, _SupportsAppDependencies, Sendable` | 16.0 | 应用动作协议；最低 Xcode 未由该文档证明，builder 声明未读 | https://developer.apple.com/tutorials/data/documentation/appintents/appintent.json |
| A2 | `AppIntent.perform()`：`func perform() async throws -> Self.PerformResult` | 16.0 | 执行方法；返回依赖的自身声明未在原分析完整核验；本次沿用原报告记录 | https://developer.apple.com/tutorials/data/documentation/appintents/appintent/perform().json |
| A3 | `TargetContentProvidingIntent`：`protocol TargetContentProvidingIntent : AppIntent` | 26.0 | 内容目标协议；不单凭协议声明确认导航回调接线 | https://developer.apple.com/tutorials/data/documentation/appintents/targetcontentprovidingintent.json |
| A4 | `AppIntent.supportedModes`：`static var supportedModes: IntentModes { get }` | 26.0 | 执行模式属性；精确前台成员未核验 | https://developer.apple.com/tutorials/data/documentation/appintents/appintent/supportedmodes.json |
| A5 | `IntentModes`：`struct IntentModes` | 26.0 | 模式类型；成员可用性不能从类型推断；本次沿用原报告记录 | https://developer.apple.com/tutorials/data/documentation/appintents/intentmodes.json |
| A6 | `AppEntity`：`protocol AppEntity : AppValue, DisplayRepresentable, Identifiable where Self == Self.ValueType, Self.ID : EntityIdentifierConvertible, Self.ID : Sendable` | 16.0 | 实体协议；未覆盖参数与显示类型的全部依赖 | https://developer.apple.com/tutorials/data/documentation/appintents/appentity.json |
| A7 | `EntityQuery`：`protocol EntityQuery : DynamicOptionsProvider, PersistentlyIdentifiable, Sendable` | 16.0 | ID 查询协议；具体查询方法/搜索能力仍需逐项查验 | https://developer.apple.com/tutorials/data/documentation/appintents/entityquery.json |
| A8 | `AppShortcutsProvider`：`protocol AppShortcutsProvider : Sendable` | 16.0 | 仅协议声明；不证明任何 phrase、初始化重载或入口已可用 | https://developer.apple.com/tutorials/data/documentation/appintents/appshortcutsprovider.json |
| A9 | 项目配置事实，而非 Apple API：`IPHONEOS_DEPLOYMENT_TARGET = 26.0`、`SDKROOT = iphoneos`、`SWIFT_VERSION = 6.0` | 应用目标 26.0 | 主应用/测试 Debug、Release；不代表具体 SDK 版本 | `EnglishReader.xcodeproj/project.pbxproj: XCBuildConfiguration` |

| 缺口 ID | 尚未验证的精确范围 | 最低 OS / SDK | 下一项检查与决策影响 |
| --- | --- | --- | --- |
| G1 | `IntentModes.foreground` 自身声明、SwiftUI `onAppIntentExecution` 适用重载及参数交付语义 | **待验证，不推断** | 阅读各自官方符号页及 builder Xcode 27.2 的 AppIntents/SwiftUI 声明；确认冷启动、活跃 view 与已展示 reader 的导航接线。两候选普通路径及下述收藏机会的阻塞项 |
| G2 | `IntentResult`、所选 `.result()` 工厂、标题/结果元数据依赖；参数实体方向的 `@Parameter` 所选初始化器、实体显示类型、ID 查询/建议/字符串匹配方法 | **各成员待验证，不借 A1/A6/A7 的版本替代** | 先选最小实现签名，再逐符号核对声明、availability、依赖类型；验证无副作用只读查询设计。未完成前不进入就绪首批 |
| G3 | `AppShortcut` 所选初始化重载、`AppShortcutsProvider.appShortcuts`、所选 phrase 类型及 `.applicationName` token 的声明与曝光条件 | **待验证** | 读取自身文档/SDK；后续才评估短语、语言、元数据提取和系统入口可见性。A8 仅验证 provider 协议，不验证此曝光链；单独延后，不偷偷纳入首批 |
| G4 | 任何具体 schema domain.member、依赖实体、必填参数/结果、必要动作组，以及 Spotlight 内容索引方案 | **未确定** | 本次不选择具体 schema/索引 API；若产品另行要求，再核对精确符号和目标 SDK、硬件/语言/地区/功能开关条件。普通 Intent 不等于 Apple Intelligence 支持 |

已阅读的技能参考：`/run/airbuild/skills/apple-integrations/SKILL.md` 及 `topics/app-intents-reference/GUIDE.md`；`/run/airbuild/skills/apple-intelligence/SKILL.md` 及 `topics/ios27-apple-intelligence-reference/GUIDE.md` 的 Siri/schema/实体章节。**这些是发现线索，不是精确 API 或当前 builder 的验证来源。**本次没有文档网络整体不可用的问题；缺口主要是未读完整成员链及无法从当前 shell 读取 builder SDK，不能把“未核验”写成“不存在”。

## 其余业务、计划与排除项

未发现可据以纳入首批的独立已计划 Intent；下表主要是**已有应用业务但本轮不推荐曝光**，或根本不属于现有功能的想法。

| 用户任务 | 业务状态与代码依据 | 结论 / 排除原因 | 改变决策的条件 |
| --- | --- | --- | --- |
| 导入 EPUB/TXT | 已实现：`ImportBookView.fileImporter → LibraryStore.importBook → BookImporter.load`；安全作用域文件、格式/大小/DRM/重复校验 | 不建议首批：文件选择与错误修复依赖交互；相对直接点“导入”收益小 | 明确需要文件自动化，再单独评估文件参数、权限和重复策略；不直接把当前函数搬到后台 |
| 查词 | 已实现：`ReadingSurface.Coordinator` 选区 → `SelectionPanel` / `SystemDictionary`；使用系统词典，下载词典可能需联网 | 不建议首批：价值依赖原文选区和上下文，不是应用自有词典查询服务 | 有独立词条查询场景并完成系统词典与返回内容边界核验 |
| 收藏词句、查看收藏、回到原文 | 已实现：`ReaderView.save` / `LibraryStore.savePassage`、`ContentView` 收藏列表与 `FavoriteDetail`；UUID + 章节 + UTF-16 offset，原书删除后保留词句但不能回原文 | 本轮延后；具体“打开收藏”普通导航机会见下，不自动扩展到新增收藏或朗读 | 真实需要系统收藏入口时再决定查询/导航范围，处理已删除收藏与原书；不把正文默认为语音输出 |
| 标记已掌握 | 已实现的实际函数为 `LibraryStore.toggleMastered(id:)`，每次翻转；UI 及撤销都调用该函数 | 不建议首批；不能包装成幂等“设为已掌握”，重复执行会反转结果 | 若获授权，需要新增设定目标状态的业务函数/守卫，另算成本与确认行为 |
| 删除书籍/收藏 | 已实现：`removeBook`、`deleteFavorite`；UI 有确认，删除原书保留收藏 | 不建议：自用产品入口收益低，破坏性风险和恢复负担高；现有 UI 确认不会自动覆盖 Intent | 有明确自动化需求时重新评估认证、确认、失效 ID 和恢复方案 |
| 字号、外观、目录、切换 tab、查词帮助 | 已实现：`ReaderSettings`、`ReaderView` 目录、`ContentView.tab` | 不建议：设置/界面操作，不是本轮有独立任务价值的系统入口 | 仅在具体无障碍或使用场景证明价值后重评 |
| 继续“最后阅读的一本”的更严格规则 | 当前已有 `lastReadBookID`，所以“未实现最近打开身份”的旧排除理由撤销；但“仅滚动才更新、引用不更新”并非现有规则 | 不把更严格规则顺带纳入接入工作 | 产品确需区别正常阅读与引用查看，再独立批准规则变更 |
| AI 翻译/摘要、云同步、朗读服务 | 当前检查到的代码无对应业务实现；`DictionaryHelp` 明示不提供整句翻译 | 非本轮授权范围，不为 schema 匹配制造功能 | 独立产品立项后再评估；不在此次报告中当成计划事实 |

### 收藏条目的可选普通入口：打开收藏（仅供以后）

- **业务状态 / 代码链：已实现。**`EnglishReader/ContentView.swift: ContentView.body` 收藏列表按 `mastered` 分段，词句按钮设置 `favorite = item` → `.sheet(item: $favorite)` → `FavoriteDetail(store:item:openSource:)` 展示选词、原句与出处。数据由 `ReaderView.save(_:) → LibraryStore.savePassage(...) → commit / Snapshot.favorites` 保存，`SavedPassage.id` 是持久化 UUID；无现有 Intent、实体或查询。
- **结论：待验证、当前不实施。**以后若在普通内容导航中二选一，指定收藏详情可能比额外指定书籍更贴近复习场景；没有使用数据证明其频率，不改写为已规划功能。拟议 `OpenFavoriteIntent`、`FavoriteEntity`、`FavoriteQuery` 均尚不存在，普通路径 API 仍受 G1/G2 阻塞，不能进入就绪批次。
- **拟议参数 / 身份 / 歧义：**一个必填收藏实体，无可选业务参数，按 `SavedPassage.id` 精确回查，不拿词语、书名、原书 UUID 代替收藏身份。同词多条时显示选词与书名/章节，仍相同时辅助短 ID，必须选择具体 UUID，禁止取第一条。拟议系统查询涵盖当前存在的已掌握及未掌握收藏，不因活跃 UI 分段而自动换条目；建议数量上限、查询与消歧都是新增适配工作，不是现有查询 API。执行时再按同一 UUID 复核；Snapshot 当前未校验收藏 UUID 唯一性，异常重复 ID 应拒绝歧义。收藏删除后快捷指令失效，删后重存不按相同词句重绑。
- **结果 / 重复 / 来源：**前台打开该条当前详情，不朗读、不 toggle 掌握、不删除、不自动跳原文或改阅读位置。重复打开应复用/安全更新详情，模态协调尚需接线。原书移除但收藏存在时仍打开详情并沿用“原书已不在书架”的说明。若随后用户点“回到原文”，现有 `FavoriteDetail.openSource → ReaderRoute(bookID:chapter:offset:) → ReaderView` 用 `lookingAtQuote` 避免预览自动覆盖正常进度，并提供返回/从这里继续选项；这不自动算作拟议 Intent 的结果，进入 reader 仍会更新 `lastReadBookID`。
- **数据 / 安全：**共用当前私有 store 与 `favorite`，没有系统前台交付入口；实体查询若发生在 view 激活前，应拟议无副作用只读快照并在执行时与活跃 store 复核，不直接构造会播种示例的 `LibraryStore()`，不写回覆盖位置。无账户/跨用户范围，但收藏原句可能敏感；设备解锁、app 登录、数据访问和动作确认不是同一概念。仅拟议最少选择标签/ID，不把完整原句放进返回值、语音、日志或默认索引；标签本身的锁屏暴露也须核验。非破坏性打开无需额外删除确认，修改/删除留在原有 UI 流程；读取失败不冒充空收藏或成功。
- **普通路径 / schema / 系统面：**优先考虑手动配置的 Shortcuts 前台动作；A1/A3/A4 仅覆盖协议/属性，A6/A7 仅覆盖实体/查询协议，精确导航、结果、参数、显示和查询依赖仍缺 G1/G2。App Shortcuts、Siri 短语另缺 G3；Spotlight 内容索引不默认纳入；普通 Siri 调用不等于 Apple Intelligence 支持。schema 未确认精确 domain.member、必填输入/结果、依赖实体与动作组，当前不建议投入，不分配猜测版本；未来如选增强，需先核 SDK/OS 和硬件、语言/地区及功能条件，再决定 gate 与 iOS 26 普通路径回退。
- **成本 / 验证：****M**，假设复用前台导航交付，另需只读查询、UUID 消歧、失效处理与最少信息展示。以后先补 G1/G2，再由用户另行授权实现；随后才检查冷/热启动、同词多条、已掌握、收藏删后重存、原书移除、同名重导不重绑、空收藏/损坏库与文件保护。当前没有此路径的编译、元数据、入口可见性、模拟器或真机执行证据。

## 产品交接

1. **当前实施首批与技术就绪首批均为 0。**保留原报告动作身份；本次重点纠正“继续阅读”的真实语义，并记录收藏详情的可选普通入口。若后续批准，优先补继续阅读的 G1/G2，再由产品决定是否确需指定收藏或旧报告的指定书籍入口；都不是已集成动作。
2. 保持本机离线阅读、自用和 iOS 26 目标不变；不额外申请权限、不加云服务、不顺带改写最近打开规则、schema 或 Spotlight 全文索引。
3. API 声明/可用性、源码接入、编译/元数据、入口可见性、模拟器执行、真机执行是不同证据层级。后续实施获授权后才能依次验证，特别是有签名真机上的 Siri、快捷指令与 Spotlight；**本次没有任何 Siri 真机测试，不承诺可用。**Apple Intelligence 还需另核硬件、系统、语言/地区和功能条件，本轮不作支持承诺。
4. 本次仅更新这份既有报告，没有修改应用代码、工程、权限、deployment target 或构建脚本，没有执行构建、测试、模拟器操作或业务数据操作。已有 Xcode 27.2 / SDK 27.2 构建成功及 iOS 27.2 runtime 的事实不转化为尚未实现系统入口的验证结果。

**报告路径：**`/projects/7cf1e695-cc08-42ca-ac39-63f2facec305/intent-opportunities.md`。最重要的缺口仍是完整前台 API/冷启动交付，以及参数实体的无副作用查询、身份消歧与隐私暴露；不是缺少最近打开书籍 ID。
