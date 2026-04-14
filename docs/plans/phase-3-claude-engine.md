# Phase 3: Claude Review Engine

## Goal
Implement the Claude API integration using `one_llm`, the prompt construction module, the core reviewer functor, and end-to-end PR review flow. At the end of this phase, a PR webhook can trigger a full review: fetch diff → call Claude → post PR review with inline comments.

## Prerequisites
- Phase 2 complete and passing QA
- Read `.cursor/rules/backend-developer.mdc` for code style
- Use context7 MCP for Claude API tool_use documentation
- Use serena to navigate `backend/one_llm/lib/anthropic.ml` and `anthropic.atd`

## Tasks

### 3.1 Define `review_types.atd`

Structured output schema that Claude will return via tool_use:

```
type severity = [
  | Critical <json name="critical">
  | Warning <json name="warning">
  | Suggestion <json name="suggestion">
  | Nitpick <json name="nitpick">
  | Praise <json name="praise">
]

type finding = {
  path: string;
  ?line: int option;
  ?end_line: int option;
  severity: severity;
  category: string;
  message: string;
  ?suggested_fix: string option;
}

type review_output = {
  summary: string;
  findings: finding list;
  ~overall_assessment <ocaml default="\"\"">: string;
}
```

Add ATDgen generation rules to `lib/dune` (same pattern as `github_types.atd`).

### 3.2 Build the JSON Schema for tool_use

The Claude API requires a JSON Schema for the tool's `input_schema`. We need to generate this from `review_types.atd` or define it manually.

**Approach**: Define the schema as a `Yojson.Safe.t` literal in OCaml, matching the `review_output` type exactly:

```ocaml
let review_schema : Yojson.Safe.t = `Assoc [
  "type", `String "object";
  "properties", `Assoc [
    "summary", `Assoc [
      "type", `String "string";
      "description", `String "High-level summary of the review (2-4 sentences)";
    ];
    "findings", `Assoc [
      "type", `String "array";
      "items", `Assoc [
        "type", `String "object";
        "properties", `Assoc [
          "path", `Assoc [
            "type", `String "string";
            "description", `String "File path relative to repo root";
          ];
          "line", `Assoc [
            "type", `String "integer";
            "description", `String "Line number in the new version of the file";
          ];
          "end_line", `Assoc [
            "type", `String "integer";
            "description", `String "End line for multi-line findings";
          ];
          "severity", `Assoc [
            "type", `String "string";
            "enum", `List [`String "critical"; `String "warning"; `String "suggestion"; `String "nitpick"; `String "praise"];
          ];
          "category", `Assoc [
            "type", `String "string";
            "description", `String "Category: bug, security, performance, style, logic, error-handling, naming, documentation";
          ];
          "message", `Assoc [
            "type", `String "string";
            "description", `String "Clear explanation of the finding";
          ];
          "suggested_fix", `Assoc [
            "type", `String "string";
            "description", `String "Code suggestion to fix the issue, if applicable";
          ];
        ];
        "required", `List [`String "path"; `String "severity"; `String "category"; `String "message"];
      ];
    ];
    "overall_assessment", `Assoc [
      "type", `String "string";
      "description", `String "Brief overall quality assessment";
    ];
  ];
  "required", `List [`String "summary"; `String "findings"; `String "overall_assessment"];
]
```

### 3.3 Implement `review_prompt.ml`

Construct the system prompt and user message for Claude:

```ocaml
val system_prompt : ?override:string -> unit -> string
(** System prompt instructing Claude how to review code.
    Uses override from config if provided, otherwise default. *)

val build_user_message :
  diff:string ->
  ?pr_title:string ->
  ?pr_description:string ->
  ?file_contents:(string * string) list ->
  unit -> string
(** Build the user message containing the diff and context *)

val estimate_prompt_tokens : system:string -> user:string -> int
(** Rough token estimate for the prompt *)
```

**Default system prompt** (store as a string constant):

```
You are an expert code reviewer. Review the following code changes and provide actionable feedback.

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
- If the code looks good, say so briefly with few or no findings
```

**User message format**:
```
## Pull Request: {title}

{description}

## Diff

{diff}

## File Contents (for context)

### {path}
```{ext}
{content}
```
```

### 3.4 Implement Claude module in `api_remote.ml`

Use `one_llm`'s `Anthropic.chat_completion`:

```ocaml
module Claude_remote : Api.Claude = struct
  let review_tool : Anthropic_t.tool = {
    name = "submit_review";
    description = Some "Submit a structured code review with findings for each issue found";
    input_schema = Review_prompt.review_schema;
  }

  let review_code ~ctx ~diff ~files ~description =
    let secrets = ctx.secrets in
    let config = ctx.config in
    let system = Review_prompt.system_prompt ?override:config.system_prompt_override () in
    let user_msg = Review_prompt.build_user_message ~diff ~pr_description:description
      ~file_contents:files () in
    let messages = [
      Anthropic_t.{ role = `User; content = user_msg }
    ] in
    let model = Model.Anthropic.of_string config.model in
    let%lwt result = Anthropic.chat_completion
      ~x_api_key:secrets.anthropic_api_key
      ~version:secrets.anthropic_version
      ~tools:[review_tool]
      ~tool_choice:Anthropic_t.{ type_ = "tool"; name = "submit_review" }
      ~max_tokens:4096
      model
      messages
    in
    match result.value with
    | Ok response ->
      (* Extract the ToolUse content block *)
      let tool_use = List.find_map (function
        | Anthropic_t.ToolUse tu when String.equal tu.name "submit_review" ->
          Some tu.input
        | _ -> None
      ) response.content in
      begin match tool_use with
      | Some input_json ->
        let json_str = Yojson.Safe.to_string input_json in
        Lwt.return (Review_types_j.review_output_of_string json_str)
      | None ->
        Devkit.Exn.fail "Claude did not return submit_review tool use"
      end
    | Error err ->
      Devkit.Exn.fail "Claude API error: %s" err.message
end
```

**Important considerations:**
- Check the exact type of `Anthropic_t.tool` in `backend/one_llm/lib/anthropic.atd` — the field names may differ slightly
- The `model` parameter may need to be constructed differently — check `Model.Anthropic` enum values
- Verify how `messages` type works — it may be `Anthropic_t.message list` or a different format
- Handle the `system` prompt — check if `Anthropic.chat_completion` has a `~system` parameter or if it goes in messages

### 3.5 Implement Claude mock in `api_local.ml`

```ocaml
module Claude_local : Api.Claude = struct
  let review_code ~ctx ~diff ~files ~description =
    (* Read pre-recorded response from mock_api_responses/claude/ *)
    let mock_path = "mock_api_responses/claude/review_response.json" in
    let json_str = (* read file *) in
    Lwt.return (Review_types_j.review_output_of_string json_str)
end
```

### 3.6 Implement `reviewer.ml` — Core logic functor

This is the main orchestration module, equivalent to monorobot's `action.ml`:

```ocaml
module Make (GH : Api.Github) (AI : Api.Claude) (SL : Api.Slack) : sig
  val process_event : Context.t -> event:Github.event -> unit Lwt.t
end = struct

  let should_review_pr ~ctx (pr : Github_types_t.pr_notification) =
    let config = Context.get_config ctx ~repo_url:pr.repository.url in
    let dominated_by_ignored_author =
      List.exists (fun a -> String.equal a pr.sender.login) config.ignored_authors
    in
    let dominated_by_action = match pr.action with
      | "opened" -> config.auto_review_pr_open
      | "synchronize" -> config.auto_review_pr_sync
      | "reopened" -> config.auto_review_pr_open
      | _ -> false
    in
    (not dominated_by_ignored_author) && dominated_by_action

  let review_pr ~ctx (pr_notif : Github_types_t.pr_notification) =
    let repo_url = pr_notif.repository.url in
    let number = pr_notif.number in
    let pr = pr_notif.pull_request in
    (* 1. Fetch PR diff *)
    let%lwt diff_text = GH.get_pr_diff ~ctx ~repo_url ~number in
    (* 2. Parse diff *)
    let parsed_diff = Diff_parser.parse diff_text in
    let config = Context.get_config ctx ~repo_url in
    let filtered_diff = Diff_parser.filter_paths parsed_diff ~ignored:config.ignored_paths in
    (* 3. Check size limits *)
    let total_lines = Diff_parser.total_lines filtered_diff in
    if total_lines > config.max_diff_lines then
      Lwt.return_unit  (* skip oversized PRs *)
    else begin
      (* 4. Optionally fetch key file contents for context *)
      let%lwt file_contents = fetch_key_files ~ctx ~repo_url ~diff:filtered_diff
        ~ref_:(Option.map (fun h -> h.Github_types_t.sha) pr.head) in
      (* 5. Call Claude *)
      let%lwt review = AI.review_code ~ctx ~diff:diff_text
        ~files:file_contents ~description:pr.body in
      (* 6. Map findings to GitHub review comments *)
      let comments = List.filter_map (fun (finding : Review_types_t.finding) ->
        let file_diff = List.find_opt
          (fun fd -> String.equal fd.Diff_parser.path finding.path)
          filtered_diff
        in
        match file_diff with
        | None -> None
        | Some fd ->
          match finding.line with
          | None -> None
          | Some line ->
            let position = Diff_parser.line_to_position fd ~line ~side:`Right in
            Option.map (fun pos -> Github_types_t.{
              path = finding.path;
              position = Some pos;
              line = None;
              side = Some "RIGHT";
              body = format_finding_body finding;
            }) position
      ) review.findings in
      (* 7. Post review *)
      let review_req = Github_types_t.{
        commit_id = Option.map (fun h -> h.Github_types_t.sha) pr.head;
        body = review.summary;
        event = "COMMENT";
        comments;
      } in
      GH.create_pr_review ~ctx ~repo_url ~number review_req
    end

  let process_event ctx ~event =
    match event with
    | Github.Pull_request pr when should_review_pr ~ctx pr ->
      review_pr ~ctx pr
    | Github.Push push ->
      (* Handled in Phase 4 *)
      Lwt.return_unit
    | _ ->
      Lwt.return_unit
end
```

**Helper: `format_finding_body`** — Format a finding into a readable GitHub comment:
```
**[severity] category**: message

Suggested fix:
```suggestion
code here
```
```

### 3.7 Wire up `request_handler.ml`

Update the `/github` endpoint to actually process events through the reviewer:

```ocaml
(* Instantiate with real implementations *)
module R = Reviewer.Make(Api_remote.Github_remote)(Api_remote.Claude_remote)(Api_remote.Slack_remote)

let process_github ~ctx ~headers ~body =
  match Github.validate_and_parse ~ctx ~headers ~body with
  | Error msg -> respond_error 400 msg
  | Ok event ->
    Lwt.async (fun () ->
      try%lwt R.process_event ctx ~event
      with exn -> log_error exn; Lwt.return_unit
    );
    respond_ok "accepted"
```

Note: Use `Lwt.async` to process in the background so we return 200 immediately (GitHub requires response within 10 seconds).

### 3.8 Create mock Claude response files

`test/mock_api_responses/claude/review_response.json`:
```json
{
  "summary": "The changes look generally good but there are a few issues to address.",
  "findings": [
    {
      "path": "src/main.ml",
      "line": 42,
      "severity": "warning",
      "category": "error-handling",
      "message": "This function can raise Not_found but the exception is not caught.",
      "suggested_fix": "Use Option.value ~default instead of List.assoc"
    },
    {
      "path": "src/main.ml",
      "line": 55,
      "severity": "nitpick",
      "category": "style",
      "message": "Consider using Printf.sprintf instead of string concatenation for readability."
    }
  ],
  "overall_assessment": "Solid implementation with minor error handling gaps."
}
```

### 3.9 Write end-to-end golden file test

In `test/test.ml`, add a test that:
1. Loads a PR webhook payload from `mock_payloads/pr_opened.json`
2. Uses `Api_local` implementations (mock GitHub + mock Claude)
3. Processes the event through the reviewer functor
4. Captures the review that would be posted to GitHub
5. Compares with `expected/pr_opened_review.json`

```ocaml
module R_test = Reviewer.Make(Api_local.Github_local)(Api_local.Claude_local)(Api_local.Slack_local)

let test_pr_opened () =
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.read_mock_payload "pr_opened.json" in
  let event = Github.parse_event ~event_type:"pull_request" ~body:payload |> Result.get_ok in
  let%lwt () = R_test.process_event ctx ~event in
  let actual = Api_local.Github_local.get_posted_reviews () in
  Test_helpers.assert_golden ~expected:"expected/pr_opened_review.json" ~actual
```

## Verification

1. `dune build` compiles
2. `dune runtest` — all tests pass including end-to-end golden file test
3. Manual test with `check` command: `./reviewotron check --event-type=pull_request --payload=test/mock_payloads/pr_opened.json --secrets=secrets.json.example` shows the formatted review
4. (Optional) Live test: point at a real test PR with valid secrets, verify review is posted correctly

## QA Checklist
- [ ] Claude API integration matches `one_llm` library's actual interface (verify field names, types)
- [ ] Tool_use schema matches `review_types.atd` exactly
- [ ] Finding-to-comment mapping uses correct position calculation
- [ ] Large PR handling: size limits respected, clear skip logging
- [ ] Error handling for Claude API failures (rate limit, timeout)
- [ ] No sensitive data logged (API keys, tokens)
- [ ] Async processing: webhook returns 200 immediately
- [ ] Golden file test is deterministic
