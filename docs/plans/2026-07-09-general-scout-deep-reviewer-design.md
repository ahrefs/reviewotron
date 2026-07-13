# General Review: Scout + Deep Reviewer Design

**Date:** 2026-07-09
**Status:** Validated with José (session 2026-07-08/09). Implementation plan: `2026-07-09-general-scout-deep-reviewer.md`.

## Motivation

DoorDash published results ([blog](https://careersatdoordash.com/blog/how-we-learned-to-trust-our-ai-code-reviewer-at-doordash/)) showing single-pass AI reviewers caught ~30% of real issues in their PRs, while a staged **scout → deep reviewer → validation** harness (Sonnet 4.6 + Opus 4.8) caught 53.6% at $3.91/PR. Their V2→V3 lesson: the bottleneck was **diffused attention**, not model strength — separating "noticing" from "verifying" is what moved recall.

Reviewotron's **security plugin already has this shape** (triage → per-class analysis → validator, per-stage model tiers, corpus + `quality_metrics` benchmark). The **general plugin does not**: it is a single-pass full-context review (`max_steps = 1`, no tools) followed by a validator — exactly the ~30%-recall regime.

## Goals & Constraints

- **Goal:** higher recall AND better precision for the general review.
- **Constraint:** general review is the accessory (security is the product focus). Total review cost must not rise much; ROI matters.
- **Constraint:** Anthropic models only for now (no Kimi/GLM/Grok). The tier seam must keep future non-Anthropic scouts a config-only change.
- Security plugin untouched in v1.

## Architecture (v1)

```
diff + metadata
      │
      ▼
┌─────────────────┐   no leads   ┌──────────────┐
│ general_scout    │ ───────────▶ │ early exit:  │
│ Sonnet (Standard)│              │ [] findings  │
│ 1 pass, no tools │              └──────────────┘
└─────────────────┘
      │ leads (capped, over-flagging bias)
      ▼
┌──────────────────────┐
│ general_deep_review  │  one batched call, all leads
│ Opus (Strong default)│  input: leads + annotated diff
│ 1 pass, no tools v1  │  + file contents for lead files only
│ disprove-first       │  output: review_output (existing type)
└──────────────────────┘
      │ findings
      ▼
existing filter_candidates → existing general_validator → confirmed findings
```

### Stage contracts

1. **Scout** (`general_scout`, new): reads the diff + change title/description (NOT full file contents). Emits investigation leads `{path, line, end_line?, hypothesis, category, confidence}`. Over-flagging bias like `triage_agent` — a missed lead is unrecoverable; a bogus lead costs the deep reviewer a paragraph. Leads capped (`max_leads`, default 10, truncated by confidence rank with a log line). Style/naming/docs are never leads; security leads suppressed when the security plugin is enabled.
2. **Early exit:** zero leads → plugin returns no findings; deep reviewer and validator never run. Clean PRs get cheaper than today.
3. **Deep reviewer** (`general_deep_review`, new): ONE batched call over all leads (not per-lead fan-out). Input: formatted leads + annotated diff + file contents of only the files referenced by leads (subset of already-fetched `metadata.file_contents`). Posture: try to **disprove** each lead first; only surviving leads become findings. Output reuses `Review_types.review_output` so everything downstream is unchanged. May report a defect it directly observes while verifying a lead, but must not perform a general sweep.
4. **Validator** (existing `general_validator`, unchanged): final precision backstop.

## Model assignment (decided)

| Stage | Tier | Model | Rationale |
|---|---|---|---|
| Scout | `Standard` | Sonnet 5 | Recall ceiling lives here. Haiku-vs-Sonnet input cost difference is cents; not worth risking the ceiling. Security triage gets away with `Fast` because it pattern-matches enumerated vuln classes; general noticing is open-ended reasoning. |
| Deep reviewer | `Strong` (default) | Opus 4.8 | José's call: Opus by default, Sonnet as the config fallback; iterate if too slow/expensive. Matches DoorDash's proven config. Input is lead-focused, so Opus cost stays modest. |
| Validator | `Standard` | Sonnet 5 | Unchanged. |

**Tier refresh (free win):** `default_model_id` still maps Standard→`claude-sonnet-4-6` and Strong→`claude-opus-4-6`, both legacy per current model docs. Bump Standard→`claude-sonnet-5` ($3/$15, intro $2/$10 until 2026-08-31 — cheaper than today) and Strong→`claude-opus-4-8` (same $5/$25 as 4.6). The SDK's `Model_catalog` lacks these variants but `language_model ~model:` accepts raw ID strings; `default_model_id` returns string literals instead. `cost_tracking.ml` needs a `claude-sonnet-5` pricing prefix entry; `claude-opus-4-8` already matches the `claude-opus-4` prefix at correct rates.

**`config.model` trap:** `config.model : string` defaults to `"claude-sonnet-4-6"` and is unconditionally passed to the general review call — the plugin's `model_tier` is currently dead. It becomes `string option [@json.option]`: `None` (absent) → tier decides; `Some id` → explicit override of the deep reviewer only. Scout and validator never read it.

## Cost envelope

Today: 1 Sonnet call (full diff + ALL file contents + 4096 thinking) + validator. New worst case: 1 Sonnet scout (diff only, small output) + 1 Opus call (diff + lead-file subset of contents) + validator. Scout input < today's review input (no file contents). Deep reviewer input ≤ today's (file subset), at Opus rates (~1.7× Sonnet on that call). Net: modest increase on PRs with leads, decrease on clean PRs, partially offset by Sonnet 5 intro pricing. General plugin remains a small share of total review cost (security dominates).

## Config surface (all in `general_plugin_config`)

- `scout_enabled : bool` (default `true`; `false` = legacy single-pass path, preserved verbatim as rollback)
- `scout_model_tier : model_tier` (default `Standard`)
- `deep_reviewer_model_tier : model_tier` (default `Strong`)
- `max_leads : int` (default `10`)
- `model : string option` (was `string`; explicit deep-reviewer override only)

## Roadmap after v1

- **v2 — benchmark before tuning** (the actual DashBench lesson): general-review corpus + replay harness modeled on the security corpus/`quality_metrics`. Ground truth from human review comments on merged PRs, `reviewotron-feedback-events.jsonl` reactions, incident-linked regressions. Metrics: scout lead recall, end-to-end recall/precision, cost per PR. Every knob (scout tier, Opus ROI, `max_leads`, thinking budgets) becomes an experiment.
- **v3 — bounded tool use for the deep reviewer** (reuse `security_tools` `get_file_content`, hard fetch cap, `max_steps ≤ 4`) only if the bench shows context-starvation misses.
- **v4 — re-review reconciliation**: dedup/stale-finding handling across PR iterations on top of `diff_anchor`/`review_comment`.
- **Later:** port lead-focused batching to the security analysis stage if the bench supports it; non-Anthropic scout models via the existing provider seam.
