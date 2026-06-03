"""Claude local log adapter for token-analyser.

This wraps the existing Claude parser functions so the legacy behavior stays
byte-for-byte close while parse-logs.py can route by runtime.
"""

from __future__ import annotations

import sys
from datetime import datetime
from typing import Any, Callable


class ClaudeUsageAdapter:
    runtime = "claude"

    def __init__(
        self,
        *,
        find_project_dir: Callable[[str], Any],
        get_session_files: Callable[[Any, str, str | None], list[Any]],
        parse_session_file: Callable[[Any, Any], dict[str, Any]],
        detect_issues: Callable[[list[dict[str, Any]]], list[dict[str, Any]]],
        determine_health: Callable[[list[dict[str, Any]]], str],
        savings_comparison: Callable[[str, int, int, int, int, float | None], list[dict[str, Any]]],
        local_tz,
    ):
        self.find_project_dir = find_project_dir
        self.get_session_files = get_session_files
        self.parse_session_file = parse_session_file
        self.detect_issues = detect_issues
        self.determine_health = determine_health
        self.savings_comparison = savings_comparison
        self.local_tz = local_tz

    def analyse(self, project_path: str, mode: str, session_id: str | None) -> dict[str, Any]:
        project_dir = self.find_project_dir(project_path)
        session_files = self.get_session_files(project_dir, mode, session_id)

        if not session_files:
            return {
                "runtime": self.runtime,
                "mode": mode,
                "period": datetime.now(self.local_tz).strftime("%Y-%m-%d %H:%M"),
                "sessions": [],
                "totals": {
                    "api_calls": 0,
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "ratio": 0,
                    "est_cost_usd": 0.0,
                },
                "health": "ok",
                "top_issues": [],
                "savings_comparison": [],
            }

        sessions = []
        for sf in session_files:
            try:
                sessions.append(self.parse_session_file(sf, project_dir))
            except Exception as e:
                print(f"WARNING: failed to parse {sf}: {e}", file=sys.stderr)

        sessions.sort(key=lambda s: s.get("timestamp_start") or "", reverse=True)
        primary_model = next(
            (s["model"] for s in sessions if s.get("model")),
            "anthropic_claude_sonnet_4_6",
        )

        total_calls = sum(s["api_calls"] + s.get("subagent_calls", 0) for s in sessions)
        total_in = sum(s["input_tokens"] for s in sessions)
        total_out = sum(s["output_tokens"] for s in sessions)
        total_cache_read = sum(s["cache_read_tokens"] for s in sessions)
        cost_values = [s["est_cost_usd"] for s in sessions]
        total_cost = sum(cost_values) if all(c is not None for c in cost_values) else None
        total_alt_cost = round(
            sum(
                s["recommendation"]["est_cost"]
                for s in sessions
                if s.get("recommendation") and s["recommendation"].get("est_cost") is not None
            ),
            2,
        )
        total_duration_min = sum(s.get("duration_min", 0) for s in sessions)
        overall_ratio = total_in // max(total_out, 1)

        issues = self.detect_issues(sessions)
        health = self.determine_health(issues)
        savings = self.savings_comparison(primary_model, total_in, total_out, total_cache_read, 0, total_cost)

        return {
            "runtime": self.runtime,
            "mode": mode,
            "period": datetime.now(self.local_tz).strftime("%Y-%m-%d %H:%M"),
            "model": primary_model,
            "sessions": sessions,
            "totals": {
                "api_calls": total_calls,
                "input_tokens": total_in,
                "cache_read_tokens": total_cache_read,
                "output_tokens": total_out,
                "ratio": overall_ratio,
                "est_cost_usd": round(total_cost, 4) if total_cost is not None else None,
                "alt_cost_usd": total_alt_cost,
                "duration_min": total_duration_min,
            },
            "health": health,
            "top_issues": issues[:5],
            "savings_comparison": savings,
        }
