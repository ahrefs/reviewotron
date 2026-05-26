# Reviewotron

An agentic code review bot that uses Claude AI to review GitHub pull requests and push events. It posts inline review comments on PRs, commit comments on pushes to `develop`, and sends Slack notifications.

Reviewotron includes a **multi-agent security analysis pipeline** that detects injection, XSS, command injection, authentication, authorization, and SSRF vulnerabilities. Security findings go through adversarial validation before being reported, keeping noise low.

## Table of Contents

- [How It Works](#how-it-works)
- [Setup](#setup)
- [Configuration](#configuration)
- [Security Review Pipeline](#security-review-pipeline)
- [Slack Integration](#slack-integration)
- [State and Persistence](#state-and-persistence)
- [CLI Usage](#cli-usage)
- [Cost Tracking](#cost-tracking)
- [Limitations](#limitations)
- [Known Issues](#known-issues)
- [Troubleshooting](#troubleshooting)

---

## How It Works

Reviewotron runs as an HTTP server that receives GitHub webhook events. It can review on PR open/update, on pushes to `develop`, or when someone posts a `REVIEW` comment on a PR. **All triggers are off by default** — see [Defaults](#defaults) below.

For each enabled trigger, the bot:

1. **Receives the webhook** at the `/github` endpoint
2. **Validates the signature** using the configured webhook secret (HMAC-SHA256)
3. **Fetches the repo config** from `.reviewotron.json` in the repo (via GitHub API), or uses defaults
4. **Fetches the diff** for the PR or push (for `REVIEW` comments, also fetches the full PR via the API to recover `head.sha`, since `issue_comment` webhooks don't carry it)
5. **Filters the diff** — removes ignored paths, checks size limits
6. **Runs review plugins** concurrently:
   - **General review** — Claude analyzes the diff for bugs, style, logic, performance, etc.
   - **Security review** — A multi-agent pipeline scans for vulnerabilities (see [below](#security-review-pipeline))
7. **Posts results**:
   - PR events: a single GitHub PR review with inline comments
   - Push events: commit comments for critical/warning findings + a Slack message
   - `REVIEW` comments: same as PR events

### Event Flow

```
GitHub Webhook (POST /github)
    │
    ├─ Signature validation (HMAC-SHA256)
    ├─ Event parsing (pull_request, push, or issue_comment)
    ├─ Config fetch from .reviewotron.json
    ├─ Diff fetch + filtering
    │
    ├─ General Review Plugin (Claude Sonnet)
    │     └─ Structured output: summary + findings
    │
    ├─ Security Review Plugin (multi-agent)
    │     ├─ Triage Agent (Haiku) → route signals
    │     ├─ Analysis Agents (Sonnet, parallel) → candidate findings
    │     ├─ Validator Agent (Sonnet) → confirm/reject
    │     └─ Memory Curator (Haiku, async) → update memory
    │
    ├─ Merge + deduplicate findings
    │
    └─ Post results
          ├─ PR → GitHub PR review (inline comments)
          └─ Push → commit comments + Slack notification
```

### Supported GitHub Events

| Event | Trigger | Gated by | Output |
|-------|---------|----------|--------|
| `pull_request` (opened, reopened, ready_for_review) | PR opened, reopened, or marked ready | `auto_review_pr_open` | GitHub PR review with inline comments |
| `pull_request` (synchronize) | New commits pushed to a PR | `auto_review_pr_sync` | GitHub PR review with inline comments |
| `push` (to `refs/heads/develop`) | Code pushed to develop | `review_pushes_to_develop` | Commit comments + Slack message |
| `issue_comment` (created, on a PR, body equals `REVIEW`) | Manual trigger via PR comment | `auto_review_on_comment` | GitHub PR review with inline comments |

The `REVIEW` trigger is exact-match: the comment body must equal the literal string `REVIEW` after trimming whitespace. Anything else (including `REVIEW please` or quoted text) is ignored silently. The bot must have the `pull_request` GitHub App permission and the **Issue comment** webhook event subscribed.

Events are processed asynchronously — the webhook returns `200 accepted` immediately, and the review runs in the background.

### Defaults

**All four automatic-review triggers default to `false`.** A repo without a `.reviewotron.json` (or one that doesn't set the relevant flags) receives no reviews. Opt in via `.reviewotron.json`:

| Flag | Effect when `true` |
|------|--------------------|
| `auto_review_pr_open` | Review PRs on open / reopen / ready-for-review |
| `auto_review_pr_sync` | Review PRs when new commits land on them |
| `review_pushes_to_develop` | Review pushes to the `develop` branch |
| `auto_review_on_comment` | Review when someone posts a `REVIEW` comment on a PR |

Manual `REVIEW` comments bypass the dedup that protects the automatic flow from re-reviewing the same head SHA — by design, since the manual trigger means the user wants a fresh review.

---

## Setup

### Prerequisites

- OCaml toolchain with opam
- An Anthropic API key
- A GitHub personal access token (or GitHub App installation) for each repo
- (Optional) A Slack bot token for push notifications

### Build

```bash
make build        # Build the project
make test         # Run tests
make fmt          # Format code
make clean        # Clean build artifacts
```

### Secrets File

Create a `secrets.json` file (see `secrets.json.example`):

```json
{
  "repos": [
    {
      "url": "https://github.com/org/repo",
      "gh_token": "ghp_xxxxxxxxxxxx",
      "gh_hook_secret": "your-webhook-secret"
    }
  ],
  "anthropic_api_key": "sk-ant-xxxxxxxxxxxx",
  "slack_access_token": "xoxb-xxxxxxxxxxxx"
}
```

**Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `repos` | Yes | List of repositories to monitor |
| `repos[].url` | Yes | Full GitHub repository URL (e.g. `https://github.com/org/repo`) |
| `repos[].gh_token` | Yes* | GitHub personal access token with `repo` scope |
| `repos[].gh_hook_secret` | No | Webhook secret for HMAC signature validation |
| `repos[].auth` | Yes* | Alternative to `gh_token` — GitHub App installation auth (see below) |
| `anthropic_api_key` | Yes | Anthropic API key for Claude |
| `slack_access_token` | No | Slack bot token for posting messages |

*Either `gh_token` or `auth` must be set per repo. Using `gh_token` is the simpler option.

For local-only `review-diff` usage, `repos` may be an empty list as long as the
secrets file still provides `anthropic_api_key`. The webhook server still
requires at least one configured repo by default.

#### GitHub App Installation Auth

Instead of a personal access token, you can authenticate as a GitHub App installation:

```json
{
  "repos": [
    {
      "url": "https://github.com/org/repo",
      "auth": [
        "AppInstallation",
        {
          "installation_id": "12345678",
          "client_id": "Iv1.xxxxxxxxxx",
          "pem": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----"
        }
      ],
      "gh_hook_secret": "your-webhook-secret"
    }
  ]
}
```

App installation tokens are automatically refreshed and cached (55-minute TTL).

### GitHub Webhook

Configure a webhook in your GitHub repository settings:

| Setting | Value |
|---------|-------|
| Payload URL | `https://your-server:1338/github` |
| Content type | `application/json` |
| Secret | Same value as `gh_hook_secret` in secrets.json |
| Events | Select **Pull requests** and **Pushes** |

### Start the Server

```bash
./reviewotron run --port 1338 --secrets secrets.json --state state.json
```

Verify it's running:

```bash
curl http://localhost:1338/ping
```

---

## Configuration

Each repo can have a `.reviewotron.json` file in its root. For GitHub webhooks, this is fetched from the repo via the GitHub Contents API on each event. For local `review-diff`, the same file is loaded from the local review root. If the file doesn't exist, defaults are used.

### Full Configuration Reference

```json
{
  "max_diff_lines": 2000,
  "max_files": 50,
  "max_tokens_per_review": 100000,
  "model": "claude-sonnet-4-6",
  "ignored_paths": ["*.test.js", "vendor/"],
  "ignored_authors": ["dependabot[bot]"],
  "auto_review_pr_open": false,
  "auto_review_pr_sync": false,
  "review_pushes_to_develop": false,
  "auto_review_on_comment": false,
  "review_draft_prs": false,
  "system_prompt_override": null,
  "slack_channel": "#code-reviews",
  "show_review_cost": false,
  "review_plugins": {
    "general": {
      "enabled": true,
      "system_prompt_override": null
    },
    "security": {
      "enabled": false,
      "vuln_classes": ["injection", "xss", "command_injection", "authn", "authz", "ssrf"],
      "triage_model_tier": "fast",
      "analysis_model_tier": "standard",
      "validator_model_tier": "standard",
      "confidence_threshold": "medium",
      "memory_max_tokens": 5000
    }
  }
}
```

### Config Fields

| Field | Default | Description |
|-------|---------|-------------|
| `max_diff_lines` | `2000` | Maximum total diff lines to review. PRs exceeding this are skipped. |
| `max_files` | `50` | Maximum files (currently used for informational purposes). |
| `max_tokens_per_review` | `100000` | Token budget hint for the review agent. |
| `model` | `claude-sonnet-4-6` | Model ID for the general review agent. |
| `ignored_paths` | `[]` | Glob patterns for files to exclude from review. Supports `*` and `**` wildcards. |
| `ignored_authors` | `[]` | GitHub usernames whose PRs/pushes should be skipped. |
| `auto_review_pr_open` | `false` | Review PRs when they are opened, reopened, or marked ready. |
| `auto_review_pr_sync` | `false` | Review PRs when new commits are pushed to them. |
| `review_pushes_to_develop` | `false` | Review pushes to the `develop` branch. |
| `auto_review_on_comment` | `false` | Review when someone posts a top-level PR comment whose body is exactly `REVIEW` (after trimming). Requires the GitHub App to subscribe to **Issue comment** events. |
| `review_draft_prs` | `false` | Include draft PRs in automatic reviews. By default drafts are skipped regardless of `auto_review_pr_open` / `auto_review_pr_sync`. |
| `system_prompt_override` | `null` | Replace the default general review system prompt entirely. |
| `slack_channel` | `null` | Slack channel for push review notifications. Requires `slack_access_token` in secrets. |
| `show_review_cost` | `false` | Append a cost summary footer to PR reviews. |
| `review_plugins` | (see below) | Per-plugin configuration. |

### Plugin Configuration

#### General Plugin

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `true` | Enable/disable the general code review. |
| `system_prompt_override` | `null` | Override the general review prompt (plugin-level). |

#### Security Plugin

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `false` | Enable/disable security analysis. |
| `vuln_classes` | All 6 classes | Which vulnerability types to scan for. |
| `triage_model_tier` | `"fast"` | Model tier for the triage agent. |
| `analysis_model_tier` | `"standard"` | Model tier for per-class analysis agents. |
| `validator_model_tier` | `"standard"` | Model tier for the adversarial validator. |
| `confidence_threshold` | `"medium"` | Minimum triage confidence to trigger analysis. `"high"` = only high-confidence signals. `"medium"` = high + medium. `"low"` = all signals. **Note:** signals whose vuln class is explicitly listed in `vuln_classes` always pass through regardless of this threshold. |
| `memory_max_tokens` | `5000` | Target size limit for the repo's security memory file. |

#### Model Tiers

| Tier | Model | Typical Use |
|------|-------|-------------|
| `"fast"` | `claude-haiku-4-5-20251001` | Triage, memory curator |
| `"standard"` | `claude-sonnet-4-6` | Analysis agents, validator, general review |
| `"strong"` | `claude-opus-4-6` | Reserved for complex codebases |

#### Vulnerability Classes

| Value | Description |
|-------|-------------|
| `"injection"` | SQL injection, NoSQL injection, query string construction |
| `"xss"` | Cross-site scripting (reflected, stored, DOM-based) |
| `"command_injection"` | OS command injection via exec/system/popen |
| `"authn"` | Authentication bypass, weak token validation, missing expiry |
| `"authz"` | Authorization flaws, IDOR, missing permission checks |
| `"ssrf"` | Server-side request forgery via user-controlled URLs |

### Skip Behavior

Reviewotron skips events in these cases:

- **Bot senders** — any login ending in `[bot]`
- **Ignored authors** — usernames in the `ignored_authors` list
- **Non-reviewable actions** — PR closed, edited, or other non-code-change actions
- **Draft PRs** — skipped until marked ready
- **Already reviewed** — same PR + head SHA (or same push after SHA) already processed
- **Empty diff** — all files filtered by `ignored_paths`
- **Diff too large** — exceeds `max_diff_lines`
- **Non-develop pushes** — only `refs/heads/develop` is reviewed

---

## Security Review Pipeline

When the security plugin is enabled, every diff goes through a multi-agent pipeline:

### 1. Triage (Haiku, single-shot)

Scans the diff for security-relevant patterns and classifies them by vulnerability type. This is intentionally biased toward **over-flagging** — it's cheap to run an analysis agent that finds nothing, costly to miss a real issue.

The triage agent outputs signals with confidence levels (`high`, `medium`, `low`). The `confidence_threshold` config controls which signals proceed to analysis.

### 2. Analysis (Sonnet, per vulnerability class, parallel)

For each flagged vulnerability class, a specialized agent runs deep analysis:

1. **Source identification** — Where does user-controlled input enter?
2. **Sink identification** — Where does data reach a dangerous operation?
3. **Data flow tracing** — Can the source reach the sink? Traces through variables, function calls, returns.
4. **Sanitization evaluation** — Is there adequate, context-correct sanitization on the path?

Analysis agents can fetch additional files from the repo via the GitHub Contents API when they need to trace a data flow beyond the diff.

### 3. Validation (Sonnet, adversarial)

All candidate findings from all analysis agents pass through a single validator agent. It acts as an adversarial false-positive filter, checking:

- The claimed source actually accepts external input
- The claimed sink actually performs the dangerous operation
- Every step in the flow path is backed by evidence (file + line)
- The sanitization assessment is correct

**Findings that fail validation are dropped.** This is by design — a noisy security reviewer that cries wolf loses developer trust. Dropped findings are logged for offline prompt tuning.

### 4. Memory Curation (Haiku, async)

After the review is posted, a curator agent runs asynchronously to update the repo's security memory with learnings from the review. This is fire-and-forget — it doesn't block the review.

### Severity Mapping

| Analysis Confidence | Post-Validation Severity |
|---------------------|--------------------------|
| High + Confirmed | Critical |
| Medium + Confirmed | Warning |
| Low + Confirmed | Warning |

---

## Slack Integration

Push reviews (to `develop`) optionally send a Slack notification. This requires:

1. A `slack_access_token` in `secrets.json` — a Slack bot token (`xoxb-...`) with `chat:write` permission
2. A `slack_channel` set in the repo's `.reviewotron.json`

The message includes:
- Pusher name and commit count
- Link to the compare view on GitHub
- Review summary text
- Finding counts (critical, warnings, suggestions)
- Color-coded: red if any critical findings, green otherwise

If the security plugin encountered an error, a note is appended to the Slack message.

If `slack_access_token` is not configured, Slack posting is silently skipped.

---

## State and Persistence

### State File

The `--state` flag enables persistent state tracking. The state file (JSON) records:

- **PR reviews**: repo URL, PR number, head SHA, timestamp, review costs
- **Push reviews**: repo URL, after SHA
- **Generic change reviews**: repo key, change key, timestamp, review costs

For GitHub webhooks, this prevents duplicate reviews — if the same PR at the same commit SHA is already recorded, the review is skipped. Local diff reviews record their `repo_key` and `change_key` in the same state file, but currently do not skip duplicates. State is trimmed to the 500 most recent records per repo key.

Without `--state`, state is in-memory only and lost on restart. This means reviews may be duplicated after a server restart.

### Security Memory Files

The security pipeline maintains per-repo memory files at `memory/{repo-slug}.md`. These are plain-text markdown files (target ~5000 tokens) that accumulate knowledge about the repo:

- Architecture notes (frameworks, DB access patterns, auth middleware)
- Known safe patterns (parameterized queries, auto-escaping templates)
- Known risk areas (shell command construction, raw HTML rendering)
- Suppressions (accepted risks with context)

Memory is injected into every security agent's prompt, reducing redundant file fetching and pattern re-discovery across reviews.

Updates go through a queue file (`memory/{repo-slug}.queue`) for distributed safety — multiple reviewotron instances can append to the queue, and the curator processes it serially.

### Debug Dumps

When an agent's structured output can't be parsed, a debug dump is saved to `debug/{repo-slug}/{sha-prefix}/`. These contain the raw agent output for diagnosing prompt or parsing issues.

---

## CLI Usage

### `reviewotron run` — Start the Webhook Server

```
reviewotron run [OPTIONS]
```

| Option | Default | Description |
|--------|---------|-------------|
| `-p`, `--port` | `1338` | HTTP server port |
| `--secrets` | `secrets.json` | Path to secrets file |
| `--config-filename` | `.reviewotron.json` | Config filename to look for in repos |
| `--state` | (none — in-memory) | Path to state file for persistence |
| `--logfile` | (stderr) | Log file path |
| `--loglevel` | (default) | Log level: `debug`, `info`, `warn`, `error` |

### `reviewotron check` — Parse a Webhook Payload (Dry Run)

```
reviewotron check --event-type pull_request --payload payload.json [OPTIONS]
```

Parses and displays a GitHub webhook payload without starting the server or performing any review. Useful for verifying payload parsing.

| Option | Required | Description |
|--------|----------|-------------|
| `--event-type` | Yes | GitHub event type (`pull_request` or `push`) |
| `--payload` | Yes | Path to JSON payload file |
| `--secrets` | No | Path to secrets file (defaults to `secrets.json`; must exist for initialization) |

### `reviewotron review-diff` — Review a Local Unified Diff

```
reviewotron review-diff [OPTIONS]
```

Runs the same core review engine against a local unified diff and prints the final review to stdout. Logs go to stderr unless `--logfile` is set. When `--diff` is omitted, Reviewotron generates a Git diff from the merge-base of `HEAD` and the inferred base ref, including working-tree changes. This path does not fetch or publish through GitHub; local file-content expansion uses `--root`.

Local reviews load `.reviewotron.json` from `--root` before applying path filters and size limits. Use `--config-filename` to point at a different filename or absolute config path.

| Option | Default | Description |
|--------|---------|-------------|
| `--diff` | Git diff against inferred base | Path to a unified diff file |
| `--base` | inferred from Git | Base ref for generated diffs; tries `origin/HEAD`, `origin/main`, `origin/master`, then the upstream remote |
| `--root` | Git worktree root, then cwd | Repository root for local file-content lookups |
| `--repo-key` | `local:<root>` | Stable repository key for config, memory paths, and state |
| `--change-key` | digest of diff | Stable change key recorded in state |
| `--title` | inferred from base or diff file | Title passed to review agents |
| `--description-file` | (none) | Optional file used as the review description |
| `--config-filename` | `.reviewotron.json` | Config file loaded from `--root`, or absolute config path |
| `--output` | `markdown` | Output format: `markdown` or `json` |
| `--secrets` | `./secrets.json` | Path to secrets file for the Anthropic API key |
| `--state` | (none — in-memory) | Optional state file updated after a successful review |

JSON output is a list of machine-readable findings. Each item has this shape:

```json
{
  "file": "backend/safer-claude-code/safer_claude_code.ml",
  "line": 492,
  "summary": "Legacy session-id file from old scc crashes startup because ensure_dir refuses to treat a regular file as a directory",
  "failure_scenario": "Any user who ran a previous scc has a regular file at <scc_metadata>/sessions/<wt_basename> holding their last session UUID. After upgrading, the first scc -f or scc run-on calls prepare_session_id_mount, which calls ensure_dir(Filename.dirname host_path) — i.e. ensure_dir on the legacy file path. ensure_dir sees S_REG and fails. scc aborts on startup until the user manually removes the legacy file."
}
```

### Endpoints

| Path | Description |
|------|-------------|
| `/ping` | Health check — returns uptime |
| `/github` | GitHub webhook receiver |

---

## Cost Tracking

Every agent call tracks token usage and estimates cost:

- **Per agent**: input tokens, output tokens, cache read tokens, cache creation tokens, model ID, number of tool-use turns, files fetched, estimated USD cost
- **Per plugin**: aggregated agent costs (general, security)
- **Per review**: total across all plugins

Costs are:
- **Logged** at `info` level after each review
- **Stored** in `state.json` alongside the review record (when state persistence is enabled)
- **Optionally shown** in the PR review footer (when `show_review_cost: true`)

Cost footer example:
> *Review cost: 5 agents (general: 1 agent, security: 4 agents), ~$0.42*

### Pricing

Costs are estimated using a built-in pricing table that includes prompt caching rates:

| Model Family | Input | Output | Cache Write (5m) | Cache Read |
|--------------|-------|--------|------------------|------------|
| Claude Opus 4.x | $5.00/MTok | $25.00/MTok | $6.25/MTok | $0.50/MTok |
| Claude Sonnet 4.x | $3.00/MTok | $15.00/MTok | $3.75/MTok | $0.30/MTok |
| Claude Haiku 4.5 | $1.00/MTok | $5.00/MTok | $1.25/MTok | $0.10/MTok |

Cache write tokens are charged at 1.25x the base input price (5-minute TTL). Cache read tokens are charged at 0.1x the base input price. Cache token counts are extracted from the Anthropic API response and tracked per-agent.

The pricing table is a single record in the codebase (`lib/cost_tracking.ml`) — update it when prices change.

---

## Limitations

### Diff Size

PRs with more than `max_diff_lines` (default 2000) total diff lines are **skipped entirely**. There is no partial review — it's all or nothing. For large PRs, consider breaking them into smaller ones.

### Push Reviews

Only pushes to `refs/heads/develop` are reviewed. Other branches, including `main`/`master`, are not reviewed on push. PR reviews cover all branches.

### File Content Fetching

- The general review plugin fetches up to **5 key files** for additional context (added or modified files only)
- Security analysis agents can fetch any file via `get_file_content`, bounded by the agent's `max_steps` limit
- All file fetches use the PR head SHA as the git ref, so agents see the PR branch state (not the default branch)

### Static Analysis Only

The security pipeline performs **static analysis on the diff and referenced files**. It cannot:

- Execute code or run tests
- Detect runtime-only vulnerabilities
- Analyze compiled/minified code meaningfully
- Check infrastructure configuration (Terraform, Docker, etc.)

### Security Scope

- 6 vulnerability classes are supported. Other classes (e.g., cryptographic weaknesses, deserialization, path traversal) are not covered.
- The triage agent may miss security signals in unusual code patterns. Bumping `triage_model_tier` to `"standard"` (Sonnet) can improve recall at higher cost.
- AuthN/AuthZ/SSRF analysis from diff context alone is inherently limited. These classes produce the most false negatives.

### Webhook Signature Validation

If no `gh_hook_secret` is configured for a repo, webhook signature validation is **skipped** — the event is accepted without verification. While the review will fail at the GitHub API step if no auth token is configured, it's best practice to always set a webhook secret.

### Duplicate Prevention

Duplicate review prevention relies on the state file. Without `--state`, or after a server restart with in-memory-only state, the same PR/push may be reviewed again.

### Concurrent Reviews

Multiple reviews can run concurrently (events are processed via `Lwt.async`). The security memory queue handles concurrent appends safely, but there's no global rate limiting on Anthropic API calls.

---

## Troubleshooting

### Review not triggering

1. Check the webhook delivery log in GitHub (Settings > Webhooks > Recent Deliveries)
2. Verify the server is running: `curl http://your-server:1338/ping`
3. Check the server logs for skip reasons:
   - `"bot sender"` — the event was from a bot account
   - `"ignored author"` — the author is in `ignored_authors`
   - `"action ... not reviewable"` — the PR action doesn't trigger reviews
   - `"draft PR"` — mark the PR as ready for review
   - `"already reviewed at ..."` — duplicate detection fired
4. Check that the repo URL in `secrets.json` matches exactly (including `https://github.com/...`)

### Review fails

- `"no auth configured for repo ..."` — the repo URL in the webhook doesn't match any entry in `secrets.json`
- `"failed to fetch config"` — GitHub API error fetching `.reviewotron.json` (check token permissions)
- `"triage agent failed"` / `"analysis agent failed"` — Claude API error (check `anthropic_api_key`, rate limits)
- `"failed to post review"` — GitHub API error posting the review (check token scopes: needs `repo` or `pull_request:write`)

### Security findings not appearing

1. Check that `review_plugins.security.enabled` is `true` in `.reviewotron.json` (it is `false` by default)
2. Check the `confidence_threshold` — `"high"` is very selective. Try `"medium"` or `"low"`
3. Check the logs for `"triage: no actionable signals"` (the diff may not contain security-relevant code)
4. Check for `"validator rejected"` messages — the finding was detected but rejected as a false positive
5. Bump `analysis_model_tier` to `"strong"` for complex codebases

### Debug dumps

When an agent produces output that can't be parsed as structured JSON, a debug dump is saved to `debug/{repo-slug}/{sha-prefix}/`. Look here when you see `"failed to parse ... output"` in the logs.

---

## Known Issues

- **No rate limiting for Anthropic API calls.** Concurrent reviews (e.g., multiple PRs opened at once) will all call the Anthropic API simultaneously. There is no built-in throttling or queue. The SDK handles 429 errors with automatic retry and exponential backoff, so transient rate limits self-heal. At typical usage (a handful of monitored repos), this is unlikely to be an issue.

---

## Architecture (for contributors)

```
src/
  reviewotron.ml          CLI entrypoint (cmdliner: run + check commands)
  request_handler.ml      HTTP server, webhook routing, signature validation

lib/
  api.ml                  Module type signatures (Github, Agent_runner, Slack)
  api_remote.ml           Production implementations (real HTTP calls)
  api_local.ml            Mock implementations (for testing)

  context.ml              Application context: secrets, config cache, state
  config_types.ml         All configuration types ([@@deriving json])
  github_types.ml         GitHub API request/response types
  slack_types.ml          Slack API types

  github.ml               Event parsing, signature validation
  github_auth.ml          GitHub token/JWT auth (PAT + App Installation)

  reviewer.ml             Plugin orchestrator (Make functor)
  review_plugin.ml        Plugin interface type
  general_review_plugin.ml  General code review (single Claude agent)
  security_review_plugin.ml Multi-agent security pipeline

  agent_runner.ml         Generic agent execution via ocaml-ai-sdk
  triage_agent.ml         Triage agent config + prompt
  analysis_agent.ml       Per-vuln-class analysis agent framework
  validator_agent.ml      Adversarial validation agent
  memory_curator_agent.ml Memory update curator agent

  security_types.ml       All security pipeline types
  security_tools.ml       get_file_content tool for agents
  security_memory.ml      Memory file + queue I/O

  review_types.ml         Finding, severity, review output types
  review_format.ml        Finding → PR comment / Slack formatting
  review_prompt.ml        General review prompt construction

  cost_tracking.ml        Per-agent + per-review cost estimation
  diff_parser.ml          Unified diff parser + path filtering
  state.ml / state_types.ml  Persistent state (review dedup)
  http_util.ml            HTTP request helper

test/
  test.ml                 Main test suite (golden-file tests)
  test_diff_parser.ml     Diff parser unit tests
  test_security_corpus.ml Security corpus test runner (calls Claude — on-demand)
  test_helpers.ml         Test context setup
  mock_api_responses/     Golden-file fixtures
  mock_payloads/          Sample webhook payloads
  security_corpus/        Synthetic vulnerable/safe diffs per vuln class
```

The codebase uses OCaml functors for testability — `Reviewer.Make` takes `Github`, `Agent_runner`, and `Slack` module implementations, so tests can inject mock versions (`Api_local`) without any HTTP calls.
