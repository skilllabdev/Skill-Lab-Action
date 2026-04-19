# Skill-Lab Action

Evaluate, judge, and optimize agent skills (`SKILL.md` files) in pull requests.
A single composite GitHub Action that runs static checks, a security scan, an
LLM-as-judge rubric, or an LLM rewrite — and posts the results as a PR comment.

[Skill-Lab](https://skill-lab.dev) is the evaluation framework; this action is
the GitHub front door to it.

## Why use this

- **Zero-config.** The default mode calls `api.skill-lab.dev`, which absorbs
  the LLM cost. No API key, no installation, no billing to wire up.
- **Escape hatch for privacy.** Supply an `api-key` and the action switches to
  BYOK mode: it installs the OSS [`skill-lab`](https://pypi.org/project/skill-lab/)
  CLI on the runner and uses your key / model of choice.
- **Three modes.** `check` (static + security), `judge` (adds LLM rubric),
  `optimize` (adds a rewrite proposal).
- **Slash-command optimize flow.** `/optimize` triggers a rewrite; reviewers
  can tweak the proposed content inside the PR comment; `/apply-optimize`
  commits it.
- **Single PR comment.** Upserted via an HTML marker — no comment spam.

## Quick start

```yaml
# .github/workflows/skill-review.yml
name: Skill Review
on:
  pull_request:
    paths: ['**/SKILL.md']
permissions:
  pull-requests: write
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: skilllabdev/skill-lab-action@v1
        with:
          mode: judge
```

That's the whole thing — drop it in, open a PR that touches a `SKILL.md` file,
and you'll get an evaluation comment.

## Modes

| Mode | What runs | LLM? | Trigger pattern |
|------|-----------|------|-----------------|
| `check`    | static checks + security scan | no | `pull_request` on `**/SKILL.md` |
| `judge`    | static + security + 8-criterion LLM rubric | yes | `pull_request` on `**/SKILL.md` |
| `optimize` | judge + LLM rewrite proposal | yes | `/optimize` comment |
| `apply`    | writes optimized content from last comment, commits, pushes | no | `/apply-optimize` comment |

### Mode → CLI mapping

In BYOK mode the action shells out to the `sklab` CLI. The mapping is:

| Action `mode` | Equivalent BYOK command | Backend endpoint |
|---------------|-------------------------|------------------|
| `check`       | `sklab evaluate --skip-review` (full 37-check static + security, no LLM) | `GET /v1/repos/:o/:r/evaluate` |
| `judge`       | `sklab evaluate --model <model>` (static + security + LLM rubric in one call) | `GET /evaluate` + `POST /judge` |
| `optimize`    | `sklab evaluate --model <model>` + `sklab optimize --model <model>` | `GET /evaluate` + `POST /judge` + `POST /optimize` |
| `apply`       | no CLI equivalent — parses the last sklab-action comment and commits | no backend call |

Note: `mode: check` is **not** `sklab check` — the CLI's `check` subcommand runs only HIGH-severity checks as a fast pre-flight. The action's `check` mode runs the full static + security pipeline, matching `sklab evaluate --skip-review`.

## Inputs

| Name | Default | Description |
|------|---------|-------------|
| `mode` | `check` | `check`, `judge`, `optimize`, or `apply`. See [mode → CLI mapping](#mode--cli-mapping) below. |
| `fail-threshold` | `0` | Minimum static quality score (0–100) to pass. `0` = informational only. |
| `security-gate` | `true` | Fail the check when the security scan returns `BLOCK`. |
| `judge-threshold` | `0` | Minimum judge score (0–100) to pass. `0` = informational only. |
| `spec-only` | `false` | Skip quality-suggestion checks; run only spec-required ones. |
| `api-key` | `""` | If set, switches to BYOK — installs the CLI and uses your key. If empty, calls `api.skill-lab.dev` (free tier). |
| `model` | `claude-haiku-4-5-20251001` | LLM model (BYOK only). Prefix determines which provider env var is set: `claude-*` → `ANTHROPIC_API_KEY`, `gpt-*`/`o1-*`/`o3-*` → `OPENAI_API_KEY`, `gemini-*` → `GEMINI_API_KEY`. |
| `comment` | `true` | Post / update a PR comment with results. |
| `sklab-version` | `latest` | Pin the CLI version (BYOK only). |
| `max-skills` | `10` | Cap the number of skills processed per run. |
| `path` | `""` | Evaluate this skill explicitly (e.g. `skills/my-skill`). Overrides auto-detection — used by the slash-command workflows below. |
| `github-token` | `${{ github.token }}` | Token used for `gh api` calls and the `apply` commit. |

## Outputs

| Name | Type | Description |
|------|------|-------------|
| `results` | JSON string | Array of per-skill results (see schema below). `optimize.optimized_content` is stripped to fit GitHub's step-output size limit — use `results-file` for the full payload. |
| `any-failed` | `'true'`/`'false'` | Any skill failed any gate. |
| `skills-count` | integer | Number of skills processed. |
| `total-cost` | string | `"free (backend tier)"` or `"~$0.0043 (1200 tokens)"` for BYOK. |
| `applied` | `'true'`/`'false'` | `apply` mode only — did a commit actually land on the PR branch. |

### Results schema

```jsonc
[
  {
    "path": "skills/my-skill/SKILL.md",
    "skill_dir": "skills/my-skill",
    "mode": "judge",
    "source": "backend",
    "static":   { "quality_score": 87.5, "passed": 30, "total": 37, "dimensions": [...], "failed_checks": [...] },
    "security": { "scan_status": "ALLOW", "findings": [] },
    "judge":    { "judge_score": 78.5, "activation_score": 82, "instruction_score": 75, "verdict": "...", "criteria": [...], "suggestions": [...], "usage": {...} },
    "optimize": { "original_score": 78.5, "optimized_score": 88.5, "original_failures": 4, "optimized_failures": 1, "optimized_content": "...", "usage": {...} },
    "gates":    { "static_pass": true, "security_pass": true, "judge_pass": true, "overall_pass": true },
    "error":    null
  }
]
```

Fields that weren't computed for the mode (e.g. `judge` in `check` mode) are `{}`.

## Example workflows

### 1. Check on every PR

```yaml
name: Skill Check
on:
  pull_request:
    paths: ['**/SKILL.md']
permissions:
  pull-requests: write
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: skilllabdev/skill-lab-action@v1
        with:
          mode: check
          fail-threshold: 75
          security-gate: true
```

### 2. `/optimize` slash command

```yaml
name: Skill Optimize
on:
  issue_comment:
    types: [created]

permissions:
  pull-requests: write
  contents: read

jobs:
  optimize:
    if: >-
      github.event.issue.pull_request &&
      startsWith(github.event.comment.body, '/optimize')
    runs-on: ubuntu-latest
    steps:
      - name: Extract path argument (optional)
        id: args
        env:
          BODY: ${{ github.event.comment.body }}
        run: |
          # "/optimize skills/my-skill" → skills/my-skill. Empty → evaluate every changed SKILL.md.
          path="$(printf '%s' "$BODY" | awk '{print $2}')"
          echo "path=${path:-}" >> "$GITHUB_OUTPUT"

      - name: Check out PR head
        uses: actions/checkout@v4
        with:
          ref: refs/pull/${{ github.event.issue.number }}/head

      - uses: skilllabdev/skill-lab-action@v1
        with:
          mode: optimize
          path: ${{ steps.args.outputs.path }}
```

The action posts a collapsible diff in the PR comment. Reviewers can edit the
proposed content inside the markdown code block before applying.

### 3. `/apply-optimize` slash command

```yaml
name: Skill Apply Optimized
on:
  issue_comment:
    types: [created]

permissions:
  pull-requests: write
  contents: write

jobs:
  apply:
    if: >-
      github.event.issue.pull_request &&
      startsWith(github.event.comment.body, '/apply-optimize')
    runs-on: ubuntu-latest
    steps:
      - name: Get PR head ref
        id: pr
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ref=$(gh api "repos/$GITHUB_REPOSITORY/pulls/${{ github.event.issue.number }}" --jq '.head.ref')
          echo "ref=$ref" >> "$GITHUB_OUTPUT"

      - uses: actions/checkout@v4
        with:
          ref: ${{ steps.pr.outputs.ref }}
          token: ${{ secrets.GITHUB_TOKEN }}

      - uses: skilllabdev/skill-lab-action@v1
        with:
          mode: apply
```

### 4. BYOK (bring your own LLM key)

```yaml
jobs:
  judge:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: skilllabdev/skill-lab-action@v1
        with:
          mode: judge
          api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          model: claude-sonnet-4-6
```

### 5. Full pipeline — judge gates the PR, optimize runs on demand

Combine workflows 1 + 2 + 3 in the same repo. The review workflow gates the PR
merge; `/optimize` generates a rewrite proposal when requested; `/apply-optimize`
lands it on the branch.

### 6. Headless (no comment, exit code only)

```yaml
      - uses: skilllabdev/skill-lab-action@v1
        with:
          mode: check
          comment: false
          fail-threshold: 70
```

## Troubleshooting

- **Fork PRs can't post comments.** `GITHUB_TOKEN` is read-only on fork PRs, so
  the action falls back to `$GITHUB_STEP_SUMMARY`. The evaluation still runs;
  reviewers see it in the job summary panel.
- **Backend 429 / unreachable.** The action prints the error and suggests
  adding `api-key: ${{ secrets.ANTHROPIC_API_KEY }}` for BYOK fallback. Pair
  the two patterns with `continue-on-error` + a second step if you want
  automatic failover.
- **`/apply-optimize` says "no blocks found".** The latest `<!-- sklab-action -->`
  comment on the PR doesn't contain `<!-- sklab-optimized:... -->` markers — run
  `/optimize` first.
- **Apply doesn't commit.** Ensure the caller workflow has
  `permissions: { contents: write }` and checks out the PR head branch (not the
  detached ref). See example 3 above.
- **Monorepo with lots of skills.** Bump `max-skills` (default 10) and set
  `paths-ignore` on the workflow to skip non-skill file changes.

## Development

Scripts live in `scripts/` and are composed by `action.yml` — no Docker, no
Node, just `bash` + `jq` + `gh` (preinstalled on GitHub runners) + `python3`
(for the apply-mode regex).

Self-tests run in `.github/workflows/test.yml` against `tests/fixtures/`:

- `good-skill/` — expected to pass all gates
- `bad-skill/` — low static score (informational)
- `malicious-skill/` — expected to trigger a security `BLOCK`

To debug locally, export the env vars each script requires and run it directly,
or invoke the action against a branch in your own repo:

```yaml
- uses: skilllabdev/skill-lab-action@main   # or any branch / SHA
  with:
    mode: check
    path: tests/fixtures/good-skill
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
