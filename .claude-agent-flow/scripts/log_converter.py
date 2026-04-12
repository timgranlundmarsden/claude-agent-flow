#!/usr/bin/env python3
"""
log_converter.py — Parse a Claude Code .jsonl session file and output visualiser JSON.

Usage:
    python3 .claude-agent-flow/scripts/log_converter.py session.jsonl > output.json
"""

import argparse
import json
import re
import sys


# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------

def agent_position(index: int) -> tuple[int, int]:
    """Return (x, y) for agent at the given index (0-based)."""
    if index == 0:
        return 60, 80
    # Alternate x between 60 and 280, increment y by 120 each pair
    pair = (index - 1) // 2
    col = (index - 1) % 2  # 0 → x=60, 1 → x=280
    x = 60 if col == 0 else 280
    y = 80 + 120 * (pair + 1)
    return x, y


def slugify(name: str) -> str:
    """Convert an agent name to a URL-safe id."""
    slug = name.lower().strip()
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    slug = slug.strip("-")
    return slug or "agent"


# ---------------------------------------------------------------------------
# Agent registry
# ---------------------------------------------------------------------------

class AgentRegistry:
    def __init__(self):
        self._agents: list[dict] = []
        self._id_set: set[str] = set()

    def ensure(self, name: str) -> dict:
        """Return existing agent dict or create a new one."""
        slug = slugify(name)
        # Deduplicate slug
        if slug not in self._id_set:
            index = len(self._agents)
            x, y = agent_position(index)
            agent = {
                "id": slug,
                "label": name,
                "model": "opus",
                "x": x,
                "y": y,
            }
            self._agents.append(agent)
            self._id_set.add(slug)
        return next(a for a in self._agents if a["id"] == slug)

    @property
    def agents(self) -> list[dict]:
        return list(self._agents)

    def count(self) -> int:
        return len(self._agents)


# ---------------------------------------------------------------------------
# Status generators
# ---------------------------------------------------------------------------

def status_for_tool_call(tool_name: str) -> str:
    return f"Running {tool_name}..."


def status_for_thinking() -> str:
    return "Thinking..."


def status_for_message(text: str) -> str:
    snippet = text[:40]
    return f"{snippet}..."


def status_for_activate(label: str) -> str:
    return label


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def extract_agent_name(input_dict: dict) -> str:
    """Try to extract a human-readable agent name from a tool_use input dict."""
    for key in ("description", "prompt", "name"):
        val = input_dict.get(key)
        if val and isinstance(val, str):
            # Use first non-empty line, truncated to 40 chars
            first_line = val.strip().splitlines()[0][:40]
            if first_line:
                return first_line
    return "agent"


def truncate_tool_result(content) -> str:
    """Stringify and truncate tool result content to 500 chars."""
    if isinstance(content, list):
        # content can be a list of content blocks
        parts = []
        for block in content:
            if isinstance(block, dict):
                parts.append(block.get("text", json.dumps(block, ensure_ascii=False)))
            else:
                parts.append(str(block))
        text = "\n".join(parts)
    elif isinstance(content, str):
        text = content
    else:
        text = json.dumps(content, ensure_ascii=False)

    if len(text) > 500:
        return text[:500] + "[truncated]"
    return text


def parse_session(lines: list[str]) -> tuple[list[dict], list[dict], list[dict]]:
    """
    Parse JSONL lines into (agents, transitions, events).
    Returns (agents_list, transitions_list, events_list).
    """
    registry = AgentRegistry()
    events: list[dict] = []
    transitions: list[dict] = []
    transition_counter = 0

    # Ensure orchestrator is always agent[0]
    orchestrator = registry.ensure("orchestrator")
    current_agent_id = orchestrator["id"]

    for lineno, raw in enumerate(lines, start=1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"Warning: skipping malformed JSON on line {lineno}: {exc}", file=sys.stderr)
            continue

        record_type = record.get("type")
        message = record.get("message", {})
        content = message.get("content", [])

        if not isinstance(content, list):
            content = []

        if record_type == "assistant":
            for block in content:
                if not isinstance(block, dict):
                    continue
                block_type = block.get("type")

                if block_type == "thinking":
                    events.append({
                        "agent": current_agent_id,
                        "kind": "thinking",
                        "text": block.get("thinking", ""),
                        "status": status_for_thinking(),
                    })

                elif block_type == "text":
                    text = block.get("text", "")
                    events.append({
                        "agent": current_agent_id,
                        "kind": "message",
                        "text": text,
                        "status": status_for_message(text),
                    })

                elif block_type == "tool_use":
                    tool_name = block.get("name", "")
                    tool_input = block.get("input", {})

                    if tool_name == "Agent":
                        # Detect sub-agent boundary
                        sub_name = extract_agent_name(tool_input if isinstance(tool_input, dict) else {})
                        sub_agent = registry.ensure(sub_name)
                        sub_id = sub_agent["id"]

                        # Activate event for the new agent
                        events.append({
                            "agent": sub_id,
                            "kind": "activate",
                            "text": f"Agent activated: {sub_agent['label']}",
                            "status": status_for_activate(sub_agent["label"]),
                        })

                        # Transition from current to new agent
                        transition_counter += 1
                        transitions.append({
                            "id": f"t{transition_counter}",
                            "from": current_agent_id,
                            "to": sub_id,
                            "type": "normal",
                            "label": f"invoke {sub_agent['label']}",
                        })

                        current_agent_id = sub_id
                    else:
                        # Regular tool call
                        args_str = json.dumps(tool_input, ensure_ascii=False) if tool_input else "{}"
                        events.append({
                            "agent": current_agent_id,
                            "kind": "tool-call",
                            "text": f"{tool_name}({args_str[:200]})" if len(args_str) > 200 else f"{tool_name}({args_str})",
                            "tool": tool_name,
                            "args": args_str,
                            "status": status_for_tool_call(tool_name),
                        })

        elif record_type == "user":
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_result":
                    result_content = block.get("content", "")
                    events.append({
                        "agent": current_agent_id,
                        "kind": "tool-result",
                        "text": truncate_tool_result(result_content),
                        "status": "done",
                    })

    return registry.agents, transitions, events


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a Claude Code .jsonl session file to visualiser JSON."
    )
    parser.add_argument("session_file", help="Path to the .jsonl session file")
    args = parser.parse_args()

    try:
        with open(args.session_file, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        print(f"Error: cannot open file: {exc}", file=sys.stderr)
        sys.exit(1)

    agents, transitions, events = parse_session(lines)

    # Warn if no agent boundaries were found (only orchestrator)
    agent_tool_found = any(
        e.get("kind") == "activate" for e in events
    )
    if not agent_tool_found:
        print(
            "Warning: No Agent tool calls found — treating entire session as single orchestrator agent",
            file=sys.stderr,
        )

    output = {
        "title": "Converted Session",
        "subtitle": "auto-converted from Claude Code session log",
        "agents": agents,
        "transitions": transitions,
        "events": events,
    }

    json.dump(output, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")

    print(
        f"Converted: {len(events)} events, {len(agents)} agents",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
