# Jev candidate-ranking experiment

This benchmark tests whether a TypeSafe Score can order security candidates by
readiness for scarce validator budget. It does not replace validation or discard
candidates.

Run it with:

```sh
TYPESAFE_API_KEY=... dune exec ./test/jev_score_benchmark.exe -- --repeats 5 > results.jsonl
```

The four-level Score rates candidates from contradicted or unsupported evidence
through a concrete source-to-sink or missing-control proof. The balanced corpus
contains eight confirmed and eight rejected candidates across all supported
security classes. It includes mitigating controls such as parameter binding,
numeric reduction, contextual HTML sanitization, ownership helpers, destination
constraints, basename reduction, and scoped sudo rules.

## 2026-09-22 baseline

Across five repetitions:

- every repetition produced AUC 1.0;
- confirmed candidates scored between 2.78 and 2.96;
- rejected candidates scored between 0.02 and 1.06;
- every threshold from 1.25 through 2.75 separated all 80 judgments;
- no request failed;
- 80 requests used 42,810 input tokens and cost $0.001798;
- median request latency was 233 ms and p95 was 306 ms.

The low-confidence boundary cases were numeric reduction before SQL interpolation
and sanitized HTML. That is useful ranking behavior: they remained below every
confirmed candidate without pretending the evidence was unambiguous.

The conservative integration is to sort candidates before validator batching
while still validating all of them. A hard cutoff would trade recall for cost and
needs captured validator outcomes from real reviews as a held-out evaluation.

## 2026-09-25 production-output evaluation

We scored 26 captured post-dedup candidates five times against frozen validator
outcomes: 20 confirmed and 6 rejected. AUC ranged from 0.713 to 0.742, with
substantial overlap between confirmed and rejected scores. The 130 judgments had
no service errors and cost $0.019680.

That separation is too weak to change validator ordering or impose a cutoff, so
candidate ranking is not integrated.
