#!/usr/bin/env bash
# BYOK evaluation mode: installs skill-lab CLI and runs sklab against each skill.
# Called when $API_KEY is non-empty. Produces the same output shape as evaluate-backend.sh.

set -euo pipefail

: "${GITHUB_OUTPUT:?}"
: "${RUNNER_TEMP:?}"
: "${MODE:?}"
: "${PATHS:?}"
: "${API_KEY:?}"
MODEL="${MODEL:-claude-haiku-4-5-20251001}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-0}"
SECURITY_GATE="${SECURITY_GATE:-true}"
JUDGE_THRESHOLD="${JUDGE_THRESHOLD:-0}"
SPEC_ONLY="${SPEC_ONLY:-false}"
SKLAB_VERSION="${SKLAB_VERSION:-latest}"

# ---- map model prefix → provider env var ----
case "$MODEL" in
  claude-*|anthropic/*)    export ANTHROPIC_API_KEY="$API_KEY" ;;
  gpt-*|o1-*|o3-*|openai/*) export OPENAI_API_KEY="$API_KEY" ;;
  gemini-*|google/*)        export GEMINI_API_KEY="$API_KEY" ;;
  *)
    echo "::warning::Unknown model prefix '$MODEL'; defaulting API key to ANTHROPIC_API_KEY"
    export ANTHROPIC_API_KEY="$API_KEY"
    ;;
esac

# ---- install CLI once ----
echo "::group::Install skill-lab CLI"
if [ "$SKLAB_VERSION" = "latest" ]; then
  pip install --quiet --upgrade skill-lab
else
  pip install --quiet "skill-lab==$SKLAB_VERSION"
fi
sklab --version || true
echo "::endgroup::"

# ---- helpers: normalize sklab JSON to unified schema ----
# sklab output shape may not exactly match the backend; re-map defensively.

extract_static() {
  jq -c '{
    quality_score: (.quality_score // .score // 0),
    passed: (.checks_passed // .passed // 0),
    total: (.checks_run // .total // 0),
    overall_pass: (.overall_pass // false),
    dimensions: (
      (.results // .checks // [])
      | map(select(.dimension != "security"))
      | group_by(.dimension // "other")
      | map({
          name: (.[0].dimension // "other"),
          passed: (map(select(.passed == true)) | length),
          failed: (map(select(.passed == false)) | length)
        })
    ),
    failed_checks: (
      (.results // .checks // [])
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
  # Derive BLOCK/SUS/ALLOW from dimension="security" checks inside results[].
  jq -c '
    (.results // .checks // [] | map(select(.dimension == "security"))) as $sec
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
  # sklab embeds the rubric in .judge_review on the evaluate response.
  # Backend /judge returns it unwrapped. Handle both shapes.
  jq -c '(.judge_review // .judge // .) | {
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

run_sklab() {
  # Invoke sklab, capture stdout (JSON on success). Stderr goes to the runner log.
  sklab "$@" 2>&1
}

results='[]'
any_failed=false
total_tokens=0
total_cost=0

while IFS= read -r file_path; do
  [ -z "$file_path" ] && continue
  skill_dir="${file_path%/SKILL.md}"

  echo "::group::Evaluating $file_path (BYOK, $MODEL)"

  error_msg=""
  static='{}' ; security='{}' ; judge='{}' ; optimize='{}'

  # sklab's judge rubric lives inside `sklab evaluate` (controlled by --skip-review).
  # check mode:    evaluate --skip-review   — static + security only, no LLM
  # judge mode:    evaluate --model M       — static + security + judge in one call
  # optimize mode: evaluate --model M, then optimize --model M (two calls)
  eval_args=(evaluate --format json)
  [ "$SPEC_ONLY" = "true" ] && eval_args+=(--spec-only)
  if [ "$MODE" = "check" ]; then
    eval_args+=(--skip-review)
  else
    eval_args+=(--model "$MODEL")
  fi

  if eval_out=$(run_sklab "${eval_args[@]}" "$skill_dir"); then
    static=$(extract_static <<< "$eval_out")
    security=$(extract_security <<< "$eval_out")
    if [ "$MODE" != "check" ]; then
      judge=$(extract_judge <<< "$eval_out")
      t=$(jq -r '.usage.tokens // 0' <<< "$judge"); total_tokens=$((total_tokens + t))
      c=$(jq -r '.usage.cost // 0'   <<< "$judge"); total_cost=$(awk -v a="$total_cost" -v b="$c" 'BEGIN{print a+b}')
    fi
  else
    error_msg="sklab evaluate failed: $(printf '%s' "$eval_out" | head -c 2000)"
  fi

  if [ -z "$error_msg" ] && [ "$MODE" = "optimize" ]; then
    if opt_out=$(run_sklab optimize --format json --model "$MODEL" "$skill_dir"); then
      optimize=$(extract_optimize <<< "$opt_out")
      t=$(jq -r '.usage.tokens // 0' <<< "$optimize"); total_tokens=$((total_tokens + t))
      c=$(jq -r '.usage.cost // 0'   <<< "$optimize"); total_cost=$(awk -v a="$total_cost" -v b="$c" 'BEGIN{print a+b}')
    else
      error_msg="sklab optimize failed: $(printf '%s' "$opt_out" | head -c 2000)"
    fi
  fi

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
    --arg source "byok" --arg error "$error_msg" \
    --argjson static "$static" --argjson security "$security" \
    --argjson judge "$judge" --argjson optimize "$optimize" \
    --argjson gates "$gates" '{
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
lite=$(jq -c 'map(.optimize |= (del(.optimized_content)))' <<< "$results")

cost_label=$(awk -v c="$total_cost" -v t="$total_tokens" 'BEGIN{printf "~$%.4f (%d tokens)", c, t}')

{
  echo "results<<SKLAB_EOF"
  echo "$lite"
  echo "SKLAB_EOF"
  echo "results-file=$results_file"
  echo "any-failed=$any_failed"
  echo "total-cost=$cost_label"
} >> "$GITHUB_OUTPUT"

echo "BYOK evaluation complete: any_failed=$any_failed, cost=$cost_label"
