(** Prompt construction for Claude code review. *)

let preamble =
  {|You are an expert code reviewer. Review the following code changes and provide actionable feedback.|}

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

let guidelines =
  {|Guidelines:
- Only comment on the changed lines (additions), not existing code.
- Every finding MUST include `path` (file path, no prefix) and `line`. The `line` value MUST equal the exact number shown in the left column of the diff line you are commenting on — copy it verbatim, do not count or estimate. Do not put line numbers inside `path` or `message`.
- Prefer single-line anchors. Only set `end_line` when the finding is genuinely unintelligible without a range — e.g. a specific control-flow branch, a try/catch body, or the few lines that carry the bug. Do NOT span an entire function. When set, `line` is the first relevant line and `end_line` is the last; both MUST be copied verbatim from the annotated diff's left column, both MUST sit inside the same hunk, and `end_line` MUST be strictly greater than `line`. Leave `end_line` null for single-line findings.
- If you cannot pinpoint a specific changed line for an observation, do not emit a finding — mention it in the top-level `summary` or `overall_assessment` instead.
- If multiple findings concern the same root cause, emit ONE finding with a combined message. Do not attach sibling comments at nearby lines describing variants of the same issue.
- A recommended alternative implementation or refactor belongs in the top-level `summary`, not as an inline finding attached to an unrelated line.
- Do not emit pure documentation nits (e.g. "consider adding JSDoc", "could be documented") unless the code is genuinely unclear.
- For each finding, suggest a fix when possible.
- Use "praise" severity for particularly good patterns.
- Use "nitpick" sparingly — only for truly minor style issues.
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
  String.concat "\n\n" [ preamble; focus; guidelines; output_hygiene ]

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
