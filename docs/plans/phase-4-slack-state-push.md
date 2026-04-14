# Phase 4: Slack + State + Push Reviews

## Goal
Add push-to-develop review support (commit comments + Slack notifications), state persistence to avoid duplicate reviews, and path/author filtering. At the end of this phase, both PR and push events are fully handled.

## Prerequisites
- Phase 3 complete and passing QA
- Read `.cursor/rules/backend-developer.mdc` for code style
- Use serena to study monorobot's `lib/state.ml` for state persistence pattern

## Tasks

### 4.1 Define `state.atd`

Track which PRs and commits have been reviewed to avoid duplicates:

```
type review_record = {
  pr_number: int;
  head_sha: string;
  reviewed_at: string;
  ?review_id: int option;
  tokens_used: int;
}

type push_review_record = {
  after_sha: string;
  reviewed_at: string;
  tokens_used: int;
}

type repo_state = {
  ~pr_reviews <ocaml default="[]">: review_record list;
  ~push_reviews <ocaml default="[]">: push_review_record list;
}

type state = {
  repos: (string * repo_state) list <json repr="object">;
}
```

Add ATDgen generation rules to `lib/dune`.

### 4.2 Implement `state.ml`

State persistence following monorobot's pattern:

```ocaml
type t = {
  mutable data : State_t.state;
  filepath : string option;
}

val create : ?filepath:string -> unit -> t

val is_pr_reviewed : t -> repo_url:string -> pr_number:int -> head_sha:string -> bool
(** Check if this exact PR+SHA combo was already reviewed *)

val record_pr_review : t -> repo_url:string -> pr_number:int -> head_sha:string ->
  ?review_id:int -> tokens_used:int -> unit
(** Record that a PR was reviewed *)

val is_push_reviewed : t -> repo_url:string -> after_sha:string -> bool
(** Check if this push was already reviewed *)

val record_push_review : t -> repo_url:string -> after_sha:string -> tokens_used:int -> unit
(** Record that a push was reviewed *)

val save : t -> unit
(** Persist state to disk using Devkit.Files.save_as for atomic writes *)

val load : filepath:string -> t
(** Load state from disk *)
```

**State file management:**
- Use `Devkit.Files.save_as` for atomic writes (per backend-developer.mdc)
- Keep a bounded history (e.g., last 1000 reviews per repo) to prevent unbounded growth
- Trim old entries on save

### 4.3 Update `context.ml` to include state

Add state to the context:

```ocaml
type t = {
  secrets : Config_t.secrets;
  config : Config_t.config;
  state : State.t;
}
```

### 4.4 Implement `slack.ml` — Standalone webhook

Simple Slack incoming webhook integration:

```ocaml
module Slack_remote : Api.Slack = struct
  let post_message ~ctx ~text ?attachments () =
    let config = Context.get_config ctx ~repo_url:"" in
    match config.slack_webhook_url with
    | None -> Lwt.return_unit  (* no webhook configured, skip *)
    | Some url ->
      let payload = `Assoc (
        [ "text", `String text ] @
        (match attachments with
         | None | Some [] -> []
         | Some atts -> [ "attachments", `List atts ])
      ) in
      let body = Yojson.Safe.to_string payload in
      let headers = [ "Content-Type: application/json" ] in
      let%lwt _response = Web.http_request_lwt' ~headers ~body `POST url in
      Lwt.return_unit
end
```

**Slack message format for push reviews:**
```json
{
  "text": ":robot_face: *Code Review* for push to `develop`",
  "attachments": [
    {
      "color": "#36a64f",
      "title": "Push by <author> — <N> commits",
      "title_link": "<compare_url>",
      "text": "<review summary>",
      "fields": [
        { "title": "Findings", "value": "<N critical, N warnings, N suggestions>", "short": true },
        { "title": "Tokens Used", "value": "<N>", "short": true }
      ],
      "footer": "reviewotron"
    }
  ]
}
```

### 4.5 Implement mock Slack in `api_local.ml`

```ocaml
module Slack_local : Api.Slack = struct
  let posted_messages = ref []

  let post_message ~ctx ~text ?attachments () =
    posted_messages := (text, attachments) :: !posted_messages;
    Lwt.return_unit

  let get_posted_messages () = List.rev !posted_messages
  let clear () = posted_messages := []
end
```

### 4.6 Add push-to-develop review in `reviewer.ml`

Add `review_push` function to the reviewer functor:

```ocaml
let should_review_push ~ctx (push : Github_types_t.commit_pushed_notification) =
  let config = Context.get_config ctx ~repo_url:push.repository.url in
  (* Only review pushes to develop branch *)
  let is_develop = String.equal push.ref "refs/heads/develop" in
  let not_ignored = not (List.exists
    (fun a -> String.equal a push.sender.login) config.ignored_authors) in
  let not_duplicate = not (State.is_push_reviewed ctx.state
    ~repo_url:push.repository.url ~after_sha:push.after) in
  is_develop && not_ignored && not_duplicate && config.review_pushes_to_develop

let review_push ~ctx (push : Github_types_t.commit_pushed_notification) =
  let repo_url = push.repository.url in
  (* 1. Fetch aggregate diff: before...after *)
  let%lwt diff_text = GH.get_compare_diff ~ctx ~repo_url
    ~base:push.before ~head:push.after in
  (* 2. Parse and filter *)
  let parsed_diff = Diff_parser.parse diff_text in
  let config = Context.get_config ctx ~repo_url in
  let filtered_diff = Diff_parser.filter_paths parsed_diff ~ignored:config.ignored_paths in
  let total_lines = Diff_parser.total_lines filtered_diff in
  if total_lines > config.max_diff_lines then
    Lwt.return_unit
  else begin
    (* 3. Build description from commit messages *)
    let description = push.commits
      |> List.map (fun c -> Printf.sprintf "- %s" c.Github_types_t.message)
      |> String.concat "\n" in
    (* 4. Call Claude *)
    let%lwt review = AI.review_code ~ctx ~diff:diff_text ~files:[]
      ~description in
    (* 5. Post inline commit comments for critical/warning findings *)
    let%lwt () = Lwt_list.iter_s (fun (finding : Review_types_t.finding) ->
      match finding.severity, finding.line with
      | (`Critical | `Warning), Some _line ->
        let comment = Github_types_t.{
          body = format_finding_body finding;
          path = Some finding.path;
          position = None;  (* commit comments use line, not position *)
          line = finding.line;
        } in
        GH.create_commit_comment ~ctx ~repo_url ~sha:push.after comment
      | _ -> Lwt.return_unit  (* skip non-critical for commit comments *)
    ) review.findings in
    (* 6. Post summary to Slack *)
    let slack_text = Printf.sprintf
      ":robot_face: *Code Review* for push to `develop` by %s"
      push.pusher.name in
    let attachment = format_slack_attachment ~push ~review in
    let%lwt () = SL.post_message ~ctx ~text:slack_text
      ~attachments:[attachment] () in
    (* 7. Record in state *)
    let tokens_used = Diff_parser.estimate_tokens filtered_diff in
    State.record_push_review ctx.state ~repo_url ~after_sha:push.after
      ~tokens_used;
    State.save ctx.state;
    Lwt.return_unit
  end
```

### 4.7 Add duplicate prevention to PR reviews

Update `review_pr` in `reviewer.ml`:

```ocaml
let review_pr ~ctx (pr_notif : Github_types_t.pr_notification) =
  let repo_url = pr_notif.repository.url in
  let number = pr_notif.number in
  let pr = pr_notif.pull_request in
  let head_sha = Option.map (fun h -> h.Github_types_t.sha) pr.head in
  (* Check for duplicate *)
  match head_sha with
  | Some sha when State.is_pr_reviewed ctx.state ~repo_url ~pr_number:number ~head_sha:sha ->
    Lwt.return_unit  (* already reviewed this exact version *)
  | _ ->
    (* ... existing review logic ... *)
    (* After posting, record the review *)
    let tokens_used = Diff_parser.estimate_tokens filtered_diff in
    State.record_pr_review ctx.state ~repo_url ~pr_number:number
      ~head_sha:(CCOption.get_or ~default:"unknown" head_sha)
      ~tokens_used;
    State.save ctx.state;
    Lwt.return_unit
```

### 4.8 Add path filtering to reviewer

In `should_review_pr` and `should_review_push`, add check for empty diff after filtering:

```ocaml
(* After filtering ignored paths, if no files remain, skip *)
let filtered_diff = Diff_parser.filter_paths parsed_diff ~ignored:config.ignored_paths in
if filtered_diff = [] then
  Lwt.return_unit  (* all files are ignored *)
```

### 4.9 Create mock payloads and expected outputs for push events

- `test/mock_payloads/push_develop.json` — push to develop with 2-3 commits
- `test/mock_api_responses/github/compare_abc_def.diff` — aggregate diff for push
- `test/mock_api_responses/claude/push_review_response.json` — mock Claude response for push
- `test/expected/push_develop_comments.json` — expected commit comments
- `test/expected/push_develop_slack.json` — expected Slack message

### 4.10 Write golden file tests for push + duplicate prevention

Add tests to `test/test.ml`:

1. **Push review**: push payload → Claude mock → commit comments + Slack message
2. **Duplicate PR prevention**: process same PR twice, verify only one review posted
3. **Duplicate push prevention**: process same push twice, verify only one review
4. **Ignored author**: verify PR from ignored author is skipped
5. **Ignored paths**: verify PR touching only ignored files is skipped

## Verification

1. `dune build` compiles
2. `dune runtest` — all tests pass including new push and state tests
3. `./reviewotron check --event-type=push --payload=test/mock_payloads/push_develop.json` shows commit comments and Slack message
4. State file is created and persisted correctly
5. Duplicate detection works (run check twice, second time should skip)

## QA Checklist
- [ ] State persistence uses atomic writes (`Devkit.Files.save_as`)
- [ ] State is bounded (old entries trimmed)
- [ ] Push reviews only trigger on develop branch
- [ ] Duplicate detection is SHA-based (not just PR number)
- [ ] Slack webhook URL is optional — no crash if not configured
- [ ] Commit comments only posted for critical/warning findings
- [ ] Slack message is well-formatted with summary and finding counts
- [ ] All new tests are deterministic
