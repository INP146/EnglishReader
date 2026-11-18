# 翻译：设计与计划

记录词典查不到时的翻译、可选翻译引擎（用户自带 Key）、单词卡里的显示方式，以及实施进度。词典本身见 `docs/dictionary-design.md`。

## 目标

- 词典查不到（选中整句、词典没收的词或人名）时，单词卡里直接给出译文，不用再点“翻译”跳到系统面板。
- 用户自己选翻译引擎。联网引擎一律由用户提供自己的 API Key（BYOK），app 不提供、也不代付任何服务，没有后端。
- 不联网、不配置时也基本可用：默认引擎是 Apple 本机翻译，联网引擎不可用时退回它。
- 大模型引擎还能结合句子解释生词，补上词典查不到时最缺的“这个词在这里是什么意思”。

## 什么时候翻译

查词流程不变：先查词典（含词组和变形还原），查不到才翻译。

| 选中内容 | 词典 | 单词卡显示 |
|---|---|---|
| 单词或词组 | 查到 | 词典释义，与现在一致 |
| 单词或词组 | 查不到 | “离线词典里没有这个词”提示 + 语境释义（大模型引擎）或译文（其他引擎），标明“机器翻译 · <引擎名>” |
| 多个词，且不是词典里的词组（句子、半句） | — | 原文 + 译文 |

- “查不到时自动翻译”是一个开关（默认开）。关掉后单词卡显示“翻译”按钮，点了才翻译，不自动发出请求。
- 单个词用纯翻译引擎（Apple、DeepL）时译文常常不准，所以字号小一号、颜色用次要色，并标明来源，让用户看出这不是词典释义。
- 词典查到时也可以手动请求语境释义，作为展开区里的一个区块。这放在后面的步骤，收起态不变（与 `dictionary-design.md` 的约定一致）。
- 底部“翻译”按钮保留，仍打开系统翻译面板（能换语言、朗读）。

## 引擎

| 引擎 | 需要 | 整句翻译 | 语境释义 | 流式输出 | 说明 |
|---|---|---|---|---|---|
| Apple 本机翻译 | 下载语言包 | ✓ | — | — | 默认引擎，不用配置，没网时也能用 |
| OpenAI 兼容接口 | 服务地址、Key、模型 | ✓ | ✓ | ✓ | 一个接口覆盖 OpenAI、DeepSeek、通义、Kimi、OpenRouter、局域网 Ollama 等 |
| Claude | Key、模型 | ✓ | ✓ | ✓ | Messages API，原生接口与 OpenAI 格式不同 |
| Gemini | Key、模型 | ✓ | ✓ | ✓ | Gemini API（`generativelanguage.googleapis.com`），用 `x-goog-api-key` |
| DeepL | Key | ✓ | — | — | 免费版 Key 以 `:fx` 结尾，走 `api-free.deepl.com`；用 `context` 参数传入所在句子 |

不做的：

- **ML Kit Translate**：质量与 Apple 本机翻译相当，官方只支持 CocoaPods，用 SPM 要靠社区重新打包，语言模型文件还得自己处理。和 Apple 本机翻译能力重叠，不值得多一个重依赖。
- **TranslateGemma**（Google，2026-01，基于 Gemma 3，最小 4B）：质量更好，能结合上下文，但 4B 的 BF16 权重约 8 GB，4 位量化后估计 2–3 GB，还要接 MLX 或 llama.cpp 运行，对手机内存要求也高。以后可以做成“可选下载的本机引擎”，见“以后”。
- **自建代理**：不卖服务，所以不做。

### 模型名

不在代码里写死默认模型（模型更新太快，写死的很快就过时）。设置页提供“获取模型列表”，调用各家的模型列表接口（OpenAI 兼容的 `GET /models`、Claude 的 `GET /v1/models`、Gemini 的 `models.list`），用户从列表里选，也可以手填。

## 接口

参考了开源多引擎翻译工具的做法：每个服务声明自己支持的查询类型（翻译 / 词典式释义），大模型服务统一走流式输出，各服务有自己的配置页。这里简化为：

```swift
enum TranslationRequest {
    case translate(text: String)                    // 整句
    case explain(word: String, sentence: String)    // 生词的语境释义
}

protocol TranslationEngine {
    var id: TranslationEngineID { get }
    var capabilities: Set<TranslationCapability> { get }   // .translate, .explain
    /// 逐段给出累计结果；不支持流式的引擎只给出一次。
    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}
```

- `TranslationService`（单例，与 `WordDictionary` 并列）根据设置选择引擎：引擎不支持 `.explain` 时把 `explain` 降级为翻译这个词；当前引擎没配置或请求失败时退回 Apple 本机翻译，并在结果里带上实际使用的引擎，单词卡据此标注来源。
- 结果按（引擎、请求）在内存里缓存，同一次阅读里重复点同一个词不重复请求；不写盘。
- 单词卡关闭或换了选区时取消进行中的请求（结构化并发，`Task` 随视图的 `.task(id:)` 取消）。

### HTTP 客户端：不引入 SDK

各家接口都是“一个 POST + SSE 流式响应”，用 `URLSession.bytes(for:)` 按行解析 SSE 即可，每个引擎一百行左右。评估过的库：

- OpenAI 的 Swift 社区库（如 MacPaw/OpenAI）只覆盖 OpenAI 格式；Claude 没有官方 Swift SDK；Gemini 的官方 Swift SDK 已转为 Firebase AI Logic，依赖 Firebase 项目，不适合用户自带 Key。
- 用三个不同的库接三家，依赖和行为都不统一，不如共用一个小的 SSE 解析器，各引擎只负责拼请求和取出文本增量。

### Apple 本机翻译

- 用 `LanguageAvailability().status(from: en, to: zh-Hans)` 判断状态：
  - `.installed`：直接翻译。iOS 26 可以用 `TranslationSession(installedSource:target:)` 直接创建会话，不必通过 `.translationTask` 视图修饰符（实现时先核对 API）。
  - `.supported`（未下载）：不自动弹下载提示，单词卡显示“下载翻译语言包”按钮，点了走 `prepareTranslation()` 或系统翻译面板。
  - `.unsupported`：只显示词典提示。
- 源语言固定英文，目标语言固定简体中文（界面是中文）。以后要支持其他目标语言时，再加一个设置项。

## 提示词

- **translate**：系统提示要求“只输出译文，不解释、不加引号”；原文放在明确的分隔符里。
- **explain**：输入生词和所在句子，要求输出简短中文，固定格式：第一行“词性 释义”（这个词在本句中的意思），第二行一句话说明（如“人名”“俚语，意为……”“古英语拼法，即……”），不超过两行。
- 书的原文可能包含类似指令的文字。原文只作为数据放在分隔符里，输出只作为纯文本显示，不执行、不解析为链接或标记，风险可控。

## 单词卡

- 选中的是句子时，顶部原文改用正文字号、最多显示若干行，不用单词的大标题样式；收藏星标不显示（生词本只收单词和词组）。
- 译文区域与释义区一样有最大高度，超出滚动；流式输出时逐段出现，开头显示加载指示。
- 出错时显示一行原因和“重试”：Key 无效（401/403）、额度或频率限制（429）、网络不可用（这种情况下已退回 Apple 本机翻译时，只标注来源，不报错）。
- 收藏词典里没有的词时，生词本保存语境释义（或译文）的快照作为释义，标明来源；没有结果时与现在一样只存原文。

## 设置 › 翻译

放在“设置”里“词典”下面：

- **翻译引擎**：单选，Apple 本机翻译 / OpenAI 兼容 / Claude / Gemini / DeepL。未配置的引擎显示“未配置”，选中时进入配置页。
- **查不到时自动翻译**：开关，默认开。
- **各引擎配置页**：
  - OpenAI 兼容：服务地址（默认 `https://api.openai.com/v1`）、API Key、模型（获取列表或手填）
  - Claude、Gemini：API Key、模型
  - DeepL：API Key
  - 共有：“测试”按钮（发一句短文本，显示结果或错误）、“删除 Key”
- **Apple 本机翻译**：显示语言包状态，未下载时提供下载入口。
- **页脚：联网说明**：使用联网引擎时，选中的文字和所在句子会发给所选服务商，按服务商自己的隐私政策处理；书的其余内容和生词本不上传。“关于”页和 `SOURCE.md` 同步改写。

### Key 的存放

- 存在 Keychain（`kSecClassGenericPassword`，service `com.inp146.readling.translation`，account 为引擎 id），可访问性 `AfterFirstUnlockThisDeviceOnly`，不随 iCloud 同步、不进备份。
- 服务地址、模型名、所选引擎等非机密设置用 `@AppStorage`。
- 输入框是安全输入，配置页只显示 Key 的末四位。

## 测试

- **单元测试**：
  - 用 `URLProtocol` 桩拦截请求，检查各引擎拼出的请求（地址、头、正文），并喂入录好的 SSE 片段，检查解析出的文本增量、结束和错误映射（401、429、断流）。
  - DeepL 免费 / 付费地址的选择。
  - 退回逻辑：引擎未配置、请求失败时使用 Apple 本机翻译，结果标注的引擎正确。
  - Keychain 读写删除。
- **UI 测试**：模拟器上很可能没装翻译语言包，也不能用真实 Key。加启动参数 `-translationEngine stub`，使用返回固定文本的桩引擎，在 `SelectionUITests` 里选中句子，要求单词卡出现译文，并且点按后正常关闭。

## 以后

1. 词典查到时，展开区里按需请求“语境释义”。
2. 本机大模型引擎：iOS 26 Foundation Models（只在支持 Apple Intelligence 的设备上可用），或可选下载的 TranslateGemma 4B（量化，MLX 运行）。
3. 目标语言设置。

## 进度

- [ ] 第 1 步：`TranslationEngine` 协议与 `TranslationService`、Apple 本机引擎、单词卡内联译文与句子样式、自动翻译开关、桩引擎与 UI 测试
- [ ] 第 2 步：SSE 解析、OpenAI 兼容引擎、Keychain、设置 › 翻译与配置页（含获取模型列表、测试）、联网说明
- [ ] 第 3 步：Claude、Gemini、DeepL 引擎；生词本保存翻译快照
- [ ] 以后：查到时的语境释义、本机大模型、目标语言
