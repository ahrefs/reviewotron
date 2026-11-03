# Decision model calibration

Every decision feature compares a model probability against a threshold, and
probabilities from one decision model say nothing about another. This file
records how the `gpt-6-luna` thresholds in `lib/decision_model.ml` were chosen,
and why Luna keeps the shared production questions. The `jev` values come from
the earlier experiments in `jev_*_experiment.md`.

## Method

`test/decision_calibration_benchmark.ml` sends the production questions from
`lib/decision_questions.ml`. It groups them into requests the way the runtime
does and uses the same question names. A corpus only supplies states and
labels, so a corpus built for an older prompt still measures the shipped one:

```sh
OPENROUTER_API_KEY=... dune exec ./test/decision_calibration_benchmark.exe -- \
  --model gpt-6-luna --feature build_claim --corpus build_claim.json \
  --repeats 1 --orders original,sorted,reversed
```

The corpus format is `{"cases": [{"name", "expected", "state"}]}`, with `state`
in the exact shape production sends. `decision_routing_benchmark
--dump-calibration-corpus` writes the triage corpus. `--dump-questions` prints
the production questions, and `--override FILE` swaps a question for an
experiment.

Apart from the in-repo security corpus, the corpora come from captured
reviews of a private codebase and are not vendored. They are the same labeled
sets behind the Jev numbers.

### Key order changes Luna's answers

Luna returns the same probability for byte-identical input, so repeating a
request measures nothing. Reordering the keys of the same JSON state is a
different story. Across the corpora it moved single probabilities by up to
0.98 (0.00 to 0.98 for one source-constraint case, 0.05 to 0.90 for one
build-claim case). Production always sends one fixed order, but real inputs
vary far more than key order does, so a margin that exists in only one order
will not survive production.

Every case was therefore scored under three orders: the corpus order, keys
sorted, and keys reverse-sorted. A positive counts as caught only if it is
caught under all three. A control counts as harmed if any order harms it.
A threshold had to harm no control. Among the thresholds that passed, the
choice favored distance from the controls.

A first pass scored only the corpus order. Several of its thresholds failed
this test, including a suggestion-guard change from 0.50 to 0.35 that only won
in that order. They were replaced.

## Results (2026-11-03, `openai/gpt-6-luna-decisions-20261006`)

All counts are cases that hold under every key order.

| Feature | Luna threshold | Luna on the corpus | Jev reference (corpus order only) |
|---|---|---|---|
| Triage | 0.70 | 15/15 vulnerable routed (weakest 0.84), 2/7 safe routed | 15/15 at 0.80, 5 of 35 safe repetitions |
| Analysis gate | 0.60 | 8/8 confirmed classes kept (weakest 0.74), 10 of 16 unconfirmed routes skipped | 8/8 kept, 8 skipped |
| Grouping, notification | 0.30 | 10/10 positive pairs grouped, 0/4 controls (max 0.04) | 10/10 and 0/4 at 0.70 |
| Grouping, proposal | 0.30 | 8/8 duplicate pairs proposed, 13/27 others sent to the verifier | 8/8 and about half at 0.70 |
| Build-claim guard | 0.70 | 0/8 false claims, 0/125 controls | 5/5 held-out, plus the source-only false claim |
| Suggestion guard | 0.50 | 5/20 broken fixes removed, 1/18 valid fixes removed | 0 valid fixes removed |
| Cascade confirm | support ≥ 0.40, fatal ≤ 0.30 | 7/23 confirmed candidates bypass the validator, 0/3 rejected | 7/23 at 0.62 / 0.30 |
| Cascade reject | disabled | no safe boundary | 1/3 rejected at 0.70 / 0.30 |
| Source constraint | ≥ 0.30, support ≤ 0.30 | 0/7 constrained findings rejected, 0/28 controls | 4/7 at 0.60 / 0.30 |

Jev was measured before the key-order test existed and could not be
re-measured (see below), so its column is not directly comparable.

## Where Luna is weaker than Jev

- **Build-claim guard.** The five false claims that come with commit checks
  score 0.05–0.95 depending on key order, and one control reaches 0.64.
  No threshold catches a false claim under every order without harming a
  control. At 0.70 the guard rarely fires.
- **Source constraint.** Both human-rejected findings drop to 0.00 under some
  order. All controls stay at 0.00, so the check is harmless and catches
  nothing.
- **Cascade reject.** Six validator-confirmed candidates reach a fatal-defect
  probability of 0.70 or more under some order, so `cascade_reject` is `None`.
- **Suggestion guard.** One fix labeled valid scores as defective under every
  order and threshold.

Grouping, triage, the analysis gate, and the cascade confirm boundary hold
under every order.

## Luna-specific questions (rejected)

Per-model wording was tried for the three weakest features. To avoid fitting
the questions to their own test data, the steps were fixed in advance:

1. Each corpus was split into a dev set and a held-out set before any variant
   ran. Every case whose content had been read during diagnosis went to dev.
2. At most three variants per feature, written as generic guidance that names
   no case, and selected on dev scores under all three key orders.
3. The selected variant ran once on held-out. It would be accepted only if it
   caught at least one more held-out positive than the production question,
   harmed no more controls, and showed a gain in the same range as on dev.

| Feature | Dev result | Held-out result | Decision |
|---|---|---|---|
| Build-claim guard | No variant caught a dev false claim under every order. One scored 0.81 in one order and 0.02 in another; two raised control scores to 0.59 and 0.84 | Not run: nothing passed dev | Keep production question |
| Source constraint | No variant beat production; one raised a control to 0.86 | Not run | Keep production question |
| Suggestion defect | Best variant removed 2/12 broken fixes against 1/12 at zero harm | 1/8 broken removed against 2/8 for production, 0 valid removed by either | Rejected: the dev gain reversed |

Neither the dev nor the held-out results support adopting a variant. Two
results are classic overfitting. A build-claim variant that looked like a
clear win in one key order disappeared under the others. The suggestion
variant's dev gain turned into a held-out loss. The splits are small (3 to 12
positives each), so one case decides a comparison. A real improvement needs a
larger labeled corpus, not more wording.

## Moderation

OpenRouter marks Luna as moderated. Across about 6,000 calibration requests,
which included exploit descriptions and attacker-controlled source code,
OpenAI refused one question: `policy_regression` on an encrypted secrets file.
It refused every time the file was sent in its original key order and
answered when the keys were reordered. OpenRouter returns a refusal as HTTP
502, and the client reports it without retrying. A refused question fails its
whole request and leaves that file unevaluated. Decision triage then falls
back to the primary triager, and the analysis gate keeps every primary route.

## Not yet measured

- **Jev through OpenRouter.** The Jev thresholds were measured against
  TypeSafe's own API (`jev-1.13.0`). Reviewotron now calls `typesafe/jev-1.13`
  through OpenRouter, which reports the same version, but the account used
  here blocks the TypeSafe provider. Rerun the corpora with `--model jev
  --orders original,sorted,reversed` once the provider is allowed. That run
  also shows whether Jev is as sensitive to key order as Luna.
