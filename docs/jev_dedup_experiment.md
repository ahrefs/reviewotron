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

That evaluation compared post-dedup analysis candidates. It did not measure
same-sink claims already removed by the existing deterministic pass, evidence
loss from selecting one candidate, or final unique-defect recall. The result
supports semantic relationship discovery, not pre-validation suppression.

## 2026-09-25 lossless confirmed-finding evaluation

A second frozen corpus contains all 35 within-review pairs among 20 independently
confirmed findings. Eight pairs were labeled as sharing a causal source or
control; 27 required separate publication. Each finding included its validator
evidence and proof.

The strict question asked whether Jev could authorize publishing a pair as one
finding. At threshold 0.50 it proposed none of the 40 positive repeated decisions
and made no false proposals. The finding proofs did not establish enough shared
source-of-truth or generation evidence for a safe merge.

The lossless retrieval question instead asked whether a pair warranted shared
verification. Requiring both orderings to reach 0.70 produced:

| Repeated decisions | Result |
| --- | ---: |
| True proposals | 40/40 |
| Missed proposals | 0/40 |
| Extra verification proposals | 66/135 |
| Correctly separate | 69/135 |

This is useful as a recall-oriented proposal stage: it retrieves every labeled
relationship while sending about 13 additional pairs per 35-pair repetition to
a verifier. It is not precise enough to merge findings directly. Both runs
made 700 requests with no service errors, used 1,854,060 input tokens, and cost
$0.077871.

The implementation therefore validates every candidate, preserves confirmed
same-line findings, and records Jev grouping proposals only after validation.
No proposal changes the published review.

## 2026-09-25 consolidation-verifier evaluation

The Jev proposal stage now feeds a pairwise reasoning verifier in shadow mode.
The verifier accepts a consolidation only when it names one shared cause and
repair, returns both member IDs and sink locations, and has no unresolved
assumptions. Original findings and proofs remain in the debug artifact; review
publication is unchanged.

On one frozen repetition, Jev proposed 21 of the 35 confirmed-finding pairs: all
8 labeled shared-cause pairs and 13 separate controls.

| Verifier evidence | Shared-cause accepted | Separate controls rejected | Cost |
| --- | ---: | ---: | ---: |
| Captured finding proofs only | 1/8 | 13/13 | $0.818153 |
| Exact reviewed diff, seven remaining positives | 0/7 | — | $0.726488 |
| Exact diff plus located generator evidence, seven remaining positives | 7/7 | — | $1.033701 |

The initial run had zero false consolidations but only 12.5% recall. Every miss
correctly named the missing fact: the finding proofs and diff did not prove that
`users_props.ml` generates the affected `authorized_keys` files. Adding the
relevant `gen_authorized_keys.ml` and access-policy excerpts raised the seven
missed positives to 7/7 while satisfying the local evidence-preservation guard.

Allowing the verifier to guess repository paths was both ineffective and
expensive. One unrestricted probe used 12 file fetches and cost $3.141607; a
four-step targeted probe still missed the generator and cost $1.542475. The
useful next change is bounded evidence retrieval that locates source-of-truth
and generated-file relationships before verification. Loosening the verifier
would trade away the zero-false-consolidation result.

## Next Jev experiments

1. Add Jev routing signals to the existing triage union so Jev can increase
   analysis coverage without suppressing an existing route.
2. Check individual source, sink, mitigation, and policy claims against located
   evidence; use uncertainty to fetch evidence or escalate to the validator.
3. Mine analysis/validator disagreements offline to expand independently labeled
   evaluation sets.
4. Suggest finding continuity across revisions while keeping fix verification
   independent.
