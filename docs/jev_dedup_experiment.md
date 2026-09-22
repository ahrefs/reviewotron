# Jev semantic dedup experiment

This benchmark asks whether two analysis candidates describe the same underlying
security defect and would be resolved by one concrete repair. It runs before any
Reviewotron integration change.

Run it with:

```sh
TYPESAFE_API_KEY=... dune exec ./test/jev_dedup_benchmark.exe -- --repeats 5 > results.jsonl
```

The corpus contains 18 balanced pairs. Duplicate pairs include different anchor
lines, cross-file evidence, paraphrased descriptions, and different vulnerability
classes for the same command-injection sink. Distinct pairs include adjacent
defects and separate authz and injection defects sharing the same sink line.

## 2026-09-22 baseline

| Method | Correct pairs |
| --- | ---: |
| Exact `(sink.path, sink.line)` | 10/18 |
| Same class and sink within three lines | 11/18 |
| Jev, one authored orientation at threshold 0.70 | 90/90 repeated decisions |
| Jev, raw judgments in both orientations at threshold 0.70 | 175/180 repeated decisions |
| Jev, mean of both orientations at threshold 0.65 | 90/90 repeated pair decisions |

Swapping `finding_a` and `finding_b` changed probabilities by 0.037 on average
and as much as 0.19. Combining both orientations removed that ordering artifact:
the highest distinct-pair mean was 0.60 and the lowest duplicate-pair mean was
0.705. The perfect threshold interval on this corpus was 0.601–0.705.

The symmetric run made 180 requests with no service failures, used 116,230 input
tokens, and cost $0.004882. Median request latency was 241 ms. The two orientations
can be requested concurrently if this is integrated.

These are hand-authored pairs based on Reviewotron's observed failure modes. The
result shows that semantic dedup is technically plausible and materially stronger
than line heuristics on these cases. A held-out set of real analysis outputs is
still required before changing production deduplication.
