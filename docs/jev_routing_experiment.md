# Jev routing experiment

This benchmark isolates security-class routing from Reviewotron's analysis and
validator stages. It does not run or post a review.

Run it with:

```sh
TYPESAFE_API_KEY=... dune exec ./test/jev_routing_benchmark.exe -- --repeats 5 > results.jsonl
```

The corpus has 22 diffs: 15 vulnerable cases and 7 safe controls. It includes
cross-file XSS, SQL injection, and authentication changes, plus a multi-hunk
path-traversal change. Each context is scored for all eight security classes.
The evaluation below uses only the corpus's labeled class; an additional class
can legitimately warrant analysis and therefore is not automatically a false
positive.

## 2026-09-22 baseline

Jev model: `jev-1.13.0`. Five repetitions produced 375 requests with no service
failures. Total reported TypeSafe cost was $0.022446.

At a threshold of 0.85:

| Context | True routes | False routes | Misses | Stable decisions | Cost |
| --- | ---: | ---: | ---: | ---: | ---: |
| Per file | 75/75 | 0/35 | 0 | 110/110 | $0.007733 |
| Per hunk | 75/75 | 0/35 | 0 | 110/110 | $0.007994 |
| Whole diff | 74/75 | 0/35 | 1 | 109/110 | $0.006718 |

Per-file and per-hunk routing made identical labeled decisions. Per-hunk
requests cost slightly more and did not improve the multi-hunk case. Whole-diff
routing was cheaper because it made fewer requests, but the authorization case
crossed the threshold across repetitions (0.84–0.87).

At the current experimental threshold of 0.80, every context shape routed all
75 vulnerable repetitions and also routed 5 of 35 safe repetitions. A threshold
of 0.85 cleanly separated this corpus for per-file routing, but it was selected
on the same small corpus and should not be used as a production default until a
held-out set confirms it.

The result supports keeping per-file context as the routing baseline. It does
not establish an end-to-end detection improvement because analysis and
validation were intentionally excluded.
