# Jev analysis-retry experiment

Reviewotron already retries structurally invalid analysis output. This benchmark
tests a different decision: whether a well-formed analysis failed to resolve its
routed security concern and deserves one corrective retry.

Run it with:

```sh
TYPESAFE_API_KEY=... dune exec ./test/jev_noul_benchmark.exe -- \
  --corpus test/jev_retry_cases.json --repeats 5 > results.jsonl
```

The balanced corpus contains 18 cases. Retry cases include empty misses,
incorrect safe conclusions, an unrelated but structurally valid candidate, one
candidate hiding a second missed path, and an admitted inability to inspect a
helper. Accept cases include specific safe controls and candidates that already
cover the routed concern.

## 2026-09-22 baseline

The existing structural policy would not retry any corpus item because every
output is well formed, giving 9/18 correct decisions. Across five Jev repetitions:

- all 45 retry judgments scored between 0.83 and 0.96;
- all 45 accept judgments scored between 0.08 and 0.27;
- every threshold from 0.50 through 0.825 made all 90 decisions correctly;
- no case crossed a threshold in that interval;
- 90 requests used 45,280 input tokens and cost $0.001902;
- median request latency was 228 ms and p95 was 272 ms.

This is the widest separation in the Jev experiments so far. A semantic retry
gate could prevent accepted false negatives while avoiding unconditional costly
analysis retries. The corpus is curated from Reviewotron failure modes; captured
production analysis outputs remain necessary as a held-out evaluation before
integration.
