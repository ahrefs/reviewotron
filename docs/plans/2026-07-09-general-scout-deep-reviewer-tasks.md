# Scout + Deep Reviewer — Task Manifest (for orchestrator bootstrap)

> **For the orchestrator session:** the harness task list is session-scoped, so
> these tasks will NOT appear in your TaskList. Bootstrap by creating them
> verbatim with TaskCreate (one per section below), then wire dependencies with
> TaskUpdate `addBlockedBy` per the graph. Then execute per the Orchestrator
> Protocol in `2026-07-09-general-scout-deep-reviewer.md`.

**Normative documents (read both in full before dispatching anything):**
- Design: `docs/plans/2026-07-09-general-scout-deep-reviewer-design.md`
- Plan (task steps, scope contracts, gates, anti-drift rules): `docs/plans/2026-07-09-general-scout-deep-reviewer.md`

**Dependency graph:** `1`, `2`, `3` unblocked → `4`, `5` blocked by `3` → `6` blocked by `1, 2, 4, 5` → `7` blocked by `6`.
Branch: `general-scout-deep-reviewer` (cut from `main`). Commit per task, never push, no PRs.

---

## Task 1: Refresh default model tiers to Sonnet 5 / Opus 4.8

Execute "Task 1: Model tier refresh" from the plan.
- **Scope:** `lib/agent_runner.ml{,i}`, `lib/cost_tracking.ml`, `lib/config_types.ml` (jsonschema description only), `test/test.ml`. `lib/llm_provider.ml` only if `normalize_model_id` requires it.
- **Subagent:** model=`sonnet`, persona "meticulous OCaml maintenance engineer".
- **Success:** `default_model_id Standard = "claude-sonnet-5"`, `Strong = "claude-opus-4-8"`; `claude-sonnet-5` pricing entry ($3/$15) added BEFORE the `claude-sonnet-4` prefix entry; pricing resolution test added; no stale model refs (except `config_types.ml:190`, which is Task 2's); `dune build` + `dune runtest` green on the repo's LOCAL opam switch.
- **Commit:** `Refresh default model tiers to Sonnet 5 / Opus 4.8`

## Task 2: Add scout/deep-reviewer config surface to general plugin

Execute "Task 2: Config surface" from the plan.
- **Scope:** `lib/config_types.ml{,i}`, `lib/general_review_plugin.ml` (ONLY the `~model_id` call site), `test/test.ml`.
- **Subagent:** model=`sonnet`, persona "OCaml engineer, config/serialization specialist".
- **Success:** `general_plugin_config` gains `scout_enabled` (default true), `scout_model_tier` (Standard), `deep_reviewer_model_tier` (Strong), `max_leads` (10), exactly as quoted in the plan; top-level `model : string` becomes `string option [@json.option]` (explicit deep-reviewer override; absent ⇒ `None` — grep ALL `.model` consumers and fix minimally); config-parse tests cover defaulting and explicit round-trip; gates green.
- **Commit:** `Add scout/deep-reviewer config surface to general plugin`

## Task 3: Add scout lead types to review_types

Execute "Task 3: Scout output types" from the plan.
- **Scope:** `lib/review_types.ml{,i}`, `test/test.ml`, create `test/mock_api_responses/scout/{leads_two,leads_empty,leads_overflow}.json`.
- **Subagent:** model=`sonnet`, persona "OCaml engineer, serialization specialist".
- **Success:** `scout_lead {path; line; end_line option; hypothesis; category : finding_category; confidence}` and `scout_output {leads; skip_note}` with `_to_json`/`_of_json`/`_jsonschema` each, following `review_types.ml`'s EXISTING deriving conventions (copy `validated_finding`'s pattern); TDD: parse + round-trip tests written failing first; `leads_overflow.json` has 12 leads (Task 6 uses it); gates green.
- **Commit:** `Add scout lead types for general review pipeline`

## Task 4: Add general scout agent module — blockedBy: 3

Execute "Task 4: Scout agent module" from the plan. The system prompt in the plan is transcribed VERBATIM modulo the `{SECURITY_SECTION}`/`{SECURITY_CATEGORY}` substitutions.
- **Scope:** create `lib/general_scout_agent.ml{,i}`; `test/test.ml`.
- **Subagent:** model=`opus`, persona "LLM prompt engineer who writes OCaml; recall-obsessed".
- **Success:** `config ~model_tier ~security_covered_elsewhere` (name `"general_scout"`, `max_steps=1`, `thinking_budget=Some 2048`, `output_schema=scout_output_jsonschema`); `build_input` = title/description + `annotated_diff_format_explainer` + diff, NO file contents; `cap_leads` stable-sorts by `Config_types.confidence_rank` desc, truncates to `max_leads`, logs drops; all plan Step-6 test assertions pass; gates green.
- **Commit:** `Add general scout agent`

## Task 5: Add general deep reviewer agent module — blockedBy: 3

Execute "Task 5: Deep reviewer agent module" from the plan. System prompt VERBATIM.
- **Scope:** create `lib/general_deep_reviewer_agent.ml{,i}`; `test/test.ml`.
- **Subagent:** model=`opus`, persona "senior code reviewer persona-smith; precision-obsessed".
- **Success:** `config ~model_tier ~system_prompt_override` (name `"general_deep_review"`, `max_steps=1`, `thinking_budget=Some 4096`, `output_schema=review_output_jsonschema` — the EXISTING review output type, no new output types); `build_input` = numbered leads `L0..` + change metadata + contents of ONLY lead-referenced files (dedup, preserve `file_contents` order; copy `Review_prompt.build_user_message`'s file-section format) + explainer + diff last; plan Step-5 test assertions pass; gates green.
- **Commit:** `Add general deep reviewer agent`

## Task 6: Wire scout → deep reviewer pipeline — blockedBy: 1, 2, 4, 5

Execute "Task 6: Pipeline wiring" from the plan (the riskiest task — dispatch with the full plan + design doc).
- **Scope:** `lib/general_review_plugin.ml{,i}`; `lib/api_local.ml` only if `agent_response_map` doesn't route arbitrary names (read `api_local.ml:288-310` first — it likely needs nothing); create `test/mock_api_responses/deep_review/confirmed_one.json`; `test/test.ml`.
- **Subagent:** model=`opus`, persona "careful systems integrator; hates behavior changes".
- **Success:** `scout_enabled=true` → scout (tier from config, NO model_id override) → `cap_leads` → EARLY EXIT on zero leads (no deep review, no validator, single `general_scout` cost entry) → deep review (`deep_reviewer_model_tier`, `?model_id:general_cfg.model`, TOP-LEVEL `config.system_prompt_override` per the plan's CAREFUL note — two fields share that name) → existing `filter_candidates` + `run_validator` UNCHANGED; `scout_enabled=false` → legacy single-pass path byte-identical (extracted as `run_single_pass`, keeps 4096 thinking budget); all four plan integration tests (full flow / early exit / cap / legacy) pass; pre-existing tests pass without modification except ≤2 re-pointed at `scout_enabled=false` (list them; >2 = stop and report).
- **Commit:** `Wire scout → deep reviewer pipeline into general review plugin`

## Task 7: Final sweep, offline smoke, release gate — blockedBy: 6

Execute "Task 7: Final sweep & release gate" from the plan.
- **Scope:** docs index files only if they index plan docs; otherwise verification-only, zero code edits.
- **Subagent:** model=`sonnet`, persona "release engineer".
- **Success:** clean tree after `dune build && dune runtest && dune build @fmt --auto-promote`; offline CLI smoke (review-diff/review-path with both plugins disabled via inline `--config`) passes; optional live review-diff smoke with the scout pipeline if an Anthropic key is present — report `general_scout` / `general_deep_review` cost lines; final report with per-task diffstat, deviations, discoveries. NO push, NO PR — José reviews the branch.
