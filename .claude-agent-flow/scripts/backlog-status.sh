#!/usr/bin/env bash
# backlog-status.sh — generates the backlog status dashboard
#
# Usage:
#   backlog-status.sh                          first pass — outputs table or __MCP_NEEDED__ block
#   backlog-status.sh --pr-data '<json>'       second pass — PR data injected, outputs final markdown
#
# Cache: ~/.cache/backlog-status/cache.json (never written to repo)

set -euo pipefail

CACHE_DIR="$HOME/.cache/backlog-status"
CACHE_FILE="$CACHE_DIR/cache.json"
OPEN_PR_TTL=600  # seconds before re-fetching open PR state
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "/home/user/agent-team")"

mkdir -p "$CACHE_DIR"

# ── cache helpers ─────────────────────────────────────────────────────────────

cache_read() {
  # cache_read <top-key> <sub-key>  → prints JSON value or nothing
  [[ ! -f "$CACHE_FILE" ]] && return
  python3 - "$1" "$2" "$CACHE_FILE" <<'EOF'
import json, sys
key, subkey, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(path))
    v = d.get(key, {}).get(subkey)
    if v is not None:
        print(json.dumps(v))
except Exception:
    pass
EOF
}

cache_write() {
  # cache_write <top-key> <sub-key> <json-value>
  python3 - "$1" "$2" "$3" "$CACHE_FILE" <<'EOF'
import json, os, sys
key, subkey, value, path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {}
if os.path.exists(path):
    try: d = json.load(open(path))
    except Exception: pass
d.setdefault(key, {})[subkey] = json.loads(value)
json.dump(d, open(path, 'w'))
EOF
}

# ── task view with mtime-based cache ─────────────────────────────────────────

get_task_view() {
  local task_id="$1"
  local task_num="${task_id#TASK-}"
  local task_file mtime=""

  task_file=$(find "$REPO_ROOT/backlog/tasks" -name "task-${task_num}*" 2>/dev/null | head -1)
  [[ -n "$task_file" ]] && mtime=$(stat -c%Y "$task_file" 2>/dev/null || echo "")

  # cache hit?
  local cached
  cached=$(cache_read "task_views" "$task_id" 2>/dev/null || echo "")
  if [[ -n "$cached" && -n "$mtime" ]]; then
    local cached_mtime
    cached_mtime=$(echo "$cached" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mtime',''))" 2>/dev/null || echo "")
    if [[ "$cached_mtime" == "$mtime" ]]; then
      echo "$cached" | python3 -c "import json,sys; print(json.load(sys.stdin)['data'])" 2>/dev/null
      return 0
    fi
  fi

  # fetch fresh
  local output
  output=$(backlog task view "$task_id" --plain 2>/dev/null) || return 1

  # store in cache
  if [[ -n "$mtime" ]]; then
    local payload
    payload=$(python3 -c "
import json, sys
data = sys.stdin.read()
print(json.dumps({'data': data, 'mtime': sys.argv[1]}))
" "$mtime" <<< "$output" 2>/dev/null || echo "")
    [[ -n "$payload" ]] && cache_write "task_views" "$task_id" "$payload" 2>/dev/null || true
  fi

  echo "$output"
}

# ── PR data injection (second pass) ──────────────────────────────────────────

PR_DATA_FILE=""
if [[ "${1:-}" == "--pr-data-file" ]]; then
  PR_DATA_FILE="${2:-}"
  shift 2
fi

get_injected_pr() {
  local pr_num="$1"
  [[ -z "$PR_DATA_FILE" || ! -f "$PR_DATA_FILE" ]] && return
  python3 - "$pr_num" "$PR_DATA_FILE" <<'EOF'
import json, sys
pr_num, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
pr = d.get(pr_num) or d.get(str(int(pr_num)))
if pr:
    print(json.dumps(pr))
EOF
}

# ── Step 1: list tasks ────────────────────────────────────────────────────────

task_list=$(backlog task list --plain 2>/dev/null) || {
  echo "# Backlog Status"
  echo ""
  echo "> **Error:** backlog CLI failed. Run /diagnostic."
  exit 0
}

declare -A task_status
declare -a active_ids=()
declare -a done_ids=()

current_status=""
while IFS= read -r line; do
  if [[ "$line" =~ ^([A-Za-z][A-Za-z\ ]+):$ ]]; then
    current_status="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" =~ TASK-([0-9]+) ]]; then
    tid="TASK-${BASH_REMATCH[1]}"
    task_status["$tid"]="$current_status"
    if [[ "${current_status,,}" == "done" ]]; then
      done_ids+=("$tid")
    else
      active_ids+=("$tid")
    fi
  fi
done <<< "$task_list"

if [[ ${#active_ids[@]} -eq 0 && ${#done_ids[@]} -eq 0 ]]; then
  echo "# Backlog Status"
  echo ""
  echo "_No tasks in backlog._"
  exit 0
fi

# ── Step 2: fetch detail for active tasks ─────────────────────────────────────

declare -A task_title=()
declare -A task_updated=()
declare -A task_pr_num=()
declare -A task_pr_url=()
declare -A task_wmd=()
declare -A task_unchecked=()
declare -a skipped_ids=()

for tid in "${active_ids[@]}"; do
  view_output=$(get_task_view "$tid" 2>/dev/null) || { skipped_ids+=("$tid"); continue; }

  # title: format is "Task TASK-N - <title>"
  title_raw=$(echo "$view_output" | grep -m1 "^Task TASK-[0-9]" | sed 's/^Task TASK-[0-9]*[[:space:]]*-[[:space:]]*//' | tr -d '|' || echo "")
  task_title["$tid"]="${title_raw:-$tid}"

  # updated timestamp
  upd=$(echo "$view_output" | grep -m1 "^Updated:" | sed 's/^Updated:[[:space:]]*//' || echo "")
  task_updated["$tid"]="$upd"

  # PR URL — last occurrence in full output
  last_pr=$(echo "$view_output" | grep -oE 'github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -1 || echo "")
  if [[ -n "$last_pr" ]]; then
    task_pr_num["$tid"]=$(echo "$last_pr" | grep -oE '[0-9]+$')
    task_pr_url["$tid"]="https://$last_pr"
  fi

  # What it must do section
  task_wmd["$tid"]=$(echo "$view_output" | awk '/^## What it must do/{found=1;next} found && /^## /{found=0} found{print}' || echo "")

  # Unchecked AC items
  task_unchecked["$tid"]=$(echo "$view_output" | grep -E '^\- \[ \]' | sed 's/^- \[ \] //' | tr '\n' ',' | sed 's/,$//' || echo "")
done

# ── Step 3a: owner/repo ───────────────────────────────────────────────────────

remote_url=$(git remote get-url origin 2>/dev/null || echo "")

# Works with github.com URLs, SSH urls, and proxy URLs like http://host/git/owner/repo
owner=""
repo=""
if [[ -n "$remote_url" ]]; then
  # strip .git suffix and trailing slash
  clean_url="${remote_url%.git}"
  clean_url="${clean_url%/}"
  # extract last two path segments (owner/repo)
  repo=$(echo "$clean_url" | grep -oE '[^/:@]+$')
  owner=$(echo "$clean_url" | grep -oE '[^/:@]+/[^/:@]+$' | cut -d/ -f1)
fi

PR_LOOKUP_UNAVAILABLE=false
[[ -z "$owner" || -z "$repo" ]] && PR_LOOKUP_UNAVAILABLE=true

# ── Steps 3b/3c: resolve PR data ─────────────────────────────────────────────

declare -A pr_map=()
declare -A task_branch=()
declare -a needs_pr_lookup=()
declare -a pr_nums_to_fetch=()

PR_NEEDED_FILE="/tmp/backlog-status-pr-needed.$$.txt"

if [[ "$PR_LOOKUP_UNAVAILABLE" == false ]]; then

  # collect PR numbers; check task_pr_map cache for tasks with no noted PR
  for tid in "${active_ids[@]}"; do
    _is_skipped=false
    for s in "${skipped_ids[@]+"${skipped_ids[@]}"}"; do [[ "$s" == "$tid" ]] && _is_skipped=true && break; done
    [[ "$_is_skipped" == true ]] && continue

    pr_num="${task_pr_num[$tid]:-}"
    if [[ -z "$pr_num" ]]; then
      cached_pr=$(cache_read "task_pr_map" "$tid" 2>/dev/null | tr -d '"' || echo "")
      if [[ -n "$cached_pr" ]]; then
        task_pr_num["$tid"]="$cached_pr"
        pr_num="$cached_pr"
      fi
    fi

    if [[ -n "$pr_num" ]]; then
      pr_nums_to_fetch+=("$pr_num")
    else
      needs_pr_lookup+=("$tid")
    fi
  done

  # for each known PR number: check cache, use injected data, or mark as needed
  for pr_num in $(printf '%s\n' "${pr_nums_to_fetch[@]+"${pr_nums_to_fetch[@]}"}" | sort -u); do
    [[ -z "$pr_num" ]] && continue

    cached_pr_json=$(python3 - "$pr_num" "$CACHE_FILE" "$OPEN_PR_TTL" 2>/dev/null <<'EOF' || true
import json, os, time, sys
pr_num, path, ttl = sys.argv[1], sys.argv[2], int(sys.argv[3])
if not os.path.exists(path): exit(0)
try:
    d = json.load(open(path))
    pr = d.get('pr_state', {}).get(pr_num)
    if pr:
        if pr.get('permanent') or (time.time() - pr.get('fetched_at', 0) < ttl):
            print(json.dumps(pr))
except Exception:
    pass
EOF
)

    if [[ -n "$cached_pr_json" ]]; then
      pr_map["$pr_num"]="$cached_pr_json"
    elif [[ -n "$PR_DATA_FILE" && -f "$PR_DATA_FILE" ]]; then
      injected=$(get_injected_pr "$pr_num" 2>/dev/null || echo "")
      if [[ -n "$injected" ]]; then
        pr_map["$pr_num"]="$injected"
        # persist to cache — write injected JSON via temp file to avoid quoting issues
        _tmp_pr=$(mktemp)
        echo "$injected" > "$_tmp_pr"
        python3 - "$pr_num" "$CACHE_FILE" "$_tmp_pr" 2>/dev/null <<'EOF' || true
import json, os, time, sys
pr_num, path, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.load(open(tmp))
payload['fetched_at'] = time.time()
if payload.get('merged_at'):
    payload['permanent'] = True
d = {}
if os.path.exists(path):
    try: d = json.load(open(path))
    except Exception: pass
d.setdefault('pr_state', {})[pr_num] = payload
json.dump(d, open(path, 'w'))
EOF
        rm -f "$_tmp_pr"
      fi
    else
      echo "PR_NUM:$pr_num" >> "$PR_NEEDED_FILE"
    fi
  done

  # tasks with no PR number: branch-name match via open PR list (if available)
  if [[ ${#needs_pr_lookup[@]} -gt 0 ]]; then
    if [[ -n "$PR_DATA_FILE" && -f "$PR_DATA_FILE" ]]; then
      open_prs_json=$(python3 - "$PR_DATA_FILE" 2>/dev/null <<'EOF' || true
import json, sys
d = json.load(open(sys.argv[1]))
prs = d.get('open_prs')
if prs:
    print(json.dumps(prs))
EOF
)

      if [[ -n "$open_prs_json" ]]; then
        _open_prs_file=$(mktemp)
        echo "$open_prs_json" > "$_open_prs_file"
        for tid in "${needs_pr_lookup[@]}"; do
          tid_num="${tid#TASK-}"
          matched=$(python3 - "$tid_num" "$_open_prs_file" 2>/dev/null <<'PYEOF' || true
import json, re, sys
tid_num, path = sys.argv[1], sys.argv[2]
prs = json.load(open(path))
for pr in prs:
    ref = pr.get('head_ref','') or pr.get('head',{}).get('ref','')
    if re.search(r'(?i)TASK-' + tid_num + r'([^0-9]|$)', ref):
        print(json.dumps({
            'state': pr.get('state'), 'merged_at': pr.get('merged_at'),
            'closed_at': pr.get('closed_at'), 'updated_at': pr.get('updated_at'),
            'head_ref': ref, 'html_url': pr.get('html_url'), 'number': pr.get('number')
        }))
        break
PYEOF
)

          if [[ -n "$matched" ]]; then
            pr_num=$(echo "$matched" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null || echo "")
            if [[ -n "$pr_num" ]]; then
              task_pr_num["$tid"]="$pr_num"
              pr_map["$pr_num"]="$matched"
              cache_write "task_pr_map" "$tid" "\"$pr_num\"" 2>/dev/null || true
            fi
          fi
        done
        rm -f "$_open_prs_file"
      fi
    else
      echo "OPEN_PR_LIST:true" >> "$PR_NEEDED_FILE"
    fi
  fi
fi

# ── remote branch fallback — Branch to Test only ──────────────────────────────

remote_refs=$(git ls-remote --heads origin 2>/dev/null || echo "")

for tid in "${active_ids[@]}"; do
  _is_skipped=false
  for s in "${skipped_ids[@]+"${skipped_ids[@]}"}"; do [[ "$s" == "$tid" ]] && _is_skipped=true && break; done
  [[ "$_is_skipped" == true ]] && continue

  pr_num="${task_pr_num[$tid]:-}"
  if [[ -n "$pr_num" && -n "${pr_map[$pr_num]:-}" ]]; then
    pr_state=$(echo "${pr_map[$pr_num]}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
    pr_head=$(echo "${pr_map[$pr_num]}"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('head_ref',''))" 2>/dev/null || echo "")
    if [[ "$pr_state" == "open" ]]; then
      task_branch["$tid"]="$pr_head"
    else
      task_branch["$tid"]="main"
    fi
  else
    tid_num="${tid#TASK-}"
    matched_branch=$(echo "$remote_refs" | grep -oE 'refs/heads/[^\t ]+' | sed 's|refs/heads/||' | grep -iE "TASK-${tid_num}([^0-9]|$)" | head -1 || echo "")
    task_branch["$tid"]="${matched_branch:-main}"
  fi
done

# ── if first pass and MCP data needed, emit marker and exit ───────────────────

if [[ -f "$PR_NEEDED_FILE" ]]; then
  _pr_lines=$(grep "^PR_NUM:" "$PR_NEEDED_FILE" 2>/dev/null || true)
  pr_nums=$(echo "$_pr_lines" | sed 's/^PR_NUM://' | tr '\n' ',' | sed 's/,$//')
  needs_open=$(grep -c "^OPEN_PR_LIST:" "$PR_NEEDED_FILE" 2>/dev/null || echo 0)
  rm -f "$PR_NEEDED_FILE"

  echo "__MCP_NEEDED__"
  [[ -n "$pr_nums" ]]    && echo "PR_NUMS:$pr_nums"
  [[ "$needs_open" -gt 0 ]] && echo "OPEN_PR_LIST:true"
  echo "OWNER:$owner"
  echo "REPO:$repo"
  exit 0
fi
rm -f "$PR_NEEDED_FILE" 2>/dev/null || true

# ── Step 3.5: fallback task_updated to PR merge/update timestamp ───────────────

for tid in "${active_ids[@]}"; do
  [[ -n "${task_updated[$tid]:-}" ]] && continue  # already has timestamp
  pr_num="${task_pr_num[$tid]:-}"
  [[ -z "$pr_num" || -z "${pr_map[$pr_num]:-}" ]] && continue

  pr_json="${pr_map[$pr_num]}"
  merged=$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('merged_at') or '')" 2>/dev/null || echo "")
  if [[ -n "$merged" ]]; then
    # Use PR merge timestamp; convert to local timezone
    task_updated[$tid]=$(TZ=Europe/Berlin date -d "$merged" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$merged")
  else
    # Fall back to updated_at if not merged
    updated_at=$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('updated_at') or '')" 2>/dev/null || echo "")
    if [[ -n "$updated_at" ]]; then
      task_updated[$tid]=$(TZ=Europe/Berlin date -d "$updated_at" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$updated_at")
    fi
  fi
done

# ── Step 4: sort active tasks ─────────────────────────────────────────────────

mapfile -t sorted_active < <(
  for tid in "${active_ids[@]}"; do
    _skip=false
    for s in "${skipped_ids[@]+"${skipped_ids[@]}"}"; do [[ "$s" == "$tid" ]] && _skip=true && break; done
    [[ "$_skip" == true ]] && continue
    upd="${task_updated[$tid]:-}"
    num="${tid#TASK-}"
    title="${task_title[$tid]:-$tid}"
    status_lc="${task_status[$tid]:-}"
    status_lc="${status_lc,,}"
    if [[ -n "$upd" ]]; then
      # Group 0: has a last-updated date — sort ascending by date
      printf "0\t%s\t%05d\t%s\n" "$upd" "$num" "$tid"
    elif [[ "$status_lc" == "ready for review" || "$status_lc" == "in progress" || "$status_lc" == "blocked" ]]; then
      # Group 1: no date, active non-todo state — sort by task num
      printf "1\t\t%05d\t%s\n" "$num" "$tid"
    else
      # Group 2: no date, To Do — sort alphabetically by title
      printf "2\t\t%s\t%s\n" "$title" "$tid"
    fi
  done | sort | awk -F'\t' '{print $4}'
)

# ── timestamp conversion ──────────────────────────────────────────────────────

declare -A pr_activity=()
declare -A pr_ts_raw=()
declare -A pr_ts_suffix=()

for tid in "${sorted_active[@]+"${sorted_active[@]}"}"; do
  pr_num="${task_pr_num[$tid]:-}"
  if [[ -z "$pr_num" || -z "${pr_map[$pr_num]:-}" ]]; then
    pr_activity["$tid"]="—"; continue
  fi
  pr_json="${pr_map[$pr_num]}"
  state=$(echo    "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
  merged=$(echo   "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('merged_at') or '')" 2>/dev/null || echo "")
  closed=$(echo   "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('closed_at') or '')" 2>/dev/null || echo "")
  updated_at=$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('updated_at') or '')" 2>/dev/null || echo "")

  if [[ "$state" == "open" ]]; then
    pr_ts_raw["$tid"]="$updated_at"; pr_ts_suffix["$tid"]=""
  elif [[ -n "$merged" ]]; then
    pr_ts_raw["$tid"]="$merged";     pr_ts_suffix["$tid"]=" *(merged)*"
  else
    pr_ts_raw["$tid"]="$closed";     pr_ts_suffix["$tid"]=" *(closed)*"
  fi
done

for tid in "${sorted_active[@]+"${sorted_active[@]}"}"; do
  raw="${pr_ts_raw[$tid]:-}"
  [[ -z "$raw" ]] && continue
  converted=$(TZ=Europe/Berlin date -d "$raw" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "${raw} (UTC)")
  pr_activity["$tid"]="${converted}${pr_ts_suffix[$tid]:-}"
done

# ── Step 5: pad with Done tasks if active < 5 ────────────────────────────────

active_count=${#sorted_active[@]}
declare -a padding_rows=()

if [[ "$active_count" -lt 5 && ${#done_ids[@]} -gt 0 ]]; then
  needed=$(( 5 - active_count ))

  mapfile -t sorted_done < <(
    for tid in "${done_ids[@]}"; do
      upd=$(python3 - "$tid" "$CACHE_FILE" 2>/dev/null <<'EOF' || true
import json, os, sys
tid, path = sys.argv[1], sys.argv[2]
if not os.path.exists(path): exit(0)
try:
    d = json.load(open(path))
    tv = d.get('task_views', {}).get(tid, {})
    data = tv.get('data','') if isinstance(tv, dict) else ''
    for line in data.splitlines():
        if line.startswith('Updated:'):
            print(line.split('Updated:',1)[1].strip())
            break
except Exception:
    pass
EOF
)
      [[ -z "$upd" ]] && upd="0000-00-00 00:00"
      num="${tid#TASK-}"
      printf "%s\t%05d\t%s\n" "$upd" "$num" "$tid"
    done | sort -r | awk -F'\t' '{print $3}' | head -"$needed"
  )

  for tid in "${sorted_done[@]+"${sorted_done[@]}"}"; do
    view_output=$(get_task_view "$tid" 2>/dev/null) || continue
    d_title=$(echo "$view_output" | grep -m1 "^Task TASK-[0-9]" | sed 's/^Task TASK-[0-9]*[[:space:]]*-[[:space:]]*//' | tr -d '|' || echo "$tid")
    d_updated=$(echo "$view_output" | grep -m1 "^Updated:" | sed 's/^Updated:[[:space:]]*//' || echo "")
    d_pr_num=$(echo "$view_output" | grep -oE 'github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -1 | grep -oE '[0-9]+$' || echo "")

    d_branch="—"; d_pr_open="—"; d_pr_closed="—"; d_activity="—"

    if [[ -n "$d_pr_num" && -n "${pr_map[$d_pr_num]:-}" ]]; then
      pr_json="${pr_map[$d_pr_num]}"
      d_state=$(echo   "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
      d_merged=$(echo  "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('merged_at') or '')" 2>/dev/null || echo "")
      d_url=$(echo     "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || echo "")
      d_head=$(echo    "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('head_ref',''))" 2>/dev/null || echo "")
      if [[ "$d_state" == "open" ]]; then
        d_branch="$d_head"; d_pr_open="[PR-${d_pr_num}](${d_url})"
      else
        d_branch="main"; d_pr_closed="[PR-${d_pr_num}](${d_url})"
        [[ -n "$d_merged" ]] && d_activity="$(TZ=Europe/Berlin date -d "$d_merged" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$d_merged (UTC)") *(merged)*"
      fi
    fi

    padding_rows+=("| $tid | $d_title | Done | $d_updated | $d_branch | $d_pr_open | $d_pr_closed | $d_activity |")
  done
fi

# ── Step 6: hygiene blockquote ────────────────────────────────────────────────

hygiene_count=0
for tid in "${sorted_active[@]+"${sorted_active[@]}"}"; do
  [[ "${task_status[$tid],,}" != "ready for review" ]] && continue
  pr_num="${task_pr_num[$tid]:-}"
  [[ -z "$pr_num" || -z "${pr_map[$pr_num]:-}" ]] && continue
  merged=$(echo "${pr_map[$pr_num]}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('merged_at') or '')" 2>/dev/null || echo "")
  [[ -n "$merged" ]] && (( hygiene_count += 1 )) || true
done

# ── Step 8: emit final output ─────────────────────────────────────────────────

generated=$(TZ=Europe/Berlin date "+%Y-%m-%d %H:%M" 2>/dev/null || date -u "+%Y-%m-%d %H:%M (UTC)")

echo "# Backlog Status"
echo ""
echo "*Generated: ${generated} CET*"
echo ""

[[ "$hygiene_count" -gt 0 ]] && {
  echo "> **Heads up:** ${hygiene_count} Ready-for-Review task(s) have merged PRs — consider moving to Done."
  echo ""
}

echo "## Active Tasks"
echo ""
echo "| Task | Description | State | Last Updated (CET) | Branch to Test | PR Open | PR Closed | PR Activity (CET) |"
echo "|------|-------------|-------|--------------------|----------------|---------|-----------|-------------------|"

for tid in "${sorted_active[@]+"${sorted_active[@]}"}"; do
  status="${task_status[$tid]:-}"
  title="${task_title[$tid]:-$tid}"
  updated="${task_updated[$tid]:-}"
  branch="${task_branch[$tid]:-main}"
  pr_num="${task_pr_num[$tid]:-}"
  pr_open="—"; pr_closed="—"
  activity="${pr_activity[$tid]:-—}"

  if [[ -n "$pr_num" && -n "${pr_map[$pr_num]:-}" ]]; then
    pr_json="${pr_map[$pr_num]}"
    state=$(echo    "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
    html_url=$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || "${task_pr_url[$tid]:-}")
    if [[ "$state" == "open" ]]; then
      pr_open="[PR-${pr_num}](${html_url})"
    else
      pr_closed="[PR-${pr_num}](${html_url})"
    fi
  fi

  echo "| $tid | $title | $status | $updated | $branch | $pr_open | $pr_closed | $activity |"
done

for row in "${padding_rows[@]+"${padding_rows[@]}"}"; do
  echo "$row"
done

echo ""

# ── QA Test Guide ─────────────────────────────────────────────────────────────

declare -a rfr_tasks=()
for tid in "${sorted_active[@]+"${sorted_active[@]}"}"; do
  [[ "${task_status[$tid],,}" == "ready for review" ]] && rfr_tasks+=("$tid")
done

if [[ ${#rfr_tasks[@]} -gt 0 ]]; then
  echo "## Still Pending Review — QA Test Guide"
  echo ""
  for tid in "${rfr_tasks[@]}"; do
    pr_num="${task_pr_num[$tid]:-}"
    title="${task_title[$tid]:-$tid}"
    if [[ -n "$pr_num" && -n "${pr_map[$pr_num]:-}" ]]; then
      pr_json="${pr_map[$pr_num]}"
      state=$(echo  "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "open")
      html_url=$(echo "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || echo "")
      merged=$(echo  "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('merged_at') or '')" 2>/dev/null || echo "")
      label="open"
      [[ -n "$merged" ]] && label="merged"
      [[ "$state" == "closed" && -z "$merged" ]] && label="closed"
      echo "### $tid — $title — [PR-${pr_num}](${html_url}) *($label)*"
    else
      echo "### $tid — $title"
    fi
    echo ""
    # placeholder — the command layer writes the QA paraphrase
    wmd=$(echo "${task_wmd[$tid]:-}" | head -5 | tr '\n' '~')
    unchecked="${task_unchecked[$tid]:-}"
    echo "__QA_PARAPHRASE__:${tid}:${wmd}:${title}:${unchecked}"
    echo ""
    [[ -n "$unchecked" ]] && echo "**Note:** $unchecked" && echo ""
  done
fi

# ── footer ────────────────────────────────────────────────────────────────────

[[ "$PR_LOOKUP_UNAVAILABLE" == true ]] && echo "> PR state lookup unavailable — table reflects backlog only."
if [[ ${#skipped_ids[@]} -gt 0 ]]; then
  joined=$(printf '%s, ' "${skipped_ids[@]}"); joined="${joined%, }"
  echo "> **Warning:** Could not fetch detail for task(s): $joined — skipped."
fi
