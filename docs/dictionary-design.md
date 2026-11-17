# 离线词典：设计与计划

记录查词词典的分包方式、单词卡排版、下载机制和后续扩展的设计决定，以及实施进度。数据来源与许可见 `EnglishReader/SOURCE.md`。

## 目标

- 单词卡保持简明，详细内容放进“展开”。
- 一套默认的离线词典与单词卡排版：不联网也完整可用。
- 在 app 内按需下载更大的离线词库；今后可接入网络词典、LLM 语境释义；自定义词典（StarDict、MDict）放在最后，因为格式解析和排版是难点。
- 存储空间不是主要顾虑，关键是分级清楚、可选。

## 数据：ECDICT 与分包

数据来自 ECDICT（`ecdict.csv`，77 万条，MIT）。统计（2026-11-17 版）：

| 类别 | 条目 |
|---|---|
| 常用单词（考试标签、柯林斯/牛津标记，或 BNC/词频前 6 万） | 5.8 万 |
| 其余普通单词 | 约 23.5 万（几乎都没有词频数据） |
| 所有义项都带学科标注（“[医]”等）的单词 | 约 8 万 |
| 专有名词（首字母大写） | 约 2.6 万 |
| 通用短语（各词都是常用词，无学科标注） | 约 6 万 |
| 学科短语 | 约 27 万 |
| 专有名词短语 | 约 2 万 |

### 并集分包，不做层层包含

每条只归入一个包，各包可以任意组合，查词时按顺序查所有已装的包，取第一个命中的结果。所有包都出自同一版 ECDICT，同一个词不会有两种说法。

| 包 id | 名称 | 内容 | 条目 / 大小 | 获取方式 |
|---|---|---|---|---|
| core | 核心词典 | 常用词、它们的变形、通用短语（含短语动词、习语），外加变形表 | 15.3 万 / 24 MB | 内置 |
| extended | 扩展词汇 | 其余普通单词和短语 | 23 万 / 22 MB | 下载 |
| medicine, chemistry, computing, economics, law, electronics, mechanics, sciences | 医学、化学、计算机、经济、法律、电子电气、机械工程、其他学科 | 所有义项都带对应学科标注的单词和短语 | 共 35 万 / 28 MB | 下载，按学科选装 |
| names | 人名地名 | 首字母大写的单词和短语：人名、地名、机构、学名 | 4.1 万 / 4 MB | 下载 |

分包规则（`Tools/build-dictionary.py`）：

1. 单词，并且是常用词或常用词的变形 → core
2. 短语，无学科标注、不是大写开头，且各词都是常用词（或 sb、sth、one's 这类占位词）→ core
3. 所有义项（“[网络]”义项不算）都带学科标注 → 对应学科包。一条跨两个学科就两个包各放一份，app 查到后按 key 去重
4. 首字母大写 → names
5. 其余 → extended

“give up”有一条“[法]”义项，但另有通用义项，所以留在 core。

### 为什么不按水平分包

- 所有考试词（中考到 GRE）都已经在 core 里。
- core 之外的词几乎没有词频数据，无法按难度排序。
- 水平决定的是“哪些词你大概不用查”，不是“词典该收什么”。所以水平应该做成用户设置（考试标签显示、按难度筛选生词、在正文里标出超出水平的词），不做成分包。

ECDICT 另有 340 万条的完整版（压缩后 216 MB），多出来的主要是专业术语和专有名词。暂不采用；如果学科包需要扩充，它是现成的来源，分包规则不用变。

### 包格式（schema 2）

每个包是一个 SQLite 文件 `dictionary-<id>.sqlite`：

```sql
meta(key TEXT PRIMARY KEY, value TEXT)   -- schema, id, title, group, order, version, source, sourceCommit, entries
entry(key TEXT PRIMARY KEY,              -- 规范化后的小写形式，与 WordDictionary.normalize 一致
      word, phonetic,
      translation,                       -- 全部中文义项，一行一组；含 “[网络]” 和学科义项
      definition,                        -- 英文释义，一行一个义项（Webster 的硬换行已接回）
      tags, collins, oxford, rank,
      forms)                             -- "p:went/d:gone/..."，p d i 3 r t s
form(form TEXT PRIMARY KEY, lemma TEXT)  -- 仅 core：变形 → 原形
```

`schema` 不匹配的包，app 会忽略。

## 变形还原层

- 变形 → 原形只由 core 的 `form` 表决定，所以生词本的 key 与装了哪些包无关。
- 构建时决定哪些变形需要跳转：
  - 变形没有自己的词条，或自己的词条指回这个原形（exchange 的 `0:` 字段，或释义里写着“go的过去式”这类说明）
  - 有多个候选原形时取更常用的那个：does 是 do 而不是 doe
  - ECDICT 漏掉的 am、are、was、were 在脚本里手工补上
- 运行时：
  - 有跳转就显示原形词条，并在变形词有独立常用词义时，附上“found 本身：vt. 建立”
  - 原形所在的包没装时，显示变形词自己的词条，但词头和 key 仍用原形
  - 短语逐词还原：gave up → give up
  - 缩写词尾（'s、'll、n't 等）先去掉再查

## 单词卡

字段化排版，与数据来自哪个包无关：

- **收起（默认）**：词头、音标、朗读（系统离线 TTS）、收藏；变形说明（“considering 是 consider 的现在分词”）；简明释义（最多四行通用义项，学科和网络义项只在没有通用义项时显示）；变形词自身的词义。
- **展开**：其余义项、英文释义、词形、等级（考试标签、柯林斯星级、牛津 3000）、以该词开头的短语（短语动词优先，点按展开释义）、来源。

今后的网络词典和 LLM 结果作为展开区里新增的区块，收起态不变。生词本保存的是收藏那一刻的简明释义快照，换了词典也不受影响。

## 下载（第 2 步）

- **托管**：词典包压缩成 zip，作为 GitHub Releases 资源，发布在本仓库（INP146/EnglishReader，公开）的 `dict-<版本>` 标签下，见 `docs/release.md`。App Store 托管的 On-Demand Resources 和 Background Assets 不适用：app 目前是重签安装，不经过 App Store。
- **清单**：`Dictionaries/manifest.json` 放在仓库里，app 从 `raw.githubusercontent.com/INP146/EnglishReader/main/Dictionaries/manifest.json` 读取。清单写明格式（`format: 1`）和版本（`release`），每个包写明 id、名称、分组、顺序、schema、版本、条目数、zip 大小、解压后大小、sha256、下载地址。
- **下载与安装**：
  - 下载用 `URLSession` 的下载任务，失败时保留续传数据（resume data）。最大的包压缩后约 9 MB，所以不用后台会话（background session）。
  - 下完先校验 sha256，再用 ZIPFoundation 解压到临时目录。
  - 用 `DictionaryPack` 打开校验 schema 和 id，原子地移动到 `Application Support/EnglishReader/Dictionaries/<id>.sqlite`，并标记为不进 iCloud 备份（可以重新下载）。
  - 最后调用 `WordDictionary.reload()`。
- **更新与删除**：清单里的版本比已装的新，就显示“更新”；删除时先关闭数据库再删文件，然后重新加载。
- **隐私说明**：书和生词从不上传；只有在用户主动打开词典设置或下载词典时才联网。“关于”页和 SOURCE.md 同步改写。
- **测试**：单元测试用本地 `file://` 清单和 zip 走完下载、校验、安装、更新、删除；启动参数 `-dictionaryManifestURL` 可让 app 改用本地 HTTP 服务器上的清单。

### 设置 › 词典

放在“阅读器设置”下面，和它同一组：

- **核心词典**：显示“内置”和条目数。
- **扩展词汇、学科（八个）、人名地名**：每行显示名称、条目数和大小，以及状态和操作：下载、下载进度（可取消）、已安装（可删除）、有更新。
- **单词卡**：
  - 默认展开（`dictionaryExpandByDefault`）
  - 朗读口音：美音 / 英音（`dictionaryAccent`）
- **页脚**：数据来源与联网说明。

查不到词时，单词卡提示“可在 设置 › 词典 下载更多词库”。

### 发布

词典包的版本、构建、发布和上线流程见 `docs/release.md`。

## 以后

1. 网络词典接口、LLM 语境释义（iOS 26 FoundationModels，本机生成），作为展开区的异步区块。
2. 用户水平设置：显示难度、筛选生词、在正文里标出超出水平的词。
3. 自定义词典导入：先 StarDict（格式简单），再 MDict（需要解析库，释义是 HTML，展开区要能显示网页内容）。

## 进度

- [x] 第 1 步：分包脚本与 schema 2、内置核心包、变形还原层、并集查词、单词卡收起/展开（2026-11-17）
- [x] 第 2 步：打包与清单工具、下载管理、设置 › 词典（2026-11-17）
- [x] 发布流程：`Tools/dictionary_release.py`、Actions 工作流、ECDICT 固定到 `9c46923`（2026-11-18）
- [x] AI 起草发布说明（`Tools/release_ai.py`，2026-11-18）
- [x] 发布 `dict-2026.11.18.1` 并 adopt（2026-11-18；`dict-2026.11.18` 因 CI 缺 Python 3.9 未发布）
- [ ] 以后：网络词典与 LLM、水平设置、自定义导入
