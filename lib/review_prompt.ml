(** Prompt construction for Claude code review. *)

let default_system_prompt =
  {|You are an expert code reviewer. Review the following code changes and provide actionable feedback.

Focus on:
- Bugs and logic errors
- Security vulnerabilities
- Performance issues
- Error handling gaps
- Code clarity and maintainability

Guidelines:
- Only comment on the changed lines (additions), not existing code
- Be specific — reference exact line numbers and file paths
- For each finding, suggest a fix when possible
- Use "praise" severity for particularly good patterns
- Use "nitpick" sparingly — only for truly minor style issues
- Be concise — one clear sentence per finding
- If the code looks good, say so briefly with few or no findings|}

let review_schema : Yojson.Safe.t = (Review_types.review_output_jsonschema :> Yojson.Safe.t)

let system_prompt ?override () =
  match override with
  | Some s -> s
  | None -> default_system_prompt

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
