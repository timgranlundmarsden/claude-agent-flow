#!/usr/bin/env python3
"""
test_log_converter.py — Tests for log_converter.py

Run with: python3 .claude-agent-flow/tests/test_log_converter.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

CONVERTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../scripts/log_converter.py")


def run_converter(jsonl_content: str) -> tuple[int, dict | None, str]:
    """
    Write jsonl_content to a temp file, run log_converter.py against it.
    Returns (returncode, parsed_output_or_None, stderr_text).
    """
    with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False, encoding="utf-8") as fh:
        fh.write(jsonl_content)
        tmp_path = fh.name

    try:
        result = subprocess.run(
            [sys.executable, CONVERTER, tmp_path],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        stdout = result.stdout.strip()
        parsed = None
        if stdout:
            try:
                parsed = json.loads(stdout)
            except json.JSONDecodeError:
                pass
        return result.returncode, parsed, result.stderr
    finally:
        os.unlink(tmp_path)


def make_assistant_thinking(text: str) -> str:
    rec = {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": text}]}}
    return json.dumps(rec)


def make_assistant_text(text: str) -> str:
    rec = {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}
    return json.dumps(rec)


def make_tool_use(name: str, input_dict: dict) -> str:
    rec = {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": input_dict}]}}
    return json.dumps(rec)


def make_tool_result(content: str) -> str:
    rec = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "abc123", "content": content}]}}
    return json.dumps(rec)


class TestHappyPath(unittest.TestCase):

    def test_basic_session_structure(self):
        """A session with thinking, text, tool_use and tool_result produces valid output."""
        lines = "\n".join([
            make_assistant_thinking("Let me think..."),
            make_assistant_text("Here is my response."),
            make_tool_use("Read", {"file_path": "/tmp/foo.py"}),
            make_tool_result("file contents here"),
        ])
        rc, output, stderr = run_converter(lines)
        self.assertEqual(rc, 0, f"Non-zero exit: {stderr}")
        self.assertIsNotNone(output)
        self.assertIn("title", output)
        self.assertIn("subtitle", output)
        self.assertIn("agents", output)
        self.assertIn("transitions", output)
        self.assertIn("events", output)

    def test_thinking_event(self):
        lines = make_assistant_thinking("some deep thought")
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        thinking_events = [e for e in output["events"] if e["kind"] == "thinking"]
        self.assertEqual(len(thinking_events), 1)
        self.assertEqual(thinking_events[0]["text"], "some deep thought")
        self.assertEqual(thinking_events[0]["status"], "Thinking...")

    def test_message_event(self):
        lines = make_assistant_text("Hello, world! This is the assistant speaking.")
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        message_events = [e for e in output["events"] if e["kind"] == "message"]
        self.assertEqual(len(message_events), 1)
        self.assertEqual(message_events[0]["text"], "Hello, world! This is the assistant speaking.")
        # Status should be first 40 chars + "..."
        self.assertTrue(message_events[0]["status"].endswith("..."))
        self.assertLessEqual(len(message_events[0]["status"]), 44)  # 40 + "..."

    def test_tool_call_event(self):
        lines = make_tool_use("Bash", {"command": "ls -la"})
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        tool_events = [e for e in output["events"] if e["kind"] == "tool-call"]
        self.assertEqual(len(tool_events), 1)
        self.assertEqual(tool_events[0]["tool"], "Bash")
        self.assertEqual(tool_events[0]["status"], "Running Bash...")

    def test_tool_result_event(self):
        lines = make_tool_result("output from bash")
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        result_events = [e for e in output["events"] if e["kind"] == "tool-result"]
        self.assertEqual(len(result_events), 1)
        self.assertEqual(result_events[0]["text"], "output from bash")

    def test_agent_tool_creates_activate_and_transition(self):
        """An Agent tool_use creates an activate event and a transition."""
        lines = "\n".join([
            make_assistant_text("Delegating to sub-agent..."),
            make_tool_use("Agent", {"description": "backend-builder", "prompt": "do the thing"}),
        ])
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        activate_events = [e for e in output["events"] if e["kind"] == "activate"]
        self.assertEqual(len(activate_events), 1)
        self.assertGreaterEqual(len(output["transitions"]), 1)
        t = output["transitions"][0]
        self.assertEqual(t["from"], "orchestrator")
        self.assertIn("type", t)
        self.assertIn("label", t)

    def test_agents_list_includes_orchestrator(self):
        lines = make_assistant_text("hi")
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        ids = [a["id"] for a in output["agents"]]
        self.assertIn("orchestrator", ids)

    def test_agent_positions_orchestrator(self):
        lines = make_assistant_text("hi")
        rc, output, _ = run_converter(lines)
        orchestrator = next(a for a in output["agents"] if a["id"] == "orchestrator")
        self.assertEqual(orchestrator["x"], 60)
        self.assertEqual(orchestrator["y"], 80)

    def test_agent_positions_stagger(self):
        """Second and third agents alternate x between 60 and 280."""
        lines = "\n".join([
            make_tool_use("Agent", {"description": "agent-one"}),
            make_tool_use("Agent", {"description": "agent-two"}),
        ])
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        agents_by_id = {a["id"]: a for a in output["agents"]}
        self.assertIn("agent-one", agents_by_id)
        self.assertIn("agent-two", agents_by_id)
        a1 = agents_by_id["agent-one"]
        a2 = agents_by_id["agent-two"]
        # First sub-agent: x=60, y=200 (index 1: pair=0, col=0)
        self.assertEqual(a1["x"], 60)
        self.assertEqual(a1["y"], 200)
        # Second sub-agent: x=280, y=200 (index 2: pair=0, col=1)
        self.assertEqual(a2["x"], 280)
        self.assertEqual(a2["y"], 200)

    def test_transition_structure(self):
        lines = make_tool_use("Agent", {"description": "my-agent"})
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        self.assertEqual(len(output["transitions"]), 1)
        t = output["transitions"][0]
        for key in ("id", "from", "to", "type", "label"):
            self.assertIn(key, t, f"Transition missing key: {key}")

    def test_no_agent_calls_warning(self):
        lines = make_assistant_text("just the orchestrator here")
        rc, output, stderr = run_converter(lines)
        self.assertEqual(rc, 0)
        self.assertIn("No Agent tool calls found", stderr)

    def test_stderr_conversion_stats(self):
        lines = "\n".join([
            make_assistant_thinking("thinking"),
            make_assistant_text("text"),
        ])
        rc, output, stderr = run_converter(lines)
        self.assertEqual(rc, 0)
        self.assertIn("Converted:", stderr)
        self.assertIn("events", stderr)
        self.assertIn("agents", stderr)

    def test_output_metadata_fields(self):
        lines = make_assistant_text("hi")
        rc, output, _ = run_converter(lines)
        self.assertEqual(output["title"], "Converted Session")
        self.assertEqual(output["subtitle"], "auto-converted from Claude Code session log")

    def test_agent_model_field(self):
        lines = make_assistant_text("hi")
        rc, output, _ = run_converter(lines)
        orchestrator = next(a for a in output["agents"] if a["id"] == "orchestrator")
        self.assertEqual(orchestrator["model"], "opus")


class TestEdgeCases(unittest.TestCase):

    def test_empty_file(self):
        """An empty .jsonl file should produce a valid but empty output."""
        rc, output, stderr = run_converter("")
        self.assertEqual(rc, 0)
        self.assertIsNotNone(output)
        self.assertIn("events", output)
        self.assertEqual(output["events"], [])
        # Should still have orchestrator
        self.assertEqual(len(output["agents"]), 1)
        self.assertEqual(output["agents"][0]["id"], "orchestrator")

    def test_blank_lines_ignored(self):
        """Blank lines in the JSONL file are silently skipped."""
        content = "\n\n" + make_assistant_text("hello") + "\n\n"
        rc, output, stderr = run_converter(content)
        self.assertEqual(rc, 0)
        self.assertEqual(len([e for e in output["events"] if e["kind"] == "message"]), 1)

    def test_unicode_content(self):
        """Unicode characters in text are preserved in output."""
        text = "こんにちは世界 — Hello World! 🌍"
        lines = make_assistant_text(text)
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        message_events = [e for e in output["events"] if e["kind"] == "message"]
        self.assertEqual(len(message_events), 1)
        self.assertEqual(message_events[0]["text"], text)

    def test_unicode_not_escaped_in_output(self):
        """ensure_ascii=False: non-ASCII chars appear literally in stdout."""
        text = "日本語テスト"
        lines = make_assistant_text(text)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False, encoding="utf-8") as fh:
            fh.write(lines)
            tmp_path = fh.name
        try:
            result = subprocess.run(
                [sys.executable, CONVERTER, tmp_path],
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            # The raw stdout should contain literal unicode, not \\uXXXX escapes
            self.assertIn("日本語テスト", result.stdout)
            self.assertNotIn("\\u65e5", result.stdout)  # 日 escaped
        finally:
            os.unlink(tmp_path)

    def test_long_tool_result_truncated(self):
        """Tool results > 500 chars are truncated with [truncated] suffix."""
        long_content = "x" * 600
        lines = make_tool_result(long_content)
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        result_events = [e for e in output["events"] if e["kind"] == "tool-result"]
        self.assertEqual(len(result_events), 1)
        text = result_events[0]["text"]
        self.assertTrue(text.endswith("[truncated]"), f"Expected [truncated] suffix, got: {text[-30:]}")
        # Total length should be 500 + len("[truncated]") = 511
        self.assertEqual(len(text), 511)

    def test_tool_result_at_exactly_500_not_truncated(self):
        """Tool results of exactly 500 chars are NOT truncated."""
        exact_content = "y" * 500
        lines = make_tool_result(exact_content)
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        result_events = [e for e in output["events"] if e["kind"] == "tool-result"]
        self.assertFalse(result_events[0]["text"].endswith("[truncated]"))
        self.assertEqual(len(result_events[0]["text"]), 500)

    def test_tool_result_at_501_truncated(self):
        """Tool results of 501 chars are truncated."""
        content = "z" * 501
        lines = make_tool_result(content)
        rc, output, _ = run_converter(lines)
        result_events = [e for e in output["events"] if e["kind"] == "tool-result"]
        self.assertTrue(result_events[0]["text"].endswith("[truncated]"))

    def test_malformed_json_lines_skipped(self):
        """Malformed JSON lines are skipped with a stderr warning."""
        good_line = make_assistant_text("valid line")
        bad_line = "{this is not valid json"
        content = "\n".join([good_line, bad_line, good_line])
        rc, output, stderr = run_converter(content)
        self.assertEqual(rc, 0)
        self.assertIn("Warning: skipping malformed JSON", stderr)
        # Two good lines → two message events
        message_events = [e for e in output["events"] if e["kind"] == "message"]
        self.assertEqual(len(message_events), 2)

    def test_multiple_malformed_lines_reported(self):
        """Each malformed line produces its own warning."""
        bad1 = "{bad json 1"
        bad2 = "also bad"
        content = "\n".join([bad1, bad2])
        rc, output, stderr = run_converter(content)
        self.assertEqual(rc, 0)
        warning_count = stderr.count("Warning: skipping malformed JSON")
        self.assertEqual(warning_count, 2)

    def test_agent_name_from_prompt_field(self):
        """When 'description' is absent, falls back to 'prompt' field."""
        lines = make_tool_use("Agent", {"prompt": "do the task"})
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        # Should have created an agent with a name derived from "do the task"
        agent_ids = [a["id"] for a in output["agents"]]
        self.assertIn("do-the-task", agent_ids)

    def test_agent_name_from_name_field(self):
        """When 'description' and 'prompt' are absent, falls back to 'name' field."""
        lines = make_tool_use("Agent", {"name": "my-worker"})
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        agent_ids = [a["id"] for a in output["agents"]]
        self.assertIn("my-worker", agent_ids)

    def test_agent_name_fallback_to_agent(self):
        """When no name fields present, defaults to 'agent'."""
        lines = make_tool_use("Agent", {})
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        agent_ids = [a["id"] for a in output["agents"]]
        self.assertIn("agent", agent_ids)

    def test_duplicate_agent_calls_not_duplicated(self):
        """Multiple Agent calls with the same name don't create duplicate agents."""
        lines = "\n".join([
            make_tool_use("Agent", {"description": "worker"}),
            make_tool_use("Agent", {"description": "worker"}),
        ])
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        worker_agents = [a for a in output["agents"] if a["id"] == "worker"]
        self.assertEqual(len(worker_agents), 1)

    def test_missing_content_field_graceful(self):
        """Records with missing content are handled without crashing."""
        record = {"type": "assistant", "message": {}}
        content = json.dumps(record)
        rc, output, _ = run_converter(content)
        self.assertEqual(rc, 0)

    def test_content_not_list_graceful(self):
        """Records with non-list content are handled without crashing."""
        record = {"type": "assistant", "message": {"content": "not a list"}}
        content = json.dumps(record)
        rc, output, _ = run_converter(content)
        self.assertEqual(rc, 0)

    def test_nonexistent_file_exits_nonzero(self):
        """Passing a non-existent file path exits with code 1."""
        result = subprocess.run(
            [sys.executable, CONVERTER, "/nonexistent/path/file.jsonl"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Error:", result.stderr)

    def test_no_args_exits_nonzero(self):
        """Running without arguments exits non-zero (argparse error)."""
        result = subprocess.run(
            [sys.executable, CONVERTER],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_tool_result_list_content(self):
        """Tool result with list content (multiple blocks) is concatenated."""
        record = {
            "type": "user",
            "message": {
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "id1",
                        "content": [
                            {"type": "text", "text": "block one"},
                            {"type": "text", "text": "block two"},
                        ],
                    }
                ]
            },
        }
        content = json.dumps(record)
        rc, output, _ = run_converter(content)
        self.assertEqual(rc, 0)
        result_events = [e for e in output["events"] if e["kind"] == "tool-result"]
        self.assertEqual(len(result_events), 1)
        self.assertIn("block one", result_events[0]["text"])
        self.assertIn("block two", result_events[0]["text"])

    def test_message_status_truncation_boundary(self):
        """Message status is exactly first 40 chars + '...' for long texts."""
        text = "A" * 80
        lines = make_assistant_text(text)
        rc, output, _ = run_converter(lines)
        events = [e for e in output["events"] if e["kind"] == "message"]
        expected_status = "A" * 40 + "..."
        self.assertEqual(events[0]["status"], expected_status)

    def test_short_message_status(self):
        """Message status for short text is text[:40] + '...'."""
        text = "Short"
        lines = make_assistant_text(text)
        rc, output, _ = run_converter(lines)
        events = [e for e in output["events"] if e["kind"] == "message"]
        self.assertEqual(events[0]["status"], "Short...")

    def test_thinking_event_agent_assignment(self):
        """Thinking events before any Agent call belong to orchestrator."""
        lines = make_assistant_thinking("planning...")
        rc, output, _ = run_converter(lines)
        events = [e for e in output["events"] if e["kind"] == "thinking"]
        self.assertEqual(events[0]["agent"], "orchestrator")

    def test_events_after_agent_call_belong_to_sub_agent(self):
        """Events emitted after an Agent tool call belong to the sub-agent."""
        lines = "\n".join([
            make_tool_use("Agent", {"description": "sub-builder"}),
            make_assistant_text("sub-agent message"),
        ])
        rc, output, _ = run_converter(lines)
        message_events = [e for e in output["events"] if e["kind"] == "message"]
        self.assertEqual(len(message_events), 1)
        self.assertEqual(message_events[0]["agent"], "sub-builder")

    def test_transition_id_increments(self):
        """Each transition gets a unique incremented id."""
        lines = "\n".join([
            make_tool_use("Agent", {"description": "agent-a"}),
            make_tool_use("Agent", {"description": "agent-b"}),
        ])
        rc, output, _ = run_converter(lines)
        transition_ids = [t["id"] for t in output["transitions"]]
        self.assertEqual(len(set(transition_ids)), len(transition_ids))

    def test_agent_third_position(self):
        """Third sub-agent (index 3) goes to x=60, y=320."""
        lines = "\n".join([
            make_tool_use("Agent", {"description": "agent-one"}),
            make_tool_use("Agent", {"description": "agent-two"}),
            make_tool_use("Agent", {"description": "agent-three"}),
        ])
        rc, output, _ = run_converter(lines)
        agents_by_id = {a["id"]: a for a in output["agents"]}
        a3 = agents_by_id["agent-three"]
        # index 3: pair=1, col=0 → x=60, y=80+120*2=320
        self.assertEqual(a3["x"], 60)
        self.assertEqual(a3["y"], 320)

    def test_mixed_content_types_in_single_message(self):
        """Multiple content blocks in one assistant message are all converted."""
        record = {
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "thinking", "thinking": "deep thought"},
                    {"type": "text", "text": "response"},
                    {"type": "tool_use", "name": "Bash", "input": {"command": "echo hi"}},
                ]
            },
        }
        content = json.dumps(record)
        rc, output, _ = run_converter(content)
        self.assertEqual(rc, 0)
        kinds = [e["kind"] for e in output["events"]]
        self.assertIn("thinking", kinds)
        self.assertIn("message", kinds)
        self.assertIn("tool-call", kinds)


class TestOutputFormat(unittest.TestCase):

    def test_output_is_valid_json(self):
        """stdout is always valid JSON."""
        lines = make_assistant_text("hi")
        rc, output, _ = run_converter(lines)
        self.assertEqual(rc, 0)
        self.assertIsNotNone(output)

    def test_agents_have_required_fields(self):
        """Each agent has id, label, model, x, y."""
        lines = make_assistant_text("hi")
        rc, output, _ = run_converter(lines)
        for agent in output["agents"]:
            for key in ("id", "label", "model", "x", "y"):
                self.assertIn(key, agent, f"Agent missing key: {key}")

    def test_transitions_have_required_fields(self):
        """Each transition has id, from, to, type, label."""
        lines = make_tool_use("Agent", {"description": "worker"})
        rc, output, _ = run_converter(lines)
        for t in output["transitions"]:
            for key in ("id", "from", "to", "type", "label"):
                self.assertIn(key, t, f"Transition missing key: {key}")

    def test_events_have_required_fields(self):
        """Each event has agent, kind, text, status."""
        lines = "\n".join([
            make_assistant_thinking("t"),
            make_assistant_text("m"),
            make_tool_use("Bash", {"command": "ls"}),
            make_tool_result("output"),
        ])
        rc, output, _ = run_converter(lines)
        for event in output["events"]:
            for key in ("agent", "kind", "text", "status"):
                self.assertIn(key, event, f"Event {event.get('kind')} missing key: {key}")

    def test_tool_call_events_have_tool_and_args(self):
        """tool-call events have tool and args fields."""
        lines = make_tool_use("Read", {"file_path": "/tmp/x"})
        rc, output, _ = run_converter(lines)
        tc_events = [e for e in output["events"] if e["kind"] == "tool-call"]
        self.assertEqual(len(tc_events), 1)
        self.assertIn("tool", tc_events[0])
        self.assertIn("args", tc_events[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
