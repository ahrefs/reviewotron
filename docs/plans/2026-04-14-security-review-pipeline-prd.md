# Security Review Pipeline — Product Requirements Document

## Shannon-Inspired Multi-Agent Static Analysis for Reviewotron

**Date:** 2026-04-14
**Status:** Draft
**Supersedes:** `agentic_security_pr_reviewer.md` (initial sketch)

---

## 1. Problem Statement

Modern CI pipelines lack deep, contextual security reasoning. Traditional SAST tools are fast but noisy (high false-positive rates). Manual security reviews are accurate but don't scale. Shannon (KeygraphHQ) demonstrated that multi-agent AI reasoning — source identification, sink identification, data flow tracing, sanitization evaluation, and exploitability validation — produces high-quality, low-noise security findings.

Reviewotron currently runs a single general-purpose code review agent. This PRD specifies how to extend it with a **multi-agent security analysis pipeline** adapted from Shannon's methodology for static PR review.

### Key Adaptation from Shannon

Shannon is a runtime exploitation engine — it validates findings by executing exploits against live applications ("No Exploit, No Report"). In a static PR review context, runtime exploitation is impossible. We replace it with **evidence-based static validation**: findings are only reported when the full source→sink→flow path is demonstrable within the available code context, and a dedicated validator agent confirms each finding adversarially.

---

## 2. Goals & Non-Goals

### Goals

- Detect security vulnerabilities in PR diffs with high precision (low false positives)
- Support 6 vulnerability classes: Injection, XSS, Command Injection, AuthN, AuthZ, SSRF
- Run fully autonomously — no human-in-the-loop at any stage
- Integrate findings as inline PR comments alongside general review findings
- Track per-review cost with per-agent granularity
- Maintain a per-repo security memory to accelerate future reviews
- Be configurable per-repo (which plugins run, which vuln classes, model selection)

### Non-Goals

- Runtime exploitation or dynamic testing (out of scope for a PR reviewer)
- Replacing dedicated SAST/DAST tools for compliance purposes
- Supporting non-GitHub platforms (GitLab, Bitbucket)
- Real-time interactive feedback during PR authoring

---

## 3. Architecture

### 3.1 Plugin System

Reviewotron gains a **plugin-based review pipeline**. The current general code review becomes one plugin; the security analysis becomes another. Each plugin is a self-contained module that produces findings in the standard `finding` type.

```
GitHub Webhook → Event Processing → Diff Extraction
                                        ↓
                              Plugin Orchestrator
                             /         |          \
                   General Review   Security Review   (future plugins...)
                        \              |              /
                         Aggregated Finding List
                                   ↓
                         Single GitHub PR Review
                         (inline comments)
```

**Plugin interface:**

```ocaml
module type Review_plugin = sig
  val name : string
  val run :
    ctx:Context.t ->
    repo_url:string ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:review_metadata ->
    Review_types.finding list Lwt.t
end
```

Plugins are enabled per-repo via `.reviewotron.json`. The orchestrator runs enabled plugins (potentially in parallel since they are independent), merges finding lists, deduplicates, and posts a single PR review.

### 3.2 Security Pipeline (Internal to Security Plugin)

```
Diff + File list + Language hints + Repo memory
                    ↓
            Triage Agent (Haiku — fast)
                    ↓
          Routing: which vuln classes are relevant?
           ↓           ↓           ↓
     Injection    XSS    Cmd Inj    ...  (parallel, Sonnet)
     Analysis     Analysis  Analysis
           ↓           ↓           ↓
          All candidate findings collected
                    ↓
            Validator Agent (Sonnet)
                    ↓
          Confirmed findings → plugin output
          Rejected findings → logged, discarded
                    ↓
            Memory Curator (Haiku, async post-review)
```

### 3.3 Agent Architecture

All agents use a generic runner built on `ocaml-ai-sdk`. No agent-specific code paths — differentiation is entirely through configuration (prompt, tools, model tier, output schema).

**Agent runner signature:**

```ocaml
module type Agent_runner = sig
  val run_agent :
    ctx:Context.t ->
    repo_url:string ->
    agent_config:Agent_config.t ->
    input:agent_input ->
    (agent_result, string) result Lwt.t
end
```

**Agent configuration type:**

```ocaml
type model_tier = Fast | Standard | Strong [@@deriving json]

type agent_config = {
  name : string;
  system_prompt : string;
  model_tier : model_tier;
  output_schema : Yojson.Basic.t;   (* derived from types via ppx_deriving_jsonschema *)
  tools : tool_name list;
  max_steps : int;
} [@@deriving json]
```

**Implementation uses `Generate_text.generate` from `ocaml-ai-sdk`:**

- Multi-step tool loop is handled by the SDK (automatic tool execution + result feeding)
- Structured output via `Output.object_` with derived JSON Schema
- Real token usage from `Usage.t` in results
- Built-in retry with exponential backoff
- Provider-agnostic (can swap Anthropic for OpenAI without code changes)

### 3.4 Interactive Context Expansion

Analysis agents receive the diff and triage signals as initial context. When they need more context (e.g., to trace a data flow into a function defined in another file), they invoke the `get_file_content` tool. The SDK's tool loop handles this automatically:

1. Agent reasons: "input flows into `Auth.validate(token)` — need to see implementation"
2. Agent calls tool: `get_file_content { path: "lib/auth.ml" }`
3. SDK executes callback → reviewotron fetches file via GitHub Contents API → returns content
4. Agent continues reasoning with expanded context

Context expansion is **demand-driven** — no artificial caps. Agents fetch what they need. Cost is naturally bounded by the model's context window and the `max_steps` limit on tool round-trips.

---

## 4. Agents

### 4.1 Triage Agent

**Purpose:** Fast scan of the diff to identify security-relevant regions and route to appropriate analysis agents.

**Model tier:** Fast (Haiku) — configurable per-repo to Standard if quality is insufficient.

**Input:** Raw diff text, changed file paths, detected languages (from file extensions), repo security memory.

**Tools:** None (single-shot, no context expansion needed).

**Behavior:** Scans for patterns that indicate security-relevant changes. Biased toward **over-flagging** — it's cheap to spawn an analysis agent that finds nothing, costly to skip one that would have found something.

**Signal examples:**
- SQL/query string construction → `injection`
- HTML template rendering, string interpolation into markup → `xss`
- `exec`, `system`, `popen`, shell invocations → `command_injection`
- Auth middleware changes, session handling, token validation → `authn`
- Permission checks, role guards, resource ownership → `authz`
- HTTP client calls, URL construction from inputs, redirect handling → `ssrf`

**Output type:**

```ocaml
type confidence = High | Medium | Low [@@deriving json, jsonschema]

type vuln_class =
  | Injection
  | Xss
  | Command_injection
  | Authn
  | Authz
  | Ssrf
[@@deriving json, jsonschema]

type region = {
  path : string; [@jsonschema.description "File path in the diff"]
  start_line : int;
  end_line : int;
} [@@deriving json, jsonschema]

type triage_signal = {
  vuln_class : vuln_class;
  confidence : confidence;
  regions : region list;
  rationale : string;
} [@@deriving json, jsonschema]

type triage_output = {
  signals : triage_signal list;
  language_hints : string list;
  skip_reason : string option;
} [@@deriving json, jsonschema]
```

**Routing logic (in OCaml, not in the agent):**
- `High` or `Medium` confidence signals → spawn analysis agent for that vuln class
- `Low` confidence signals → only spawn if the vuln class is in the repo's `vuln_classes` config list
- No signals → security plugin returns empty findings (fast exit)

### 4.2 Analysis Agents (Per Vulnerability Class)

**Purpose:** Deep source-sink-flow-sanitization reasoning for a specific vulnerability class.

**Model tier:** Standard (Sonnet).

**One agent per flagged vulnerability class, running in parallel.**

**Input:** Diff text, triage signals (flagged regions for this vuln class), language hints, repo security memory.

**Tools:** `get_file_content` — for demand-driven context expansion when tracing data flows beyond the diff.

**Shared methodology (all analysis agents follow this reasoning chain):**

1. **Source identification** — Find user-controlled inputs in the flagged regions. What data enters from outside the trust boundary?
2. **Sink identification** — Find dangerous operations for this vulnerability class. Where does data reach a sensitive function?
3. **Data flow tracing** — Can the source reach the sink? Trace the path through variables, function calls, returns. If the path leaves the diff, use `get_file_content` to follow it.
4. **Sanitization evaluation** — Is there adequate, context-correct sanitization on the path? (e.g., parameterized queries for SQL, HTML encoding for XSS in HTML context, shell escaping for command injection)

**Per-class specialization is prompt-only.** The agent execution code is generic. What differs per vuln class:
- Source/sink definitions (e.g., for Injection: sources are HTTP parameters, sinks are `db.query()` / `Caqti_request.exec` with string interpolation)
- Framework-specific patterns (e.g., OCaml/Dream vs. JS/Express)
- Sanitization adequacy criteria

**Prompts must be language-aware.** The triage agent provides `language_hints`; the analysis agent's prompt includes source/sink catalogs relevant to those languages. Prompts are parameterized, not hardcoded to one language.

**Output type:**

```ocaml
type source_evidence = {
  path : string;
  line : int;
  description : string; [@jsonschema.description "e.g. 'HTTP request parameter id'"]
} [@@deriving json, jsonschema]

type sink_evidence = {
  path : string;
  line : int;
  description : string; [@jsonschema.description "e.g. 'String concatenation into SQL query'"]
} [@@deriving json, jsonschema]

type flow_step = {
  path : string;
  line : int;
  description : string; [@jsonschema.description "e.g. 'Passed as argument to Db.execute'"]
} [@@deriving json, jsonschema]

type sanitization_status =
  | Adequate
  | Inadequate of string   [@jsonschema.description "Why the sanitization is insufficient"]
  | Missing
  | Unknown                [@jsonschema.description "Could not determine — path left visible scope"]
[@@deriving json, jsonschema]

type candidate_finding = {
  vuln_class : vuln_class;
  source : source_evidence;
  sink : sink_evidence;
  flow : flow_step list;
  sanitization : sanitization_status;
  confidence : confidence;
  description : string;
  suggested_fix : string option;
} [@@deriving json, jsonschema]

type analysis_output = {
  findings : candidate_finding list;
  files_examined : string list;
  notes : string;
} [@@deriving json, jsonschema]
```

### 4.3 Validator Agent

**Purpose:** Adversarial false-positive filter. Receives all candidate findings and makes a final accept/reject decision on each.

**Model tier:** Standard (Sonnet) — must be at least as capable as the analysis agents it's checking.

**Input:** All candidate findings from all analysis agents, original diff text, repo security memory.

**Tools:** `get_file_content` — for spot-checking evidence claims.

**Validation criteria (all must pass for a finding to be reported):**

1. **Source exists and is user-controllable** — The claimed source must actually accept external input. A hardcoded config value is not a source.
2. **Sink exists and is dangerous for this vuln class** — The claimed sink must actually perform the dangerous operation.
3. **Flow path is traceable** — Every step in the flow must be backed by evidence (file, line). No gaps or "this probably passes through..." reasoning.
4. **Sanitization assessment is correct** — If the analysis agent said "missing," the validator confirms. If "inadequate," the validator verifies why.

**Findings that fail validation are dropped.** No "needs investigation" category. A noisy security reviewer that cries wolf loses developer trust. Dropped findings are logged for offline prompt tuning.

**Output type:**

```ocaml
type validation_verdict =
  | Confirmed
  | Rejected of string [@jsonschema.description "Reason for rejection"]
[@@deriving json, jsonschema]

type validated_finding = {
  finding : candidate_finding;
  verdict : validation_verdict;
  evidence_notes : string;
} [@@deriving json, jsonschema]

type validator_output = {
  results : validated_finding list;
} [@@deriving json, jsonschema]
```

**Post-validation severity mapping:**
- `High` confidence confirmed → severity `Critical`
- `Medium` confidence confirmed → severity `Warning`
- All confirmed findings → category `Security`

### 4.4 Memory Curator Agent

**Purpose:** Update the repo security memory after each review.

**Model tier:** Fast (Haiku).

**Runs asynchronously after the review is posted** — not in the critical path.

**Input:** Current memory file contents, current token count, configured max token limit, new learnings from the review (files examined, patterns discovered, findings confirmed/rejected).

**Output:** Updated memory file content, guaranteed to be within the configured token limit.

See Section 6 for memory format details.

---

## 5. Configuration

### 5.1 Per-Repo Configuration (`.reviewotron.json`)

```json
{
  "max_diff_lines": 2000,
  "max_files": 50,
  "model": "claude-sonnet-4-5-20250929",
  "ignored_paths": ["*.test.js", "vendor/"],
  "ignored_authors": ["dependabot"],
  "auto_review_pr_open": true,
  "auto_review_pr_sync": true,
  "review_pushes_to_develop": true,
  "slack_channel": "#code-reviews",
  "show_review_cost": false,

  "review_plugins": {
    "general": {
      "enabled": true,
      "system_prompt_override": null
    },
    "security": {
      "enabled": true,
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

### 5.2 Model Tier Resolution

Model tiers map to specific model IDs. The mapping is defined in the application config (not per-repo):

| Tier | Default Model | Purpose |
|------|--------------|---------|
| `fast` | `claude-haiku-4-5-20251001` | Triage, memory curator |
| `standard` | `claude-sonnet-4-5-20250929` | Analysis agents, validator, general review |
| `strong` | `claude-opus-4-6-20260414` | Reserved for future use (complex codebases) |

Per-repo config can override the tier for each agent role (e.g., bump triage to `standard` if Haiku misses too many signals).

---

## 6. Repo Security Memory

### 6.1 Format

A single markdown file per repo, stored at `memory/{repo_slug}.md`. Plain text, human-readable, kept deliberately small (configurable, default 5000 tokens).

**Example:**

```markdown
# Security Memory: org/monorepo

## Architecture
- Backend: OCaml with Dream web framework, Caqti for DB access
- Frontend: ReasonML with ReasonReact, compiled via Melange
- All SQL goes through Caqti prepared statements — parameterized by default
- Auth: custom JWT middleware in lib/auth/jwt.ml, tokens validated via Auth.verify_token

## Known Safe Patterns
- Db.query/Db.exec always use Caqti type-safe params — not an injection sink
- Html.escape_text used consistently in all server-rendered templates
- User input from Dream.query/Dream.body always passes through Validate module

## Known Risk Areas
- lib/export/csv.ml builds shell commands with Filename.quote — fragile escaping
- frontend/packages/dashboard/src/RawHtml.re uses dangerouslySetInnerHTML
- scripts/ directory contains shell scripts that source user-provided env vars

## Suppressions
- INJ-2024-003: Db.unsafe_exec in migration runner — accepted, only runs with admin credentials
```

### 6.2 Consumption

The memory file contents are injected into every security agent's system prompt as a `## Repository Security Context` section. Small enough (~5k tokens) to add minimal cost but dramatically reduces redundant file fetching and pattern re-discovery.

### 6.3 Maintenance

The memory curator agent runs after each review (async, fire-and-forget). It receives:
- Current memory file contents
- Current token count and configured max
- Learnings from the completed review

The curator updates the file, and if the result exceeds the token limit, it compresses by: removing stale entries first, merging related entries, dropping least actionable details. The curator is the only writer to the memory file.

### 6.4 Distributed Safety

Updates go through an append-only queue file (`memory/{repo_slug}.queue`). Each completed review appends a JSON entry with its learnings. The curator processes the queue serially — reads all pending entries, incorporates into the memory file, truncates the queue. Multiple reviewotron instances can append concurrently; the next curator run reconciles.

```ocaml
type memory_update = {
  timestamp : string;
  review_id : string;
  learnings : string list;
  stale_entries : string list;
} [@@deriving json]
```

---

## 7. Cost Tracking

### 7.1 Per-Agent Tracking

Every `run_agent` call returns `Usage.t` from the SDK with real `input_tokens` and `output_tokens`. We record:

```ocaml
type agent_cost = {
  agent_name : string;
  model : string;
  input_tokens : int;
  output_tokens : int;
  turns : int;
  files_fetched : int;
  estimated_cost_usd : float;
} [@@deriving json]
```

`estimated_cost_usd` is computed per-agent using that agent's model ID against a pricing lookup table.

### 7.2 Per-Review Aggregation

```ocaml
type review_cost = {
  plugin : string;
  agents : agent_cost list;
  total_input_tokens : int;
  total_output_tokens : int;
  total_estimated_cost_usd : float;
} [@@deriving json]
```

### 7.3 Surfacing

- **Logs:** Emitted at `info` level after each review completes
- **State:** Stored in `state.json` alongside the review record
- **PR comment:** Optional footer on the review body (`Security review: 3 agents, ~$0.42`), enabled via `show_review_cost: true` in repo config

### 7.4 Implementation Note

**Model pricing must be sourced from current Anthropic documentation at implementation time.** Do not hardcode prices from this PRD. The pricing table should be a single, easily-updated record in the codebase. Consider that different models have different input/output token rates, and prompt caching (if used) has separate pricing for cache creation vs. cache read tokens.

Note: `ocaml-ai-sdk`'s `Usage.t` currently tracks `input_tokens`, `output_tokens`, and `total_tokens`. If Anthropic prompt caching is used, cache-specific token fields (`cache_creation_input_tokens`, `cache_read_input_tokens`) may need to be read from provider metadata or the SDK may need extension. Flag this during implementation.

---

## 8. Testing Strategy

### 8.1 Unit Tests (Deterministic, No Claude Calls)

Test all infrastructure using `Api_local` mocks, following the existing golden-file pattern:

- **Triage routing logic:** Given a `triage_output`, verify correct analysis agents are spawned. Edge cases: no signals, all signals, low-confidence-only.
- **Validator filtering:** Given candidate findings with various verdicts, verify only `Confirmed` findings reach the plugin output.
- **Cost calculation:** Given agent token counts and model IDs, verify correct USD estimates.
- **Memory queue processing:** Verify append, read, truncation cycle.
- **Plugin orchestrator:** Given multiple plugin outputs, verify correct merging into a single review. Test deduplication.
- **Finding-to-comment mapping:** Existing tests apply unchanged.
- **Configuration parsing:** All new config fields parse correctly, defaults apply when omitted.
- **Type serialization round-trips:** All new types with `[@@deriving json]` round-trip correctly through serialization/deserialization.

### 8.2 Agent Prompt Tests (Integration, Claude Calls)

A **test corpus** of synthetic diffs with known vulnerabilities and known-safe code:

```
test/security_corpus/
  injection/
    sql_concat_vulnerable.diff         → expect: finding with vuln_class=Injection
    sql_parameterized_safe.diff        → expect: no findings
    sql_partial_sanitization.diff      → expect: finding, sanitization=Inadequate
  xss/
    innerHTML_vulnerable.diff          → expect: finding with vuln_class=Xss
    escaped_output_safe.diff           → expect: no findings
  command_injection/
    exec_user_input.diff               → expect: finding with vuln_class=Command_injection
    exec_hardcoded_safe.diff           → expect: no findings
  authn/
    jwt_no_expiry_check.diff           → expect: finding with vuln_class=Authn
  authz/
    missing_ownership_check.diff       → expect: finding with vuln_class=Authz
  ssrf/
    url_from_user_input.diff           → expect: finding with vuln_class=Ssrf
```

Each test: run full security pipeline against the diff, assert expected outcome (found vuln class + severity, or clean).

**Triage-specific tests:** Verify triage flags the correct vuln class for every vulnerable diff in the corpus.

These tests call Claude and cost money. Run on-demand or pre-release, not on every CI push.

### 8.3 Quality Metrics

| Metric | Source | Target |
|--------|--------|--------|
| Triage recall | Corpus tests | >95% |
| Triage precision | Corpus tests | >60% (over-flagging is acceptable) |
| Analysis true positive rate | Corpus tests | >80% |
| Post-validation false positive rate | Corpus tests | <10% |
| Average cost per review | Cost tracking logs | Monitor (no fixed target) |
| Average latency | Logs | <5 min triage-only, <10 min with deep analysis |

---

## 9. Implementation Rules

### 9.1 No Manual JSON

**Manual JSON manipulation/creation is forbidden unless impossible otherwise.** All JSON values flow through derived serialization from OCaml types:

- JSON serialization/deserialization: `[@@deriving json]` via `melange-json-native`
- JSON Schema generation: `[@@deriving jsonschema]` via `ppx_deriving_jsonschema`
- Tool parameter schemas: derived from parameter types, never hand-written
- Tool execute callbacks: accept and return typed values, serialized via derivers
- Structured output schemas: derived from output types
- Configuration parsing: derived from config types

**Rationale:** Type-derived JSON ensures compile-time correctness, prevents serialization bugs, and makes schema evolution safe. The codebase already uses `ppx_deriving_jsonschema` in `review_prompt.ml` — this extends that pattern universally.

### 9.2 Existing Patterns

- Follow monorobot's functor-based API abstraction for testability
- Use `Devkit` utilities (logging, HTTP, strings) — don't reinvent
- Golden-file testing with mock implementations via `Api_local`
- Use `serena` MCP for semantic code navigation of the monorepo
- Use `context7` MCP for library documentation lookup

---

## 10. Implementation Plan

### Phase 0: Foundation — ATD → melange-json-native + ppx_deriving_jsonschema

Pure refactor. No behavior change. All existing tests must pass.

1. Add `melange-json-native` and `ppx_deriving_jsonschema` to dune dependencies
2. Migrate each ATD file one at a time, simplest first:
   - `slack_types.atd` → `slack_types.ml` with `[@@deriving json]`
   - `state.atd` → `state_types.ml` with `[@@deriving json]`
   - `config.atd` → `config_types.ml` with `[@@deriving json]`
   - `review_types.atd` → `review_types.ml` with `[@@deriving json, jsonschema]`
   - `github_types.atd` → `github_types.ml` with `[@@deriving json]`
   - `anthropic_types.atd` → keep temporarily (deleted in Phase 1)
3. For each migration: create OCaml type module, update all call sites, delete `.atd` file, verify tests pass
4. Remove ATD build dependencies from dune once all non-Anthropic types are migrated

### Phase 1: Integrate ocaml-ai-sdk

Replace hand-rolled Anthropic API calls with the SDK. General review works exactly as before through a better abstraction.

1. Add `ocaml-ai-sdk` (`ai_core`, `ai_provider`, `ai_provider_anthropic`) to dependencies
2. Implement generic `run_agent` function using `Generate_text.generate`
3. Refactor `Api.Claude` into `Api.Agent_runner` with the new signature
4. Rewrite general review as an agent config (system prompt + output schema + no tools)
5. Delete `anthropic_types.atd`, manual HTTP code, `build_anthropic_request`
6. Verify existing tests pass — review output should be identical

### Phase 2: Plugin System

The orchestrator and plugin interface, with the general review as the first plugin.

1. Define the `Review_plugin` module type
2. Wrap existing general review in a `General_review_plugin` module
3. Extend config types with `review_plugins` configuration
4. Build plugin orchestrator in `reviewer.ml` — iterate enabled plugins, collect findings, merge
5. Verify existing behavior unchanged — one plugin, same output

### Phase 3: Security Pipeline Infrastructure

Agent types, triage agent, interactive tool framework.

1. Define security types: `triage_output`, `candidate_finding`, `analysis_output`, `validator_output`, etc. — all with `[@@deriving json, jsonschema]`
2. Implement `get_file_content` tool as `Core_tool.t` with GitHub API callback (typed params and result via derivers)
3. Build triage agent config and prompt
4. Build security plugin skeleton: runs triage, routes to analysis agents (stubbed)
5. Test triage against initial corpus diffs

### Phase 4: Analysis Agents

One agent per vulnerability class, all using the shared framework.

1. Build shared analysis agent framework (common prompt structure, output schema, tool set)
2. Implement per-class prompts with language-aware source/sink catalogs:
   - Injection analysis
   - XSS analysis
   - Command injection analysis
   - AuthN analysis
   - AuthZ analysis
   - SSRF analysis
3. Test each agent against its corpus slice

### Phase 5: Validator + Finding Pipeline

Complete the pipeline from candidate findings to PR comments.

1. Build validator agent config and prompt
2. Implement candidate → validated finding conversion
3. Implement validated finding → `Review_types.finding` mapping
4. End-to-end test: webhook → triage → analysis → validation → PR comment
5. Cost tracking: accumulate `Usage.t` per agent, compute per-review cost, add optional PR footer

### Phase 6: Repo Security Memory

Memory file, curator agent, queue mechanism.

1. Define memory file format and storage path convention
2. Implement memory loading (injected into agent system prompts)
3. Implement memory curator agent (post-review, async)
4. Implement update queue for distributed safety
5. Add `memory_max_tokens` config and size enforcement in curator prompt
6. Test memory round-trip: review produces learnings → curator updates file → next review uses updated memory

### Phase 7: Test Corpus + Quality Metrics

1. Build comprehensive synthetic diff corpus (vulnerable + safe variants per vuln class, across multiple languages — prioritizing OCaml/ReasonML with JS/Python coverage)
2. Build corpus test runner (runs full pipeline, asserts expected outcomes)
3. Implement quality metric tracking (triage recall/precision, analysis TP rate, FP rate)
4. Tune prompts based on corpus results

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Triage misses security signals (false negative at the gate) | Vulnerable code not analyzed | Bias triage toward over-flagging; track triage recall; allow per-repo tier override to Sonnet |
| Analysis agents hallucinate data flow paths | False positives despite validator | Validator requires every flow step backed by file+line evidence; `get_file_content` provides ground truth |
| Token costs escalate on large diffs | Expensive reviews | Existing `max_diff_lines` config limits input size; `max_steps` on agents limits tool loops; cost tracking surfaces anomalies |
| GitHub API rate limiting during context expansion | Agent stalls or fails mid-analysis | Implement rate-limit awareness in `get_file_content` tool (respect `X-RateLimit-Remaining`); cache file contents within a review session |
| AuthN/AuthZ/SSRF agents produce low-quality results from diff-only context | Noisy findings in these classes | Triage gates these — only spawned when strong signals detected; validator provides second filter; repos can disable specific vuln classes |
| Memory file grows stale or misleading | Agents make wrong assumptions | Curator runs after every review; agents treat memory as hints, not facts — they verify via `get_file_content` when acting on memory claims |
| Concurrent reviewotron instances corrupt memory | Lost updates | Queue-based update mechanism; curator processes queue serially |
| SDK's `Usage.t` lacks cache token fields | Inaccurate cost tracking with prompt caching | Check at implementation time; extend SDK or read from provider metadata if needed |

---

## 12. Key Design Decisions Log

| Decision | Rationale |
|----------|-----------|
| Plugin system for review types | Repos opt into what they need; future extensibility without core changes |
| Triage gates deep analysis | Avoid running expensive agents on irrelevant diffs |
| Demand-driven context expansion via tool_use | Agents fetch what they need; no artificial caps; naturally bounded by context window |
| Separate validator agent (not self-validation) | Adversarial review reduces false positives; skeptical prompt counterbalances analysis bias |
| Drop uncertain findings (no "needs investigation") | Developer trust requires low noise; silent false negatives are preferable to noisy false positives for long-term adoption |
| Markdown memory file (not structured DB) | Goes directly into prompts; human-readable for debugging; cheap to maintain |
| Generic `run_agent` (not per-agent functions) | Plugin/agent extensibility without signature changes; mirrors Shannon's AGENTS registry pattern |
| ocaml-ai-sdk replaces hand-rolled API calls | Built-in tool loops, retries, structured output, real token tracking; provider-agnostic |
| melange-json-native + ppx_deriving_jsonschema replaces ATD | Required for SDK compatibility; JSON Schema derivation for tool params and structured output; compile-time correctness |
| Per-agent cost tracking with model-specific pricing | Enables data-driven decisions about model tier allocation |
