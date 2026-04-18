#!/usr/bin/env bash
# Discover SKILL.md paths to evaluate.
# Supports: pull_request, issue_comment (on PRs), push. Explicit path overrides.
# Writes `count` and `paths` (JSON array) to $GITHUB_OUTPUT.

set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_OUTPUT:?}"
: "${GITHUB_EVENT_NAME:?}"
: "${GITHUB_EVENT_PATH:?}"
MAX_SKILLS="${MAX_SKILLS:-10}"
EXPLICIT_PATH="${EXPLICIT_PATH:-}"

emit() {
  local paths_json="$1"
  local count="$2"
  {
    echo "count=$count"
    echo "paths=$paths_json"
  } >> "$GITHUB_OUTPUT"
  echo "Detected $count SKILL.md path(s): $paths_json"
}

normalize_path() {
  # Accepts either "skills/foo" (dir) or "skills/foo/SKILL.md" (file); returns file path.
  local p="${1%/}"
  if [[ "$p" == *"/SKILL.md" ]]; then
    echo "$p"
  else
    echo "$p/SKILL.md"
  fi
}

# 1. Explicit path wins (used by slash-command workflows).
if [ -n "$EXPLICIT_PATH" ]; then
  file_path="$(normalize_path "$EXPLICIT_PATH")"
  if [ ! -f "$file_path" ]; then
    echo "::error::Explicit path '$EXPLICIT_PATH' does not resolve to a SKILL.md file ($file_path not found)"
    emit "[]" 0
    exit 0
  fi
  emit "$(jq -c -n --arg p "$file_path" '[$p]')" 1
  exit 0
fi

# 2. Resolve PR number from event payload.
PR_NUMBER="$(jq -r '.pull_request.number // .issue.number // empty' "$GITHUB_EVENT_PATH")"

case "$GITHUB_EVENT_NAME" in
  pull_request)
    : "${PR_NUMBER:?pull_request event missing .pull_request.number}"
    raw=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files" --paginate \
      --jq '[.[] | select(.filename | endswith("SKILL.md")) | select(.status != "removed") | .filename]')
    ;;

  issue_comment)
    is_pr="$(jq -r '.issue.pull_request // empty' "$GITHUB_EVENT_PATH")"
    if [ -z "$is_pr" ] || [ -z "$PR_NUMBER" ]; then
      echo "::notice::issue_comment not on a PR; nothing to evaluate"
      emit "[]" 0
      exit 0
    fi
    raw=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files" --paginate \
      --jq '[.[] | select(.filename | endswith("SKILL.md")) | select(.status != "removed") | .filename]')
    ;;

  push)
    before="$(jq -r '.before // empty' "$GITHUB_EVENT_PATH")"
    after="$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")"
    if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ]; then
      # First push / new branch: scan the whole tree.
      raw=$(git ls-files '**/SKILL.md' | jq -R . | jq -cs .)
    else
      raw=$(git diff --name-only --diff-filter=d "$before" "$after" -- '**/SKILL.md' | jq -R . | jq -cs .)
    fi
    ;;

  workflow_dispatch|schedule)
    # No diff context; scan all SKILL.md files in the repo.
    raw=$(git ls-files '**/SKILL.md' | jq -R . | jq -cs .)
    ;;

  *)
    echo "::notice::Event '$GITHUB_EVENT_NAME' not supported; scanning repository"
    raw=$(git ls-files '**/SKILL.md' | jq -R . | jq -cs .)
    ;;
esac

# 3. Cap at MAX_SKILLS; warn on truncation.
total=$(jq 'length' <<< "$raw")
if [ "$total" -gt "$MAX_SKILLS" ]; then
  echo "::warning::Found $total SKILL.md files; capping at $MAX_SKILLS (see 'max-skills' input)"
  raw=$(jq -c --argjson n "$MAX_SKILLS" '.[:$n]' <<< "$raw")
  total="$MAX_SKILLS"
fi

emit "$raw" "$total"
