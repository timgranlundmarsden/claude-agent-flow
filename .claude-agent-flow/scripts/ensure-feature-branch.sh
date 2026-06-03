#!/usr/bin/env bash
# ensure-feature-branch.sh — canonical git pre-check for git-dependent commands.
# Exit 0: safe to proceed (already on a feature branch, or switched to a new one).
# Exit 1: not in a git repo.
# Exit 2: detached HEAD.
# Exit 3: slug collision after 99 attempts.
set -euo pipefail

# Check git is available and we're in a repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: ensure-feature-branch.sh: not in a git repository (this command requires git)" >&2
  exit 1
fi

# Check for detached HEAD
if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
  echo "ERROR: ensure-feature-branch.sh: detached HEAD state — checkout a named branch first" >&2
  exit 2
fi

branch=$(git branch --show-current)

if [[ "$branch" == "main" || "$branch" == "master" ]]; then
  # Derive slug from env or timestamp
  if [[ -n "${CLAUDE_BRANCH_SLUG:-}" ]]; then
    slug="$CLAUDE_BRANCH_SLUG"
  else
    slug="work-$(date +%Y%m%d)"
  fi
  # Append random 4-char suffix for uniqueness (pipefail-safe).
  # CLAUDE_BRANCH_SUFFIX is an optional test hook for deterministic suffixes.
  if [[ -n "${CLAUDE_BRANCH_SUFFIX:-}" ]]; then
    local_suffix="$CLAUDE_BRANCH_SUFFIX"
  else
    local_suffix=$(LC_ALL=C hexdump -n 2 -e '2/1 "%02x"' /dev/urandom)
  fi

  if [[ ! "$local_suffix" =~ ^[0-9a-f]{4}$ ]]; then
    local_suffix=$(printf '%04x' "$(( RANDOM % 65536 ))")
  fi
  slug="${slug}-${local_suffix}"

  candidate="claude/$slug"
  # Find unused branch name
  suffix=1
  while git show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; do
    suffix=$(( suffix + 1 ))
    if (( suffix > 99 )); then
      echo "ERROR: ensure-feature-branch.sh: could not find unused branch name for slug '$slug' (tried 99 suffixes)" >&2
      exit 3
    fi
    candidate="claude/${slug}-${suffix}"
  done

  git checkout -b "$candidate"
  echo "Switched to new branch: $candidate"
fi

# Already on a feature branch — no-op
exit 0
