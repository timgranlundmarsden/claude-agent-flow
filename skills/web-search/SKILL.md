---
name: web-search
description: >
  Optional web search skill using a LiteLLM-compatible grounded-search endpoint
  (e.g. Gemini via LiteLLM). When AGENT_FLOW_WEB_SEARCH_ENABLED=true, agents
  can shell out to this skill for real-time search results as an alternative to
  the native WebSearch tool. Outputs synthesised answer with citations (answer
  mode), raw citation list (search mode), or full API JSON (raw mode).
---

# web-search skill

Shells out to a `/chat/completions` endpoint with grounded-search capability
and returns markdown. Designed as an additive, dormant-when-disabled
complement to Claude Code's native `WebSearch` tool.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AGENT_FLOW_WEB_SEARCH_ENABLED` | Yes | — | Set to `true` or `1` to enable. Any other value → skill exits 2 (disabled). |
| `AGENT_FLOW_WEB_SEARCH_MODEL` | When enabled | — | Model ID (e.g. `gemini-2.0-flash`). |
| `AGENT_FLOW_WEB_SEARCH_BASE_URL` | When enabled | `$ANTHROPIC_BASE_URL` | Base URL for the completions endpoint. |
| `AGENT_FLOW_WEB_SEARCH_API_KEY` | When enabled | `$ANTHROPIC_API_KEY` | Bearer token for the endpoint. |
| `AGENT_FLOW_WEB_SEARCH_TOOL_SHAPE` | No | `googleSearch` | Tool shape to send. One of: `googleSearch`, `googleSearchRetrieval`, `web_search_options`. |

## Invocation

```bash
bash .claude/skills/web-search/web-search.sh [--mode answer|search|raw] "<query>"
```

## Output modes

| Mode | Output |
|---|---|
| `answer` (default) | Synthesised paragraph from LLM content + `## Sources` citation list |
| `search` | Citation list only (title + URL per line, no synthesis) |
| `raw` | Pretty-printed JSON of the full API response |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage error (bad args, missing query, unknown TOOL_SHAPE) |
| 2 | Feature disabled (`AGENT_FLOW_WEB_SEARCH_ENABLED` unset or not `true`/`1`) |
| 3 | Configuration error (missing required env var when enabled) |
| 4 | HTTP/API error (non-2xx response, timeout, jq/curl not installed) |

## Tool shapes

- **`googleSearch`** (default) — `"tools": [{"googleSearch": {}}]`
- **`googleSearchRetrieval`** — `"tools": [{"googleSearchRetrieval": {}}]`
- **`web_search_options`** — omits `tools`, adds top-level `"web_search_options": {"search_context_size": "medium"}`

## Troubleshooting

- `exit 2`: Set `AGENT_FLOW_WEB_SEARCH_ENABLED=true` in your `.env` or shell.
- `exit 3`: Check that `AGENT_FLOW_WEB_SEARCH_MODEL` and one of `AGENT_FLOW_WEB_SEARCH_BASE_URL` / `ANTHROPIC_BASE_URL` is set.
- `exit 4`: Verify the endpoint is reachable and the model supports grounded search.
- Citations missing: Try `--mode=raw` to inspect the full API response. Citations appear in `choices[0].message.annotations[]`, `choices[0].message.grounding_metadata.groundingChunks[].web`, or inline in `content`.
- **Only `true` or `1` enable the skill.** Values like `yes`, `YES`, `True`, `on` are treated as disabled.
