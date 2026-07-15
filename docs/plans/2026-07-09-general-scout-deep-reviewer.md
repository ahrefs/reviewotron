# General Scout + Deep Reviewer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the general plugin's single-pass review with a scout → deep reviewer → validator pipeline (DoorDash V3 pattern), plus a model-tier refresh, without touching the security plugin.

**Architecture:** A cheap-ish Sonnet scout reads the diff and emits capped "investigation leads"; zero leads short-circuits the plugin. An Opus deep reviewer verifies all leads in one batched call (disprove-first) and emits the existing `review_output` shape, so the existing candidate filter and `general_validator` run unchanged downstream. Normative design: `docs/plans/2026-07-09-general-scout-deep-reviewer-design.md` — read it before any task.

**Tech Stack:** OCaml, Lwt, `ocaml-ai-sdk` (Anthropic provider), `melange-json-native` + `ppx_deriving_jsonschema` derivers, OUnit-style tests in `test/test.ml` run via `dune runtest`.

---

## Orchestrator Protocol (read first, every session)

**Who runs this plan:** an orchestrator session (Opus 4.8 or stronger) that dispatches ONE subagent per task, in order, and reviews between tasks. The orchestrator NEVER implements; it dispatches, gates, and integrates.

### Environment invariants (all tasks)

- Work from repo root `~/code/opensource/reviewotron` on a feature branch cut from `main` (create `general-scout-deep-reviewer` if absent).
- Build/test with the repo's **local opam switch** (`_opam/` at repo root). If tool output shows jsonschema/SDK type errors that make no sense, you are on the wrong switch — fix the environment, do not "fix" the code. Never `opam install` anything.
- Style law: `AGENTS.md` (else-if is banned; no catch-all matches; labeled args; `.mli` for every new `.ml`; ocamlformat via `make fmt`). `lib/dune` needs no edits for new modules.
- **No new dependencies. No edits to `dune-project`, `lib/dune`, or `reviewotron.opam`.**

### Validation gate (run after EVERY task, orchestrator-side)

```bash
dune build 2>&1 | tail -5        # expect: no output/errors
dune runtest 2>&1 | tail -15     # expect: all tests pass, 0 failures
dune build @fmt --auto-promote && git diff --stat  # expect: formatting applied; review any churn
git status --porcelain            # expect: only files the task's scope contract allows
```

If any gate fails or out-of-scope files changed: reject the subagent's work, revert, re-dispatch with the failure appended to the task prompt. Two consecutive failures on the same task → STOP and report to José.

### Anti-drift rules (bind every subagent)

1. **Scope contract:** each task lists files it may create/modify. Touching anything else = automatic reject. In particular, NEVER modify: `lib/security_*`, `lib/triage_agent.*`, `lib/analysis_agent.*`, `lib/review_engine.*`, `lib/validator_agent.*`, `lib/memory_curator_agent.*`.
2. **Quoted artifacts are normative:** type definitions, config fields, defaults, agent names (`general_scout`, `general_deep_review`), and prompt texts in this plan are decided. Subagents may fix OCaml syntax to compile, but changing semantics, renaming, adding fields, or "improving" prompts is drift. If a quoted artifact cannot work as written, the subagent must STOP and return the problem instead of improvising.
3. **No opportunistic refactors.** No renames, no drive-by cleanups, no TODO sweeps.
4. **Prompt-echo check:** every dispatch prompt ends with "Restate your scope contract and definition of done before you begin." A subagent that restates them wrong gets corrected before it edits anything.
5. **Out-of-scope discoveries** (real bugs, stale docs) go in the final report, not in the diff.

### Subagent dispatch template

```
You are a <persona> working in ~/code/opensource/reviewotron (OCaml).
Read first: AGENTS.md, docs/plans/2026-07-09-general-scout-deep-reviewer-design.md,
and Task N below (pasted in full).
Scope contract: you may only create/modify: <files>.
Definition of done: <task's success criteria, verbatim>.
Hard rules: no new deps; no edits outside scope; quoted types/prompts are
normative; if blocked, stop and report rather than improvise.
Restate your scope contract and definition of done before you begin.
```

### Model & persona assignment

| Task | Subagent model | Persona |
|---|---|---|
| 1. Tier refresh | `sonnet` | Meticulous OCaml maintenance engineer |
| 2. Config surface | `sonnet` | OCaml engineer, config/serialization specialist |
| 3. Scout types | `sonnet` | OCaml engineer, serialization specialist |
| 4. Scout agent | `opus` | LLM prompt engineer who writes OCaml; recall-obsessed |
| 5. Deep reviewer agent | `opus` | Senior code reviewer persona-smith; precision-obsessed |
| 6. Pipeline wiring | `opus` | Careful systems integrator; hates behavior changes |
| 7. Final sweep | `sonnet` | Release engineer |
| Post-task review (each) | `opus` | superpowers:code-reviewer agent, briefed with this plan + the task |

Commit at the end of each task (message given per task). *Note for the orchestrator: José's standing preference is no commits without explicit request — this plan IS the explicit request for these per-task commits on the feature branch; do not push, do not open PRs.*

---

## Task 1: Model tier refresh (independent, do first)

**Files:**
- Modify: `lib/agent_runner.ml` (~line 127–132, `default_model_id`)
- Modify: `lib/agent_runner.mli` (doc comment ~lines 53–58)
- Modify: `lib/cost_tracking.ml` (pricing table, ~line 45)
- Modify: `lib/config_types.ml` (~line 105–108, `model_tier_jsonschema` description)
- Test: `test/test.ml` (only if an existing test asserts the old model IDs — search first)

**Step 1: Search for hardcoded expectations**

Run: `grep -rn "claude-sonnet-4-6\|claude-opus-4-6\|Claude_sonnet_4_6\|Claude_opus_4_6" lib test src --include="*.ml*"`
Record every hit; each is either updated in this task or explicitly listed as out of scope in your report. (`config_types.ml:190` `model` default is Task 2's scope — leave it.)

**Step 2: Change `default_model_id`** in `lib/agent_runner.ml`. The SDK `Model_catalog` has no Sonnet 5 / Opus 4.8 variants; `Llm_provider.language_model ~model_id` accepts raw strings, so return literals:

```ocaml
let default_model_id = function
  | Fast -> to_model_id Claude_haiku_4_5
  | Standard -> "claude-sonnet-5"
  | Strong -> "claude-opus-4-8"
```

Check `Llm_provider.normalize_model_id` (`lib/llm_provider.ml:59`) handles these IDs for both providers (for OpenRouter it prefixes `anthropic/`; verify the mapping doesn't whitelist known IDs — if it does, extend the mapping, staying within this task's files... `lib/llm_provider.ml` is added to scope ONLY if normalization requires it; state so in your report).

**Step 3: Add Sonnet 5 pricing** in `lib/cost_tracking.ml` pricing table, BEFORE the `claude-sonnet-4` entry (prefix match, first wins):

```ocaml
{
  model_id_prefix = "claude-sonnet-5";
  input_per_million = 3.0;
  output_per_million = 15.0;
  cache_write_per_million = 3.75;
  cache_read_per_million = 0.30;
};
```

`claude-opus-4-8` already matches the `claude-opus-4` prefix at $5/$25 — verify, don't change.

**Step 4: Update doc comments** — `agent_runner.mli` tier docs (`Standard → claude-sonnet-5`, `Strong → claude-opus-4-8`) and the `model_tier_jsonschema` description string in `config_types.ml` ("standard (Sonnet)" wording stays accurate; adjust only if it names 4.6 explicitly).

**Step 5: Build and test**

Run: `dune build && dune runtest 2>&1 | tail -5`
Expected: clean build, all tests pass. If a test asserts old IDs, update the assertion to the new IDs (that's in scope) and note it.

**Step 6: Commit** — `git add -A && git commit -m "Refresh default model tiers to Sonnet 5 / Opus 4.8"`

**Success criteria:** grep from Step 1 shows no stale references outside Task 2's file; `default_model_id Standard = "claude-sonnet-5"`; `Cost_tracking.find_pricing` resolves `claude-sonnet-5` and `claude-opus-4-8` to the rates above (add a `let%test`-style or OUnit assertion in `test/test.ml` if none exists — cost table regressions are silent zero-cost warnings otherwise); gates green.

---

## Task 2: Config surface

**Files:**
- Modify: `lib/config_types.ml` (`general_plugin_config` ~line 111, `default_general_plugin_config` ~line 152, `model` field ~line 190)
- Modify: `lib/config_types.mli` (matching signatures, ~lines 60–100)
- Modify: `lib/general_review_plugin.ml` (ONLY the `~model_id:config.model` call site, to keep it compiling — full rewiring is Task 6)
- Test: `test/test.ml`

**Step 1: Extend `general_plugin_config`:**

```ocaml
type general_plugin_config = {
  enabled : bool; [@json.default true] [@jsonschema.description "Run the general LLM code review (default true)."]
  system_prompt_override : string option;
     [@json.option] [@jsonschema.description "Replace the general review system prompt entirely."]
  scout_enabled : bool;
     [@json.default true]
     [@jsonschema.description
       "Run the scout → deep-reviewer pipeline (default true). When false, fall back to the legacy single-pass \
        general review."]
  scout_model_tier : model_tier;
     [@json.default Standard] [@jsonschema.description "Model tier for the general scout agent."]
  deep_reviewer_model_tier : model_tier;
     [@json.default Strong] [@jsonschema.description "Model tier for the general deep-reviewer agent."]
  max_leads : int;
     [@json.default 10]
     [@jsonschema.description "Maximum investigation leads passed from the scout to the deep reviewer."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]
```

Update `default_general_plugin_config` to match. Mirror in the `.mli`.

**Step 2: Convert `model` to an explicit override** (config_types.ml ~line 190):

```ocaml
model : string option;
   [@json.option]
   [@jsonschema.description
     "Explicit model ID override for the general deep reviewer. When absent, deep_reviewer_model_tier decides."]
```

Mirror in `.mli`. Fix ALL call sites (`grep -rn "\.model\b" lib src test` and inspect): in `general_review_plugin.ml` change `AI.run ~ctx ~repo_url ~model_id:config.model ...` to `AI.run ~ctx ~repo_url ?model_id:config.model ...`. Any other consumer of `config.model` (grep will find them — check `local_review.ml`, `request_handler.ml`) gets the minimal Option-aware fix, preserving behavior when set.

**Step 3: Write a config-parse test** in `test/test.ml` near existing config tests (grep `config_of_json` or `parse_config` for the local convention): a JSON config omitting the new fields must parse with the defaults above (`scout_enabled = true`, `scout_model_tier = Standard`, `deep_reviewer_model_tier = Strong`, `max_leads = 10`, `model = None`); a JSON config setting each must round-trip.

**Step 4: Run gates** (build, runtest). **Step 5: Commit** — `"Add scout/deep-reviewer config surface to general plugin"`

**Success criteria:** both new-field defaulting and explicit-value parsing covered by tests; `config.model` absent ⇒ `None` (verify no silent `"claude-sonnet-4-6"` default remains anywhere); gates green.

---

## Task 3: Scout output types

**Files:**
- Modify: `lib/review_types.ml`, `lib/review_types.mli`
- Test: `test/test.ml`
- Create: `test/mock_api_responses/scout/leads_two.json`, `test/mock_api_responses/scout/leads_empty.json`, `test/mock_api_responses/scout/leads_overflow.json` (12 leads)

**Step 1: Add types** to `review_types.ml`, following the file's existing deriving/serialization conventions EXACTLY (open the file and copy the pattern used by `validated_finding` — same ppx attributes, same manual-vs-derived style, same `_jsonschema` exposure):

```ocaml
type scout_lead = {
  path : string;
  line : int;
  end_line : int option;
  hypothesis : string;   (* what might be wrong and why it's worth a deep look *)
  category : finding_category;
  confidence : confidence;
}

type scout_output = {
  leads : scout_lead list;
  skip_note : string;    (* one line on what the scout deliberately skipped; "" if nothing *)
}
```

Expose in `.mli`: `scout_lead`/`scout_output` with `_to_json`, `_of_json`, `_jsonschema` for each, with doc comments in the file's style.

**Step 2: Failing tests first** — in `test/test.ml`: parse `leads_two.json` (expect 2 leads, exact field values), `leads_empty.json` (expect `[]`), and a round-trip `scout_output_to_json |> scout_output_of_json` equality. Write the mock JSON files to match the schema (top-level object with `leads` array and `skip_note`; lead fields exactly as the type). Run `dune runtest` — expect FAIL (types don't exist yet), then implement Step 1, then expect PASS.

**Step 3: Gates, then commit** — `"Add scout lead types for general review pipeline"`

**Success criteria:** round-trip + parse tests pass; jsonschema value builds (it's exercised at agent-config construction — assert `Review_types.scout_output_jsonschema` is a `` `Assoc `` with a `properties` key in a test); gates green.

---

## Task 4: Scout agent module

**Files:**
- Create: `lib/general_scout_agent.ml`, `lib/general_scout_agent.mli`
- Test: `test/test.ml`

Model the module structure on `lib/general_validator_agent.ml` (config value + `build_input`) and the prompt's recall posture on `lib/triage_agent.ml`. The prompt below is normative — transcribe it, don't rewrite it.

**Step 1: `general_scout_agent.mli`:**

```ocaml
(** General review scout — first stage of the general review pipeline.

    Reads the change diff and emits capped investigation leads for the
    deep reviewer.  Biased toward over-flagging: a missed lead is
    unrecoverable downstream; a bogus lead costs one paragraph of deep
    review.  Never emits style/naming/documentation leads, and skips
    security leads when the security plugin covers them. *)

(** Agent configuration for the scout.  [model_tier] comes from
    [general_plugin_config.scout_model_tier]. *)
val config : model_tier:Agent_runner.model_tier -> security_covered_elsewhere:bool -> Agent_runner.agent_config

(** Build the scout's user message from the annotated diff and change
    metadata.  File contents are deliberately excluded — the scout notices,
    the deep reviewer verifies. *)
val build_input : diff_text:string -> change_title:string -> change_description:string -> unit -> string

(** Truncate leads to [max_leads], keeping highest-confidence first (stable
    within a confidence band).  Logs what was dropped. *)
val cap_leads :
  ?log_context:string -> max_leads:int -> Review_types.scout_lead list -> Review_types.scout_lead list
```

**Step 2: system prompt** (in the `.ml`; `security_covered_elsewhere` selects between including the security paragraph or the exclusion paragraph, mirroring how `Review_prompt.system_prompt` handles the same flag — read that function first):

```
You are a code-review scout. You read a change diff and produce a list of
investigation leads for a deep reviewer. You do NOT verify, you NOTICE.

## Posture

Bias toward over-flagging. It is cheap for the deep reviewer to dismiss a
lead; it is expensive to miss a real defect because no lead pointed at it.
When in doubt, emit the lead. But every lead must name a concrete, checkable
hypothesis — "this function looks complex" is not a lead.

## What makes a good lead

- Deleted or weakened guarantees: removed checks, dropped error branches,
  narrowed retries/timeouts/locks, behavior removed while callers still
  depend on it.
- Cross-boundary drift: an interface, schema, enum, or contract changed in
  one place while siblings/callers/implementations visible in the diff (or
  clearly implied by it) were not updated.
- Silent behavior changes: same signature, different semantics — changed
  defaults, reordered operations, altered rounding/encoding/timezone/null
  handling.
- Unhandled cases introduced by the change: new enum variants, new error
  paths, new inputs that existing branches don't cover.
- Suspicious edits: off-by-one candidates, inverted conditions, swapped
  arguments, copy-paste with a missed rename, resource acquired but not
  released on a new path.
- Concurrency and lifecycle: new shared mutable state, lock scope changes,
  async operations whose failure or cancellation is now unobserved.
- Material performance regressions: new work inside hot loops, N+1 patterns,
  unbounded growth.

## What is NEVER a lead

- Style, formatting, naming, documentation, comment wording.
- Praise or "consider" suggestions without a failure hypothesis.
- Pre-existing problems the diff neither touches nor worsens.
- Missing tests, unless a specific broken input/branch can be named.
{SECURITY_SECTION}

## Output

Produce a JSON object matching the schema:
- `leads`: array of {path, line, end_line?, hypothesis, category, confidence}.
  * `path`/`line` copied verbatim from the annotated diff's file headers and
    left-column line numbers — never estimated.
  * `hypothesis`: one or two sentences: what might be wrong, and what the deep
    reviewer should check to confirm or refute it.
  * `category`: one of the finding categories (bug, logic, error_handling,
    performance{SECURITY_CATEGORY}).
  * `confidence`: high | medium | low — your confidence the lead deserves deep
    review, not that it's a confirmed defect.
- `skip_note`: one line naming the parts of the diff you deliberately did not
  flag and why (e.g. "test-only churn, generated lockfile"). Empty string if
  nothing was skipped.

Order leads by confidence, highest first. Emit an empty `leads` array when the
change genuinely warrants no deep review — an honest empty scout report is
valuable. Your final response must be a single JSON object matching the schema,
no markdown fences, no prose.
```

Where `{SECURITY_SECTION}` is, when `security_covered_elsewhere = true`:
```
- Security vulnerabilities (injection, XSS, authn/authz, SSRF, secrets):
  a dedicated security pipeline reviews this change; do not duplicate it.
```
and when `false`:
```
Security-relevant changes (injection, XSS, authn/authz, SSRF, secrets
handling) ARE valid leads — flag them with category "security".
```
`{SECURITY_CATEGORY}` is `""` when covered elsewhere, `, security` otherwise.

**Step 3: `config`** — name `"general_scout"`, `output_schema = Review_types.scout_output_jsonschema`, `max_steps = 1`, `thinking_budget = Some 2048`, `model_tier` from the parameter.

**Step 4: `build_input`** — mirror `General_validator_agent.build_input`'s Buffer style: change title + description sections, then `Review_prompt.annotated_diff_format_explainer`, then `## Diff` + diff_text. NO file contents.

**Step 5: `cap_leads`** — sort is FORBIDDEN to reorder the model's within-band ordering: use `List.stable_sort` on `Config_types.confidence_rank` descending, take first `max_leads`, log dropped count + their `path:line` at info level (Devkit `Log.from "general_scout"` — copy the logging pattern from `general_review_plugin.ml`).

**Step 6: Tests (write failing first, then implement):**
- `cap_leads` with 12 mixed-confidence leads and `max_leads:10` keeps the 10 highest-confidence, preserves relative order within bands.
- `cap_leads` with fewer than `max_leads` is identity.
- `build_input` contains title, description, explainer, and diff in that order (substring index assertions).
- `config ~model_tier:Standard ~security_covered_elsewhere:true` has name `"general_scout"`, `max_steps = 1`, and its system prompt contains "do not duplicate it"; with `~security_covered_elsewhere:false` it contains `category "security"`.

**Step 7: Gates, commit** — `"Add general scout agent"`

**Success criteria:** all Step 6 assertions pass; prompt in the `.ml` matches this plan verbatim modulo the `{...}` substitutions; no other lib file modified; gates green.

---

## Task 5: Deep reviewer agent module

**Files:**
- Create: `lib/general_deep_reviewer_agent.ml`, `lib/general_deep_reviewer_agent.mli`
- Test: `test/test.ml`

**Step 1: `.mli`:**

```ocaml
(** General deep reviewer — second stage of the general review pipeline.

    Receives the scout's investigation leads and verifies each one against
    the diff and the contents of the files the leads point at.  Disprove-first
    posture: a lead only becomes a finding when the reviewer fails to refute
    it and can ground it in visible code.  Emits the same
    [Review_types.review_output] as the legacy single-pass review, so the
    downstream candidate filter and validator are unchanged. *)

val config :
  model_tier:Agent_runner.model_tier -> system_prompt_override:string option -> Agent_runner.agent_config

(** Build the deep reviewer's user message: formatted leads, then change
    metadata, then contents of ONLY the files referenced by leads (drawn
    from [file_contents], which holds what was already fetched for the
    review), then the annotated diff. *)
val build_input :
  leads:Review_types.scout_lead list ->
  diff_text:string ->
  change_title:string ->
  change_description:string ->
  file_contents:(string * string) list ->
  unit ->
  string
```

**Step 2: system prompt** (normative; `system_prompt_override` replaces it wholesale when `Some`, mirroring the legacy behavior of `config.system_prompt_override`):

```
You are a deep code reviewer. A scout has flagged investigation leads in this
change. Your job is to verify each lead — not to re-review the whole diff.

## Method — for every lead, in order

1. Restate the lead's hypothesis in your own words.
2. Try to DISPROVE it: look for the guard, the caller contract, the test, the
   sibling update, or the invariant that makes the code correct despite the
   scout's suspicion. Most leads should die here.
3. Only if you cannot disprove it: establish the concrete failure — the input,
   state, or sequence that triggers it, and what goes observably wrong.
4. A confirmed lead becomes a finding with evidence copied verbatim from the
   provided code, anchored to the changed line responsible.

## Scope discipline

- Investigate every lead; do not skip any.
- Do not sweep the diff for new issues. If verifying a lead directly exposes a
  different defect in the same code you are reading (e.g. you check a guard and
  the guard itself is inverted), you may report it — nothing else.
- If the provided file contents are insufficient to confirm a lead, say so in
  the finding only when the risk is severe (critical severity with the missing
  context named in failure_scenario); otherwise drop the lead. Never guess.

## Findings

Only emit findings for defects with a concrete failure scenario. No style,
naming, documentation, praise, or "consider" comments — those are rejected
downstream and waste the lead's slot. severity: critical for likely breakage,
data loss, or corruption; warning for realistic failure paths; suggestion only
for a directly actionable correctness improvement. confidence reflects how
solid your verification evidence is.

## Output

A single JSON object matching the schema (summary, findings, overall
assessment). In `summary`, one line per lead: "L<n> <path>:<line> —
confirmed/refuted: <ten words>". `findings` contains only confirmed leads (and
any directly-observed defect per Scope discipline). Each finding's fields
follow the schema; `evidence_snippet` must be verbatim code from the provided
diff or file contents; `line` must be copied from the annotated diff's left
column or a file's numbered content, never estimated. No markdown fences, no
prose outside the JSON.
```

**Step 3: `config`** — name `"general_deep_review"`, `output_schema = Review_types.review_output_jsonschema`, `max_steps = 1`, `thinking_budget = Some 4096` (moved here from the legacy single-pass constant), `model_tier` from parameter.

**Step 4: `build_input`** — Buffer style again:
1. `## Investigation Leads` — numbered `L0, L1, …` with Location / Category / Confidence / Hypothesis lines (mirror `General_validator_agent.format_finding`'s formatting approach).
2. `## Change` — title + description.
3. `## Relevant File Contents` — for each `(path, contents)` in `file_contents` where `path` equals some lead's `path` (dedup paths, preserve `file_contents` order), emit `### File: <path>` + contents. Reuse the formatting the legacy path used for file contents — read `Review_prompt.build_user_message` first and copy its file-section format (including any truncation logic) so the model sees a familiar shape.
4. `Review_prompt.annotated_diff_format_explainer`, then `## Diff` + diff_text.

**Step 5: Tests (failing first):**
- `build_input` with 2 leads over files A and B, and `file_contents` covering A, B, C: output contains A and B sections, NOT C; leads numbered `L0`, `L1`; diff last.
- `build_input` with duplicate-path leads includes that file's contents once.
- `config` honors `system_prompt_override = Some "X"` (system_prompt = "X") and has name `"general_deep_review"`.

**Step 6: Gates, commit** — `"Add general deep reviewer agent"`

**Success criteria:** Step 5 assertions pass; prompt verbatim per plan; output type is the existing `review_output` (no new output types introduced); gates green.

---

## Task 6: Pipeline wiring (the risky one — dispatch with full plan + design doc)

**Files:**
- Modify: `lib/general_review_plugin.ml` (and `.mli` if it exposes internals — read it first)
- Modify: `lib/api_local.ml` (mock routing for the two new agent names, ONLY if the existing `agent_response_map` doesn't already route arbitrary names — read `lib/api_local.ml:288–310` first; it likely needs no change)
- Create: `test/mock_api_responses/deep_review/confirmed_one.json` (a valid `review_output` with 1 finding), reuse Task 3's scout mocks
- Test: `test/test.ml`

**Step 1: Read** `lib/general_review_plugin.ml` fully. The legacy `run_review` body becomes `run_single_pass` (verbatim extraction — the fallback path). Note: after Task 2, `config.model` is `string option` and threads via `?model_id`.

**Step 2: New flow** in `run_review`, selected by `config.review_plugins.general.scout_enabled`:

```ocaml
(* Sketch — adapt names to the file's conventions. Stages:
   1. scout: General_scout_agent.config ~model_tier:general_cfg.scout_model_tier
        ~security_covered_elsewhere, input from General_scout_agent.build_input
        (no model_id override — scout always follows its tier).
      Parse Review_types.scout_output_of_json; on parse failure → Error like
      the legacy path. Cost_tracking.of_agent_result ~agent_name:"general_scout".
   2. cap: General_scout_agent.cap_leads ?log_context ~max_leads:general_cfg.max_leads.
   3. early exit: leads = [] → log "scout found no leads, skipping deep review";
      return Ok { summary = "Scout found no investigation leads."; findings = [];
      overall_assessment = "" } with scout cost only. Deep reviewer and validator
      MUST NOT run (assert in tests via response-map omission — see Step 4).
   4. deep review: General_deep_reviewer_agent.config
        ~model_tier:general_cfg.deep_reviewer_model_tier
        ~system_prompt_override:config.system_prompt_override
        (CAREFUL: two fields share this name — Config_types.config has a
         TOP-LEVEL system_prompt_override (config_types.ml:210) and
         general_plugin_config has another (line 114). The legacy path reads
         the TOP-LEVEL one (general_review_plugin.ml:137). Preserve that
         exact source; do not switch to the plugin-level field.),
      ?model_id:general_cfg.model (the explicit override — deep reviewer only),
      input from build_input with metadata's title/description/file_contents.
      agent_name:"general_deep_review".
   5. downstream: EXISTING filter_candidates + run_validator, unchanged. *)
```

`security_covered_elsewhere` keeps its current derivation. All costs concatenate: scout :: deep :: validator-costs.

**Step 3: Legacy fallback** — `scout_enabled = false` routes to `run_single_pass`, byte-identical behavior to pre-change (including its `4096` thinking budget and prompt); existing legacy tests must keep passing against it (point at least one existing general-review test at `scout_enabled = false` config explicitly).

**Step 4: Integration tests** (failing first) using `Api_local.set_agent_response_map`:
- **Full flow:** map `general_scout` → `scout/leads_two.json`, `general_deep_review` → `deep_review/confirmed_one.json`, `general_validator` → an existing/new validator mock confirming candidate 0. Assert: findings length 1, cost list has ≥3 entries with agent names `general_scout`, `general_deep_review`, `general_validator`.
- **Early exit:** map ONLY `general_scout` → `scout/leads_empty.json`. Deliberately omit deep-review/validator entries — if the pipeline wrongly calls them, `Api_local` falls back to the default review-response file and the finding count/cost assertions catch it. Assert: 0 findings, exactly 1 cost entry named `general_scout`.
- **Cap:** map scout → `scout/leads_overflow.json` (12 leads) with `max_leads = 10`; assert the deep-review input (if `Api_local` records inputs — check; otherwise assert via `cap_leads` unit test only and note it).
- **Legacy:** `scout_enabled = false` + existing mock → previous behavior (reuse an existing test's assertions).
- Clean up with `clear_agent_response_map`/`reset_agent_response_path` exactly as neighboring tests do.

**Step 5: Gates, commit** — `"Wire scout → deep reviewer pipeline into general review plugin"`

**Success criteria:** all four integration tests pass; every pre-existing test passes WITHOUT modification except tests explicitly re-pointed at `scout_enabled = false` (list them in the report — more than 2 such edits is a drift signal, stop and report); `run` still returns `(findings, costs)` with plugin name `"general"`; gates green.

---

## Task 7: Final sweep & release gate

**Files:**
- Modify: `docs/README.md` or `docs/plans/README.md` ONLY if they index plan documents (check; add the two new docs to the index in the existing format)
- No other file modifications — this task is verification.

**Step 1:** Full gates on a clean tree: `dune build && dune runtest && dune build @fmt --auto-promote && git status --porcelain` (expect: empty).
**Step 2:** Offline smoke: run the local review CLI against a synthetic diff with BOTH plugins disabled via inline config (see the repo's established local smoke pattern: `review-diff`/`review-path` with `--config` disabling plugins) — asserts the CLI plumbing didn't regress. Then, IF an `ANTHROPIC_API_KEY` is configured in `secrets.json`, optionally run one live `review-diff` on a small synthetic diff with the scout pipeline enabled and report the per-agent cost lines (`general_scout`, `general_deep_review`) from the logs. If no key: skip, say so.
**Step 3:** Report: diffstat per task, deviations (should be none), out-of-scope discoveries, and the live-smoke cost numbers if run.
**Step 4:** Final commit if the index changed — `"Index scout/deep-reviewer design and plan docs"`.

**Success criteria:** clean tree, green suite, report delivered. NO push, NO PR — José reviews the branch himself.

---

## Explicitly OUT of scope for this plan (do not let any subagent start these)

- v2 benchmark/corpus work, v3 tool use, v4 re-review reconciliation (see design doc roadmap).
- Any security plugin change.
- OpenRouter/non-Anthropic providers.
- Prompt "improvements" beyond the normative texts above.
