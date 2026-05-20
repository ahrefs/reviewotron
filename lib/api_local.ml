open Devkit

let log = Log.from "api_local"

let read_mock_file path =
  try Ok (Std.input_file ~bin:true path)
  with exn -> Error (Printf.sprintf "failed to read mock file %s: %s" path (Exn.str exn))

(** Buffer for recording write operations (reviews, comments) for golden file comparison *)
let write_log = Buffer.create 4096

let get_write_log () = Buffer.contents write_log
let clear_write_log () = Buffer.clear write_log

(** Configurable mock response path for agent reviews.
    Set this before running a test to control which mock response is returned. *)
let agent_response_path = ref "mock_api_responses/claude/review_response.json"

let set_agent_response_path path = agent_response_path := path
let reset_agent_response_path () = agent_response_path := "mock_api_responses/claude/review_response.json"

(** Name-based response dispatch for multi-agent tests.
    Maps agent config names to response file paths. When set, the agent runner
    looks up config.name in this map before falling back to [agent_response_path]. *)
let agent_response_map : (string * string) list ref = ref []

let set_agent_response_map entries = agent_response_map := entries
let clear_agent_response_map () = agent_response_map := []

(** When set to [true], the next [create_pr_review] call returns an error and
    then resets the flag. Used to test retry-on-failure logic. *)
let fail_next_pr_review = ref false

let set_fail_next_pr_review () = fail_next_pr_review := true
let reset_fail_next_pr_review () = fail_next_pr_review := false

(** When set to [true], the next [create_commit_comment] call returns an error
    and then resets the flag. Used to test retry-on-failure logic. *)
let fail_next_commit_comment = ref false

let set_fail_next_commit_comment () = fail_next_commit_comment := true
let reset_fail_next_commit_comment () = fail_next_commit_comment := false

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

  let get_pull_request ~ctx:_ ~repo_url:_ ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d.json" number in
    match read_mock_file path with
    | Error msg -> Lwt.return (Error msg)
    | Ok body ->
    try Lwt.return (Ok (Github_types.pull_request_of_json (Melange_json.of_string body)))
    with exn -> Lwt.return (Error (Printf.sprintf "failed to parse mock pull_request: %s" (Exn.str exn)))

  let get_compare_diff ~ctx:_ ~repo_url:_ ~base ~head =
    let path = Printf.sprintf "mock_api_responses/github/compare_%s_%s.diff" base head in
    Lwt.return (read_mock_file path)

  let get_file_content ~ctx:_ ~repo_url:_ ~path:file_path ~ref_ =
    let path = Printf.sprintf "mock_api_responses/github/content_%s_%s" ref_ file_path in
    match read_mock_file path with
    | Ok body -> Lwt.return (Ok (Some body))
    | Error _ -> Lwt.return (Ok None)

  let create_pr_review ~ctx:_ ~repo_url ~number review =
    if !fail_next_pr_review then begin
      fail_next_pr_review := false;
      Lwt.return (Error "simulated GitHub API failure for create_pr_review")
    end
    else begin
      let json = Melange_json.to_string (Github_types.create_review_req_to_json review) in
      let entry = Printf.sprintf "[create_pr_review] repo=%s number=%d\n%s\n" repo_url number json in
      Buffer.add_string write_log entry;
      log#info "%s" entry;
      Lwt.return (Ok ())
    end

  let create_commit_comment ~ctx:_ ~repo_url ~sha comment =
    if !fail_next_commit_comment then begin
      fail_next_commit_comment := false;
      Lwt.return (Error "simulated GitHub API failure for create_commit_comment")
    end
    else begin
      let json = Melange_json.to_string (Github_types.commit_comment_req_to_json comment) in
      let entry = Printf.sprintf "[create_commit_comment] repo=%s sha=%s\n%s\n" repo_url sha json in
      Buffer.add_string write_log entry;
      log#info "%s" entry;
      Lwt.return (Ok ())
    end
end

module Agent_runner : Api.Agent_runner = struct
  let run ~ctx:_ ~repo_url:_ ?model_id:_ ?tools:_ ?debug_dir:_ ~config ~input:_ () =
    let path = Option.default !agent_response_path (List.assoc_opt config.Agent_runner.name !agent_response_map) in
    match read_mock_file path with
    | Ok json_str ->
      let output = Melange_json.of_string json_str in
      let usage : Ai_provider.Usage.t = { input_tokens = 0; output_tokens = 0; total_tokens = None } in
      Lwt.return
        (Ok
           Agent_runner.
             {
               output;
               usage;
               cache_read_input_tokens = 0;
               cache_creation_input_tokens = 0;
               steps_count = 1;
               model_id = "mock";
             })
    | Error msg -> Lwt.return (Error msg)
end

(** Recorded Slack messages for test assertions. *)
let slack_posted_messages : (string * string * Slack_types.slack_attachment list option) list ref = ref []

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
