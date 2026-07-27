#!/usr/bin/env python3
"""Generate match_workflow.js: one cheap agent per chunk of candidate pairs.

Only pair IDs are embedded in the generated script; agents read the pair bodies
from match_candidates.json themselves, keeping the orchestrator context clean.
Run the emitted match_workflow.js with the Workflow tool, then harvest its
`results` array into match_results.json (see README) for replay_aggregate.py.

Reads/writes in OUTPUT_DIR.
"""
import json
import os

import _config as C

CHUNK = 8


def main():
    cands_path = C.in_output("match_candidates.json")
    pairs = json.load(open(cands_path))
    ids = [p["pair_id"] for p in pairs]
    chunks = [ids[i:i + CHUNK] for i in range(0, len(ids), CHUNK)]

    script = """export const meta = {
  name: 'replay-match-confirm',
  description: 'Confirm same-issue matches between original eval findings and replay findings',
  phases: [{ title: 'Match' }],
}
const CANDS = %(cands)r
const CHUNKS = %(chunks)s
const SCHEMA = {
  type: 'object',
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          pair_id: { type: 'string' },
          match: { type: 'boolean' },
          reason: { type: 'string', maxLength: 200 },
        },
        required: ['pair_id', 'match', 'reason'],
        additionalProperties: false,
      },
    },
  },
  required: ['results'],
  additionalProperties: false,
}
phase('Match')
const out = await parallel(CHUNKS.map((chunk, ci) => () =>
  agent(
    `You are judging whether pairs of code-review findings describe THE SAME ISSUE.\\n\\n` +
    `Read the JSON file ${CANDS} (use the Read tool; it is an array of pair objects). ` +
    `Process EXACTLY these pair_ids: ${JSON.stringify(chunk)}.\\n\\n` +
    `Each pair has a kind. inline_finding pairs compare an original posted finding with a replay finding ` +
    `at a nearby source line. review_body pairs compare the original review body with the replay summary.\\n\\n` +
    `For inline_finding pairs decide match=true if both findings point at the same underlying defect/concern ` +
    `(same root cause and consequence), even if worded differently or with different severity. ` +
    `For review_body pairs decide match=true only when the replay body retains the same concrete actionable concern; ` +
    `a generic summary, praise, or merely related observation is not a match. ` +
    `Give a one-line reason.\\n\\n` +
    `Return via StructuredOutput: {results: [{pair_id, match, reason}, ...]} with one entry per requested pair_id.`,
    { label: `match:${ci}`, schema: SCHEMA, effort: 'low' }
  )
))
const results = out.filter(Boolean).flatMap(r => r.results)
return { results, expected: CHUNKS.flat().length, got: results.length }
""" % {"cands": cands_path, "chunks": json.dumps(chunks)}

    out_path = C.in_output("match_workflow.js")
    open(out_path, "w").write(script)
    print("pairs=%d chunks=%d -> %s" % (len(ids), len(chunks), out_path))


if __name__ == "__main__":
    main()
