open Devkit

let log = Log.from "api_local"

let read_mock_file path =
  try Ok (Std.input_file ~bin:true path)
  with exn -> Error (Printf.sprintf "failed to read mock file %s: %s" path (Exn.str exn))

(** Buffer for recording write operations (reviews, comments) for golden file comparison *)
let write_log = Buffer.create 4096

let get_write_log () = Buffer.contents write_log
let clear_write_log () = Buffer.clear write_log

(** Configurable mock response path for Claude reviews.
    Set this before running a test to control which mock response is returned. *)
let claude_response_path = ref "mock_api_responses/claude/review_response.json"

let set_claude_response_path path = claude_response_path := path
let reset_claude_response_path () = claude_response_path := "mock_api_responses/claude/review_response.json"

module Github : Api.Github = struct
  let get_config ~ctx:_ ~repo_url:_ = Lwt.return (Ok (Context.default_config ()))

  let get_pr_files ~ctx:_ ~repo_url:_ ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d_files.json" number in
    match read_mock_file path with
    | Ok body -> Lwt.return (Ok (Api_remote.parse_pr_files_json body))
    | Error msg ->
      log#error "%s" msg;
      Lwt.return (Ok [])

  let get_pr_diff ~ctx:_ ~repo_url:_ ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d.diff" number in
    Lwt.return (read_mock_file path)

  let get_compare_diff ~ctx:_ ~repo_url:_ ~base ~head =
    let path = Printf.sprintf "mock_api_responses/github/compare_%s_%s.diff" base head in
    Lwt.return (read_mock_file path)

  let get_file_content ~ctx:_ ~repo_url:_ ~path:file_path ~ref_ =
    let path = Printf.sprintf "mock_api_responses/github/content_%s_%s" ref_ file_path in
    match read_mock_file path with
    | Ok body -> Lwt.return (Ok (Some body))
    | Error _ -> Lwt.return (Ok None)

  let create_pr_review ~ctx:_ ~repo_url ~number review =
    let json = Github_types_j.string_of_create_review_req review in
    let entry = Printf.sprintf "[create_pr_review] repo=%s number=%d\n%s\n" repo_url number json in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok ())

  let create_commit_comment ~ctx:_ ~repo_url ~sha comment =
    let json = Github_types_j.string_of_commit_comment_req comment in
    let entry = Printf.sprintf "[create_commit_comment] repo=%s sha=%s\n%s\n" repo_url sha json in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok ())
end

module Claude : Api.Claude = struct
  let review_code ~ctx:_ ~repo_url:_ ~diff:_ ~files:_ ~pr_title:_ ~description:_ =
    let path = !claude_response_path in
    match read_mock_file path with
    | Ok json_str ->
      (match Review_types_j.review_output_of_string json_str with
      | review -> Lwt.return (Ok review)
      | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse mock review: %s" (Exn.str exn))))
    | Error msg -> Lwt.return (Error msg)
end

(** Recorded Slack messages for test assertions. *)
let slack_posted_messages : (string * string * Slack_types_t.slack_attachment list option) list ref = ref []

module Slack : Api.Slack = struct
  let post_message ~ctx:_ ~channel ~text ?attachments () =
    slack_posted_messages := (channel, text, attachments) :: !slack_posted_messages;
    let entry =
      match attachments with
      | None -> Printf.sprintf "[slack] #%s: %s\n" channel text
      | Some atts -> Printf.sprintf "[slack] #%s: %s (attachments: %d)\n" channel text (List.length atts)
    in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return_unit
end

let get_slack_messages () = List.rev !slack_posted_messages
let clear_slack_messages () = slack_posted_messages := []
