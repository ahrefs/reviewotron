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

## 2026-09-25 production-output evaluation

We replayed the security pipeline for 14 recent reviews and captured 26 real
post-dedup analysis candidates. Labels and thresholds were frozen before Jev
scoring. The development and held-out sets each contained an equal number of
duplicate and distinct pairs.

| Set | Exact sink | Jev at symmetric mean 0.50 | False merges |
| --- | ---: | ---: | ---: |
| Development, 18 pairs | 9/18 | 85/90 repeated decisions | 0/45 |
| Held out, 12 pairs | 6/12 | 50/60 repeated decisions | 0/30 |
| Combined unique patterns | 15/30 | 27/30 | 0/15 distinct pairs |

Across the combined sets, Jev recovered 12 of 15 duplicate patterns with
different anchors; exact sink matching recovered none. The 300 judgments had no
service errors and cost $0.017657. This evidence supports the opt-in integration
at a 0.50 threshold. The source review corpus remains private and is not vendored
with the repository.
