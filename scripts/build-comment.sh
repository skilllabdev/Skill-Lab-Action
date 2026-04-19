#!/usr/bin/env bash
# Render the unified results JSON into a PR-ready markdown comment.
# Reads $RESULTS_FILE; writes markdown to stdout.

set -euo pipefail

: "${RESULTS_FILE:?}"
: "${MODE:?}"
COMMENT_MARKER="${COMMENT_MARKER:-<!-- sklab-action -->}"

SOURCE="$(jq -r '.[0].source // "backend"' "$RESULTS_FILE")"
TOTAL_COST="$(jq -r '
  [.[] | (.judge.usage.cost // 0), (.optimize.usage.cost // 0)]
  | add // 0' "$RESULTS_FILE")"
TOTAL_TOKENS="$(jq -r '
  def t: (.tokens // ((.input_tokens // 0) + (.output_tokens // 0)));
  [.[] | (.judge.usage | t), (.optimize.usage | t)]
  | add // 0' "$RESULTS_FILE")"

badge_color() {
  awk -v s="$1" 'BEGIN {
    s += 0;
    if (s >= 90) print "brightgreen";
    else if (s >= 75) print "green";
    else if (s >= 60) print "yellow";
    else if (s >= 40) print "orange";
    else print "red";
  }'
}

badge() {
  local score="$1" label="$2" color label_enc
  color="$(badge_color "$score")"
  label_enc="$(printf '%s' "$label" | sed 's/-/--/g; s/_/__/g; s/ /%20/g')"
  printf '![%s](https://img.shields.io/badge/%s-%.1f-%s)' "$label" "$label_enc" "$score" "$color"
}

verdict_label() {
  awk -v s="$1" 'BEGIN {
    s += 0;
    if (s >= 85) print "Excellent";
    else if (s >= 70) print "Good";
    else if (s >= 55) print "Fair";
    else if (s >= 40) print "Poor";
    else print "Needs work";
  }'
}

# ---------- Header ----------
printf '%s\n' "$COMMENT_MARKER"
printf '## Skill-Lab Review\n\n'

# ---------- Summary table ----------
if [ "$MODE" = "check" ]; then
  printf '| Skill | Static | Security | Status |\n'
  printf '|-------|--------|----------|--------|\n'
else
  printf '| Skill | Static | Judge | Security | Status |\n'
  printf '|-------|--------|-------|----------|--------|\n'
fi

jq -c '.[]' "$RESULTS_FILE" | while read -r skill; do
  path="$(jq -r '.path' <<< "$skill")"
  static_score="$(jq -r '.static.quality_score // 0' <<< "$skill")"
  scan="$(jq -r '.security.scan_status // "ALLOW"' <<< "$skill")"
  overall_pass="$(jq -r '.gates.overall_pass' <<< "$skill")"
  err="$(jq -r '.error // empty' <<< "$skill")"

  if [ -n "$err" ]; then
    status="Error"
  elif [ "$overall_pass" = "true" ]; then
    status="Pass"
  else
    status="Fail"
  fi

  printf '| `%s` | %s | ' "$path" "$(badge "$static_score" "static")"
  if [ "$MODE" != "check" ]; then
    judge_score="$(jq -r '.judge.judge_score // "null"' <<< "$skill")"
    if [ "$judge_score" = "null" ] || [ -z "$judge_score" ]; then
      printf -- '— | '
    else
      printf '%s | ' "$(badge "$judge_score" "judge")"
    fi
  fi
  printf '%s | %s |\n' "$scan" "$status"
done

printf '\n'

# ---------- Per-skill details ----------
jq -c '.[]' "$RESULTS_FILE" | while read -r skill; do
  path="$(jq -r '.path' <<< "$skill")"
  skill_name="$(basename "$(dirname "$path")")"
  err="$(jq -r '.error // empty' <<< "$skill")"

  if [ -n "$err" ]; then
    printf '<details>\n<summary><b>%s</b> — Evaluation error</summary>\n\n' "$skill_name"
    printf '> %s\n\n' "$err"
    printf '</details>\n\n'
    continue
  fi

  static_score="$(jq -r '.static.quality_score // 0' <<< "$skill")"
  passed="$(jq -r '.static.passed // 0' <<< "$skill")"
  total="$(jq -r '.static.total // 0' <<< "$skill")"

  summary_line="$(printf 'Static: %.1f/100' "$static_score")"
  if [ "$MODE" != "check" ]; then
    judge_score="$(jq -r '.judge.judge_score // "null"' <<< "$skill")"
    if [ "$judge_score" != "null" ] && [ -n "$judge_score" ]; then
      verdict="$(verdict_label "$judge_score")"
      summary_line="$(printf '%s · Judge: %.1f/100 (%s)' "$summary_line" "$judge_score" "$verdict")"
    fi
  fi

  printf '<details>\n<summary><b>%s</b> — %s</summary>\n\n' "$skill_name" "$summary_line"

  # --- Static Checks ---
  printf '### Static Checks (%s/%s passed)\n\n' "$passed" "$total"
  dims="$(jq -r '.static.dimensions[]? | "| \(.name) | \(.passed) | \(.failed) |"' <<< "$skill")"
  if [ -n "$dims" ]; then
    printf '| Dimension | Passed | Failed |\n|-----------|--------|--------|\n'
    printf '%s\n\n' "$dims"
  fi

  # --- Failed Checks ---
  failed_count="$(jq -r '.static.failed_checks | length' <<< "$skill")"
  if [ "$failed_count" -gt 0 ]; then
    printf '### Failed Static Checks\n\n'
    printf '| Check | Severity | Message | Fix |\n|-------|----------|---------|-----|\n'
    jq -r '.static.failed_checks[] |
      "| `\(.check)` | \(.severity) | \(.message | gsub("\n"; " ") | gsub("\\|"; "\\|")) | \(.fix | gsub("\n"; " ") | gsub("\\|"; "\\|")) |"' <<< "$skill"
    printf '\n'
  fi

  # --- Judge ---
  if [ "$MODE" != "check" ]; then
    judge_score="$(jq -r '.judge.judge_score // "null"' <<< "$skill")"
    if [ "$judge_score" != "null" ] && [ -n "$judge_score" ]; then
      act="$(jq -r '.judge.activation_score // 0' <<< "$skill")"
      inst="$(jq -r '.judge.instruction_score // 0' <<< "$skill")"
      printf '### Judge Review — Activation Quality: %.1f · Instruction Quality: %.1f\n\n' "$act" "$inst"
      crits="$(jq -r '.judge.criteria[]? |
        "| \(.name // .criterion // "—") | \(.score // 0)/4 | \(.reasoning // "—" | gsub("\n"; " ") | gsub("\\|"; "\\|")) |"' <<< "$skill")"
      if [ -n "$crits" ]; then
        printf '| Criterion | Score | Reasoning |\n|-----------|-------|-----------|\n'
        printf '%s\n\n' "$crits"
      fi
      sugg_count="$(jq -r '.judge.suggestions | length' <<< "$skill")"
      if [ "$sugg_count" -gt 0 ]; then
        printf '### Suggestions\n\n'
        jq -r '.judge.suggestions[] | "- " + .' <<< "$skill"
        printf '\n'
      fi
    fi
  fi

  # --- Security (only if not ALLOW) ---
  scan="$(jq -r '.security.scan_status // "ALLOW"' <<< "$skill")"
  finds_count="$(jq -r '.security.findings | length' <<< "$skill")"
  if [ "$scan" != "ALLOW" ] && [ "$finds_count" -gt 0 ]; then
    printf '### Security Findings (%s)\n\n' "$scan"
    printf '| Location | Problem | Text |\n|----------|---------|------|\n'
    jq -r '.security.findings[] |
      "| \(.location // .line // "—") | \(.problem // .type // .rule // "—") | `\(.text // .match // "—" | gsub("\n"; " ") | gsub("\\|"; "\\|"))` |"' <<< "$skill"
    printf '\n'
  fi

  # --- Optimize ---
  if [ "$MODE" = "optimize" ]; then
    opt_content="$(jq -r '.optimize.optimized_content // ""' <<< "$skill")"
    if [ -n "$opt_content" ]; then
      orig="$(jq -r '.optimize.original_score // 0' <<< "$skill")"
      opt="$(jq -r '.optimize.optimized_score // 0' <<< "$skill")"
      delta="$(awk -v o="$orig" -v p="$opt" 'BEGIN { printf "%+.1f", p - o }')"
      printf '### Optimization\n\n'
      printf 'Before: **%.1f** → After: **%.1f** (%s)\n\n' "$orig" "$opt" "$delta"
      printf '<details>\n<summary>View optimized SKILL.md</summary>\n\n'
      printf '<!-- sklab-optimized:%s -->\n' "$path"
      printf '```markdown\n'
      printf '%s\n' "$opt_content"
      printf '```\n'
      printf '<!-- /sklab-optimized:%s -->\n\n' "$path"
      printf '</details>\n\n'
      printf 'Reply `/apply-optimize` to commit these changes.\n\n'
    fi
  fi

  printf '</details>\n\n'
done

# ---------- Footer ----------
printf -- '---\n'
if [ "$SOURCE" = "byok" ]; then
  if awk -v c="$TOTAL_COST" 'BEGIN { exit !(c+0 > 0) }'; then
    printf '<sub>Evaluated with Skill-Lab · Judge via BYOK · Cost ~$%.4f (%s tokens)</sub>\n' "$TOTAL_COST" "$TOTAL_TOKENS"
  else
    printf '<sub>Evaluated with Skill-Lab · BYOK mode</sub>\n'
  fi
else
  printf '<sub>Evaluated with Skill-Lab · Judge via api.skill-lab.dev (free tier)</sub>\n'
fi
