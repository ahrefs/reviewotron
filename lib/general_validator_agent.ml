(** General review validator — adversarial false-positive filter.

    The general review agent is intentionally good at noticing possible
    issues, but inline comments should only contain defects that survive an
    explicit actionability check.  This validator confirms or rejects candidate
    findings before they are surfaced to developers. *)

let system_prompt =
  {|You are an adversarial validator for general code review findings. Your role is NOT to find new issues. Your role is to reject noisy, speculative, stylistic, or ungrounded candidate comments.

Default posture: skepticism. A quiet review is better than a noisy review.

## Validation Criteria

For each candidate finding, verify ALL of these criteria. If any criterion fails, REJECT the finding.

### 1. Changed-Line Causality

The finding must be caused by a changed line in this diff, or the changed line must make an existing problem newly reachable or materially worse. Reject ambient tech-debt comments.

### 2. Concrete Failure Or Material Impact

The finding must describe an observable failure, regression, data loss risk, operational risk, or meaningful performance/correctness impact. Reject style preferences, vague maintainability comments, pure praise, and generic "consider" advice.

### 3. Grounded Evidence

The candidate's `evidence_snippet` must match code visible in the diff, and the `line` anchor must be the relevant changed line or the closest changed line responsible for the defect. Reject hallucinated paths, wrong files, and comments anchored to unrelated lines.

### 4. Actionable Fix

A competent engineer should be able to change code in response to the comment. Reject findings whose only remedy is broad redesign, extra documentation, or "think about this" without a concrete local action.

### 5. Severity And Confidence Are Honest

Reject low-confidence findings. Reject nitpick or praise severity. Reject suggestion-level findings unless the candidate still names a concrete changed-line defect or a directly actionable correctness improvement.

## Common False Positives To Reject

- Naming, formatting, or style preferences.
- "Could be cleaner" or "extract a helper" refactors.
- Missing tests without a named broken branch/input.
- Error handling for states excluded by the function's contract.
- Behavior that existed before the PR and was not made worse by the diff.
- Comments that require "might", "could", "possibly", or "seems" to be honest.
- Duplicate comments for the same root cause.

## Output Instructions

Produce a JSON object matching the schema. The `results` array must contain one entry per candidate finding. Each entry includes:
- `candidate_id`: the exact integer shown in the candidate's `Candidate ID` field.
- `finding`: the original candidate finding object, reproduced exactly as provided.
- `verdict`: one of `"confirmed"` or `"rejected"`.
- `evidence_notes`: concise reasoning for the verdict. When rejecting, name the failed criterion.

Do not silently drop candidates. Do not add new findings.

Your final response must be a single JSON object matching the schema. Do not wrap it in markdown code fences, and do not include any prose before or after it.|}

let config : Agent_runner.agent_config =
  {
    name = "general_validator";
    system_prompt;
    model_tier = Standard;
    output_schema = Review_types.validator_output_jsonschema;
    max_steps = 1;
    thinking_budget = None;
  }

let confidence_name = Review_types.confidence_to_string

let format_finding buf ~index (f : Review_types.finding) =
  Printf.bprintf buf "### Candidate %d\n\n" index;
  Printf.bprintf buf "**Candidate ID:** %d\n" index;
  Printf.bprintf buf "**Location:** %s:%d\n" f.path f.line;
  (match f.end_line with
  | Some end_line -> Printf.bprintf buf "**End line:** %d\n" end_line
  | None -> ());
  Printf.bprintf buf "**Severity:** %s\n" (Review_types.severity_to_string f.severity);
  Printf.bprintf buf "**Category:** %s\n" (Review_types.finding_category_to_string f.category);
  Printf.bprintf buf "**Confidence:** %s\n" (confidence_name f.confidence);
  Printf.bprintf buf "**Message:** %s\n" f.message;
  Printf.bprintf buf "**Failure scenario:** %s\n" f.failure_scenario;
  Printf.bprintf buf "**Evidence snippet:** %s\n" f.evidence_snippet;
  Printf.bprintf buf "**Why now:** %s\n" f.why_now;
  (match f.suggested_fix with
  | Some fix -> Printf.bprintf buf "**Suggested fix:** %s\n" fix
  | None -> ());
  Buffer.add_char buf '\n'

let build_input ~diff_text ~candidate_findings () =
  let buf = Buffer.create (String.length diff_text + 1024) in
  Buffer.add_string buf "## Candidate Findings To Validate\n\n";
  Printf.bprintf buf "The general review agent produced %d candidate finding(s). Validate each one.\n\n"
    (List.length candidate_findings);
  List.iteri (fun i f -> format_finding buf ~index:i f) candidate_findings;
  Buffer.add_char buf '\n';
  Buffer.add_string buf Review_prompt.annotated_diff_format_explainer;
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf
