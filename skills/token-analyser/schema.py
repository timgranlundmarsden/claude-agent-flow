"""Shared token-analyser domain helpers."""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

SKILL_DIR = Path(__file__).parent
PRICING_FILE = SKILL_DIR / "reference" / "model-pricing.json"


def load_pricing() -> dict[str, Any]:
    with open(PRICING_FILE) as f:
        return json.load(f)


def normalize_model_key(model: str) -> str:
    codex_variant = re.match(r"^(gpt-\d+(?:\.\d+)?-codex)-\d+s-\d+p-.+$", model)
    if codex_variant:
        return codex_variant.group(1)
    if not model.startswith("claude-"):
        return model
    key = re.sub(r"-\d{8}$", "", model)
    return "anthropic_" + key.replace("-", "_")


def calc_cost(
    model: str,
    input_tok: int,
    output_tok: int,
    cache_read_tok: int = 0,
    cache_write_tok: int = 0,
) -> float | None:
    pricing = load_pricing()["models"].get(normalize_model_key(model))
    if pricing is None:
        return None
    rate_in = pricing["in"] / 1_000_000
    rate_out = pricing["out"] / 1_000_000
    rate_cache_read = (pricing.get("cache_read") or 0) / 1_000_000
    rate_cache_write = (pricing.get("cache_write") or pricing["in"]) / 1_000_000
    return (
        input_tok * rate_in
        + output_tok * rate_out
        + cache_read_tok * rate_cache_read
        + cache_write_tok * rate_cache_write
    )


def empty_result(mode: str, local_tz) -> dict[str, Any]:
    return {
        "mode": mode,
        "period": datetime.now(local_tz).strftime("%Y-%m-%d %H:%M"),
        "sessions": [],
        "totals": {
            "api_calls": 0,
            "input_tokens": 0,
            "cache_read_tokens": 0,
            "output_tokens": 0,
            "ratio": 0,
            "est_cost_usd": 0.0,
            "duration_min": 0,
        },
        "health": "ok",
        "top_issues": [],
        "savings_comparison": [],
    }


def classify_session(api_calls: int, tool_calls: int, subagent_calls: int, output_tokens: int) -> str:
    if subagent_calls > 0:
        return "subagent"
    if api_calls >= 10 and tool_calls >= api_calls * 0.4:
        return "agentic"
    if api_calls <= 4 and output_tokens > 2000:
        return "generation"
    if api_calls <= 3:
        return "simple"
    return "reasoning"


SESSION_TYPE_MODEL = {
    "subagent": "gpt-5.4-mini",
    "agentic": "anthropic_claude_haiku_4_5",
    "generation": "gemini-2.5-flash",
    "simple": "gemini-2.5-flash-lite",
    "reasoning": "gemini-2.5-flash",
}

SESSION_TYPE_LABEL = {
    "subagent": "GPT-5.4 mini",
    "agentic": "Haiku 4.5",
    "generation": "Gemini 2.5 Flash",
    "simple": "Gemini Flash-Lite",
    "reasoning": "Gemini 2.5 Flash",
}

SESSION_TYPE_REASON = {
    "subagent": "session used subagents - GPT-5.4 mini excels at coding & orchestration",
    "agentic": "heavy tool use (Read/Bash/Grep) - Haiku 4.5 is fast & cheap for agentic loops",
    "generation": "few calls with large output - Gemini 2.5 Flash is strong at generation tasks",
    "simple": "very short session - Gemini Flash-Lite is ideal for low-complexity tasks",
    "reasoning": "general coding/reasoning session - Gemini 2.5 Flash has thinking mode but expect quality trade-off vs Sonnet",
}


def recommend_for_session(
    session_type: str,
    input_tok: int,
    output_tok: int,
    cache_read_tok: int,
    cache_write_tok: int,
    actual_cost: float | None,
) -> dict[str, Any]:
    alt_model_id = SESSION_TYPE_MODEL[session_type]
    est = calc_cost(alt_model_id, input_tok, output_tok, cache_read_tok, cache_write_tok)
    saving_pct = round((1 - est / actual_cost) * 100) if (actual_cost and est is not None) else 0
    return {
        "model": SESSION_TYPE_LABEL[session_type],
        "model_id": alt_model_id,
        "session_type": session_type,
        "est_cost": round(est, 2) if est is not None else None,
        "saving_pct": saving_pct,
        "reason": SESSION_TYPE_REASON[session_type],
    }
