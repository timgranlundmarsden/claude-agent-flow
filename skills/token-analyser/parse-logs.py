#!/usr/bin/env python3
"""
Token Analyser - pure Python log extractor for Claude Code session files.
Reads .jsonl session files and outputs compact JSON to stdout.
No LLM involved.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Local timezone for display (uses system timezone, e.g. CET/CEST automatically)
LOCAL_TZ = datetime.now().astimezone().tzinfo

# Load pricing from sibling reference file
_HERE = os.path.dirname(os.path.abspath(__file__))
_PRICING_FILE = os.path.join(_HERE, "reference", "model-pricing.json")

with open(_PRICING_FILE) as f:
    _PRICING_DATA = json.load(f)

PRICING = _PRICING_DATA["models"]
ALTERNATIVES = _PRICING_DATA["alternatives"]

CALL_BLOCK_SIZE = 10  # group main-session calls into blocks of this size


def encode_project_path(path: str) -> str:
    """Convert absolute path to Claude project dir name (leading dash is kept)."""
    return path.replace("/", "-").replace(".", "-")


def find_project_dir(project_path: str) -> Path:
    """Find the ~/.claude/projects/<encoded> directory."""
    encoded = encode_project_path(project_path)
    base = Path.home() / ".claude" / "projects" / encoded
    if not base.exists():
        print(f"ERROR: project dir not found: {base}", file=sys.stderr)
        sys.exit(1)
    return base


def _peek_session_start(path: Path) -> datetime | None:
    """Read the first timestamp entry from a JSONL file without parsing the whole thing."""
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    ts = obj.get("timestamp")
                    if ts:
                        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except (json.JSONDecodeError, ValueError):
                    continue
    except OSError:
        pass
    return None


def get_session_files(project_dir: Path, mode: str, session_id: str | None) -> list[Path]:
    """Return list of .jsonl session files to process."""
    now = datetime.now(timezone.utc)

    # Collect all .jsonl files directly in the project dir (skip subagent files)
    # Use mtime as a coarse pre-filter only, then verify with actual session start timestamp
    all_jsonl = sorted(
        [f for f in project_dir.glob("*.jsonl") if not f.name.startswith("agent-")],
        key=lambda f: f.stat().st_mtime,
        reverse=True,
    )

    if mode == "session":
        if session_id:
            target = project_dir / f"{session_id}.jsonl"
            if not target.exists():
                print(f"ERROR: session file not found: {target}", file=sys.stderr)
                sys.exit(1)
            return [target]
        # Default: prefer a session started today (local time), fall back to most recent
        if not all_jsonl:
            print("ERROR: no session files found in project dir", file=sys.stderr)
            sys.exit(1)
        local_midnight = datetime.now(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
        cutoff = local_midnight.astimezone(timezone.utc)
        today_files = [f for f in all_jsonl if (ts := _peek_session_start(f)) and ts >= cutoff]
        return [today_files[0]] if today_files else [all_jsonl[0]]

    elif mode == "today":
        # Midnight today in the system's local timezone (e.g. CET = UTC+1)
        local_midnight = datetime.now(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
        cutoff = local_midnight.astimezone(timezone.utc)
        # Use actual session start time, not mtime, so files touched today but started yesterday are excluded
        candidates = [f for f in all_jsonl if datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc) >= cutoff - timedelta(hours=1)]
        return [f for f in candidates if (ts := _peek_session_start(f)) and ts >= cutoff]

    elif mode == "24h":
        cutoff = now - timedelta(hours=24)
        candidates = [f for f in all_jsonl if datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc) >= cutoff - timedelta(hours=1)]
        return [f for f in candidates if (ts := _peek_session_start(f)) and ts >= cutoff]

    elif mode == "week":
        cutoff = now - timedelta(days=7)
        candidates = [f for f in all_jsonl if datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc) >= cutoff - timedelta(hours=1)]
        return [f for f in candidates if (ts := _peek_session_start(f)) and ts >= cutoff]

    return []


def calc_cost(model: str, input_tok: int, output_tok: int, cache_read_tok: int, cache_write_tok: int) -> float:
    """Calculate estimated cost in USD given token counts."""
    pricing = PRICING.get(model) or PRICING.get("anthropic_claude_sonnet_4_6")
    rate_in = pricing["in"] / 1_000_000
    rate_out = pricing["out"] / 1_000_000
    rate_cache_read = (pricing.get("cache_read") or 0) / 1_000_000
    # Cache write is 1.25x input for Anthropic models (stored in pricing JSON)
    rate_cache_write = (pricing.get("cache_write") or pricing["in"]) / 1_000_000
    return (
        input_tok * rate_in
        + output_tok * rate_out
        + cache_read_tok * rate_cache_read
        + cache_write_tok * rate_cache_write
    )


def savings_comparison(model: str, input_tok: int, output_tok: int, cache_read_tok: int, cache_write_tok: int, current_cost: float) -> list[dict]:
    """Compute cost if cheaper alternative models had been used."""
    results = []
    for alt in ALTERNATIVES:
        alt_model = alt["id"]
        if alt_model == model:
            continue
        est = calc_cost(alt_model, input_tok, output_tok, cache_read_tok, cache_write_tok)
        saving_pct = round((1 - est / current_cost) * 100) if current_cost > 0 else 0
        results.append({
            "model": alt["label"],
            "est_cost": round(est, 2),
            "saving_pct": saving_pct,
            "note": alt["suited_for"],
        })
    return sorted(results, key=lambda x: x["est_cost"])


def classify_session(api_calls: int, tool_calls: int, subagent_calls: int, output_tokens: int) -> str:
    """Classify session type to pick the best cheaper alternative model."""
    if subagent_calls > 0:
        return "subagent"       # orchestration with subagents → GPT-5.4 mini
    if api_calls >= 10 and tool_calls >= api_calls * 0.4:
        return "agentic"        # heavy tool use (Read/Bash/Grep) → Haiku 4.5
    if api_calls <= 4 and output_tokens > 2000:
        return "generation"     # few calls, large output → Gemini 2.5 Flash
    if api_calls <= 3:
        return "simple"         # very short session → Gemini Flash-Lite
    return "reasoning"          # extended reasoning/coding → Gemini 2.5 Flash


_SESSION_TYPE_MODEL = {
    "subagent":   "gpt-5.4-mini",
    "agentic":    "anthropic_claude_haiku_4_5",
    "generation": "gemini-2.5-flash",
    "simple":     "gemini-2.5-flash-lite",
    "reasoning":  "gemini-2.5-flash",
}

_SESSION_TYPE_LABEL = {
    "subagent":   "GPT-5.4 mini",
    "agentic":    "Haiku 4.5",
    "generation": "Gemini 2.5 Flash",
    "simple":     "Gemini Flash-Lite",
    "reasoning":  "Gemini 2.5 Flash",
}

_SESSION_TYPE_REASON = {
    "subagent":   "session used subagents — GPT-5.4 mini excels at coding & orchestration",
    "agentic":    "heavy tool use (Read/Bash/Grep) — Haiku 4.5 is fast & cheap for agentic loops",
    "generation": "few calls with large output — Gemini 2.5 Flash is strong at generation tasks",
    "simple":     "very short session — Gemini Flash-Lite is ideal for low-complexity tasks",
    "reasoning":  "general coding/reasoning session — Gemini 2.5 Flash has thinking mode but expect quality trade-off vs Sonnet",
}


def recommend_for_session(session_type: str, model: str,
                          input_tok: int, output_tok: int,
                          cache_read_tok: int, cache_write_tok: int,
                          actual_cost: float) -> dict:
    alt_model_id = _SESSION_TYPE_MODEL[session_type]
    alt_label = _SESSION_TYPE_LABEL[session_type]
    est = calc_cost(alt_model_id, input_tok, output_tok, cache_read_tok, cache_write_tok)
    saving_pct = round((1 - est / actual_cost) * 100) if actual_cost > 0 else 0
    return {
        "model": alt_label,
        "model_id": alt_model_id,
        "session_type": session_type,
        "est_cost": round(est, 2),
        "saving_pct": saving_pct,
        "reason": _SESSION_TYPE_REASON[session_type],
    }


def parse_session_file(jsonl_path: Path, project_dir: Path) -> dict:
    """Parse a single session JSONL file and return session stats dict."""
    calls = []  # list of per-call dicts
    tool_calls = 0
    model = None
    model_stats: dict[str, dict] = {}  # per-model token/call breakdown
    first_ts = None
    last_ts = None

    with open(jsonl_path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts_str = obj.get("timestamp")
            if ts_str:
                try:
                    ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    if first_ts is None or ts < first_ts:
                        first_ts = ts
                    if last_ts is None or ts > last_ts:
                        last_ts = ts
                except ValueError:
                    pass

            if obj.get("type") != "assistant":
                continue
            msg = obj.get("message", {})
            usage = msg.get("usage", {})
            out_tok = usage.get("output_tokens", 0)
            if out_tok == 0:
                continue  # skip streaming partial messages

            call_model = msg.get("model", "anthropic_claude_sonnet_4_6")
            if not model:
                model = call_model

            # Count tool-use calls
            content = msg.get("content", [])
            if any(c.get("type") == "tool_use" for c in content if isinstance(c, dict)):
                tool_calls += 1

            in_tok = usage.get("input_tokens", 0)
            cache_write = usage.get("cache_creation_input_tokens", 0)
            cache_read = usage.get("cache_read_input_tokens", 0)
            context_size = in_tok + cache_write + cache_read  # total tokens Claude saw

            # Accumulate per-model stats
            if call_model not in model_stats:
                model_stats[call_model] = {"calls": 0, "input": 0, "output": 0,
                                           "cache_read": 0, "cache_write": 0}
            ms = model_stats[call_model]
            ms["calls"] += 1
            ms["input"] += in_tok
            ms["output"] += out_tok
            ms["cache_read"] += cache_read
            ms["cache_write"] += cache_write

            calls.append({
                "input": in_tok,
                "output": out_tok,
                "cache_write": cache_write,
                "cache_read": cache_read,
                "context_size": context_size,
                "ts": ts_str,
            })

    # Parse subagent files
    session_id = jsonl_path.stem
    subagents_dir = project_dir / session_id / "subagents"
    subagent_blocks = []
    if subagents_dir.exists():
        for sa_file in subagents_dir.glob("*.jsonl"):
            sa_calls, sa_in, sa_out, sa_cache_read, sa_cache_write, sa_model = _parse_subagent(sa_file, model)
            if sa_calls > 0:
                meta_file = sa_file.with_suffix("").with_suffix(".meta.json")
                label = sa_file.stem
                agent_type = None
                if meta_file.exists():
                    try:
                        meta = json.loads(meta_file.read_text())
                        desc = meta.get("description", "")
                        agent_type = meta.get("agentType", "")
                        label = f"{label} ({desc[:40]})" if desc else label
                    except Exception:
                        pass
                sa_cost = calc_cost(sa_model or model or "anthropic_claude_sonnet_4_6",
                                    sa_in, sa_out, sa_cache_read, sa_cache_write)
                # Accumulate subagent model into model_stats
                sa_m = sa_model or model or "anthropic_claude_sonnet_4_6"
                if sa_m not in model_stats:
                    model_stats[sa_m] = {"calls": 0, "input": 0, "output": 0,
                                         "cache_read": 0, "cache_write": 0}
                model_stats[sa_m]["calls"] += sa_calls
                model_stats[sa_m]["input"] += sa_in
                model_stats[sa_m]["output"] += sa_out
                model_stats[sa_m]["cache_read"] += sa_cache_read
                model_stats[sa_m]["cache_write"] += sa_cache_write
                subagent_blocks.append({
                    "label": f"subagent {sa_file.stem[-8:]} ({sa_calls}c)",
                    "calls": sa_calls,
                    "input": sa_in + sa_cache_write,
                    "cache_read": sa_cache_read,
                    "output": sa_out,
                    "cost": round(sa_cost, 4),
                    "model": sa_m,
                    "agent_type": agent_type,
                    "is_subagent": True,
                })

    # Aggregate main session
    total_in = sum(c["input"] for c in calls)
    total_out = sum(c["output"] for c in calls)
    total_cache_write = sum(c["cache_write"] for c in calls)
    total_cache_read = sum(c["cache_read"] for c in calls)
    api_calls = len(calls)
    model = model or "anthropic_claude_sonnet_4_6"

    main_cost = calc_cost(model, total_in, total_out, total_cache_read, total_cache_write)
    subagent_total_cost = sum(b["cost"] for b in subagent_blocks)
    total_cost = main_cost + subagent_total_cost

    # Cost blocks for main session
    cost_blocks = _make_cost_blocks(calls, model)
    cost_blocks.extend(subagent_blocks)

    # Context growth (sample at regular intervals)
    context_growth = _sample_context_growth(calls)

    # Peak jump
    peak_jump = _find_peak_jump(calls)

    # Subagent total calls/tokens
    sa_calls_total = sum(b["calls"] for b in subagent_blocks)
    sa_in_total = sum(b["input"] for b in subagent_blocks)
    sa_out_total = sum(b.get("output", 0) for b in subagent_blocks)

    total_calls_all = api_calls + sa_calls_total
    grand_in = total_in + total_cache_write + sa_in_total
    ratio = grand_in // max(total_out + sa_out_total, 1)

    duration_min = 0
    if first_ts and last_ts:
        duration_min = max(1, int((last_ts - first_ts).total_seconds() / 60))

    # Local time for display — "Tue 19/03 13:24"
    start_local = first_ts.astimezone(LOCAL_TZ).strftime("%a %d/%m %H:%M") if first_ts else None

    # Session classification + per-session recommendation
    session_type = classify_session(api_calls, tool_calls, sa_calls_total, total_out)
    recommendation = recommend_for_session(
        session_type, model,
        total_in, total_out, total_cache_read, total_cache_write,
        total_cost,
    )

    return {
        "id": session_id,
        "file": str(jsonl_path),
        "timestamp_start": first_ts.isoformat() if first_ts else None,
        "timestamp_end": last_ts.isoformat() if last_ts else None,
        "start_local": start_local,
        "duration_min": duration_min,
        "model": model,
        "api_calls": api_calls,
        "tool_calls": tool_calls,
        "subagent_calls": sa_calls_total,
        "session_type": session_type,
        "input_tokens": total_in + total_cache_write,
        "cache_read_tokens": total_cache_read,
        "output_tokens": total_out,
        "ratio": ratio,
        "est_cost_usd": round(total_cost, 4),
        "recommendation": recommendation,
        "is_subagent": False,
        "cost_blocks": cost_blocks,
        "context_growth": context_growth,
        "peak_jump": peak_jump,
        "per_call": calls,
        "model_stats": model_stats,
    }


def _parse_subagent(jsonl_path: Path, parent_model: str | None) -> tuple:
    calls = 0
    total_in = total_out = total_cache_read = total_cache_write = 0
    model = parent_model
    with open(jsonl_path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") != "assistant":
                continue
            msg = obj.get("message", {})
            usage = msg.get("usage", {})
            if usage.get("output_tokens", 0) == 0:
                continue
            calls += 1
            if not model:
                model = msg.get("model")
            total_in += usage.get("input_tokens", 0)
            total_cache_write += usage.get("cache_creation_input_tokens", 0)
            total_cache_read += usage.get("cache_read_input_tokens", 0)
            total_out += usage.get("output_tokens", 0)
    return calls, total_in, total_out, total_cache_read, total_cache_write, model


def _make_cost_blocks(calls: list[dict], model: str) -> list[dict]:
    """Group main session calls into cost blocks."""
    if not calls:
        return []
    blocks = []
    n = len(calls)
    block_size = max(CALL_BLOCK_SIZE, n // 5) if n > 20 else CALL_BLOCK_SIZE
    for start in range(0, n, block_size):
        chunk = calls[start:start + block_size]
        end = start + len(chunk)
        in_tok = sum(c["input"] for c in chunk)
        cache_write = sum(c["cache_write"] for c in chunk)
        cache_read = sum(c["cache_read"] for c in chunk)
        out_tok = sum(c["output"] for c in chunk)
        cost = calc_cost(model, in_tok, out_tok, cache_read, cache_write)
        blocks.append({
            "label": f"calls {start+1}-{end}",
            "calls": len(chunk),
            "input": in_tok + cache_write,
            "cache_read": cache_read,
            "output": out_tok,
            "cost": round(cost, 4),
            "is_subagent": False,
        })
    return blocks


def _sample_context_growth(calls: list[dict], samples: int = 5) -> list[int]:
    """Return context sizes sampled at roughly equal intervals."""
    if not calls:
        return []
    if len(calls) <= samples:
        return [c["context_size"] for c in calls]
    step = len(calls) // samples
    return [calls[i]["context_size"] for i in range(0, len(calls), step)][:samples]


def _find_peak_jump(calls: list[dict]) -> dict | None:
    """Find the single call with the largest context size increase."""
    if len(calls) < 2:
        return None
    best = {"at_call": 0, "delta": 0, "pct": 0}
    for i in range(1, len(calls)):
        prev = calls[i - 1]["context_size"]
        curr = calls[i]["context_size"]
        delta = curr - prev
        pct = round(delta / max(prev, 1) * 100)
        if delta > best["delta"]:
            best = {"at_call": i + 1, "delta": delta, "pct": pct}
    return best if best["delta"] > 0 else None


def detect_issues(sessions: list[dict]) -> list[dict]:
    """Surface top issues across all sessions."""
    issues = []
    RATIO_WARN = 20
    RATIO_CRIT = 50
    ROGUE_CALLS = 50
    CONTEXT_JUMP_PCT = 100  # 100% jump = doubled context

    for s in sessions:
        ratio = s.get("ratio", 0)
        if ratio >= RATIO_CRIT:
            issues.append({"type": "high_ratio", "value": ratio, "threshold": RATIO_CRIT,
                           "severity": "critical", "session": s["id"][:8]})
        elif ratio >= RATIO_WARN:
            issues.append({"type": "high_ratio", "value": ratio, "threshold": RATIO_WARN,
                           "severity": "warning", "session": s["id"][:8]})

        for block in s.get("cost_blocks", []):
            if block.get("is_subagent") and block.get("calls", 0) >= ROGUE_CALLS:
                issues.append({
                    "type": "rogue_subagent",
                    "calls": block["calls"],
                    "cost": block["cost"],
                    "label": block["label"],
                    "severity": "critical",
                    "session": s["id"][:8],
                })

        pj = s.get("peak_jump")
        if pj and pj.get("pct", 0) >= CONTEXT_JUMP_PCT:
            issues.append({
                "type": "context_explosion",
                "delta": pj["delta"],
                "at_call": pj["at_call"],
                "pct": pj["pct"],
                "severity": "warning",
                "session": s["id"][:8],
            })

        if s.get("cache_read_tokens", 0) == 0 and s.get("api_calls", 0) > 5:
            issues.append({
                "type": "no_cache",
                "severity": "info",
                "session": s["id"][:8],
            })

    # Deduplicate same type+session
    seen = set()
    deduped = []
    for issue in issues:
        key = (issue["type"], issue.get("session", ""))
        if key not in seen:
            seen.add(key)
            deduped.append(issue)

    return sorted(deduped, key=lambda x: {"critical": 0, "warning": 1, "info": 2}[x["severity"]])


def determine_health(issues: list[dict]) -> str:
    if any(i["severity"] == "critical" for i in issues):
        return "critical"
    if any(i["severity"] == "warning" for i in issues):
        return "warning"
    return "ok"


def main():
    parser = argparse.ArgumentParser(description="Parse Claude Code session logs")
    parser.add_argument("--project-path", required=True, help="Absolute path to project directory")
    parser.add_argument("--session", help="Session UUID to analyse (default: most recent)")
    parser.add_argument("--today", action="store_true", help="Analyse all sessions today (calendar day)")
    parser.add_argument("--24h", dest="h24", action="store_true", help="Analyse sessions from last 24 hours")
    parser.add_argument("--week", action="store_true", help="Analyse sessions from last 7 days")
    args = parser.parse_args()

    if args.h24:
        mode = "24h"
    elif args.today:
        mode = "today"
    elif args.week:
        mode = "week"
    else:
        mode = "session"

    project_dir = find_project_dir(args.project_path)
    session_files = get_session_files(project_dir, mode, args.session)

    if not session_files:
        result = {
            "mode": mode,
            "period": datetime.now(LOCAL_TZ).strftime("%Y-%m-%d %H:%M"),
            "sessions": [],
            "totals": {"api_calls": 0, "input_tokens": 0, "output_tokens": 0, "ratio": 0, "est_cost_usd": 0.0},
            "health": "ok",
            "top_issues": [],
            "savings_comparison": [],
        }
        print(json.dumps(result))
        return

    sessions = []
    for sf in session_files:
        try:
            s = parse_session_file(sf, project_dir)
            sessions.append(s)
        except Exception as e:
            print(f"WARNING: failed to parse {sf}: {e}", file=sys.stderr)

    # Most recent first
    sessions.sort(key=lambda s: s.get("timestamp_start") or "", reverse=True)

    # Primary model: use the model from the first (most recent) session
    primary_model = next(
        (s["model"] for s in sessions if s.get("model")),
        "anthropic_claude_sonnet_4_6"
    )

    # Aggregate totals
    total_calls = sum(s["api_calls"] + s.get("subagent_calls", 0) for s in sessions)
    total_in = sum(s["input_tokens"] for s in sessions)
    total_out = sum(s["output_tokens"] for s in sessions)
    total_cache_read = sum(s["cache_read_tokens"] for s in sessions)
    total_cost = sum(s["est_cost_usd"] for s in sessions)
    total_alt_cost = round(sum(s["recommendation"]["est_cost"] for s in sessions if s.get("recommendation")), 2)
    total_duration_min = sum(s.get("duration_min", 0) for s in sessions)
    overall_ratio = total_in // max(total_out, 1)

    issues = detect_issues(sessions)
    health = determine_health(issues)

    savings = savings_comparison(primary_model, total_in, total_out, total_cache_read, 0, total_cost)

    result = {
        "mode": mode,
        "period": datetime.now(LOCAL_TZ).strftime("%Y-%m-%d %H:%M"),
        "model": primary_model,
        "sessions": sessions,
        "totals": {
            "api_calls": total_calls,
            "input_tokens": total_in,
            "cache_read_tokens": total_cache_read,
            "output_tokens": total_out,
            "ratio": overall_ratio,
            "est_cost_usd": round(total_cost, 4),
            "alt_cost_usd": total_alt_cost,
            "duration_min": total_duration_min,
        },
        "health": health,
        "top_issues": issues[:5],
        "savings_comparison": savings,
    }

    print(json.dumps(result, default=str))


if __name__ == "__main__":
    main()
