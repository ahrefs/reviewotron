# Security pipeline — known issues

Snapshot of open problems in the security review pipeline as of 2026-04-27,
written after a session that attempted a fix and then reverted it. Pre-fix
state matches commit `8060c13` on `security-review`. The one fix that did
land in this session is the empty-`skip_reason` defensive guard
(see "Resolved this session" below).

The pipeline has four agent stages, in order:

1. **Triage** (Haiku) — flags candidate regions per vuln class.
2. **Per-class analysis** (Sonnet, one per `vuln_class`, parallel) — produces
   `candidate_finding` records with source, sink, flow, confidence.
3. **Dedup** — pure OCaml pass over candidates, keyed on `(sink.path, sink.line)`.
4. **Validator** (Sonnet) — adversarial confirm/reject on each candidate.

Most issues below sit at one of those four stages. The "Layer" field on each
issue points at where to fix it.

---

## Issue 1 — Within-PR duplicates: same defect surfaces 2–3× to user

**Layer:** dedup pass (`lib/security_review_plugin.ml:dedup_candidates`)

**Observed:** PR #75 emitted IDOR three times; #76/#77 emitted SQL injection
twice; #74 emitted IDOR twice. Independent reviewer's complaint #1.

**Mechanism (suspected):** per-class analysis agents anchor on slightly
different sink lines for the same defect (e.g. authz agent picks the route
handler signature line, injection agent picks the SQL exec call three lines
down). Dedup keys on `(sink.path, sink.line)` exactly, so adjacent-but-distinct
sinks never collapse and both reach the validator and the user.

**Verification needed:** read the dedup logs and the `candidate_finding`
sinks for one of #75/#76/#77 to confirm sink lines actually differ by a few
rather than being the same. The dedup log only prints lines that *did*
collapse, so distinct-sink duplicates are silent in the logs by design —
need to grep the analysis_agent JSON debug dumps in `debug/` for these PRs.

**Fix space:**
- *Fuzzy-line dedup*: collapse candidates whose sinks share the same path
  and are within N lines (e.g. N=3) of each other. Risk: collapsing two
  genuinely distinct defects in a tight handler (e.g. an IDOR check missing
  on line 42 and a SQL concat on line 45). Acceptable if the validator
  prompt is tightened to confirm the kept finding's framing covers both.
- *Anchor canonicalization at analysis time*: amend `analysis_agent.ml`
  prompt to instruct each agent: "for a defect inside an Express/Hono
  handler, anchor sink on the line of the dangerous call itself, not on
  the route declaration or middleware chain." Cheaper than a code change
  and avoids the over-collapse risk, but harder to verify it sticks.
- *Both*: prompt fix first, then a small fuzzy-line guard as a backstop.

**Cost vs. value:** fuzzy-line dedup is ~20 lines + tests. Prompt change is
1 paragraph + a corpus regression run. Both worth trying before either is
called done.

---

## Issue 2 — Chained markdown XSS detected only 1/5 runs (now 0/5 in #79–#83)

**Layer:** distributed across analysis, dedup, and validator.

**Observed:** the chained vulnerability — markdown rendered to HTML returned
as response body, with `text/plain` content-type that the same response sets
from an attacker-controlled `filename` parameter — was correctly flagged on
PR #75 (1/5 in the first batch) and on PR #74 in the second batch, missed
otherwise. In the third batch (#79–#83) the failure pattern shifted to
"dedup ate the XSS framing because both findings shared the source line".

**Three sub-mechanisms, each in a different file:**

### 2a — Dedup over-collapse on coincidental anchor (PRs #77, #78, #80, #82)

The XSS agent anchors on the body-emission line *and the same handler entry
line as the source*; the injection agent anchors on the header-write line
*and the same handler entry line as the source*. Dedup sees identical
`(sink, source)` if keyed on both, and identical `(sink)` if keyed on sink
alone. Either way, one framing wins on tiebreakers, the other is dropped.

Attempted in this session: tighten dedup key to `(sink.path, sink.line,
source.path, source.line)`. **Did not work** because in this codebase both
analysis agents anchor `source` on the function/handler signature line
(where `req` enters scope), not on the specific field accessed. Reverted.

**Better fix to try next:** add `vuln_class` to the dedup key. Within-class
duplicates (3× injection at notes.ts:99, all from the same agent across
runs) still collapse — they share `vuln_class`. Cross-class chained findings
at the same sink survive. Risk: re-admits some of the across-class duplicates
from before commit 8060c13; need to measure pre-dedup candidate counts to
size that risk.

**File:** `lib/security_review_plugin.ml:dedup_candidates` around line 280.

### 2b — Validator-isolation: text/plain defence-in-depth rejection (PR #76)

When the chained XSS *did* reach the validator on PR #76, validator rejected
it with reasoning along the lines of "content-type is text/plain so this
isn't a standard XSS vector". The validator considers each finding in
isolation; it never sees that another co-located finding shows the
content-type header itself is attacker-tainted, defeating that defence.

Attempted in this session: a "Chained Findings at the Same Sink" section in
the validator system prompt + clustering candidate findings by sink in
`build_input`. **Reverted** because the independent reviewer flagged
"severity calibration drifted" and "a new false positive emerged on
middleware coverage" in the post-change batch, suggesting the validator
generalised the rule beyond the cluster case. Also, the change only helps
when both findings *survive dedup* — which they currently don't (see 2a).

**Better fix to try next:** order matters. Fix dedup first (2a) so both
findings reliably reach the validator. Then revisit the prompt change with
tighter scoping ("only when this finding's mitigation argument is itself
named as the source/sink of another finding in the same input") so the
validator can't generalise the rule.

**File:** `lib/validator_agent.ml` system prompt + `build_input`.

### 2c — XSS agent doesn't anchor on body emission (PRs #74 lost it; #83 lost it)

In PR #83 the XSS agent produced 3 findings, none at `export.ts:24` or
`:20` — the body-emission sink wasn't in its output at all. PR #74 had
similar variance. The XSS section of the analysis-agent prompt has explicit
false-positive carve-outs for `text/plain` and `application/json` responses
(`xss_section` line 290 of `lib/analysis_agent.ml`); those rules likely
suppress the body-emission framing in cases where the response carries one
of those content types — even when those headers are themselves tainted.

**Better fix to try next:** rewrite the XSS sink catalog to include
"rendered HTML returned as a response body, *regardless of the declared
content-type*, when the content-type header itself comes from
attacker-controlled input on the same response object" as an explicit
**Server-Side Template Rendering** sink. Move the text/plain/JSON
"safe pattern" entries from the FP list into a new "conditionally safe —
verify content-type is hardcoded or framework-default" subsection.

**File:** `lib/analysis_agent.ml`, `xss_section` around line 198.

---

## Issue 3 — Validator rejects on "trusted authn" without checking authn integrity

**Layer:** validator prompt + analysis-agent triage handoff.

**Observed:** in batch 1 (PRs #75, #76) the reviewer flagged that the agent
treats `user.sub` interpolation in SQL as safe by reasoning "user.sub is a
trusted authenticated identity, not user-controlled". This is the same
pathology as 2b but generalises beyond text/plain: any time a defence
requires another part of the system to be sound, the validator cites the
defence without checking the precondition.

**Why the reviewer's instance matters:** if AuthN can be bypassed elsewhere
in the diff (and JWT-without-exp findings sometimes appear in these reviews),
`user.sub` is attacker-controllable. The validator should not treat any
authenticated-identity-derived value as inherently safe when the same diff
contains an authn finding.

**Fix space:** part of the same prompt rewrite as 2b; the rule is
"co-located authn finding ⇒ authenticated-identity values are no longer
safe sources for downstream sinks".

**File:** `lib/validator_agent.ml`.

---

## Issue 4 — Systematic false negatives in source/sink coverage

**Layer:** triage prompt + analysis-agent source/sink catalogs.

**Observed:**
- **Cookie reflection in JSON response (0/5 across batch 1, 0/5 across batch 2).**
  The recent-searches cookie value flows back unsanitized into a JSON
  response body. Subdomain-set or XSS-set cookies pollute the response.
  Every run misses it.
- **Standalone javascript:-scheme markdown XSS via note.body** (separate from
  the chained version). Only surfaced as part of the chain in #74; the
  isolated rendering path on the regular notes page is missed in 4/5 runs.

**Mechanism (suspected):** the XSS section of the analysis prompt explicitly
calls out "Content rendered as JSON API responses (`Content-Type:
application/json`) — not interpreted as HTML by browsers" as a "do not
report" pattern. That carve-out is correct in isolation but wrong when the
JSON value will be read back into an HTML-rendering context (admin dashboard,
logging UI, etc.). For the standalone javascript: scheme miss, the markdown
renderer's `encodeURI` not escaping `:` is a sink the catalog doesn't list.

**Fix space:**
- Add cookie sources explicitly to the XSS source list (already there for
  some langs, but the JSON-response sink is the missing piece).
- Add `markdown-it` / `marked` / etc. specifically to the XSS sink catalog
  with a note about `encodeURI` vs `encodeURIComponent` and the colon issue.
- Soften the "JSON responses are not interpreted as HTML" rule to require
  the agent to verify *who reads the response* before applying the carve-out.

**File:** `lib/analysis_agent.ml`, `xss_section`.

---

## Issue 5 — Calibration drift between batches

**Layer:** all four — needs a regression harness rather than a code fix.

**Observed:** the independent reviewer summarising the third batch
(PRs #79–#83) said: "the improvements from 74–78 (stable header injection
severity, chained XSS detection, cleaner Hono routing model) didn't hold.
Severity calibration drifted, the chained XSS detection vanished, cookie
misuse regressed, and a new false positive emerged on middleware coverage."

**Why this is hard:** we currently evaluate by re-running the same diff
through real LLM calls and reading the posted reviews. That's both expensive
and noisy — it conflates "did our prompt change help?" with "did the model
get unlucky on this specific run?". Five samples is too few to tell.

**Fix space:**
- *Fixed-input regression harness*: capture the diff + the four agent
  invocations + their prompts as a frozen test corpus, run the corpus
  through the pipeline N times (N≥10), measure the rate at which each
  known-true-positive is caught and each known-false-positive is rejected.
  Run the corpus before and after every prompt change.
- *Snapshot the prompts in version control alongside the corpus* so that
  "we changed X and the rate moved from Y to Z" is a meaningful comparison.
- The existing `security_e2e` tests are good for plumbing but use mocked
  agent responses — they cannot detect prompt regressions.

**Cost:** 1–2 days for a basic harness over a canonical test diff. Pays for
itself the first time we catch a regression before shipping.

---

## Resolved this session

### Empty `skip_reason` silenced the pipeline

**Layer:** `lib/security_review_plugin.ml` (`run`).

**Observed:** on a real PR, triage emitted
`skip_reason: ""` (empty string) instead of `skip_reason: null` despite
having signals to report. The `match` on `skip_reason` treated `Some ""`
identically to `Some "real reason"` and bailed out of the security pipeline
with `triage: skipped ()` in the logs.

**Fix:** in `run`, normalise `Some s` where `String.trim s = ""` to `None`
before deciding whether to skip. If signals are also empty, the existing
"no actionable signals" branch in `run_analysis` handles it correctly.

**Test:** `security_e2e / empty skip_reason does not silence pipeline` —
fixture in `test/mock_api_responses/security/triage_injection_empty_skip.json`
exercises a triage output with non-empty signals + `skip_reason: ""` and
asserts a security finding is still emitted.

---

## Suggested order of attack

If you sit down with this list, here's the order I'd take:

1. **Issue 5 (regression harness)** — without this, every other change is
   a guess. Build it first, then everything below has measurable success
   criteria.
2. **Issue 2c (XSS sink catalog rewrite)** — biggest expected lift on the
   chained-XSS hit rate, isolated to one prompt section, no pipeline
   changes.
3. **Issue 1 (within-PR duplicates)** — the prompt-only anchor
   canonicalization fix first; only add fuzzy-line dedup if the prompt
   fix doesn't stick.
4. **Issue 2a (dedup key with vuln_class)** — small, contained, easy to
   roll back. With harness in place, the trade-off is measurable.
5. **Issue 2b + 3 (validator chained-finding rule)** — last, because it
   only matters when 2a is fixed and it's the change most prone to
   over-generalisation. The reverted attempt this session shows that.
6. **Issue 4 (cookie/JSON coverage)** — tightening the false-positive
   carve-outs and adding missing sinks; spot-fix as time allows, harness
   keeps it honest.

Issue 5 first is non-negotiable — running blind is what got us into the
calibration-drift situation in the first place.
