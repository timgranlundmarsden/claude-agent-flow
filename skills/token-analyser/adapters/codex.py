"""Codex local artifact adapter for token-analyser."""

from __future__ import annotations

import json
import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, Iterable, Mapping

from schema import calc_cost, classify_session, empty_result, load_pricing, normalize_model_key, recommend_for_session


@dataclass
class UsageRecord:
    timestamp: datetime | None
    model: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int | None
    cache_write_tokens: int | None
    context_size: int | None
    source: str = "jsonl"


class CodexUsageAdapter:
    runtime = "codex"

    def __init__(self, project_path: str, local_tz, env: Mapping[str, str] = os.environ):
        self.project_path = Path(project_path)
        self.local_tz = local_tz
        self.env = env

    def analyse(self, mode: str, session_id: str | None) -> dict[str, Any]:
        files = self.resolve_session_files(mode, session_id)
        sessions = []
        for path in files:
            session = self.parse_session_file(path)
            if session["api_calls"] > 0:
                sessions.append(session)
        if not sessions:
            sessions.extend(self._sqlite_sessions(mode, session_id))
        sessions = self._dedupe_sessions(sessions)

        if not sessions:
            result = empty_result(mode, self.local_tz)
            result["runtime"] = self.runtime
            result["telemetry_notes"] = ["No Codex local session artifacts found."]
            return result

        sessions.sort(key=lambda s: s.get("timestamp_start") or "", reverse=True)
        result = self._result_from_sessions(mode, sessions)
        result["runtime"] = self.runtime
        return result

    @staticmethod
    def _dedupe_sessions(sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
        by_id: dict[str, dict[str, Any]] = {}
        for session in sessions:
            session_id = session.get("id", "")
            session_key = f"{session_id}:{session.get('timestamp_start') or session.get('file') or ''}"
            current = by_id.get(session_key)
            if current is None or session.get("api_calls", 0) > current.get("api_calls", 0):
                by_id[session_key] = session
        return list(by_id.values())

    def resolve_session_files(self, mode: str, session_id: str | None) -> list[Path]:
        candidates = sorted(
            {path for root in self._candidate_roots() for path in root.rglob("*.jsonl")},
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )

        target_session = session_id or (self.env.get("CODEX_THREAD_ID") if mode == "session" else None)
        if target_session:
            candidates = [
                p for p in candidates
                if self._jsonl_matches_session(p, target_session)
            ]

        if mode == "session":
            return candidates[:1]

        now = datetime.now(timezone.utc)
        if mode == "today":
            local_midnight = datetime.now(self.local_tz).replace(hour=0, minute=0, second=0, microsecond=0)
            cutoff = local_midnight.astimezone(timezone.utc)
        elif mode == "24h":
            cutoff = now - timedelta(hours=24)
        elif mode == "week":
            cutoff = now - timedelta(days=7)
        else:
            return []

        result = []
        for path in candidates:
            ts = self._peek_session_start(path)
            fallback = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
            if (ts or fallback) >= cutoff:
                result.append(path)
        return result

    def parse_session_file(self, path: Path) -> dict[str, Any]:
        records = list(self._usage_records(path))
        session_id = self._session_id_from_jsonl(path) or path.stem
        return self._session_from_records(session_id, str(path), records)

    def _session_from_records(self, session_id: str, source_path: str, records: list[UsageRecord]) -> dict[str, Any]:
        first_ts = min((r.timestamp for r in records if r.timestamp), default=None)
        last_ts = max((r.timestamp for r in records if r.timestamp), default=None)
        model = next((r.model for r in records if r.model), "gpt-5.4")
        total_in = sum(r.input_tokens for r in records)
        total_out = sum(r.output_tokens for r in records)
        cache_read_available = all(r.cache_read_tokens is not None for r in records)
        cache_write_available = all(r.cache_write_tokens is not None for r in records)
        total_cache_read = sum(r.cache_read_tokens or 0 for r in records)
        total_cache_write = sum(r.cache_write_tokens or 0 for r in records)
        api_calls = len(records)
        sqlite_live_total = any(r.source == "sqlite-live-total" for r in records)
        cost = None if sqlite_live_total else calc_cost(model, total_in, total_out, total_cache_read, total_cache_write)
        unsupported_fields = []
        if not cache_read_available:
            unsupported_fields.append("cache_read_tokens")
        if not cache_write_available:
            unsupported_fields.append("cache_write_tokens")
        context_available = all(r.context_size is not None for r in records)
        if not context_available:
            unsupported_fields.append("context_size")
        if sqlite_live_total:
            unsupported_fields.extend(["output_token_split", "cache_token_split"])

        duration_min = 0
        if first_ts and last_ts:
            duration_min = max(1, int((last_ts - first_ts).total_seconds() / 60))

        model_stats: dict[str, dict[str, int]] = {}
        per_call = []
        for record in records:
            ms = model_stats.setdefault(
                record.model,
                {"calls": 0, "input": 0, "output": 0, "cache_read": 0, "cache_write": 0},
            )
            ms["calls"] += 1
            ms["input"] += record.input_tokens
            ms["output"] += record.output_tokens
            ms["cache_read"] += record.cache_read_tokens or 0
            ms["cache_write"] += record.cache_write_tokens or 0
            unsupported = []
            if record.cache_read_tokens is None:
                unsupported.append("cache_read")
            if record.cache_write_tokens is None:
                unsupported.append("cache_write")
            if record.context_size is None:
                unsupported.append("context_size")
            per_call.append({
                "input": record.input_tokens,
                "output": record.output_tokens,
                "cache_write": record.cache_write_tokens or 0,
                "cache_read": record.cache_read_tokens or 0,
                "context_size": record.context_size or 0,
                "ts": record.timestamp.isoformat() if record.timestamp else None,
                "unsupported": unsupported,
            })

        session_type = classify_session(api_calls, 0, 0, total_out)
        session = {
            "id": session_id,
            "file": source_path,
            "runtime": self.runtime,
            "timestamp_start": first_ts.isoformat() if first_ts else None,
            "timestamp_end": last_ts.isoformat() if last_ts else None,
            "start_local": first_ts.astimezone(self.local_tz).strftime("%a %d/%m %H:%M") if first_ts else None,
            "duration_min": duration_min,
            "model": model,
            "api_calls": api_calls,
            "tool_calls": 0,
            "subagent_calls": 0,
            "session_type": session_type,
            "input_tokens": total_in + total_cache_write,
            "cache_read_tokens": total_cache_read,
            "output_tokens": total_out,
            "ratio": (total_in + total_cache_write) // max(total_out, 1),
            "est_cost_usd": round(cost, 4) if cost is not None else None,
            "unknown_cost_models": [] if cost is not None or sqlite_live_total else [model],
            "recommendation": recommend_for_session(
                session_type, total_in, total_out, total_cache_read, total_cache_write, cost
            ),
            "is_subagent": False,
            "cost_blocks": [{
                "label": "codex session",
                "calls": api_calls,
                "input": total_in + total_cache_write,
                "cache_read": total_cache_read,
                "output": total_out,
                "cost": round(cost, 4) if cost is not None else None,
                "is_subagent": False,
            }] if records else [],
            "context_growth": [],
            "peak_jump": None,
            "per_call": per_call,
            "model_stats": model_stats,
            "unsupported_fields": unsupported_fields,
            "telemetry_notes": [
                "Codex local logs do not expose Claude cache/context telemetry for all records."
            ] if unsupported_fields else [],
        }
        if sqlite_live_total:
            session["telemetry_notes"].append(
                "Codex live SQLite logs expose cumulative total/estimated token usage; input/output/cache splits and cost are unavailable."
            )
        return session

    def _candidate_roots(self) -> list[Path]:
        roots = []
        raw = self.env.get("CODEX_TOKEN_ANALYSER_LOG_DIRS", "")
        for value in raw.split(os.pathsep):
            if value:
                roots.append(Path(value).expanduser())
        for key in ("CODEX_SESSION_LOG_DIR", "CODEX_LOG_DIR"):
            if self.env.get(key):
                roots.append(Path(self.env[key]).expanduser())
        if self.env.get("CODEX_HOME"):
            roots.append(Path(self.env["CODEX_HOME"]).expanduser() / "sessions")
        if roots:
            return [root for root in roots if root.is_dir()]
        roots.extend([
            self.project_path / ".codex",
            self.project_path / ".codex" / "sessions",
            Path.home() / ".codex" / "archived_sessions",
            Path.home() / ".codex" / "sessions",
            Path.home() / ".codex" / "logs",
            Path.home() / ".codex" / "history",
        ])
        return [root for root in roots if root.is_dir()]

    def _usage_records(self, path: Path) -> Iterable[UsageRecord]:
        fallback_model = self._model_from_jsonl(path)
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                record = self._extract_usage_record(obj, fallback_model=fallback_model)
                if record:
                    yield record

    def _extract_usage_record(self, obj: dict[str, Any], fallback_model: str | None = None) -> UsageRecord | None:
        usage = None
        container = obj
        if isinstance(obj.get("usage"), dict):
            usage = obj["usage"]
        elif isinstance(obj.get("token_usage"), dict):
            usage = obj["token_usage"]
        elif isinstance(obj.get("response"), dict) and isinstance(obj["response"].get("usage"), dict):
            container = obj["response"]
            usage = container["usage"]
        elif isinstance(obj.get("message"), dict) and isinstance(obj["message"].get("usage"), dict):
            container = obj["message"]
            usage = container["usage"]
        elif (
            isinstance(obj.get("payload"), dict)
            and isinstance(obj["payload"].get("info"), dict)
            and isinstance(obj["payload"]["info"].get("last_token_usage"), dict)
        ):
            container = obj["payload"]
            usage = obj["payload"]["info"]["last_token_usage"]

        if not usage:
            return self._extract_metadata_record(obj, fallback_model=fallback_model)

        model = (
            container.get("model")
            or obj.get("model")
            or obj.get("model_id")
            or fallback_model
            or self.env.get("CODEX_MODEL")
            or "gpt-5.4"
        )
        input_tokens = self._first_int(usage, "input_tokens", "prompt_tokens", "input")
        output_tokens = self._first_int(usage, "output_tokens", "completion_tokens", "output")
        cache_read = self._first_optional_int(
            usage,
            "cache_read_input_tokens",
            "cached_input_tokens",
            "cache_read_tokens",
            "cached_tokens",
        )
        cache_write = self._first_optional_int(usage, "cache_creation_input_tokens", "cache_write_tokens")
        if cache_read is not None and self._input_includes_cache_read(str(model)):
            input_tokens = max(input_tokens - cache_read, 0)
        context_size = self._first_optional_int(usage, "context_size")
        if context_size is None:
            context_size = self._first_optional_int(usage, "total_tokens")
        return UsageRecord(
            timestamp=self._parse_timestamp(obj.get("timestamp") or container.get("timestamp")),
            model=str(model),
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_read_tokens=cache_read,
            cache_write_tokens=cache_write,
            context_size=context_size,
        )

    def _extract_metadata_record(self, obj: dict[str, Any], fallback_model: str | None = None) -> UsageRecord | None:
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
        if not self._is_turn_metadata(obj, payload):
            return None
        context_size = (
            self._first_optional_int(obj, "context_size", "total_tokens", "estimated_token_count")
            or self._first_optional_int(payload, "context_size", "total_tokens", "estimated_token_count")
            or self._first_optional_int(info, "context_size", "total_tokens", "estimated_token_count")
        )
        if context_size is None:
            return None
        model = (
            payload.get("model")
            or obj.get("model")
            or obj.get("model_id")
            or fallback_model
            or self.env.get("CODEX_MODEL")
            or "gpt-5.4"
        )
        return UsageRecord(
            timestamp=self._parse_timestamp(obj.get("timestamp") or payload.get("timestamp")),
            model=str(model),
            input_tokens=0,
            output_tokens=0,
            cache_read_tokens=None,
            cache_write_tokens=None,
            context_size=context_size,
            source="jsonl-metadata",
        )

    @staticmethod
    def _is_turn_metadata(obj: dict[str, Any], payload: Mapping[str, Any]) -> bool:
        return (
            obj.get("type") == "turn_context"
            and bool(payload.get("turn_id"))
            and bool(payload.get("model"))
        )

    @staticmethod
    def _input_includes_cache_read(model: str) -> bool:
        pricing = load_pricing()["models"].get(normalize_model_key(model))
        return bool(pricing and pricing.get("input_includes_cache_read"))

    def _peek_session_start(self, path: Path) -> datetime | None:
        for record in self._usage_records(path):
            if record.timestamp:
                return record.timestamp
        return None

    def _sqlite_sessions(self, mode: str, session_id: str | None) -> list[dict[str, Any]]:
        sessions = []
        for db_path in self._sqlite_paths():
            for thread_id in self._sqlite_thread_ids(db_path, mode, session_id):
                records = self._sqlite_usage_records(db_path, thread_id, mode)
                if records:
                    sessions.append(self._session_from_records(thread_id, str(db_path), records))
        return sessions

    def _sqlite_paths(self) -> list[Path]:
        paths = []
        if self.env.get("CODEX_TOKEN_ANALYSER_DB"):
            paths.append(Path(self.env["CODEX_TOKEN_ANALYSER_DB"]).expanduser())
            return [path for path in dict.fromkeys(paths) if path.is_file()]
        if self.env.get("CODEX_HOME"):
            paths.append(Path(self.env["CODEX_HOME"]).expanduser() / "logs_2.sqlite")
            return [path for path in dict.fromkeys(paths) if path.is_file()]
        paths.append(Path.home() / ".codex" / "logs_2.sqlite")
        return [path for path in dict.fromkeys(paths) if path.is_file()]

    def _sqlite_thread_ids(self, db_path: Path, mode: str, session_id: str | None) -> list[str]:
        explicit = session_id or (self.env.get("CODEX_THREAD_ID") if mode == "session" else None)
        cutoff = self._mode_cutoff(mode)
        try:
            with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as conn:
                if explicit:
                    rows = conn.execute(
                        "select distinct thread_id from logs where thread_id = ?",
                        (explicit,),
                    ).fetchall()
                elif cutoff:
                    rows = conn.execute(
                        "select thread_id from logs where thread_id is not null and ts >= ? "
                        "group by thread_id order by max(ts) desc",
                        (int(cutoff.timestamp()),),
                    ).fetchall()
                else:
                    rows = conn.execute(
                        "select thread_id from logs where thread_id is not null "
                        "group by thread_id order by max(ts) desc limit 1"
                    ).fetchall()
        except sqlite3.Error:
            return []
        return [row[0] for row in rows if row[0]]

    def _sqlite_usage_records(self, db_path: Path, thread_id: str, mode: str) -> list[UsageRecord]:
        cutoff = self._mode_cutoff(mode)
        params: list[Any] = [thread_id]
        where = (
            "thread_id = ? and target = 'codex_core::session::turn' "
            "and feedback_log_body like '%total_usage_tokens=%'"
        )
        if cutoff:
            where += " and ts >= ?"
            params.append(int(cutoff.timestamp()))
        try:
            with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as conn:
                rows = conn.execute(
                    f"select ts, feedback_log_body from logs where {where} order by ts, ts_nanos, id",
                    params,
                ).fetchall()
        except sqlite3.Error:
            return []

        latest_by_turn: dict[str, tuple[int, str]] = {}
        for ts, body in rows:
            turn_id = self._regex_group(body, r"turn_id=([^\s}]+)") or f"{thread_id}:{ts}"
            latest_by_turn[turn_id] = (ts, body)

        records = []
        previous_total = 0
        for ts, body in sorted(latest_by_turn.values(), key=lambda item: item[0]):
            total = self._regex_int(body, r"total_usage_tokens=(\d+)")
            if total is None:
                continue
            estimated = self._regex_int(body, r"estimated_token_count=Some\((\d+)\)")
            delta = max(total - previous_total, 0) if previous_total else total
            previous_total = max(previous_total, total)
            records.append(UsageRecord(
                timestamp=datetime.fromtimestamp(ts, tz=timezone.utc),
                model=self._regex_group(body, r"model=([^}: ]+)") or self.env.get("CODEX_MODEL") or "gpt-5.4",
                input_tokens=delta,
                output_tokens=0,
                cache_read_tokens=None,
                cache_write_tokens=None,
                context_size=estimated or total,
                source="sqlite-live-total",
            ))
        return records

    def _mode_cutoff(self, mode: str) -> datetime | None:
        now = datetime.now(timezone.utc)
        if mode == "today":
            local_midnight = datetime.now(self.local_tz).replace(hour=0, minute=0, second=0, microsecond=0)
            return local_midnight.astimezone(timezone.utc)
        if mode == "24h":
            return now - timedelta(hours=24)
        if mode == "week":
            return now - timedelta(days=7)
        return None

    def _session_id_from_jsonl(self, path: Path) -> str | None:
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("type") == "session_meta" and isinstance(obj.get("payload"), dict):
                        session_id = obj["payload"].get("id")
                        return str(session_id) if session_id else None
        except OSError:
            return None
        return None

    def _jsonl_matches_session(self, path: Path, session_id: str) -> bool:
        if path.stem == session_id or session_id in path.stem or session_id in str(path):
            return True
        return self._session_id_from_jsonl(path) == session_id

    def _model_from_jsonl(self, path: Path) -> str | None:
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("type") == "turn_context" and isinstance(obj.get("payload"), dict):
                        model = obj["payload"].get("model")
                        return str(model) if model else None
        except OSError:
            return None
        return None

    @staticmethod
    def _regex_group(value: str, pattern: str) -> str | None:
        match = re.search(pattern, value)
        return match.group(1) if match else None

    @staticmethod
    def _regex_int(value: str, pattern: str) -> int | None:
        match = re.search(pattern, value)
        return int(match.group(1)) if match else None

    @staticmethod
    def _parse_timestamp(value: Any) -> datetime | None:
        if not value:
            return None
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value, tz=timezone.utc)
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None

    @staticmethod
    def _first_int(usage: Mapping[str, Any], *keys: str) -> int:
        value = CodexUsageAdapter._first_optional_int(usage, *keys)
        return value or 0

    @staticmethod
    def _first_optional_int(usage: Mapping[str, Any], *keys: str) -> int | None:
        for key in keys:
            if key in usage and usage[key] is not None:
                try:
                    return int(usage[key])
                except (TypeError, ValueError):
                    return None
        for details_key in ("input_token_details", "input_tokens_details", "prompt_tokens_details"):
            details = usage.get(details_key)
            if isinstance(details, dict):
                for key in keys:
                    if key in details and details[key] is not None:
                        try:
                            return int(details[key])
                        except (TypeError, ValueError):
                            return None
        return None

    def _result_from_sessions(self, mode: str, sessions: list[dict[str, Any]]) -> dict[str, Any]:
        if not sessions:
            result = empty_result(mode, self.local_tz)
            result["telemetry_notes"] = ["No Codex sessions with token usage found."]
            return result

        total_calls = sum(s["api_calls"] for s in sessions)
        total_in = sum(s["input_tokens"] for s in sessions)
        total_out = sum(s["output_tokens"] for s in sessions)
        total_cache_read = sum(s["cache_read_tokens"] for s in sessions)
        cost_values = [s["est_cost_usd"] for s in sessions]
        total_cost = sum(cost_values) if all(c is not None for c in cost_values) else None
        duration = sum(s.get("duration_min", 0) for s in sessions)
        primary_model = next((s["model"] for s in sessions if s.get("model")), "gpt-5.4")
        issues = []
        for session in sessions:
            for model in session.get("unknown_cost_models", []):
                issues.append({
                    "type": "unknown_model",
                    "model": model,
                    "severity": "critical",
                    "session": session["id"][:8],
                })
        return {
            "mode": mode,
            "period": datetime.now(self.local_tz).strftime("%Y-%m-%d %H:%M"),
            "model": primary_model,
            "sessions": sessions,
            "totals": {
                "api_calls": total_calls,
                "input_tokens": total_in,
                "cache_read_tokens": total_cache_read,
                "output_tokens": total_out,
                "ratio": total_in // max(total_out, 1),
                "est_cost_usd": round(total_cost, 4) if total_cost is not None else None,
                "alt_cost_usd": 0.0,
                "duration_min": duration,
            },
            "health": "critical" if issues else "ok",
            "top_issues": issues[:5],
            "savings_comparison": [],
            "telemetry_notes": sorted({
                note for session in sessions for note in session.get("telemetry_notes", [])
            }),
        }
