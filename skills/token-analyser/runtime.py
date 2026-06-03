"""Runtime detection for token-analyser.

Keep this aligned with .claude-agent-flow/scripts/session-start.sh:
AI_FLAVOUR is the primary contract, with Claude and Codex environment
signals as fallbacks.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping

VALID_RUNTIMES = {"claude", "codex", "none"}


def _normalise(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip().lower()
    return value if value in VALID_RUNTIMES else None


def codex_invocation_detected(env: Mapping[str, str] = os.environ) -> bool:
    originator = env.get("CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "").lower()
    return (
        env.get("CODEX_CI") == "1"
        or bool(env.get("CODEX_THREAD_ID"))
        or bool(env.get("CODEX_PROJECT_DIR"))
        or env.get("CODEX_SHELL") == "1"
        or bool(env.get("CODEX_SANDBOX"))
        or originator.startswith("codex")
    )


def claude_invocation_detected(env: Mapping[str, str] = os.environ) -> bool:
    return (
        env.get("CLAUDECODE") == "1"
        or env.get("AI_AGENT", "").startswith("claude-code/")
        or bool(env.get("CLAUDE_PROJECT_DIR"))
    )


def codex_runtime_hint_detected(env: Mapping[str, str] = os.environ) -> bool:
    if claude_invocation_detected(env):
        return False
    return Path("/opt/codex").is_dir() or Path("/opt/codex/skills").is_dir()


def detect_ai_flavour(env: Mapping[str, str] = os.environ) -> str:
    """Return claude, codex, or none from startup-compatible signals."""
    override = _normalise(env.get("TOKEN_ANALYSER_RUNTIME")) or _normalise(
        env.get("CODEX_TOKEN_ANALYSER_RUNTIME")
    )
    if override:
        return override

    ai_flavour = _normalise(env.get("AI_FLAVOUR"))
    if ai_flavour:
        return ai_flavour

    if claude_invocation_detected(env):
        return "claude"
    if codex_invocation_detected(env) or codex_runtime_hint_detected(env):
        return "codex"
    return "none"


def select_runtime(env: Mapping[str, str] = os.environ) -> str:
    """Map direct shell invocations to Claude to preserve existing CLI UX."""
    flavour = detect_ai_flavour(env)
    return "claude" if flavour == "none" else flavour
