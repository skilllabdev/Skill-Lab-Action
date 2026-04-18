#!/usr/bin/env bash
# Apply previously-generated optimized content.
# Reads the latest sklab-action comment on the PR, parses optimized blocks,
# writes each to its path, commits, and pushes to the PR head branch.

set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_EVENT_PATH:?}"
: "${GITHUB_OUTPUT:?}"
: "${GH_TOKEN:?}"
COMMENT_MARKER="${COMMENT_MARKER:-<!-- sklab-action -->}"

PR_NUMBER="$(jq -r '.issue.number // .pull_request.number // empty' "$GITHUB_EVENT_PATH")"
if [ -z "$PR_NUMBER" ]; then
  echo "::error::Cannot determine PR number — apply mode requires a PR context (pull_request or issue_comment event)"
  exit 1
fi

# Fetch all comments; take the latest with the marker.
comment_body="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" --paginate \
  --jq "[.[] | select(.body | contains(\"$COMMENT_MARKER\"))] | last | .body // empty")"

if [ -z "$comment_body" ]; then
  echo "::error::No sklab-action comment found on PR #$PR_NUMBER. Run '/optimize' first."
  exit 1
fi

# Extract optimized blocks. Python handles multiline content cleanly.
blocks_file="$(mktemp)"
printf '%s' "$comment_body" | python3 - "$blocks_file" <<'PY'
import json, re, sys

body = sys.stdin.read()
# Markers: <!-- sklab-optimized:<path> -->\n```markdown\n<content>\n```\n<!-- /sklab-optimized:<path> -->
pat = re.compile(
    r'<!--\s*sklab-optimized:(?P<path>[^>\s]+)\s*-->\s*'
    r'```(?:markdown)?\n'
    r'(?P<content>.*?)\n```\s*'
    r'<!--\s*/sklab-optimized:(?P=path)\s*-->',
    re.DOTALL,
)
blocks = [{"path": m.group("path"), "content": m.group("content")} for m in pat.finditer(body)]
with open(sys.argv[1], "w") as f:
    json.dump(blocks, f)
PY

count="$(jq 'length' "$blocks_file")"
if [ "$count" = "0" ]; then
  echo "::error::No optimized content blocks found in the latest sklab-action comment. Was the comment produced by 'mode: optimize'?"
  rm -f "$blocks_file"
  exit 1
fi

echo "Found $count optimized block(s) to apply."

# Write each block to its path.
jq -c '.[]' "$blocks_file" | while read -r block; do
  path="$(jq -r '.path' <<< "$block")"
  content="$(jq -r '.content' <<< "$block")"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  git add "$path"
  echo "  wrote $path"
done

# Anything to commit?
if git diff --cached --quiet; then
  echo "::notice::No file changes after writing optimized blocks (content already matches current tree)"
  echo "applied=false" >> "$GITHUB_OUTPUT"
  rm -f "$blocks_file"
  exit 0
fi

# Check fork status before attempting push.
head_repo="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq '.head.repo.full_name')"
head_ref="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq '.head.ref')"

if [ "$head_repo" != "$GITHUB_REPOSITORY" ]; then
  echo "::warning::PR is from a fork ($head_repo). Cannot push; optimized content stays in the review comment for manual application."
  git reset --hard HEAD
  echo "applied=false" >> "$GITHUB_OUTPUT"
  rm -f "$blocks_file"
  exit 0
fi

git config user.name "skill-lab[bot]"
git config user.email "action@skill-lab.dev"

paths_list="$(jq -r '.[].path | "- " + .' "$blocks_file")"
git commit -m "sklab: apply optimized SKILL.md

Applied via /apply-optimize on PR #$PR_NUMBER:
$paths_list"

if git push origin "HEAD:refs/heads/$head_ref"; then
  echo "applied=true" >> "$GITHUB_OUTPUT"
  echo "Pushed to $head_ref."
else
  echo "::warning::Push to $head_ref failed (insufficient permissions?). Content remains in the comment."
  echo "applied=false" >> "$GITHUB_OUTPUT"
fi

rm -f "$blocks_file"
