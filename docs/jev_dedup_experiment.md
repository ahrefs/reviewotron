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

## 2026-09-29 bounded relationship evidence

Reviewotron now derives a bounded list of companion policy and generator paths
from changed source files and affected artifacts. It supplies the first file
that exists, capped at 12,000 characters, and disables exploratory tools when
that evidence is available. Exact validated sink locations are restored in code
when the verifier copies an approximate diff line.

The seven previously missed positive pairs all had one small companion access
policy file. Supplying only that file verified 7/7 pairs for $0.914951. Supplying
both the policy and the larger generator file increased cost and reduced the
strict result to 5/7 because longer outputs copied two sink lines incorrectly.
The one-file automatic locator then verified 7/7 for $1.016241.

A full-fidelity corpus joined all 21 Jev proposals to their exact captured
diffs: eight shared-cause pairs and thirteen separation controls. The first run
exposed one false consolidation: the verifier invented a new restrictive input
allowlist to combine two context-specific shell-escaping defects. The prompt now
requires repository evidence for that input contract and otherwise keeps such
sinks separate. The crux rerun preserved the valid shared-download pair and
rejected the shell-escaping pair.

On the final 21-pair run, the verifier made all 21 intended decisions for
$1.964718: eight consolidate verdicts and thirteen keep-separate verdicts. One
consolidation copied an affected sink at line 29 instead of its validated line
31; deterministic sink preservation restores that exact location without
weakening the cause, repair, member-ID, assumption, or primary-anchor checks.
This established the lossless consolidation boundary before expanding into
notification grouping.

## 2026-09-29 notification grouping

A new real pair broadened the corpus beyond generated artifacts: one change
added `@everyone` to the separate age recipient ACLs for an incus client
certificate and its private key. The strict verifier correctly kept them as two
canonical findings because each ACL requires its own edit and re-encryption.
Jev nevertheless scored the pair as one coherent remediation notification in
all three repetitions.

The notification evaluation then labeled every pair that the strict verifier
kept separate, plus that credential pair. It contains ten positive groups and
four controls that deliberately mix authentication, privilege escalation, or
different attacker-controlled artifacts. Each pair was scored in both orders
for three repetitions.

At the existing 0.70 threshold, all 30 positive repetitions grouped and all 12
negative controls stayed separate. The 84 Jev calls cost $0.009075. This stage
is materially cheaper than the reasoning verifier and covers repeated SQL
injection sites, two ZTP paths with the same unrestricted sudo policy, two
representations of one fleet credential, and two shell contexts fed by the same
input.

Applying the accepted strict and notification edges to the five captured
reviews represented by the corpus reduces 19 confirmed findings to 8 complete
notification groups, a 58% reduction in review comments with no member finding
removed. The later credential ACL pair reduces from two comments to one.

With `jev_grouping_enabled`, verified consolidations and positive notification
pairs now affect publication. Pair edges form complete-link groups so
non-transitive relationships cannot over-group findings. One anchored comment
retains every member location, description, failure scenario, and proposed
replacement; multi-location GitHub suggestions are disabled because one
suggestion cannot safely edit multiple sites.

## 2026-09-29 candidate validation cascade

The first validator-cost experiment joined 26 real analysis candidates to their
captured validator verdicts: 23 confirmed and 3 rejected. Each candidate was
scored three times against only the changed files named by its source, sink, and
flow evidence. The initial four-level completeness Score could not separate the
classes and was discarded.

The successful formulation asks two independent Noul questions in one request:
whether the evidence directly supports the complete finding, and whether it
demonstrates a fatal validation defect. Candidates in the uncertain middle keep
the existing validator. At the measured support/fatal boundary of 0.62/0.30,
seven confirmed candidates crossed the auto-confirm boundary in all three
repetitions and no rejected candidate crossed it. They were all from one captured
review whose two validator calls cost $2.048323. Deterministic proof enforcement
accepts six of the seven; the source-policy candidate stays on the validator path.
The six accepted candidates include all three candidates from the review's second
validator call, which cost $0.557326. Jev costs $0.000503 for all seven candidates,
so eliminating that one call alone saves $0.556823 on the review. Shrinking the
first validator call from four candidates to one should save more, but that
unmeasured amount is not included.

At the inverse reject boundary of fatal probability at least 0.70 and support at
most 0.30, one rejected candidate was rejected in all three repetitions and no
confirmed candidate was rejected. The other two rejected cases remained
uncertain and correctly stayed on the reasoning path. This is a small captured
corpus rather than an independent held-out result; the runtime path is therefore
opt-in and fails open to the validator.

## 2026-09-29 validator source-constraint challenge

Two older published SSRF findings supplied the first independent disagreement
set: both passed Reviewotron's validator and later received explicit negative
human feedback. They claimed that YouTube video and thumbnail URLs could select
arbitrary outbound destinations. At the exact reviewed commit, the caller
instead constructs both URLs from UUID paths under a configured HTTPS assets
domain.

The original two-question cascade correctly refused to auto-confirm either
finding but left both in the uncertain validator path. A broad publication-
defect question was discarded because it missed the human-rejected cases and
crossed confirmed cases. A direct source-provenance question separated them:
across three repetitions, both human-rejected findings scored at least 0.64
when supplied the candidate diff and bounded caller evidence, while all 23
validator-confirmed controls stayed at or below 0.23. Those 84 calls cost
$0.015958.

A validator-only check confirmed the evidence effect. Sink-only prompts
confirmed both findings in all six verdicts, including prompts carrying a Jev
warning. Adding the caller evidence rejected both in all six verdicts. The
runtime cascade now records files already fetched by the validator and checks
each confirmation against those files plus the candidate diff. Rejection
requires both source-constraint probability at least 0.60 and direct support at
most 0.30. Missing files, credentials, or successful Jev responses preserve the
validator result.

## 2026-09-29 finding continuity across revisions

The refreshed feedback history contained two pull requests with confirmed
security findings on more than one reviewed revision. Both real repeated
findings were paired with five hard same-PR controls: similar authorization
removals in separate services, separate anonymous endpoints, certificate and
private-key ACLs, and separate same-file command-injection and SSRF paths.

Each pair was scored in both orientations for three repetitions. Requiring both
orientations to reach the threshold linked both repeated findings and none of
the five controls at every threshold from 0.60 through 0.80. One same-file
command-injection control scored 0.79–0.81 in one direction but 0.43–0.47 in
reverse, confirming that the complete-link rule is necessary. The 42 calls cost
$0.002918.

Token similarity could not provide this separation: one negative control was
more lexically similar than both positives. Continuity is not integrated yet.
Prior findings are available only in the publication feedback store, after the
current revision has been independently validated; suppressing the current
finding would save no review cost and could hide an unresolved defect.

## 2026-09-29 suggested-fix integrity guard

Five real suggestions previously adjudicated as mechanically broken were paired
with five upvoted, mechanically valid controls and each finding's exact reviewed
file diff. The broken set included a no-op that left an unbound name unchanged,
literal `\\n` text, deployment prose in a code suggestion, a duplicated log
call, and a parallelized N+1 query that preserved the reported defect.

Across three repetitions, broken suggestions scored 0.56–0.95 and controls
scored 0.08–0.35. A 0.50 threshold removed all 15 broken repetitions and
preserved all 15 controls. The 30 calls had no errors and cost $0.002833, or
about $0.000094 per suggestion. A 0.60 threshold would have missed the
deployment-prose case.

The opt-in `review_plugins.jev_suggestion_guard_enabled` integration runs after
both plugins have validated and deduplicated findings. It removes only
`suggested_fix`; the finding, location, impact, and evidence remain unchanged.
Missing credentials, missing diff evidence, and Jev failures preserve the
suggestion.

## False build-claim experiment

A broad “withhold unsupported finding” question did not improve the saved
current baseline: the five historical cases it identified were already removed
by Reviewotron. On 48 labeled candidates emitted by newer pipeline runs, it also
failed to separate false positives from protected findings.

A first narrower question identified compiler-diagnostic findings, but this
mixed two different cases. One was a real OCaml compile failure with a broken
no-op suggestion; the suggestion guard is the correct treatment because it
preserves the useful finding. The other claimed an unbound `encoder` even
though the post-change file bound it earlier in the function.

The final question therefore asks only whether bounded post-change file context
directly disproves an explicit deterministic build claim. Across three runs on
48 current candidates, it rejected both generated versions of the false
`encoder` finding at 0.71–0.85 and preserved all other candidates at 0.17 or
below, including 22 protected true positives. The 144 calls cost $0.026389.
Across three runs on the larger 75-finding historical set, the same invalid
finding scored 0.78 in every run; every other finding scored at most 0.27 and
all 23 protected findings survived. The 225 calls cost $0.044679.

The opt-in `review_plugins.jev_build_claim_guard_enabled` integration uses the
measured 0.70 threshold after normal validation and deduplication. It checks
only general findings, omits suggestion payloads from the judgment, and fails
open when source context, credentials, or Jev are unavailable.

## Next Jev experiments

1. Expand the independent human-feedback set beyond two SSRF findings before
   treating source-constraint rejection as a default.
2. Expand the suggested-fix corpus beyond the five known broken payloads.
3. Gather more false build claims and real compiler-diagnostic controls before
   enabling the build-claim guard by default.
4. Gather more multi-revision positives and define a notification behavior for
   continuity that does not hide unresolved findings.
