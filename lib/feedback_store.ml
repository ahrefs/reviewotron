open Devkit

let log = Log.from "feedback_store"

type paths = {
  targets : string;
  events : string;
  evidence_root : string;
}

type reaction_counts = {
  plus_one : int;
  minus_one : int;
}

type target_status =
  | Active
  | Final_due
  | Closed
  | Expired
  | Missing
  | Error

type stop_reason =
  | Pr_closed
  | Poll_window_elapsed
  | Comment_missing
  | Api_error

type target_kind =
  | Pr_review_comment
  | Pr_review_body

type target = {
  feedback_id : string;
  review_batch_id : string;
  status : target_status;
  stop_reason : stop_reason option;
  repo_url : string;
  pr_number : int;
  head_sha : string;
  target_kind : target_kind;
  review_id : int;
  comment_id : int option;
  review_node_id : string option;
  created_at : string;
  poll_until : string;
  first_user_interaction_at : string option;
  last_polled_at : string option;
  final_polled_at : string option;
  path : string option;
  line : int option;
  start_line : int option;
  severity : string option;
  category : string option;
  confidence : string option;
  finding : Yojson.Basic.t option;
  comment_body_sha256 : string option;
  review_body_sha256 : string option;
  evidence_dir : string option;
  finding_id : string option;
  finding_source : string option;
  plugin_name : string option;
  last_counts : reaction_counts;
}

type file = {
  schema : int;
  targets : target list;
}

type t = {
  paths : paths;
  mutex : Lwt_mutex.t;
  mutable data : file;
}

type target_input = {
  feedback_id : string;
  comment : Review_comment.t;
  finding : Review_types.finding;
  comment_body : string;
  evidence_dir : string option;
  finding_id : string option;
  finding_source : string option;
  plugin_name : string option;
}

type review_body_target_input = {
  feedback_id : string;
  review_node_id : string;
  review_body : string;
  evidence_dir : string option;
}

let schema_version = 3
let targets_filename = "reviewotron-feedback-targets.json"
let events_filename = "reviewotron-feedback-events.jsonl"
let evidence_dirname = "reviewotron-feedback-evidence"
let default_poll_interval_seconds = 60 * 60
let five_days_seconds = 5 * 24 * 60 * 60
let one_day_seconds = 24 * 60 * 60
let zero_counts = { plus_one = 0; minus_one = 0 }

let rec ensure_dir path =
  match Sys.file_exists path with
  | true ->
    (match (Unix.stat path).Unix.st_kind with
    | Unix.S_DIR -> ()
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
      invalid_arg (Printf.sprintf "expected directory at %s" path))
  | false ->
    let parent = Filename.dirname path in
    if not (String.equal parent path) then ensure_dir parent;
    Unix.mkdir path 0o700

let derive_paths ?feedback_dir ~state_filepath () =
  let dir =
    match feedback_dir with
    | Some dir -> dir
    | None -> Filename.dirname state_filepath
  in
  {
    targets = Filename.concat dir targets_filename;
    events = Filename.concat dir events_filename;
    evidence_root = Filename.concat dir evidence_dirname;
  }

let utc_string t = Ptime.to_rfc3339 ~frac_s:0 ~tz_offset_s:0 t

let parse_time s =
  match Ptime.of_rfc3339 s |> Ptime.rfc3339_string_error with
  | Ok (time, _tz, _count) -> Ok time
  | Error msg -> Error msg

let parse_time_exn field value =
  match parse_time value with
  | Ok time -> time
  | Error msg -> invalid_arg (Printf.sprintf "invalid %s timestamp %S: %s" field value msg)

let add_seconds time seconds =
  match Ptime.add_span time (Ptime.Span.of_int_s seconds) with
  | Some value -> value
  | None -> invalid_arg "feedback timestamp outside supported range"

let min_time a b =
  match Ptime.compare a b <= 0 with
  | true -> a
  | false -> b

let target_status_to_string = function
  | Active -> "active"
  | Final_due -> "final_due"
  | Closed -> "closed"
  | Expired -> "expired"
  | Missing -> "missing"
  | Error -> "error"

let target_status_of_string = function
  | "active" -> Active
  | "final_due" -> Final_due
  | "closed" -> Closed
  | "expired" -> Expired
  | "missing" -> Missing
  | "error" -> Error
  | value -> invalid_arg (Printf.sprintf "unknown feedback target status: %s" value)

let target_status_to_json status = `String (target_status_to_string status)
let target_status_of_json = function
  | `String value -> target_status_of_string value
  | json -> Melange_json.of_json_error ~json "expected feedback target status string"

let stop_reason_to_string = function
  | Pr_closed -> "pr_closed"
  | Poll_window_elapsed -> "poll_window_elapsed"
  | Comment_missing -> "comment_missing"
  | Api_error -> "api_error"

let stop_reason_of_string = function
  | "pr_closed" -> Pr_closed
  | "poll_window_elapsed" -> Poll_window_elapsed
  | "comment_missing" -> Comment_missing
  | "api_error" -> Api_error
  | value -> invalid_arg (Printf.sprintf "unknown feedback stop reason: %s" value)

let stop_reason_to_json reason = `String (stop_reason_to_string reason)
let stop_reason_of_json = function
  | `String value -> stop_reason_of_string value
  | json -> Melange_json.of_json_error ~json "expected feedback stop reason string"

let target_kind_to_string = function
  | Pr_review_comment -> "pr_review_comment"
  | Pr_review_body -> "pr_review_body"

let target_kind_of_string = function
  | "pr_review_comment" -> Pr_review_comment
  | "pr_review_body" -> Pr_review_body
  | value -> invalid_arg (Printf.sprintf "unknown feedback target kind: %s" value)

let target_kind_to_json kind = `String (target_kind_to_string kind)
let target_kind_of_json = function
  | `String value -> target_kind_of_string value
  | json -> Melange_json.of_json_error ~json "expected feedback target kind string"

let sha256_hex value = Digestif.SHA256.(digest_string value |> to_hex)

let digest_id ~prefix value = Printf.sprintf "%s%s" prefix (sha256_hex value)

let make_review_batch_id ~repo_url ~pr_number ~head_sha ~now ~nonce =
  Printf.sprintf "%s\000%d\000%s\000%s\000%s" repo_url pr_number head_sha (utc_string now) nonce
  |> digest_id ~prefix:"rvb_"

let make_feedback_id ~review_batch_id ~index ~path ~line ~comment_body =
  Printf.sprintf "%s\000%d\000%s\000%d\000%s" review_batch_id index path line comment_body |> digest_id ~prefix:"rvf_"

let make_review_body_feedback_id ~review_batch_id ~review_node_id ~review_body =
  Printf.sprintf "%s\000review_body\000%s\000%s" review_batch_id review_node_id review_body |> digest_id ~prefix:"rvf_"

let make_finding_id ~review_batch_id ~index ~path ~line ~finding_json ~comment_body =
  let finding_sha256 = Yojson.Basic.to_string finding_json |> sha256_hex in
  let comment_body_sha256 = sha256_hex comment_body in
  Printf.sprintf "%s\000%d\000%s\000%d\000%s\000%s" review_batch_id index path line finding_sha256 comment_body_sha256
  |> digest_id ~prefix:"rvfind_"

let feedback_marker ~feedback_id = Printf.sprintf "<!-- reviewotron-feedback-id: %s -->" feedback_id

let append_marker ~feedback_id body = Printf.sprintf "%s\n\n%s" body (feedback_marker ~feedback_id)

let extract_marker body =
  let prefix = "<!-- reviewotron-feedback-id: " in
  let suffix = " -->" in
  body
  |> String.split_on_char '\n'
  |> List.find_map (fun line ->
    let line = String.trim line in
    match CCString.prefix ~pre:prefix line && CCString.suffix ~suf:suffix line with
    | false -> None
    | true ->
      let start = String.length prefix in
      let len = String.length line - start - String.length suffix in
      (match len > 0 with
      | true -> Some (String.sub line start len)
      | false -> None))

let json_string name value = name, `String value
let json_int name value = name, `Int value

let json_string_option name = function
  | None -> name, `Null
  | Some value -> name, `String value

let json_int_option name = function
  | None -> name, `Null
  | Some value -> name, `Int value

let reaction_counts_to_json counts = `Assoc [ "plus_one", `Int counts.plus_one; "minus_one", `Int counts.minus_one ]

let reaction_counts_of_json = function
  | `Assoc fields ->
    let int_field name =
      match List.assoc_opt name fields with
      | Some (`Int value) -> value
      | Some json -> Melange_json.of_json_error ~json (Printf.sprintf "expected integer field %s" name)
      | None -> invalid_arg (Printf.sprintf "missing field %s" name)
    in
    { plus_one = int_field "plus_one"; minus_one = int_field "minus_one" }
  | json -> Melange_json.of_json_error ~json "expected reaction counts object"

let required_option field = function
  | Some value -> value
  | None -> invalid_arg (Printf.sprintf "missing target field %s" field)

let target_to_json (target : target) =
  let common_fields =
    [
      json_string "feedback_id" target.feedback_id;
      json_string "review_batch_id" target.review_batch_id;
      "status", target_status_to_json target.status;
      ( "stop_reason",
        match target.stop_reason with
        | None -> `Null
        | Some reason -> stop_reason_to_json reason );
      json_string "repo_url" target.repo_url;
      json_int "pr_number" target.pr_number;
      json_string "head_sha" target.head_sha;
      "target_kind", target_kind_to_json target.target_kind;
      json_int "review_id" target.review_id;
      json_string "created_at" target.created_at;
      json_string "poll_until" target.poll_until;
      json_string_option "first_user_interaction_at" target.first_user_interaction_at;
      json_string_option "last_polled_at" target.last_polled_at;
      json_string_option "final_polled_at" target.final_polled_at;
      json_string_option "evidence_dir" target.evidence_dir;
      "last_counts", reaction_counts_to_json target.last_counts;
    ]
  in
  let target_fields =
    match target.target_kind with
    | Pr_review_comment ->
      [
        json_int_option "comment_id" target.comment_id;
        json_string "path" (required_option "path" target.path);
        json_int "line" (required_option "line" target.line);
        json_int_option "start_line" target.start_line;
        json_string "severity" (required_option "severity" target.severity);
        json_string "category" (required_option "category" target.category);
        json_string "confidence" (required_option "confidence" target.confidence);
        "finding", required_option "finding" target.finding;
        json_string "comment_body_sha256" (required_option "comment_body_sha256" target.comment_body_sha256);
        json_string_option "review_node_id" target.review_node_id;
        json_string_option "review_body_sha256" target.review_body_sha256;
        json_string_option "finding_id" target.finding_id;
        json_string_option "finding_source" target.finding_source;
        json_string_option "plugin_name" target.plugin_name;
      ]
    | Pr_review_body ->
      [
        json_string "review_node_id" (required_option "review_node_id" target.review_node_id);
        json_string "review_body_sha256" (required_option "review_body_sha256" target.review_body_sha256);
      ]
  in
  `Assoc (common_fields @ target_fields)

let required_field fields name =
  match List.assoc_opt name fields with
  | Some json -> json
  | None -> invalid_arg (Printf.sprintf "missing field %s" name)

let required_string fields name =
  match required_field fields name with
  | `String value -> value
  | json -> Melange_json.of_json_error ~json (Printf.sprintf "expected string field %s" name)

let required_int fields name =
  match required_field fields name with
  | `Int value -> value
  | json -> Melange_json.of_json_error ~json (Printf.sprintf "expected integer field %s" name)

let optional_string fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> None
  | Some (`String value) -> Some value
  | Some json -> Melange_json.of_json_error ~json (Printf.sprintf "expected optional string field %s" name)

let optional_int fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> None
  | Some (`Int value) -> Some value
  | Some json -> Melange_json.of_json_error ~json (Printf.sprintf "expected optional integer field %s" name)

let target_of_json = function
  | `Assoc fields ->
    let target_kind =
      match List.assoc_opt "target_kind" fields with
      | None -> Pr_review_comment
      | Some json -> target_kind_of_json json
    in
    let common =
      {
        feedback_id = required_string fields "feedback_id";
        review_batch_id = required_string fields "review_batch_id";
        status = target_status_of_json (required_field fields "status");
        stop_reason =
          (match List.assoc_opt "stop_reason" fields with
          | None | Some `Null -> None
          | Some json -> Some (stop_reason_of_json json));
        repo_url = required_string fields "repo_url";
        pr_number = required_int fields "pr_number";
        head_sha = required_string fields "head_sha";
        target_kind;
        review_id = required_int fields "review_id";
        comment_id = None;
        review_node_id = None;
        created_at = required_string fields "created_at";
        poll_until = required_string fields "poll_until";
        first_user_interaction_at = optional_string fields "first_user_interaction_at";
        last_polled_at = optional_string fields "last_polled_at";
        final_polled_at = optional_string fields "final_polled_at";
        path = None;
        line = None;
        start_line = None;
        severity = None;
        category = None;
        confidence = None;
        finding = None;
        comment_body_sha256 = None;
        review_body_sha256 = None;
        evidence_dir = optional_string fields "evidence_dir";
        finding_id = None;
        finding_source = None;
        plugin_name = None;
        last_counts = reaction_counts_of_json (required_field fields "last_counts");
      }
    in
    (match target_kind with
    | Pr_review_comment ->
      {
        common with
        comment_id = optional_int fields "comment_id";
        review_node_id = optional_string fields "review_node_id";
        path = Some (required_string fields "path");
        line = Some (required_int fields "line");
        start_line = optional_int fields "start_line";
        severity = Some (required_string fields "severity");
        category = Some (required_string fields "category");
        confidence = Some (required_string fields "confidence");
        finding =
          Some
            (match List.assoc_opt "finding" fields with
            | Some json -> json
            | None -> `Assoc []);
        comment_body_sha256 = Some (required_string fields "comment_body_sha256");
        review_body_sha256 = optional_string fields "review_body_sha256";
        finding_id = optional_string fields "finding_id";
        finding_source = optional_string fields "finding_source";
        plugin_name = optional_string fields "plugin_name";
      }
    | Pr_review_body ->
      {
        common with
        review_node_id = Some (required_string fields "review_node_id");
        review_body_sha256 = Some (required_string fields "review_body_sha256");
      })
  | json -> Melange_json.of_json_error ~json "expected feedback target object"

let file_to_json file = `Assoc [ "schema", `Int file.schema; "targets", `List (List.map target_to_json file.targets) ]

let file_of_json = function
  | `Assoc fields ->
    let schema =
      match List.assoc_opt "schema" fields with
      | Some (`Int value) -> value
      | Some json -> Melange_json.of_json_error ~json "expected integer field schema"
      | None -> schema_version
    in
    let targets =
      match List.assoc_opt "targets" fields with
      | Some (`List values) -> List.map target_of_json values
      | Some json -> Melange_json.of_json_error ~json "expected targets array"
      | None -> []
    in
    { schema; targets }
  | json -> Melange_json.of_json_error ~json "expected feedback file object"

let empty_file = { schema = schema_version; targets = [] }

let load_file path =
  match Sys.file_exists path with
  | false -> empty_file
  | true ->
  try Std.input_file ~bin:true path |> Melange_json.of_string |> file_of_json
  with exn ->
    log#warn "failed to load feedback targets from %s: %s, starting fresh" path (Exn.str exn);
    empty_file

let create ?feedback_dir ~state_filepath () =
  let paths = derive_paths ?feedback_dir ~state_filepath () in
  ensure_dir (Filename.dirname paths.targets);
  { paths; mutex = Lwt_mutex.create (); data = load_file paths.targets }

let paths t = t.paths
let data t = t.data

let save_targets_unlocked t =
  let dir = Filename.dirname t.paths.targets in
  let tmp = Filename.temp_file ~temp_dir:dir ".reviewotron-feedback-targets" ".tmp" in
  let json = Yojson.Basic.pretty_to_string (file_to_json t.data) in
  let oc = open_out_bin tmp in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc json);
  Sys.rename tmp t.paths.targets

let append_event_unlocked t event_json =
  let line = Yojson.Basic.to_string event_json ^ "\n" in
  let oc = open_out_gen [ Open_creat; Open_text; Open_append ] 0o600 t.paths.events in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc line)

let with_lock t f = Lwt_mutex.with_lock t.mutex (fun () -> Lwt.return (f ()))

let replace_target (targets : target list) (updated : target) =
  List.map
    (fun (target : target) ->
      match String.equal target.feedback_id updated.feedback_id with
      | true -> updated
      | false -> target)
    targets

let find_target (targets : target list) ~feedback_id =
  List.find_opt (fun (target : target) -> String.equal target.feedback_id feedback_id) targets

let counts_equal a b = Int.equal a.plus_one b.plus_one && Int.equal a.minus_one b.minus_one
let counts_nonzero counts = counts.plus_one > 0 || counts.minus_one > 0

let counts_of_reactions reactions =
  List.fold_left
    (fun counts (reaction : Github_types.reaction) ->
      match reaction.content with
      | "+1" -> { counts with plus_one = counts.plus_one + 1 }
      | "-1" -> { counts with minus_one = counts.minus_one + 1 }
      | _ -> counts)
    zero_counts reactions

let counts_of_github_counts (counts : Github_types.reaction_counts) =
  { plus_one = counts.plus_one; minus_one = counts.minus_one }

let reaction_counts_changed_event ~feedback_id ~observed_at counts =
  `Assoc
    [
      "schema", `Int schema_version;
      "kind", `String "reaction_counts_changed";
      "feedback_id", `String feedback_id;
      "observed_at", `String (utc_string observed_at);
      "plus_one", `Int counts.plus_one;
      "minus_one", `Int counts.minus_one;
    ]

let comment_id_resolved_event ~feedback_id ~observed_at ~comment_id =
  `Assoc
    [
      "schema", `Int schema_version;
      "kind", `String "comment_id_resolved";
      "feedback_id", `String feedback_id;
      "observed_at", `String (utc_string observed_at);
      "comment_id", `Int comment_id;
    ]

let target_finalized_event target ~observed_at =
  let stop_reason =
    match target.stop_reason with
    | None -> `Null
    | Some reason -> `String (stop_reason_to_string reason)
  in
  `Assoc
    [
      "schema", `Int schema_version;
      "kind", `String "target_finalized";
      "feedback_id", `String target.feedback_id;
      "observed_at", `String (utc_string observed_at);
      "status", `String (target_status_to_string target.status);
      "stop_reason", stop_reason;
      "plus_one", `Int target.last_counts.plus_one;
      "minus_one", `Int target.last_counts.minus_one;
    ]

let record_posted_pr_review_targets t ~repo_url ~pr_number ~head_sha ~review_id ~review_batch_id ~created_at
  ?review_body_target inputs =
  let has_body_target =
    match review_body_target with
    | Some _ -> true
    | None -> false
  in
  match has_body_target, inputs with
  | false, [] -> Lwt.return_unit
  | true, [] | false, _ :: _ | true, _ :: _ ->
    with_lock t (fun () ->
      let created_at_string = utc_string created_at in
      let poll_until = add_seconds created_at five_days_seconds |> utc_string in
      let inline_targets =
        List.map
          (fun input ->
            let finding_json = Review_types.finding_to_json input.finding in
            {
              feedback_id = input.feedback_id;
              review_batch_id;
              status = Active;
              stop_reason = None;
              repo_url;
              pr_number;
              head_sha;
              target_kind = Pr_review_comment;
              review_id;
              comment_id = None;
              review_node_id = None;
              created_at = created_at_string;
              poll_until;
              first_user_interaction_at = None;
              last_polled_at = None;
              final_polled_at = None;
              path = Some input.comment.path;
              line = Some input.comment.line;
              start_line = input.comment.start_line;
              severity = Some (Review_types.severity_to_string input.finding.severity);
              category = Some (Review_types.finding_category_to_string input.finding.category);
              confidence = Some (Review_types.confidence_to_string input.finding.confidence);
              finding = Some finding_json;
              comment_body_sha256 = Some (sha256_hex input.comment_body);
              review_body_sha256 = None;
              evidence_dir = input.evidence_dir;
              finding_id = input.finding_id;
              finding_source = input.finding_source;
              plugin_name = input.plugin_name;
              last_counts = zero_counts;
            })
          inputs
      in
      let body_targets =
        match review_body_target with
        | None -> []
        | Some input ->
          [
            {
              feedback_id = input.feedback_id;
              review_batch_id;
              status = Active;
              stop_reason = None;
              repo_url;
              pr_number;
              head_sha;
              target_kind = Pr_review_body;
              review_id;
              comment_id = None;
              review_node_id = Some input.review_node_id;
              created_at = created_at_string;
              poll_until;
              first_user_interaction_at = None;
              last_polled_at = None;
              final_polled_at = None;
              path = None;
              line = None;
              start_line = None;
              severity = None;
              category = None;
              confidence = None;
              finding = None;
              comment_body_sha256 = None;
              review_body_sha256 = Some (sha256_hex input.review_body);
              evidence_dir = input.evidence_dir;
              finding_id = None;
              finding_source = None;
              plugin_name = None;
              last_counts = zero_counts;
            };
          ]
      in
      let targets = body_targets @ inline_targets in
      t.data <- { t.data with targets = targets @ t.data.targets };
      save_targets_unlocked t)

let active_target_for_pr ~repo_url ~pr_number target =
  match target.status with
  | Active -> String.equal target.repo_url repo_url && Int.equal target.pr_number pr_number
  | Final_due | Closed | Expired | Missing | Error -> false

let apply_user_interaction t ~repo_url ~pr_number ~received_at =
  with_lock t (fun () ->
    let changed = ref false in
    let update target =
      match active_target_for_pr ~repo_url ~pr_number target, target.first_user_interaction_at with
      | true, None ->
        let created_at = parse_time_exn "created_at" target.created_at in
        (match Ptime.compare received_at created_at > 0 with
        | false -> target
        | true ->
          let interaction_deadline = add_seconds received_at one_day_seconds in
          let existing_deadline = parse_time_exn "poll_until" target.poll_until in
          let poll_until = min_time existing_deadline interaction_deadline |> utc_string in
          changed := true;
          { target with first_user_interaction_at = Some (utc_string received_at); poll_until })
      | true, Some _ -> target
      | false, None | false, Some _ -> target
    in
    t.data <- { t.data with targets = List.map update t.data.targets };
    match !changed with
    | true -> save_targets_unlocked t
    | false -> ())

let mark_pr_closed t ~repo_url ~pr_number ~closed_at:(_ : Ptime.t) =
  with_lock t (fun () ->
    let changed = ref false in
    let update target =
      match active_target_for_pr ~repo_url ~pr_number target with
      | true ->
        changed := true;
        { target with status = Final_due; stop_reason = Some Pr_closed }
      | false -> target
    in
    t.data <- { t.data with targets = List.map update t.data.targets };
    match !changed with
    | true -> save_targets_unlocked t
    | false -> ())

let login_mentions_reviewotron login = String.lowercase_ascii login |> CCString.find ~sub:"reviewotron" >= 0

let is_bot_sender (sender : Github_types.github_user) =
  CCString.suffix ~suf:"[bot]" sender.login
  ||
  match sender.type_ with
  | Some type_ -> String.equal (String.lowercase_ascii type_) "bot"
  | None -> false

let is_human_sender (sender : Github_types.github_user) ~performed_via_github_app =
  match performed_via_github_app with
  | Some _ -> false
  | None ->
  match is_bot_sender sender, login_mentions_reviewotron sender.login with
  | true, _ -> false
  | false, true -> false
  | false, false -> true

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b

let action_is_issue_comment_interaction = function
  | "created" | "edited" -> true
  | _ -> false

let action_is_review_interaction = function
  | "submitted" | "edited" | "dismissed" -> true
  | _ -> false

let action_is_review_comment_interaction = function
  | "created" | "edited" -> true
  | _ -> false

let action_is_pr_interaction = function
  | Github.Synchronize | Github.Reopened | Github.Ready_for_review -> true
  | Github.Opened | Github.Closed | Github.Edited | Github.Other _ -> false

let handle_webhook_event t ~event ~received_at =
  match event with
  | Github.Pull_request n ->
    (match Github.pr_action_of_string n.action with
    | Github.Closed -> mark_pr_closed t ~repo_url:n.repository.url ~pr_number:n.number ~closed_at:received_at
    | action ->
      let performed_via_github_app = first_some n.performed_via_github_app n.pull_request.performed_via_github_app in
      (match action_is_pr_interaction action && is_human_sender n.sender ~performed_via_github_app with
      | true -> apply_user_interaction t ~repo_url:n.repository.url ~pr_number:n.number ~received_at
      | false -> Lwt.return_unit))
  | Github.Issue_comment n ->
    let performed_via_github_app = first_some n.performed_via_github_app n.comment.performed_via_github_app in
    (match
       Option.is_some n.issue.pull_request
       && action_is_issue_comment_interaction n.action
       && is_human_sender n.sender ~performed_via_github_app
     with
    | true -> apply_user_interaction t ~repo_url:n.repository.url ~pr_number:n.issue.number ~received_at
    | false -> Lwt.return_unit)
  | Github.Pull_request_review n ->
    let performed_via_github_app = first_some n.performed_via_github_app n.review.performed_via_github_app in
    (match action_is_review_interaction n.action && is_human_sender n.sender ~performed_via_github_app with
    | true -> apply_user_interaction t ~repo_url:n.repository.url ~pr_number:n.pull_request.number ~received_at
    | false -> Lwt.return_unit)
  | Github.Pull_request_review_comment n ->
    let performed_via_github_app = first_some n.performed_via_github_app n.comment.performed_via_github_app in
    (match action_is_review_comment_interaction n.action && is_human_sender n.sender ~performed_via_github_app with
    | true -> apply_user_interaction t ~repo_url:n.repository.url ~pr_number:n.pull_request.number ~received_at
    | false -> Lwt.return_unit)
  | Github.Push _ | Github.Unknown _ -> Lwt.return_unit

let terminal_status = function
  | Closed | Expired | Missing | Error -> true
  | Active | Final_due -> false

let poll_due ~poll_interval_seconds ~now target =
  match target.status with
  | Final_due -> true
  | Active ->
    let poll_until = parse_time_exn "poll_until" target.poll_until in
    (match Ptime.compare now poll_until >= 0, target.last_polled_at with
    | true, _ -> true
    | false, None -> true
    | false, Some last_polled_at ->
      let last = parse_time_exn "last_polled_at" last_polled_at in
      Ptime.Span.compare (Ptime.diff now last) (Ptime.Span.of_int_s poll_interval_seconds) >= 0)
  | Closed | Expired | Missing | Error -> false

let pollable_targets ?(poll_interval_seconds = default_poll_interval_seconds) t ~now =
  let poll_interval_seconds = max 0 poll_interval_seconds in
  with_lock t (fun () -> List.filter (poll_due ~poll_interval_seconds ~now) t.data.targets)

let resolve_comment_id t ~now ~feedback_id ~comment_id =
  with_lock t (fun () ->
    match find_target t.data.targets ~feedback_id with
    | None -> ()
    | Some target ->
    match target.comment_id with
    | Some existing when Int.equal existing comment_id -> ()
    | Some _ -> ()
    | None ->
      let updated = { target with comment_id = Some comment_id } in
      t.data <- { t.data with targets = replace_target t.data.targets updated };
      save_targets_unlocked t;
      append_event_unlocked t (comment_id_resolved_event ~feedback_id ~observed_at:now ~comment_id))

let finalized_status target ~now =
  match target.status with
  | Final_due ->
    (match target.stop_reason with
    | Some Pr_closed -> Some Closed
    | Some Poll_window_elapsed | Some Comment_missing | Some Api_error | None -> Some Expired)
  | Active ->
    let poll_until = parse_time_exn "poll_until" target.poll_until in
    (match Ptime.compare now poll_until >= 0 with
    | true -> Some Expired
    | false -> None)
  | Closed | Expired | Missing | Error -> None

let note_reaction_interaction target ~now ~counts =
  match target.first_user_interaction_at, counts_nonzero counts with
  | None, true ->
    let interaction_deadline = add_seconds now one_day_seconds in
    let existing_deadline = parse_time_exn "poll_until" target.poll_until in
    let poll_until = min_time existing_deadline interaction_deadline |> utc_string in
    { target with first_user_interaction_at = Some (utc_string now); poll_until }
  | None, false | Some _, true | Some _, false -> target

let update_after_poll t ~now ~feedback_id ~counts =
  with_lock t (fun () ->
    match find_target t.data.targets ~feedback_id with
    | None -> ()
    | Some target ->
      let counts_changed = not (counts_equal target.last_counts counts) in
      let target = note_reaction_interaction target ~now ~counts in
      let status_after = finalized_status target ~now in
      let updated =
        match status_after with
        | None -> { target with last_polled_at = Some (utc_string now); last_counts = counts }
        | Some status ->
          {
            target with
            status;
            stop_reason =
              (match target.stop_reason, status with
              | Some reason, _ -> Some reason
              | None, Expired -> Some Poll_window_elapsed
              | None, Closed -> Some Pr_closed
              | None, Missing -> Some Comment_missing
              | None, Error -> Some Api_error
              | None, Active | None, Final_due -> None);
            last_polled_at = Some (utc_string now);
            final_polled_at = Some (utc_string now);
            last_counts = counts;
          }
      in
      t.data <- { t.data with targets = replace_target t.data.targets updated };
      save_targets_unlocked t;
      (match counts_changed with
      | true -> append_event_unlocked t (reaction_counts_changed_event ~feedback_id ~observed_at:now counts)
      | false -> ());
      (match status_after with
      | None -> ()
      | Some _ -> append_event_unlocked t (target_finalized_event updated ~observed_at:now)))

let mark_missing t ~now ~feedback_id =
  with_lock t (fun () ->
    match find_target t.data.targets ~feedback_id with
    | None -> ()
    | Some target ->
    match terminal_status target.status with
    | true -> ()
    | false ->
      let updated =
        {
          target with
          status = Missing;
          stop_reason = Some Comment_missing;
          last_polled_at = Some (utc_string now);
          final_polled_at = Some (utc_string now);
        }
      in
      t.data <- { t.data with targets = replace_target t.data.targets updated };
      save_targets_unlocked t;
      append_event_unlocked t (target_finalized_event updated ~observed_at:now))
