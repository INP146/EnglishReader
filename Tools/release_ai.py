"""Draft dictionary release notes with a locally configured AI CLI (stdlib only).

The agent runs in the repository, reads the docs and the Git changes since the previous
release on its own, and fills in the notes file.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import NamedTuple

ENV_KEYS = (
    "RELEASE_AI_PROVIDER",
    "RELEASE_AI_MODEL",
    "RELEASE_AI_TIMEOUT_SECONDS",
)
TAG_RE = re.compile(r"dict-\d{4}\.\d{2}\.\d{2}(?:\.[1-9]\d*)?")


class AIConfig(NamedTuple):
    provider: str
    model: str
    timeout: int


def load_config(root: Path) -> AIConfig:
    """Read only the release settings from .env; never source it or export anything else."""
    values = {}
    env_path = root / ".env"
    if env_path.is_file():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^\s*(?:export\s+)?(\w+)\s*=\s*(.*?)\s*$", line)
            if not match or match[1] not in ENV_KEYS:
                continue
            try:
                parts = shlex.split(match[2], comments=True)
            except ValueError as exc:
                raise ValueError(f".env 中 {match[1]} 的引号不完整") from exc
            values[match[1]] = " ".join(parts)
    for key in ENV_KEYS:
        if key in os.environ:
            values[key] = os.environ[key]
    provider = values.get("RELEASE_AI_PROVIDER", "none").strip().lower()
    if provider not in {"none", "codex", "claude"}:
        raise ValueError("RELEASE_AI_PROVIDER 必须是 codex、claude 或 none")
    try:
        timeout = int(values.get("RELEASE_AI_TIMEOUT_SECONDS", "600"))
    except ValueError as exc:
        raise ValueError("RELEASE_AI_TIMEOUT_SECONDS 必须是正整数") from exc
    if timeout <= 0:
        raise ValueError("RELEASE_AI_TIMEOUT_SECONDS 必须是正整数")
    return AIConfig(provider, values.get("RELEASE_AI_MODEL", "").strip(), timeout)


def git(root: Path, *args: str) -> str:
    try:
        result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, encoding="utf-8", timeout=30)
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"Git {args[0]} 超时；未修改任何文件") from exc
    if result.returncode:
        raise ValueError(f"Git {args[0]} 失败；请确认比较基准 tag 存在且属于当前 HEAD 历史")
    return result.stdout


def resolve_base_tag(previous: str | None, base_tag: str | None = None) -> str:
    if base_tag is None:
        if previous is None:
            raise ValueError("首次发布没有上一个词典版本，请用 --base-tag 指定比较基准，或设置 RELEASE_AI_PROVIDER=none")
        base_tag = f"dict-{previous}"
    if TAG_RE.fullmatch(base_tag) is None:
        raise ValueError("--base-tag 必须是完整的词典发布 tag，例如 dict-2026.11.18.1")
    return base_tag


def validate_base_tag(root: Path, previous: str | None, base_tag: str | None = None) -> str:
    base_tag = resolve_base_tag(previous, base_tag)
    base = git(root, "rev-parse", "--verify", f"refs/tags/{base_tag}^{{commit}}").strip()
    git(root, "merge-base", "--is-ancestor", base, "HEAD")
    return base_tag


def make_prompt(version: str, base_tag: str, target: str) -> str:
    return f"""在当前 Readling 仓库中为词典包 dict-{version} 编写中文发布说明，直接编辑 {target}。
先阅读 AGENTS.md、docs/release.md 和 docs/releases/ 里的历史发布说明。自行查看
{base_tag} 到当前工作区的 Git 提交和差异（含未提交的改动），重点是 Tools/build-dictionary.py
的收录与分包规则、Dictionaries/release.json 的数据源，以及查词相关的 app 代码；需要时可以用
sqlite3 对比 build/dict 里刚构建的词典包和 Readling/Resources/dictionary-core.sqlite。
在模板中填写“主要变更”：读者能感知的收录或释义变化、各包条目数变化的原因、数据源是否更换、
是否需要新版 app（例如词典包 schema 变化）。按实际代码和数据判断，不要臆测。
保持标题、章节结构和词典包表格；保留顶部 RELEASE_TODO 人工审阅标记，有待确认的内容也用
RELEASE_TODO 标记。本次只修改 {target}，完成后简述你写入的内容。
"""


def validate_draft(content: str, version: str) -> None:
    if not content.startswith(f"# 词典包 dict-{version} 发布说明\n"):
        raise ValueError("Agent 写入的发布说明标题与版本不一致")
    for heading in ("## 主要变更", "## 词典包", "## 上线"):
        section = re.search(rf"(?m)^{re.escape(heading)}[ \t]*\n([\s\S]*?)(?=^## |\Z)", content)
        if not section or not section[1].strip():
            raise ValueError(f"Agent 写入的发布说明缺少或未填写 {heading}")


def generate(root: Path, version: str, previous: str | None, config: AIConfig, *, template: str, target: Path,
             base_tag: str | None = None) -> str:
    """Writes `template` to `target` (relative to root), has the agent fill it in and returns the result.
    On any failure the new draft is removed."""
    executable = shutil.which(config.provider)
    if not executable:
        raise ValueError(f"找不到 {config.provider} CLI；请安装并登录，或设置 RELEASE_AI_PROVIDER=none")
    base_tag = validate_base_tag(root, previous, base_tag)
    path = root / target
    if path.exists() or path.is_symlink():
        raise ValueError(f"{target} 已存在；保留已有发布说明")
    prompt = make_prompt(version, base_tag, target.as_posix())
    print(f"正在调用 {config.provider} 生成 {base_tag} → dict-{version} 的发布说明草稿（待人工审阅）...", flush=True)
    if config.provider == "codex":
        command = [
            executable, "-a", "never", "exec", "--sandbox", "workspace-write",
            "--cd", str(root), "--add-dir", str(path.parent), "--ephemeral", "--color", "never",
        ]
    else:
        command = [
            executable, "-p", "--output-format", "json", "--no-session-persistence",
            "--permission-mode", "acceptEdits", "--allowedTools",
            "Read", "Glob", "Grep", "Edit", "Write", "Bash(git:*)", "Bash(sqlite3:*)",
        ]
    if config.model:
        command.extend(["--model", config.model])
    if config.provider == "codex":
        command.append("-")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(template, encoding="utf-8")
    try:
        try:
            result = subprocess.run(command, input=prompt, cwd=root, capture_output=True, text=True,
                                    encoding="utf-8", timeout=config.timeout)
        except subprocess.TimeoutExpired as exc:
            raise ValueError(f"{config.provider} 生成超时（{config.timeout} 秒）；未修改版本文件") from exc
        if config.provider == "claude":
            # The JSON result says why a run failed (e.g. "API Error: …"); stderr is never shown.
            try:
                envelope = json.loads(result.stdout)
            except ValueError:
                envelope = None
            if result.returncode or not isinstance(envelope, dict) or envelope.get("is_error"):
                reason = envelope.get("result") if isinstance(envelope, dict) else None
                detail = f"：{str(reason)[:200]}" if reason else "；请检查 CLI 登录和模型配置"
                raise ValueError(f"claude 生成失败{detail}（未修改版本文件）")
        elif result.returncode:
            raise ValueError(f"{config.provider} 生成失败；请检查 CLI 登录和模型配置（未修改版本文件）")
        if not path.is_file() or path.is_symlink():
            raise ValueError("Agent 未写入目标发布说明")
        content = path.read_text(encoding="utf-8")
        if content == template:
            raise ValueError("Agent 未填写发布说明模板")
        validate_draft(content, version)
        if "RELEASE_TODO" not in content:
            title, remainder = content.split("\n", 1)
            content = f"{title}\n\nRELEASE_TODO：请审阅 AI 生成的主要变更，完成后删除此行。\n{remainder}"
            path.write_text(content, encoding="utf-8")
        return content
    except BaseException:
        # Only the draft this call created goes; an existing note is never touched.
        if path.exists():
            path.unlink()
        raise
