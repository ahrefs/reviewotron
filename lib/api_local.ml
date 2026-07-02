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

(** When set, the next [get_pr_diff] call returns this value instead of reading
    a mock file, then resets. Lets tests inject diff-fetch failures (e.g. the
    GitHub 406 "too_large" response) and empty/oversized diffs. *)
let next_pr_diff : (string, Http_util.error) result option ref = ref None

let set_next_pr_diff_error ?status message =
  let error =
    match status with
    | Some status -> Http_util.Status (status, message)
    | None -> Http_util.Local message
  in
  next_pr_diff := Some (Error error)

let set_next_pr_diff diff = next_pr_diff := Some (Ok diff)
let reset_next_pr_diff () = next_pr_diff := None

let next_issue_comment_result : (unit, string) result option ref = ref None
let set_next_issue_comment_error message = next_issue_comment_result := Some (Error message)
let reset_next_issue_comment_result () = next_issue_comment_result := None

let next_created_review_id = ref 1000
let next_pr_review_result : (Github_types.created_pr_review, string) result option ref = ref None

let set_next_created_review_id id = next_created_review_id := id
let set_next_pr_review_error message = next_pr_review_result := Some (Error message)
let reset_next_pr_review_result () = next_pr_review_result := None

let pr_review_comment_results : (int * (Github_types.pr_review_comment list, string) result) list ref = ref []
let reaction_results : (int * (Github_types.reaction list, string) result) list ref = ref []
let pr_review_body_reaction_results : (string * (Github_types.reaction_counts option, string) result) list ref = ref []

let set_pr_review_comments ~review_id comments =
  pr_review_comment_results := (review_id, Ok comments) :: List.remove_assoc review_id !pr_review_comment_results

let set_pr_review_comments_error ~review_id message =
  pr_review_comment_results := (review_id, Error message) :: List.remove_assoc review_id !pr_review_comment_results

let reset_pr_review_comments () = pr_review_comment_results := []

let set_pr_review_comment_reactions ~comment_id reactions =
  reaction_results := (comment_id, Ok reactions) :: List.remove_assoc comment_id !reaction_results

let set_pr_review_comment_reactions_error ~comment_id message =
  reaction_results := (comment_id, Error message) :: List.remove_assoc comment_id !reaction_results

let reset_pr_review_comment_reactions () = reaction_results := []

let remove_pr_review_body_reaction_result review_node_id =
  List.filter (fun (candidate, _result) -> not (String.equal candidate review_node_id)) !pr_review_body_reaction_results

let set_pr_review_body_reaction_counts ~review_node_id counts =
  pr_review_body_reaction_results :=
    (review_node_id, Ok (Some counts)) :: remove_pr_review_body_reaction_result review_node_id

let set_pr_review_body_reaction_counts_missing ~review_node_id =
  pr_review_body_reaction_results := (review_node_id, Ok None) :: remove_pr_review_body_reaction_result review_node_id

let set_pr_review_body_reaction_counts_error ~review_node_id message =
  pr_review_body_reaction_results :=
    (review_node_id, Error message) :: remove_pr_review_body_reaction_result review_node_id

let reset_pr_review_body_reaction_counts () = pr_review_body_reaction_results := []

let next_reaction_id = ref 1
let reset_reactions () = next_reaction_id := 1

module Github : Api.Github = struct
  let get_config ~ctx:_ ~repo_url:_ = Lwt.return (Ok (Context.default_config ()))

  let get_pr_files ~ctx:_ ~repo_url:_ ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d_files.json" number in
    match read_mock_file path with
    | Ok body -> Lwt.return (Ok (Api_remote.parse_pr_files_json body))
    | Error msg ->
      log#error "%s" msg;
      Lwt.return (Ok [])

  (* Mock files yield a plain string error; lift it into the typed HTTP error
     the real implementation returns (no HTTP status for a missing fixture). *)
  let mock_diff_result path = read_mock_file path |> Result.map_error (fun message -> Http_util.Local message)

  let get_pr_diff ~ctx:_ ~repo_url:_ ~number ?log_context:_ () =
    match !next_pr_diff with
    | Some override ->
      next_pr_diff := None;
      Lwt.return override
    | None ->
      let path = Printf.sprintf "mock_api_responses/github/pr_%d.diff" number in
      Lwt.return (mock_diff_result path)

  let get_pull_request ~ctx:_ ~repo_url:_ ~number =
    let path = Printf.sprintf "mock_api_responses/github/pr_%d.json" number in
    match read_mock_file path with
    | Error msg -> Lwt.return (Error msg)
    | Ok body ->
    try Lwt.return (Ok (Github_types.pull_request_of_json (Melange_json.of_string body)))
    with exn -> Lwt.return (Error (Printf.sprintf "failed to parse mock pull_request: %s" (Exn.str exn)))

  let get_compare_diff ~ctx:_ ~repo_url:_ ~base ~head ?log_context:_ () =
    let path = Printf.sprintf "mock_api_responses/github/compare_%s_%s.diff" base head in
    Lwt.return (mock_diff_result path)

  let get_file_content ~ctx:_ ~repo_url:_ ~path:file_path ~ref_ ?log_context:_ () =
    let path = Printf.sprintf "mock_api_responses/github/content_%s_%s" ref_ file_path in
    match read_mock_file path with
    | Ok body -> Lwt.return (Ok (Some body))
    | Error _ -> Lwt.return (Ok None)

  let create_pr_review ~ctx:_ ~repo_url ~number ?log_context:_ review =
    match !next_pr_review_result with
    | Some result ->
      next_pr_review_result := None;
      Lwt.return result
    | None ->
      let json = Melange_json.to_string (Github_types.create_review_req_to_json review) in
      let entry = Printf.sprintf "[create_pr_review] repo=%s number=%d\n%s\n" repo_url number json in
      Buffer.add_string write_log entry;
      log#info "%s" entry;
      let id = !next_created_review_id in
      next_created_review_id := id + 1;
      Lwt.return
        (Ok
           {
             Github_types.id;
             node_id = Some (Printf.sprintf "PRR_node_%d" id);
             html_url = Some (Printf.sprintf "%s/pull/%d#pullrequestreview-%d" repo_url number id);
           })

  let create_commit_comment ~ctx:_ ~repo_url ~sha ?log_context:_ comment =
    let json = Melange_json.to_string (Github_types.commit_comment_req_to_json comment) in
    let entry = Printf.sprintf "[create_commit_comment] repo=%s sha=%s\n%s\n" repo_url sha json in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok ())

  let create_issue_comment ~ctx:_ ~repo_url ~number ?log_context:_ comment =
    match !next_issue_comment_result with
    | Some result ->
      next_issue_comment_result := None;
      Lwt.return result
    | None ->
      let json = Melange_json.to_string (Github_types.issue_comment_req_to_json comment) in
      let entry = Printf.sprintf "[create_issue_comment] repo=%s number=%d\n%s\n" repo_url number json in
      Buffer.add_string write_log entry;
      log#info "%s" entry;
      Lwt.return (Ok ())

  let list_pr_review_comments ~ctx:_ ~repo_url ~number ~review_id =
    let entry = Printf.sprintf "[list_pr_review_comments] repo=%s number=%d review_id=%d\n" repo_url number review_id in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    match List.assoc_opt review_id !pr_review_comment_results with
    | Some result -> Lwt.return result
    | None -> Lwt.return (Ok [])

  let list_pr_review_comment_reactions ~ctx:_ ~repo_url ~comment_id =
    let entry = Printf.sprintf "[list_pr_review_comment_reactions] repo=%s comment_id=%d\n" repo_url comment_id in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    match List.assoc_opt comment_id !reaction_results with
    | Some result -> Lwt.return result
    | None -> Lwt.return (Ok [])

  let get_pr_review_reaction_counts ~ctx:_ ~repo_url ~review_node_id =
    let entry = Printf.sprintf "[get_pr_review_reaction_counts] repo=%s review_node_id=%s\n" repo_url review_node_id in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    match List.assoc_opt review_node_id !pr_review_body_reaction_results with
    | Some result -> Lwt.return result
    | None -> Lwt.return (Ok (Some { Github_types.plus_one = 0; minus_one = 0 }))

  let create_issue_reaction ~ctx:_ ~repo_url ~number ~content ?log_context:_ () =
    let reaction_id = !next_reaction_id in
    next_reaction_id := reaction_id + 1;
    let entry =
      Printf.sprintf "[create_issue_reaction] repo=%s number=%d content=%s id=%d\n" repo_url number content reaction_id
    in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok reaction_id)

  let create_issue_comment_reaction ~ctx:_ ~repo_url ~comment_id ~content ?log_context:_ () =
    let reaction_id = !next_reaction_id in
    next_reaction_id := reaction_id + 1;
    let entry =
      Printf.sprintf "[create_issue_comment_reaction] repo=%s comment_id=%d content=%s id=%d\n" repo_url comment_id
        content reaction_id
    in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok reaction_id)

  let delete_issue_reaction ~ctx:_ ~repo_url ~number ~reaction_id ?log_context:_ () =
    let entry = Printf.sprintf "[delete_issue_reaction] repo=%s number=%d id=%d\n" repo_url number reaction_id in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok ())

  let delete_issue_comment_reaction ~ctx:_ ~repo_url ~comment_id ~reaction_id ?log_context:_ () =
    let entry =
      Printf.sprintf "[delete_issue_comment_reaction] repo=%s comment_id=%d id=%d\n" repo_url comment_id reaction_id
    in
    Buffer.add_string write_log entry;
    log#info "%s" entry;
    Lwt.return (Ok ())
end

module Agent_runner : Api.Agent_runner = struct
  (* Test-only agent runner. This deliberately exercises the same orchestration
     path as the remote runner while returning deterministic outputs. These
     outputs prove schema and control-flow contracts, not prompt quality. *)
  let result output =
    let usage : Ai_provider.Usage.t = { input_tokens = 0; output_tokens = 0; total_tokens = None } in
    Ok
      Agent_runner.
        {
          output;
          usage;
          cache_read_input_tokens = 0;
          cache_creation_input_tokens = 0;
          steps_count = 1;
          tool_calls_count = 0;
          tool_results_count = 0;
          model_id = "mock";
          reported_cost_usd = None;
        }

  let validator_output ~path ~line ~severity ~category ~message =
    let finding : Review_types.finding =
      {
        path;
        line;
        end_line = None;
        severity;
        category;
        message;
        failure_scenario = "mock validator scenario";
        evidence_snippet = "mock validator evidence";
        why_now = "mock validator why_now";
        confidence = Review_types.High;
        suggested_fix = None;
      }
    in
    Review_types.validator_output_to_json
      {
        results =
          [
            {
              candidate_id = 0;
              finding;
              verdict = Review_types.Confirmed;
              evidence_notes = "mock validator confirmation";
            };
          ];
      }

  let default_validator_output () =
    let general_review_path =
      Option.default !agent_response_path (List.assoc_opt "general_review" !agent_response_map)
    in
    if String.equal general_review_path "mock_api_responses/claude/push_review_response.json" then
      validator_output ~path:"backend/api/src/request_handler.ml" ~line:15 ~severity:Review_types.Warning
        ~category:Review_types.Security
        ~message:
          "The webhook handler processes the request body without any validation or signature verification. This could \
           allow unauthorized webhook deliveries."
    else
      validator_output ~path:"src/main.ml" ~line:14 ~severity:Review_types.Warning ~category:Review_types.Error_handling
        ~message:"The `process` function can raise exceptions but the result is used without error handling."

  let run ~ctx:_ ~repo_url:_ ?model_id:_ ?tools:_ ?debug_dir:_ ?log_context:_ ~config ~input:_ () =
    match List.assoc_opt config.Agent_runner.name !agent_response_map, config.Agent_runner.name with
    | None, "general_validator" -> Lwt.return (result (default_validator_output ()))
    | path_opt, _ ->
      let path = Option.default !agent_response_path path_opt in
      (match read_mock_file path with
      | Ok json_str -> Lwt.return (result (Melange_json.of_string json_str))
      | Error msg -> Lwt.return (Error msg))
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
