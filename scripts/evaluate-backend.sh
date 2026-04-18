#!/usr/bin/env bash
# Backend evaluation mode: calls api.skill-lab.dev endpoints and
# normalizes the response into the unified results schema.
#
# Called when $API_KEY is empty. Produces:
#   $GITHUB_OUTPUT: results (lite JSON), results-file (path), any-failed, total-cost

set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_OUTPUT:?}"
: "${RUNNER_TEMP:?}"
: "${MODE:?}"
: "${PATHS:?PATHS JSON array must be set}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-0}"
SECURITY_GATE="${SECURITY_GATE:-true}"
JUDGE_THRESHOLD="${JUDGE_THRESHOLD:-0}"
SPEC_ONLY="${SPEC_ONLY:-false}"
BASE_URL="${SKLAB_API_BASE:-https://api.skill-lab.dev}"

OWNER="${GITHUB_REPOSITORY%%/*}"
REPO="${GITHUB_REPOSITORY##*/}"

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

# Shape-normalizing extractors. All defensive: backend may return partial fields.
extract_static() {
  # Security-dimension checks are surfaced via extract_security; exclude them
  # from failed_checks to avoid rendering the same row twice in the comment.
  jq -c '{
    quality_score: (.quality_score // 0),
    passed: (.checks_passed // 0),
    total: (.checks_run // 0),
    overall_pass: (.overall_pass // false),
    dimensions: (
      (.results // [])
      | map(select(.dimension != "security"))
      | group_by(.dimension // "other")
      | map({
          name: (.[0].dimension // "other"),
          passed: (map(select(.passed == true)) | length),
          failed: (map(select(.passed == false)) | length)
        })
    ),
    failed_checks: (
      (.results // [])
      | map(select(.passed == false and .dimension != "security"))
      | map({
          check: (.check_id // .check_name // .name // "unknown"),
          severity: (.severity // "info"),
          message: (.message // .description // ""),
          fix: (.fix // .details.suggestion // .suggestion // "")
        })
    )
  }'
}

extract_security() {
  # The API represents security as five checks inside results[] tagged
  # dimension="security". Derive a BLOCK/SUS/ALLOW verdict from them:
  #   BLOCK if any high-severity security check failed
  #   SUS   if any security check failed (non-high)
  #   ALLOW otherwise
  jq -c '
    (.results // [] | map(select(.dimension == "security"))) as $sec
    | ($sec | map(select(.passed == false and .severity == "high"))) as $high
    | ($sec | map(select(.passed == false))) as $failed
    | {
        scan_status: (if ($high | length) > 0 then "BLOCK"
                      elif ($failed | length) > 0 then "SUS"
                      else "ALLOW" end),
        findings: ($failed | map({
          location: (.check_id),
          problem: (.check_name // .check_id),
          text: (.message // ""),
          severity: .severity,
          details: (.details // {})
        }))
      }'
}

extract_judge() {
  jq -c '{
    judge_score: (.judge_score // 0),
    activation_score: (.activation_score // 0),
    instruction_score: (.instruction_score // 0),
    verdict: (.verdict // ""),
    criteria: (.criteria // []),
    suggestions: (.suggestions // []),
    usage: (.usage // {})
  }'
}

extract_optimize() {
  jq -c '{
    original_score: (.original_score // 0),
    optimized_score: (.optimized_score // 0),
    original_failures: (.original_failures // 0),
    optimized_failures: (.optimized_failures // 0),
    optimized_content: (.optimized_content // ""),
    usage: (.usage // {})
  }'
}

call_api() {
  local method="$1" url="$2" body="${3:-}"
  local out http_code
  out=$(mktemp)
  if [ "$method" = "GET" ]; then
    http_code=$(curl -sS -o "$out" -w '%{http_code}' "$url" || echo "000")
  else
    http_code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
      -H 'content-type: application/json' -d "${body:-{}}" "$url" || echo "000")
  fi
  if [ "$http_code" = "429" ]; then
    echo "::error::api.skill-lab.dev rate-limited this request (HTTP 429). Consider adding 'api-key' for BYOK mode."
    cat "$out" >&2
    rm -f "$out"
    return 1
  fi
  if [ "$http_code" = "000" ] || [ "$http_code" -ge 500 ] 2>/dev/null; then
    echo "::error::api.skill-lab.dev unreachable or errored (HTTP $http_code). Consider 'api-key' for BYOK fallback."
    cat "$out" >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
  [ "$http_code" -lt 400 ]
}

results='[]'
any_failed=false

# Iterate paths.
while IFS= read -r file_path; do
  [ -z "$file_path" ] && continue
  skill_dir="${file_path%/SKILL.md}"
  enc_path="$(urlencode "$skill_dir")"
  qs="path=$enc_path"
  [ "$SPEC_ONLY" = "true" ] && qs="$qs&spec_only=true"

  echo "::group::Evaluating $file_path"

  error_msg=""
  static='{}' ; security='{}' ; judge='{}' ; optimize='{}'

  # ---- evaluate (static + security) ----
  if eval_resp=$(call_api GET "$BASE_URL/v1/repos/$OWNER/$REPO/evaluate?$qs"); then
    static=$(extract_static <<< "$eval_resp")
    security=$(extract_security <<< "$eval_resp")
  else
    error_msg="evaluate call failed"
  fi

  # ---- judge (if mode requires LLM) ----
  if [ -z "$error_msg" ] && [ "$MODE" != "review" ]; then
    if judge_resp=$(call_api POST "$BASE_URL/v1/repos/$OWNER/$REPO/judge?$qs" '{}'); then
      judge=$(extract_judge <<< "$judge_resp")
    else
      error_msg="judge call failed"
    fi
  fi

  # ---- optimize (optimize mode only) ----
  if [ -z "$error_msg" ] && [ "$MODE" = "optimize" ]; then
    if opt_resp=$(call_api POST "$BASE_URL/v1/repos/$OWNER/$REPO/optimize?$qs" '{}'); then
      optimize=$(extract_optimize <<< "$opt_resp")
    else
      error_msg="optimize call failed"
    fi
  fi

  # ---- gates ----
  gates=$(jq -nc \
    --arg ft "$FAIL_THRESHOLD" --arg jt "$JUDGE_THRESHOLD" --arg sg "$SECURITY_GATE" \
    --argjson static "$static" --argjson security "$security" --argjson judge "$judge" '
      def ft_pass: ($ft | tonumber) == 0 or (($static.quality_score // 0) >= ($ft | tonumber));
      def sg_pass: $sg != "true" or (($security.scan_status // "ALLOW") != "BLOCK");
      def jt_pass: ($jt | tonumber) == 0 or (($judge.judge_score // 0) >= ($jt | tonumber));
      { static_pass: ft_pass, security_pass: sg_pass, judge_pass: jt_pass,
        overall_pass: (ft_pass and sg_pass and jt_pass) }')

  result=$(jq -nc \
    --arg path "$file_path" --arg skill_dir "$skill_dir" --arg mode "$MODE" \
    --arg source "backend" \
    --arg error "$error_msg" \
    --argjson static "$static" --argjson security "$security" \
    --argjson judge "$judge" --argjson optimize "$optimize" \
    --argjson gates "$gates" '
    {
      path: $path, skill_dir: $skill_dir, mode: $mode, source: $source,
      static: $static, security: $security, judge: $judge, optimize: $optimize,
      gates: $gates,
      error: (if $error == "" then null else $error end)
    }')

  results=$(jq -c --argjson r "$result" '. + [$r]' <<< "$results")
  overall=$(jq -r '.overall_pass' <<< "$gates")
  [ "$overall" != "true" ] && any_failed=true

  echo "::endgroup::"
done < <(jq -r '.[]' <<< "$PATHS")

results_file="$RUNNER_TEMP/sklab-results.json"
echo "$results" > "$results_file"

# Lite version (strip large optimized_content) for action output.
lite=$(jq -c 'map(.optimize |= (del(.optimized_content)))' <<< "$results")

{
  echo "results<<SKLAB_EOF"
  echo "$lite"
  echo "SKLAB_EOF"
  echo "results-file=$results_file"
  echo "any-failed=$any_failed"
  echo "total-cost=free (backend tier)"
} >> "$GITHUB_OUTPUT"

echo "Backend evaluation complete: any_failed=$any_failed"
