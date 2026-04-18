#!/usr/bin/env bash
# Upsert (POST or PATCH) the sklab-action PR comment.
# Finds an existing comment by marker; PATCHes it, or POSTs a new one.
# Falls back to $GITHUB_STEP_SUMMARY if writes fail (fork PRs, missing perms).

set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_EVENT_PATH:?}"
: "${GH_TOKEN:?}"
: "${COMMENT_FILE:?}"
COMMENT_MARKER="${COMMENT_MARKER:-<!-- sklab-action -->}"

PR_NUMBER="$(jq -r '.pull_request.number // .issue.number // empty' "$GITHUB_EVENT_PATH")"

fallback_to_summary() {
  local reason="$1"
  echo "::warning::$reason — writing to job summary instead"
  {
    printf '\n'
    cat "$COMMENT_FILE"
    printf '\n'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

if [ -z "$PR_NUMBER" ]; then
  fallback_to_summary "Not in a PR context"
  exit 0
fi

# Find existing sklab-action comment (use jq's select; contains needs an exact string match on body).
existing_id="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" --paginate \
  --jq "[.[] | select(.body | contains(\"$COMMENT_MARKER\"))] | last | .id // empty")"

body_json="$(jq -Rs '{body: .}' < "$COMMENT_FILE")"

if [ -n "$existing_id" ]; then
  if ! echo "$body_json" | gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$existing_id" --input - >/dev/null; then
    fallback_to_summary "Failed to PATCH existing comment $existing_id (fork PR or missing pull-requests:write?)"
    exit 0
  fi
  echo "Updated existing sklab-action comment (id=$existing_id)"
else
  if ! echo "$body_json" | gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" --input - >/dev/null; then
    fallback_to_summary "Failed to POST new comment (fork PR or missing pull-requests:write?)"
    exit 0
  fi
  echo "Posted new sklab-action comment"
fi
