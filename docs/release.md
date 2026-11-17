# 发布

本仓库的发布流程。现在只有词典包的发布；以后 app 的发布也写在这里。

## 通用约定

- 本地脚本负责准备与校验，推送 tag 后由 GitHub Actions 构建并创建 Release。脚本从不提交、打 tag 或推送，这几步都由人执行。
- 每个发布 tag 的发布说明放在 `docs/releases/<tag>.md`，同时用作该 tag 的 GitHub Release 正文。发布失败的 tag 的说明也保留，作为记录。
- 已推送的 tag 不移动、不删除。校验或构建失败、或者发布后发现问题，修好后用下一个版本号重新发布。

## 词典包

数据与分包的设计见 `docs/dictionary-design.md`。

**版本**：`2026.11.18`，同一天再发布一次用 `2026.11.18.1`。tag 为 `dict-<版本>`。每个包的 `meta.version` 和清单都记录版本；app 按数字逐段比较，清单里的版本更新时显示“更新”。

**数据源固定**：`Dictionaries/release.json` 记录当前版本，以及 ECDICT 的提交号、`ecdict.csv` 的下载地址和 sha256。构建只用这份固定的数据，下载后先核对 sha256，所以任何时候都能重建出同一批包。

**Tools/dictionary_release.py**（只用标准库，兼容 macOS 自带的 Python 3.9）：

| 命令 | 作用 |
|---|---|
| `prepare <版本> [--source-commit <ECDICT 提交>] [--base-tag <tag>]` | 版本必须比当前新。构建全部包，起草发布说明 `docs/releases/dict-<版本>.md`，最后才更新 app 内置的核心词典和 `release.json`，所以起草失败时什么都没变。`--dry-run` 只列出将修改的文件、检查 AI 配置和比较基准，不构建也不调用模型。 |
| `check [tag] [--require-notes]` | 核对 `release.json`、内置核心词典的 meta、`manifest.json`；`--require-notes` 还要求发布说明已完成（标题与 tag 一致、填写了“主要变更”、不含 `RELEASE_TODO`）。 |
| `build [--verify-core]` | 按 `release.json` 构建全部包到 `build/dict`，打成 zip，生成 `manifest.json` 和 `SHA256SUMS`。zip 的时间戳和权限固定，同一环境构建两次逐字节一致。`--verify-core` 用表内容哈希比对构建出的核心词典和 app 内置的，不受 SQLite 版本影响。 |
| `adopt <版本>` | 下载已发布 Release 的 `manifest.json` 和 `SHA256SUMS`，核对哈希，确认每个包都能下载，再写入 `Dictionaries/manifest.json`。 |

**AI 起草发布说明**（`Tools/release_ai.py`）：在仓库根目录的 `.env`（不提交，模板见 `.env.example`）里配置一次：

```dotenv
RELEASE_AI_PROVIDER=claude      # codex / claude / none；没有 .env 时为 none，只生成模板
RELEASE_AI_MODEL=               # 留空沿用 CLI 自己的配置，不需要 API key
RELEASE_AI_TIMEOUT_SECONDS=600
```

- Shell 里已设置的同名变量优先于 `.env`；脚本只读这三个键，不执行 `.env`。CI 的 `check` 不读 `.env`，也不调用 AI。
- `prepare` 在构建完成后，把带表格的模板（各包条目数和相对当前版本的变化）写入 `docs/releases/dict-<版本>.md`，再在仓库根目录非交互地运行本机已登录的 CLI：codex 用 `exec --sandbox workspace-write`；claude 用 `-p`，只允许 Read、Glob、Grep、Edit、Write、`git` 和 `sqlite3`。
- Agent 自己阅读 AGENTS.md、本文档和历史发布说明，查看比较基准 tag（默认是上一个词典版本，例如 `dict-2026.11.18.1`，可用 `--base-tag` 指定）到当前工作区的改动，直接填写“主要变更”。比较基准必须存在且在 HEAD 历史里，否则在构建前就拒绝。
- 脚本读回实际写入的文件，检查标题和三个章节；草稿始终带顶部的 `RELEASE_TODO` 审阅标记（agent 删掉了也会补回），所以必须人工审阅后才能通过 `check --require-notes`。
- 生成失败、超时或草稿格式不对时，删除本次新建的草稿，`release.json` 和内置核心词典保持原样；已有的发布说明从不覆盖。claude 失败时报出它返回的原因（例如网络错误），不输出 stderr。

**Actions**：

- `validate-dictionaries.yml`：在 PR 和推送 main 时运行，也由发布流程调用。运行 `check` 和 `Tools/tests` 里的脚本测试；发布时还要求 tag 与 `release.json` 一致，并要求发布说明已完成。
- `publish-dictionaries.yml`：推送 `dict-*` tag 时运行。先校验，再 `build --verify-core`，然后用发布说明创建 Release，附上各包 zip、`manifest.json` 和 `SHA256SUMS`。Release 带 `--latest=false`，不占用仓库的 Latest Release，留给以后的 app 发布。已存在的 Release 不覆盖。

**日常发版**：

```sh
python3 Tools/dictionary_release.py prepare 2026.12.01 --dry-run
python3 Tools/dictionary_release.py prepare 2026.12.01        # 换数据源时加 --source-commit <40 位提交号>
# 审阅（或在 none 模式下填写）docs/releases/dict-2026.12.01.md，删除全部 RELEASE_TODO
python3 Tools/dictionary_release.py check --require-notes
# 跑 app 的单元测试和选词 UI 测试（核心词典变了）
git add -A && git commit
git push origin main
git tag -a dict-2026.12.01 -m "词典包 dict-2026.12.01"
git push origin dict-2026.12.01
# Actions 成功后：
python3 Tools/dictionary_release.py adopt 2026.12.01
git add Dictionaries/manifest.json && git commit && git push origin main
```

清单最后由人来提交：Release 的资源都确认能下载之后，app 才会看到新包。只改 app 而不改词典时，不需要走这个流程。

**失败与重跑**：校验或构建失败时不会创建 Release，修好后用下一个版本号重新发布。Release 创建后发现问题，同样发下一个版本，再 `adopt`。
