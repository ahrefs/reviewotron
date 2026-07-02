type totals = {
  target_count : int;
  reacted_count : int;
  plus_one : int;
  minus_one : int;
  positive_count : int;
  negative_count : int;
  mixed_count : int;
  unreacted_count : int;
}

type target_summary = {
  feedback_id : string;
  review_batch_id : string;
  target_kind : string;
  finding_id : string option;
  finding_source : string option;
  plugin_name : string option;
  status : string;
  repo_url : string;
  pr_number : int;
  review_id : int;
  review_node_id : string option;
  comment_id : int option;
  github_comment_url : string option;
  github_review_url : string option;
  path : string option;
  line : int option;
  severity : string option;
  category : string option;
  confidence : string option;
  message : string option;
  routing_outcome : string option;
  comment_body_sha256 : string option;
  review_body_sha256 : string option;
  plus_one : int;
  minus_one : int;
  sentiment : string;
  last_polled_at : string option;
  first_user_interaction_at : string option;
}

type review_summary = {
  review_batch_id : string;
  evidence_dir : string;
  repo_url : string option;
  pr_number : int option;
  head_sha : string option;
  trigger : string option;
  config_sha256 : string option;
  diff_sha256 : string option;
  github_review_id : int option;
  comment_count : int option;
  targets : target_summary list;
  totals : totals;
  warnings : string list;
}

type sentiment_filter =
  | All
  | Reacted
  | Positive
  | Negative
  | Mixed
  | Unreacted

type filter = {
  sentiment : sentiment_filter;
  review_batch_id : string option;
  pr_number : int option;
  limit : int option;
}

type t = {
  targets_file : string;
  events_file : string;
  evidence_root : string;
  event_count : int;
  reviews : review_summary list;
  totals : totals;
  warnings : string list;
}

let default_filter = { sentiment = All; review_batch_id = None; pr_number = None; limit = None }

type manifest = {
  repo_url : string option;
  pr_number : int option;
  head_sha : string option;
  trigger : string option;
  config_sha256 : string option;
  diff_sha256 : string option;
  github_review_id : int option;
  comment_count : int option;
}

type evidence_finding = {
  finding_id : string;
  routing_outcome : string option;
  message : string option;
}

let empty_totals =
  {
    target_count = 0;
    reacted_count = 0;
    plus_one = 0;
    minus_one = 0;
    positive_count = 0;
    negative_count = 0;
    mixed_count = 0;
    unreacted_count = 0;
  }

let string_opt name = function
  | Some value -> name, `String value
  | None -> name, `Null

let int_opt name = function
  | Some value -> name, `Int value
  | None -> name, `Null

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Bool _ | `Float _ | `Int _ | `List _ | `Null | `String _ -> None

let string_field key json =
  match assoc_opt key json with
  | Some (`String value) -> Some value
  | Some (`Assoc _) | Some (`Bool _) | Some (`Float _) | Some (`Int _) | Some (`List _) | Some `Null | None -> None

let int_field key json =
  match assoc_opt key json with
  | Some (`Int value) -> Some value
  | Some (`Assoc _) | Some (`Bool _) | Some (`Float _) | Some (`List _) | Some `Null | Some (`String _) | None -> None

let list_field key json =
  match assoc_opt key json with
  | Some (`List values) -> values
  | Some (`Assoc _) | Some (`Bool _) | Some (`Float _) | Some (`Int _) | Some `Null | Some (`String _) | None -> []

let read_file path =
  try Ok (Std.input_file ~bin:true path)
  with exn -> Error (Printf.sprintf "failed to read %s: %s" path (Printexc.to_string exn))

let read_json_file path =
  match Sys.file_exists path with
  | false -> Ok None
  | true ->
  match read_file path with
  | Error _ as error -> error
  | Ok contents ->
  try Ok (Some (Yojson.Basic.from_string contents))
  with exn -> Error (Printf.sprintf "failed to parse %s: %s" path (Printexc.to_string exn))

let read_targets path =
  match read_json_file path with
  | Error _ as error -> error
  | Ok None -> Ok { Feedback_store.schema = 3; targets = [] }
  | Ok (Some json) ->
  try Ok (Feedback_store.file_of_json json)
  with exn -> Error (Printf.sprintf "failed to decode feedback targets from %s: %s" path (Printexc.to_string exn))

let nonempty_lines text =
  text |> String.split_on_char '\n' |> List.filter (fun line -> not (String.equal (String.trim line) ""))

let count_event_lines path =
  match Sys.file_exists path with
  | false -> Ok 0
  | true ->
  match read_file path with
  | Error _ as error -> error
  | Ok contents -> Ok (List.length (nonempty_lines contents))

let manifest_of_json json =
  {
    repo_url = string_field "repo_url" json;
    pr_number = int_field "pr_number" json;
    head_sha = string_field "head_sha" json;
    trigger = string_field "trigger" json;
    config_sha256 = string_field "config_sha256" json;
    diff_sha256 = string_field "diff_sha256" json;
    github_review_id = int_field "github_review_id" json;
    comment_count = int_field "comment_count" json;
  }

let evidence_finding_of_json json =
  match string_field "finding_id" json with
  | None -> None
  | Some finding_id ->
    let finding_json =
      match assoc_opt "finding" json with
      | Some json -> json
      | None -> `Null
    in
    Some
      {
        finding_id;
        routing_outcome = string_field "routing_outcome" json;
        message = string_field "message" finding_json;
      }

let load_evidence_findings dir =
  let path = Filename.concat dir "findings.json" in
  match read_json_file path with
  | Error msg -> [], [ msg ]
  | Ok None -> [], [ Printf.sprintf "missing evidence findings file: %s" path ]
  | Ok (Some json) ->
    let findings = list_field "findings" json |> List.filter_map evidence_finding_of_json in
    findings, []

let load_manifest dir =
  let path = Filename.concat dir "manifest.json" in
  match read_json_file path with
  | Error msg -> None, [ msg ]
  | Ok None -> None, [ Printf.sprintf "missing evidence manifest: %s" path ]
  | Ok (Some json) -> Some (manifest_of_json json), []

let sentiment_of_counts counts =
  match counts.Feedback_store.plus_one, counts.Feedback_store.minus_one with
  | 0, 0 -> "unreacted"
  | plus_one, minus_one when plus_one > minus_one -> "positive"
  | plus_one, minus_one when minus_one > plus_one -> "negative"
  | _plus_one, _minus_one -> "mixed"

let add_target_totals totals counts =
  let sentiment = sentiment_of_counts counts in
  let reacted =
    match counts.Feedback_store.plus_one > 0 || counts.minus_one > 0 with
    | true -> 1
    | false -> 0
  in
  {
    target_count = totals.target_count + 1;
    reacted_count = totals.reacted_count + reacted;
    plus_one = totals.plus_one + counts.plus_one;
    minus_one = totals.minus_one + counts.minus_one;
    positive_count = (totals.positive_count + if String.equal sentiment "positive" then 1 else 0);
    negative_count = (totals.negative_count + if String.equal sentiment "negative" then 1 else 0);
    mixed_count = (totals.mixed_count + if String.equal sentiment "mixed" then 1 else 0);
    unreacted_count = (totals.unreacted_count + if String.equal sentiment "unreacted" then 1 else 0);
  }

let totals_of_targets targets =
  List.fold_left
    (fun totals (target : Feedback_store.target) -> add_target_totals totals target.last_counts)
    empty_totals targets

let evidence_dir_for (paths : Feedback_store.paths) review_batch_id targets =
  match List.find_map (fun (target : Feedback_store.target) -> target.evidence_dir) targets with
  | Some dir -> dir
  | None -> Feedback_evidence.bundle_dir ~evidence_root:paths.evidence_root ~review_batch_id

let target_message_from_finding_json json = string_field "message" json

let bind_option opt f =
  match opt with
  | None -> None
  | Some value -> f value

let strip_trailing_slash value =
  match String.length value with
  | 0 -> value
  | len ->
  match Char.equal value.[len - 1] '/' with
  | true -> String.sub value 0 (len - 1)
  | false -> value

let html_repo_url repo_url =
  let api_prefix = "https://api.github.com/repos/" in
  let html_prefix = "https://github.com/" in
  match CCString.prefix ~pre:html_prefix repo_url, CCString.prefix ~pre:api_prefix repo_url with
  | true, _ -> Some (strip_trailing_slash repo_url)
  | false, true ->
    let suffix = String.sub repo_url (String.length api_prefix) (String.length repo_url - String.length api_prefix) in
    Some (html_prefix ^ strip_trailing_slash suffix)
  | false, false -> None

let github_comment_url ~repo_url ~pr_number comment_id =
  match html_repo_url repo_url, comment_id with
  | Some repo_url, Some comment_id -> Some (Printf.sprintf "%s/pull/%d#discussion_r%d" repo_url pr_number comment_id)
  | Some _, None | None, Some _ | None, None -> None

let github_review_url ~repo_url ~pr_number review_id =
  Option.map
    (fun repo_url -> Printf.sprintf "%s/pull/%d#pullrequestreview-%d" repo_url pr_number review_id)
    (html_repo_url repo_url)

let target_summary evidence_findings (target : Feedback_store.target) =
  let finding_evidence =
    match target.finding_id with
    | None -> None
    | Some finding_id -> List.find_opt (fun f -> String.equal f.finding_id finding_id) evidence_findings
  in
  let message =
    match bind_option finding_evidence (fun f -> f.message) with
    | Some _ as message -> message
    | None -> bind_option target.finding target_message_from_finding_json
  in
  let routing_outcome = bind_option finding_evidence (fun f -> f.routing_outcome) in
  let counts = target.last_counts in
  {
    feedback_id = target.feedback_id;
    review_batch_id = target.review_batch_id;
    target_kind = Feedback_store.target_kind_to_string target.target_kind;
    finding_id = target.finding_id;
    finding_source = target.finding_source;
    plugin_name = target.plugin_name;
    status = Feedback_store.target_status_to_string target.status;
    repo_url = target.repo_url;
    pr_number = target.pr_number;
    review_id = target.review_id;
    review_node_id = target.review_node_id;
    comment_id = target.comment_id;
    github_comment_url = github_comment_url ~repo_url:target.repo_url ~pr_number:target.pr_number target.comment_id;
    github_review_url = github_review_url ~repo_url:target.repo_url ~pr_number:target.pr_number target.review_id;
    path = target.path;
    line = target.line;
    severity = target.severity;
    category = target.category;
    confidence = target.confidence;
    message;
    routing_outcome;
    comment_body_sha256 = target.comment_body_sha256;
    review_body_sha256 = target.review_body_sha256;
    plus_one = counts.plus_one;
    minus_one = counts.minus_one;
    sentiment = sentiment_of_counts counts;
    last_polled_at = target.last_polled_at;
    first_user_interaction_at = target.first_user_interaction_at;
  }

let add_summary_totals totals (target : target_summary) =
  let reacted =
    match target.plus_one > 0 || target.minus_one > 0 with
    | true -> 1
    | false -> 0
  in
  {
    target_count = totals.target_count + 1;
    reacted_count = totals.reacted_count + reacted;
    plus_one = totals.plus_one + target.plus_one;
    minus_one = totals.minus_one + target.minus_one;
    positive_count = (totals.positive_count + if String.equal target.sentiment "positive" then 1 else 0);
    negative_count = (totals.negative_count + if String.equal target.sentiment "negative" then 1 else 0);
    mixed_count = (totals.mixed_count + if String.equal target.sentiment "mixed" then 1 else 0);
    unreacted_count = (totals.unreacted_count + if String.equal target.sentiment "unreacted" then 1 else 0);
  }

let totals_of_target_summaries targets = List.fold_left add_summary_totals empty_totals targets

let compare_targets (a : target_summary) (b : target_summary) =
  match a.path, b.path with
  | None, None -> String.compare a.feedback_id b.feedback_id
  | None, Some _ -> -1
  | Some _, None -> 1
  | Some a_path, Some b_path ->
  match String.compare a_path b_path with
  | 0 ->
    (match a.line, b.line with
    | Some a_line, Some b_line -> Int.compare a_line b_line
    | None, None -> String.compare a.feedback_id b.feedback_id
    | None, Some _ -> -1
    | Some _, None -> 1)
  | n -> n

let interaction_warning_marker = "reacted targets have first_user_interaction_at=null"

let interaction_warnings target_summaries =
  let reacted_without_interaction =
    List.filter
      (fun (target : target_summary) ->
        (target.plus_one > 0 || target.minus_one > 0) && Option.is_none target.first_user_interaction_at)
      target_summaries
  in
  match reacted_without_interaction with
  | [] -> []
  | _ :: _ ->
    [
      Printf.sprintf
        "%d reacted targets have first_user_interaction_at=null; run collect-feedback --poll-interval-seconds 0 to \
         backfill reaction-observed timestamps"
        (List.length reacted_without_interaction);
    ]

let is_interaction_warning warning = CCString.find ~sub:interaction_warning_marker warning >= 0

let review_summary (paths : Feedback_store.paths) review_batch_id targets =
  let evidence_dir = evidence_dir_for paths review_batch_id targets in
  let manifest, manifest_warnings = load_manifest evidence_dir in
  let evidence_findings, findings_warnings = load_evidence_findings evidence_dir in
  let target_summaries = List.map (target_summary evidence_findings) targets |> List.sort compare_targets in
  let fallback f =
    match targets with
    | [] -> None
    | target :: _rest -> Some (f target)
  in
  let manifest_repo_url = bind_option manifest (fun m -> m.repo_url) in
  let manifest_pr_number = bind_option manifest (fun m -> m.pr_number) in
  {
    review_batch_id;
    evidence_dir;
    repo_url =
      (match manifest_repo_url with
      | Some _ as value -> value
      | None -> fallback (fun (target : Feedback_store.target) -> target.repo_url));
    pr_number =
      (match manifest_pr_number with
      | Some _ as value -> value
      | None -> fallback (fun (target : Feedback_store.target) -> target.pr_number));
    head_sha =
      (match bind_option manifest (fun m -> m.head_sha) with
      | Some _ as value -> value
      | None -> fallback (fun (target : Feedback_store.target) -> target.head_sha));
    trigger = bind_option manifest (fun m -> m.trigger);
    config_sha256 = bind_option manifest (fun m -> m.config_sha256);
    diff_sha256 = bind_option manifest (fun m -> m.diff_sha256);
    github_review_id = bind_option manifest (fun m -> m.github_review_id);
    comment_count = bind_option manifest (fun m -> m.comment_count);
    targets = target_summaries;
    totals = totals_of_targets targets;
    warnings = manifest_warnings @ findings_warnings @ interaction_warnings target_summaries;
  }

let add_to_group target groups =
  let key = target.Feedback_store.review_batch_id in
  let rec add acc = function
    | [] -> List.rev ((key, [ target ]) :: acc)
    | (existing_key, targets) :: rest when String.equal existing_key key ->
      List.rev_append acc ((existing_key, target :: targets) :: rest)
    | item :: rest -> add (item :: acc) rest
  in
  add [] groups

let group_targets targets = List.fold_left (fun groups target -> add_to_group target groups) [] targets

let compare_reviews (a : review_summary) (b : review_summary) =
  match a.pr_number, b.pr_number with
  | Some x, Some y ->
    (match Int.compare x y with
    | 0 -> String.compare a.review_batch_id b.review_batch_id
    | n -> n)
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> String.compare a.review_batch_id b.review_batch_id

let load (paths : Feedback_store.paths) =
  match read_targets paths.targets with
  | Error _ as error -> error
  | Ok file ->
  match count_event_lines paths.events with
  | Error _ as error -> error
  | Ok event_count ->
    let reviews =
      file.targets
      |> group_targets
      |> List.map (fun (review_batch_id, targets) -> review_summary paths review_batch_id (List.rev targets))
      |> List.sort compare_reviews
    in
    let warnings = List.concat_map (fun (review : review_summary) -> review.warnings) reviews in
    Ok
      {
        targets_file = paths.targets;
        events_file = paths.events;
        evidence_root = paths.evidence_root;
        event_count;
        reviews;
        totals = totals_of_targets file.targets;
        warnings;
      }

let target_matches_sentiment sentiment (target : target_summary) =
  match sentiment with
  | All -> true
  | Reacted -> not (String.equal target.sentiment "unreacted")
  | Positive -> String.equal target.sentiment "positive"
  | Negative -> String.equal target.sentiment "negative"
  | Mixed -> String.equal target.sentiment "mixed"
  | Unreacted -> String.equal target.sentiment "unreacted"

let target_matches_filter filter (target : target_summary) =
  target_matches_sentiment filter.sentiment target
  &&
  match filter.pr_number with
  | Some pr_number -> Int.equal target.pr_number pr_number
  | None -> true

let review_matches_filter filter (review : review_summary) =
  match filter.review_batch_id, review.review_batch_id with
  | Some review_batch_id, candidate -> String.equal review_batch_id candidate
  | None, _ -> true

let structural_warnings warnings = List.filter (fun warning -> not (is_interaction_warning warning)) warnings

let refresh_review_after_filter (review : review_summary) targets =
  let warnings = structural_warnings review.warnings @ interaction_warnings targets in
  { review with targets; totals = totals_of_target_summaries targets; warnings }

let rec take_at_most n values =
  match Int.compare n 0 <= 0, values with
  | true, _ -> []
  | false, [] -> []
  | false, value :: rest -> value :: take_at_most (n - 1) rest

let apply_limit limit reviews =
  let rec aux remaining acc = function
    | [] -> List.rev acc
    | _ :: _ when Int.compare remaining 0 <= 0 -> List.rev acc
    | review :: rest ->
      let targets = take_at_most remaining review.targets in
      let count = List.length targets in
      let next_remaining = remaining - count in
      aux next_remaining (refresh_review_after_filter review targets :: acc) rest
  in
  aux limit [] reviews

let apply_filter filter report =
  let reviews =
    report.reviews
    |> List.filter (review_matches_filter filter)
    |> List.filter_map (fun review ->
      let targets = List.filter (target_matches_filter filter) review.targets in
      match targets with
      | [] -> None
      | _ :: _ -> Some (refresh_review_after_filter review targets))
  in
  let reviews =
    match filter.limit with
    | None -> reviews
    | Some limit -> apply_limit limit reviews
  in
  let all_targets = List.concat_map (fun review -> review.targets) reviews in
  let warnings = List.concat_map (fun (review : review_summary) -> review.warnings) reviews in
  { report with reviews; totals = totals_of_target_summaries all_targets; warnings }

let totals_to_json totals =
  `Assoc
    [
      "target_count", `Int totals.target_count;
      "reacted_count", `Int totals.reacted_count;
      "plus_one", `Int totals.plus_one;
      "minus_one", `Int totals.minus_one;
      "positive_count", `Int totals.positive_count;
      "negative_count", `Int totals.negative_count;
      "mixed_count", `Int totals.mixed_count;
      "unreacted_count", `Int totals.unreacted_count;
    ]

let target_to_json (target : target_summary) =
  let common_fields =
    [
      "feedback_id", `String target.feedback_id;
      "review_batch_id", `String target.review_batch_id;
      "target_kind", `String target.target_kind;
      "status", `String target.status;
      "repo_url", `String target.repo_url;
      "pr_number", `Int target.pr_number;
      "review_id", `Int target.review_id;
      string_opt "github_review_url" target.github_review_url;
      "plus_one", `Int target.plus_one;
      "minus_one", `Int target.minus_one;
      "sentiment", `String target.sentiment;
      string_opt "last_polled_at" target.last_polled_at;
      string_opt "first_user_interaction_at" target.first_user_interaction_at;
    ]
  in
  let target_fields =
    match target.target_kind with
    | "pr_review_body" ->
      [ string_opt "review_node_id" target.review_node_id; string_opt "review_body_sha256" target.review_body_sha256 ]
    | "pr_review_comment" ->
      [
        string_opt "finding_id" target.finding_id;
        string_opt "finding_source" target.finding_source;
        string_opt "plugin_name" target.plugin_name;
        int_opt "comment_id" target.comment_id;
        string_opt "github_comment_url" target.github_comment_url;
        string_opt "path" target.path;
        int_opt "line" target.line;
        string_opt "severity" target.severity;
        string_opt "category" target.category;
        string_opt "confidence" target.confidence;
        string_opt "message" target.message;
        string_opt "routing_outcome" target.routing_outcome;
        string_opt "comment_body_sha256" target.comment_body_sha256;
      ]
    | value -> invalid_arg (Printf.sprintf "unknown feedback report target kind: %s" value)
  in
  `Assoc (common_fields @ target_fields)

let review_to_json (review : review_summary) =
  `Assoc
    [
      "review_batch_id", `String review.review_batch_id;
      "evidence_dir", `String review.evidence_dir;
      string_opt "repo_url" review.repo_url;
      int_opt "pr_number" review.pr_number;
      string_opt "head_sha" review.head_sha;
      string_opt "trigger" review.trigger;
      string_opt "config_sha256" review.config_sha256;
      string_opt "diff_sha256" review.diff_sha256;
      int_opt "github_review_id" review.github_review_id;
      int_opt "comment_count" review.comment_count;
      "totals", totals_to_json review.totals;
      "warnings", `List (List.map (fun warning -> `String warning) review.warnings);
      "targets", `List (List.map target_to_json review.targets);
    ]

let to_json (report : t) =
  `Assoc
    [
      "schema", `Int 1;
      "targets_file", `String report.targets_file;
      "events_file", `String report.events_file;
      "evidence_root", `String report.evidence_root;
      "event_count", `Int report.event_count;
      "totals", totals_to_json report.totals;
      "warnings", `List (List.map (fun warning -> `String warning) report.warnings);
      "reviews", `List (List.map review_to_json report.reviews);
    ]

let shorten n value =
  match String.length value <= n with
  | true -> value
  | false -> String.sub value 0 (max 0 (n - 3)) ^ "..."

let option_string default = function
  | Some value -> value
  | None -> default

let option_int default = function
  | Some value -> string_of_int value
  | None -> default

let render_body_target buf (target : target_summary) =
  Printf.bprintf buf "- [%s] `%s` review body (+1=%d -1=%d)\n" target.sentiment target.feedback_id target.plus_one
    target.minus_one;
  Printf.bprintf buf "  review_id: %d; review_node_id: %s\n" target.review_id
    (option_string "unknown" target.review_node_id);
  (match target.github_review_url with
  | Some url -> Printf.bprintf buf "  github: %s\n" url
  | None -> ());
  Printf.bprintf buf "\n"

let render_inline_target ~include_messages ~max_message_chars buf (target : target_summary) =
  Printf.bprintf buf "- [%s] `%s` `%s` %s/%s/%s at `%s:%s` (+1=%d -1=%d)\n" target.sentiment target.feedback_id
    (option_string "unknown" target.plugin_name)
    (option_string "unknown" target.severity)
    (option_string "unknown" target.category)
    (option_string "unknown" target.confidence)
    (option_string "unknown" target.path) (option_int "unknown" target.line) target.plus_one target.minus_one;
  Printf.bprintf buf "  comment_id: %s; finding_id: %s\n"
    (option_int "unresolved" target.comment_id)
    (option_string "none" target.finding_id);
  (match target.github_comment_url with
  | Some url -> Printf.bprintf buf "  github: %s\n" url
  | None -> ());
  (match include_messages, target.message with
  | true, Some message -> Printf.bprintf buf "  message: %s\n" (shorten max_message_chars message)
  | true, None | false, Some _ | false, None -> ());
  Printf.bprintf buf "\n"

let render_target ~include_messages ~max_message_chars buf (target : target_summary) =
  match target.target_kind with
  | "pr_review_body" -> render_body_target buf target
  | "pr_review_comment" -> render_inline_target ~include_messages ~max_message_chars buf target
  | value -> invalid_arg (Printf.sprintf "unknown feedback report target kind: %s" value)

let render_review ~include_messages ~max_message_chars buf (review : review_summary) =
  Printf.bprintf buf "## Review `%s`\n\n" review.review_batch_id;
  Printf.bprintf buf "- PR: %s\n" (option_int "unknown" review.pr_number);
  Printf.bprintf buf "- Repo: %s\n" (option_string "unknown" review.repo_url);
  Printf.bprintf buf "- Head: `%s`\n" (option_string "unknown" review.head_sha);
  Printf.bprintf buf "- Evidence: `%s`\n" review.evidence_dir;
  Printf.bprintf buf "- Totals: targets=%d reacted=%d +1=%d -1=%d positive=%d negative=%d mixed=%d unreacted=%d\n\n"
    review.totals.target_count review.totals.reacted_count review.totals.plus_one review.totals.minus_one
    review.totals.positive_count review.totals.negative_count review.totals.mixed_count review.totals.unreacted_count;
  (match review.warnings with
  | [] -> ()
  | _ :: _ ->
    Printf.bprintf buf "Warnings:\n";
    List.iter (fun warning -> Printf.bprintf buf "- %s\n" warning) review.warnings;
    Printf.bprintf buf "\n");
  List.iter (render_target ~include_messages ~max_message_chars buf) review.targets

let render_markdown ?(include_messages = true) ?(max_message_chars = 320) (report : t) =
  let buf = Buffer.create 4096 in
  Printf.bprintf buf "# Reviewotron Feedback Report\n\n";
  Printf.bprintf buf "- Targets file: `%s`\n" report.targets_file;
  Printf.bprintf buf "- Events file: `%s` (%d events)\n" report.events_file report.event_count;
  Printf.bprintf buf "- Evidence root: `%s`\n" report.evidence_root;
  Printf.bprintf buf "- Totals: targets=%d reacted=%d +1=%d -1=%d positive=%d negative=%d mixed=%d unreacted=%d\n\n"
    report.totals.target_count report.totals.reacted_count report.totals.plus_one report.totals.minus_one
    report.totals.positive_count report.totals.negative_count report.totals.mixed_count report.totals.unreacted_count;
  (match report.warnings with
  | [] -> ()
  | _ :: _ ->
    Printf.bprintf buf "Warnings:\n";
    List.iter (fun warning -> Printf.bprintf buf "- %s\n" warning) report.warnings;
    Printf.bprintf buf "\n");
  List.iter (render_review ~include_messages ~max_message_chars buf) report.reviews;
  Buffer.contents buf
