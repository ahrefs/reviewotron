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
  {|Focus on:
- Bugs and logic errors
- Performance issues
- Error handling gaps
- Code clarity and maintainability

Security is handled by a separate, specialized review pipeline (triage → analysis → validator) that runs in parallel with this review. Do NOT emit security findings here — duplicating them creates noise. Never use category `security`. If, during your review, you spot a critical security concern that you suspect the dedicated pipeline may miss, mention it briefly in the top-level `summary` and do not attach an inline finding.|}

let guidelines =
  {|Guidelines:
- Only comment on the changed lines (additions), not existing code.
- Every finding MUST include `path` (file path, no prefix) and `line` (1-based line number from the new version of the file, matching a line that appears in the diff). Do not put line numbers inside `path` or `message`.
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

let build_user_message ~diff ?pr_title ?pr_description ?file_contents () =
  let buf = Buffer.create (String.length diff + 256) in
  (match pr_title with
  | Some title -> Buffer.add_string buf (Printf.sprintf "## Pull Request: %s\n\n" title)
  | None -> ());
  (match pr_description with
  | Some desc when String.length desc > 0 ->
    Buffer.add_string buf desc;
    Buffer.add_string buf "\n\n"
  | Some _ | None -> ());
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
