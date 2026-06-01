(** Prompt construction for Claude code review. *)

let preamble = {|You are an expert code reviewer. Review the following code changes and provide actionable feedback.|}

let focus_with_security =
  {|Focus on:
- Bugs and logic errors
- Security vulnerabilities (injection, XSS, command injection, authentication, authorization, SSRF). Scrutinize any code that handles user input, shell execution, HTML rendering, or access control. Use category `security` for these findings.
- Performance issues
- Error handling gaps
- Code clarity and maintainability|}

let focus_without_security =
  {|Your scope is: logic bugs, correctness, performance, error handling, code clarity, and non-security-related documentation gaps.

A separate, specialized security review pipeline (triage → analysis → validator) is running in parallel and covers ALL security topics, including:
- injection (SQL, NoSQL, ORM, template)
- XSS and HTML rendering of user-controlled data
- command injection (shell, exec, subprocess, process spawn, file-descriptor-based execution)
- authentication (credential handling, session management, JWT and token validation, password hashing)
- authorization and access control (ownership checks, role/permission guards, IDOR, mass assignment)
- SSRF and any code that constructs outbound requests from user input
- any code path where user-controlled input reaches a dangerous sink (shell, query, HTML, process exec, file path, URL, auth decision, deserialization)
- secret handling, process-list exposure of credentials, timing side channels

Do NOT emit findings on any of those topics, in any category. This means: no "bug" finding about an escaping helper, no "logic" finding about an auth check, no "error-handling" finding about a shell command. If the code change touches shell commands, subprocess calls, HTML rendering, URL construction, crypto, auth middleware, or credential handling, assume the security pipeline is covering it and stay silent on the security dimension — even if you would have framed the finding as a bug.

One narrow escape hatch: if you believe a critical security concern would genuinely be missed by a source→sink→flow analysis (for example, a broader architectural issue), mention it briefly in the top-level `summary`. Do not attach an inline finding.|}

let workflow =
  {|## Per-Finding Workflow

Every candidate finding MUST go through this workflow IN ORDER. Reasoning and the human-facing comment are two distinct artifacts: reasoning happens in your private thinking channel, the comment is the product. Do NOT write the comment until reasoning is complete and the verdict is decided.

1. **REASON (private).** Use your extended-thinking channel as your scratchpad. Trace the defect, check edge cases, consider whether framework conventions, surrounding code, callers, or callees already handle it. Talk yourself in or out of it. Hedging and "actually..." are allowed here — this is where uncertainty lives. Thinking does NOT appear in the structured output you return; it is your space alone.

2. **VERDICT.** At the end of reasoning, decide explicitly: is this a real, actionable defect that a human should change? If the answer is "no", "probably not", "I'm not sure", or "it turns out this is fine after all" — STOP. Do not emit a finding. Reasoning that concludes "no bug here", "this is fine", "ignore this", or "actually this works correctly" means the finding DOES NOT belong in the output — drop it entirely.

3. **ARTICULATE.** Only now write the `message`, `failure_scenario`, `evidence_snippet`, `why_now`, and `confidence` fields.
   - `message`: standalone one-sentence summary for a human reviewer who has NOT read your reasoning.
   - `failure_scenario`: concrete user/input/state path that makes the defect observable, including the resulting breakage or risk.
   - `evidence_snippet`: exact changed code or smallest relevant snippet copied from the diff.
   - `why_now`: why this must be addressed in this PR rather than treated as ambient tech debt.
   - `confidence`: calibrated as high, medium, or low using the definitions below.
   These fields must read as finished products, not thinking-out-loud trails.

4. **SIGNAL CHECK.** Re-read the drafted `message` and `failure_scenario` in isolation. Ask:
   - Does it identify a concrete defect (not a vague "consider", "might want to", or "could potentially")?
   - Would a competent reviewer learn something they wouldn't see at a glance?
   - Is it free of self-resolving hedges?
   If any answer is "no", DROP the finding. Better silence than noise.

5. **EMIT.** Only findings that pass steps 2 and 4 appear in the output.

### Banned patterns in `message` and `failure_scenario`

The `message` and `failure_scenario` fields MUST NOT contain any of the following — their presence means the finding should have been dropped at step 2 or 4, not posted:
- "actually", "wait", "never mind", "on second thought"
- "no bug here", "this is fine", "ignore this", "this works correctly", "I was wrong"
- "I think", "I believe", "it seems", "I suspect"
- "might be a bug", "could potentially", "may or may not", "possibly"
- Self-resolving reasoning of any shape (raising a concern then dismissing it in the same comment)
- The word "However" used to walk back what the comment just said

If either field needs hedging to be honest, the finding is not strong enough to post. Drop it.

Your thinking channel is private — the human reviewer does not see it. Never reference your reasoning in `message` or `failure_scenario`. Both fields must stand alone.|}

let non_findings =
  {|## What Is NOT A Finding

Do NOT emit inline findings for:
- Praise, acknowledgements, or comments whose main purpose is encouragement.
- Naming, formatting, or style preferences unless the name/format causes a concrete misread that breaks behavior.
- "Consider extracting a helper", "could be cleaner", or other refactor suggestions unless duplicated code in this diff creates a concrete defect.
- Missing tests unless you can name the exact changed branch or input that is currently broken and untested.
- Documentation requests unless the code is genuinely ambiguous and that ambiguity creates incorrect usage.
- Error handling for cases the changed function's explicit contract excludes.
- Behavior that existed before this PR and is not made worse or newly reachable by the changed lines.
- Observations that require "might", "could", "possibly", or "seems" to be honest.

If the feedback is useful but not a defect, put it in `summary` or `overall_assessment`, not in `findings`. Inline findings are reserved for concrete, actionable defects.

The `summary` is ONLY a markdown bullet list of non-finding observations worth flagging that did not become inline findings. No headline, no lead-in, no framing sentence. If there are no such observations, `summary` MUST be an empty string. The `summary` MUST NOT reference inline findings in any form: no count, no preview, no "see below", no "detailed in the inline comments". Inline findings stand alone where they are anchored.|}

let calibration =
  {|## Severity And Confidence Calibration

Severity:
- `critical`: data loss, security exposure, production outage, or a defect that blocks the core workflow.
- `warning`: real correctness/error-handling/performance issue with an observable user or operator impact.
- `suggestion`: actionable improvement tied to a concrete changed line, but not a current failure. Use sparingly and prefer the summary.
- `nitpick`: do not emit inline. Use the summary if it truly matters.
- `praise`: do not emit inline.

Confidence:
- `high`: you can show the exact input/state, changed line, execution path, and bad outcome.
- `medium`: you can show a concrete failure scenario, but one non-critical context detail is inferred from local conventions.
- `low`: something looks suspicious but you cannot construct a concrete failure path. Do NOT emit low-confidence findings.

If severity would be `nitpick` or `praise`, or confidence would be `low`, drop the finding.|}

let guidelines =
  {|Guidelines:
- Only comment on the changed lines (additions), not existing code.
- Every finding MUST include `path` (file path, no prefix) and `line`. The `line` value MUST equal the exact number shown in the left column of the diff line you are commenting on — copy it verbatim, do not count or estimate. Do not put line numbers inside `path` or `message`.
- Prefer single-line anchors. Only set `end_line` when the finding is genuinely unintelligible without a range — e.g. a specific control-flow branch, a try/catch body, or the few lines that carry the bug. Do NOT span an entire function. When set, `line` is the first relevant line and `end_line` is the last; both MUST be copied verbatim from the annotated diff's left column, both MUST sit inside the same hunk, and `end_line` MUST be strictly greater than `line`. Leave `end_line` null for single-line findings.
- If you cannot pinpoint a specific changed line for an observation, do not emit a finding — mention it in the top-level `summary` or `overall_assessment` instead.
- If multiple findings concern the same root cause, emit ONE finding with a combined message. Do not attach sibling comments at nearby lines describing variants of the same issue.
- A recommended alternative implementation or refactor belongs in the top-level `summary`, not as an inline finding attached to an unrelated line.
- Do not emit pure documentation nits (e.g. "consider adding JSDoc", "could be documented") unless the code is genuinely unclear.
- For each finding, populate `message`, `failure_scenario`, `evidence_snippet`, `why_now`, and `confidence`. This shape is consumed by a downstream validator.
- For each finding, suggest a fix when possible.
- Do not use "praise" or "nitpick" severity for inline findings.
- Be concise — one clear sentence per finding.
- If the code looks good, say so briefly with few or no findings.|}

let output_hygiene =
  {|Your final response must be a single JSON object matching the schema. Do not wrap it in markdown code fences, and do not include any prose before or after it.|}

let build_system_prompt ~security_covered_elsewhere =
  let focus =
    match security_covered_elsewhere with
    | true -> focus_without_security
    | false -> focus_with_security
  in
  String.concat "\n\n" [ preamble; focus; workflow; non_findings; calibration; guidelines; output_hygiene ]

let review_schema : Yojson.Safe.t = (Review_types.review_output_jsonschema :> Yojson.Safe.t)

let system_prompt ?override ~security_covered_elsewhere () =
  match override with
  | Some s -> s
  | None -> build_system_prompt ~security_covered_elsewhere

let format_file_content (path, content) =
  let ext =
    match String.rindex_opt path '.' with
    | Some i -> String.sub path (i + 1) (String.length path - i - 1)
    | None -> ""
  in
  Printf.sprintf "### %s\n```%s\n%s\n```" path ext content

(** Shared explainer for the annotated-diff line-number format.

    Every agent that receives a diff text from this codebase gets it in the
    form produced by {!Diff_parser.to_string_annotated}.  Each content line
    carries its new-file line number in a left column so the agent can anchor
    findings by direct lookup instead of counting.  Include this explainer in
    any agent system prompt that expects to emit [finding.line] values. *)
let annotated_diff_format_explainer =
  {|## Diff Format

Every content line in the diff is prefixed with a fixed-width column containing that line's number in the new version of the file, followed by ` | ` and the usual diff marker (` `, `+`, or `-`) and the line content.

Example:
```
@@ -10,3 +10,4 @@
  10 |  unchanged context line
  11 | +added line
  12 |  another context line
     | -a deleted line (no new-file number because it is not in the new file)
  13 |  last context line
```

Use these numbers verbatim:
- When you emit a finding with a `line` field, the value MUST equal the number shown in the left column of the line you are anchoring the finding to. Do not compute, estimate, or adjust — copy the number as displayed.
- The correct anchor is the specific line the finding is about. If the finding is about an added function, anchor on the `+` line where the function is declared (or on a specific line inside it). If the finding is about a regression introduced by surrounding changes, anchor on the context (` `) line whose number matches the code you are describing.
- Deletion-only lines have a blank number column. They exist in the old file but not the new file and CANNOT anchor a finding — pick the nearest addition or context line instead.
- Do not cite line numbers with `~` (approximate) prefixes or ranges like "line ~85" in finding messages. The column gives you the exact number.
|}

let build_user_message ~diff ?pr_title ?pr_description ?file_contents () =
  let buf = Buffer.create (String.length diff + 512) in
  (match pr_title with
  | Some title -> Buffer.add_string buf (Printf.sprintf "## Pull Request: %s\n\n" title)
  | None -> ());
  (match pr_description with
  | Some desc when String.length desc > 0 ->
    Buffer.add_string buf desc;
    Buffer.add_string buf "\n\n"
  | Some _ | None -> ());
  Buffer.add_string buf annotated_diff_format_explainer;
  Buffer.add_string buf "\n";
  Buffer.add_string buf "## Diff\n\n";
  Buffer.add_string buf diff;
  (match file_contents with
  | Some (_ :: _ as files) ->
    Buffer.add_string buf "\n\n## File Contents (for context)\n\n";
    List.iter
      (fun fc ->
        Buffer.add_string buf (format_file_content fc);
        Buffer.add_char buf '\n')
      files
  | Some _ | None -> ());
  Buffer.contents buf

let estimate_prompt_tokens ~system ~user =
  let total_chars = String.length system + String.length user in
  (* ~4 chars per token *)
  (total_chars + 3) / 4
