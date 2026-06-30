type posted_comment = {
  feedback_id : string;
  finding_id : string;
  finding_source : string;
  plugin_name : string;
  comment : Review_comment.t;
  finding : Review_types.finding;
  comment_body : string;
}

let schema_version = 1

let bundle_dir ~evidence_root ~review_batch_id = Filename.concat evidence_root review_batch_id

let sha256_hex value = Digestif.SHA256.(digest_string value |> to_hex)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc contents)

let write_json path json = write_file path (Yojson.Basic.pretty_to_string json ^ "\n")

let ensure_dir path =
  match Sys.file_exists path with
  | false -> Unix.mkdir path 0o700
  | true ->
  match (Unix.stat path).Unix.st_kind with
  | Unix.S_DIR -> ()
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
    invalid_arg (Printf.sprintf "expected directory at %s" path)

let json_string name value = name, `String value
let json_int name value = name, `Int value

let json_string_option name = function
  | None -> name, `Null
  | Some value -> name, `String value

let json_int_option name = function
  | None -> name, `Null
  | Some value -> name, `Int value

let side_to_string = function
  | Review_comment.Left -> "left"
  | Review_comment.Right -> "right"

let routing_outcome_to_string = function
  | Review_engine.Routed_inline _ -> "inline"
  | Review_engine.Routed_unchanged -> "unchanged"
  | Review_engine.Routed_anchor_failed -> "anchor_failed"
  | Review_engine.Routed_dropped_unchanged_low_severity -> "dropped_unchanged_low_severity"

let comment_anchor_to_json (comment : Review_comment.t) =
  `Assoc
    [
      json_string "path" comment.path;
      json_int "line" comment.line;
      json_string "side" (side_to_string comment.side);
      json_int_option "start_line" comment.start_line;
      ( "start_side",
        match comment.start_side with
        | None -> `Null
        | Some side -> `String (side_to_string side) );
    ]

let posted_comment_to_json (posted : posted_comment) =
  let comment = posted.comment in
  `Assoc
    [
      json_string "feedback_id" posted.feedback_id;
      json_string "finding_id" posted.finding_id;
      json_string "finding_source" posted.finding_source;
      json_string "plugin_name" posted.plugin_name;
      json_string "path" comment.path;
      json_int "line" comment.line;
      json_string "side" (side_to_string comment.side);
      json_int_option "start_line" comment.start_line;
      ( "start_side",
        match comment.start_side with
        | None -> `Null
        | Some side -> `String (side_to_string side) );
      json_string "body" posted.comment_body;
      json_string "comment_body_sha256" (sha256_hex posted.comment_body);
      "finding", Review_types.finding_to_json posted.finding;
    ]

let posted_review_json ~review_id ~pr_number ~head_sha ~review_body ~posted_comments =
  `Assoc
    [
      "schema", `Int schema_version;
      "github_review_id", `Int review_id;
      "pr_number", `Int pr_number;
      "head_sha", `String head_sha;
      "body", `String review_body;
      "comments", `List (List.map posted_comment_to_json posted_comments);
    ]

let routed_finding_to_json ~finding_id (routed : Review_engine.routed_finding) =
  let sourced = routed.sourced in
  let finding = sourced.finding in
  let fields =
    [
      json_string_option "finding_id" finding_id;
      json_string "finding_source" (Review_engine.finding_source_to_string sourced.source);
      json_string "plugin_name" sourced.plugin_name;
      json_string "routing_outcome" (routing_outcome_to_string routed.outcome);
      json_string "path" finding.path;
      json_int "line" finding.line;
      json_int_option "end_line" finding.end_line;
      "finding", Review_types.finding_to_json finding;
    ]
  in
  let fields =
    match routed.outcome with
    | Review_engine.Routed_inline comment -> ("comment_anchor", comment_anchor_to_json comment) :: fields
    | Review_engine.Routed_unchanged | Review_engine.Routed_anchor_failed
    | Review_engine.Routed_dropped_unchanged_low_severity ->
      fields
  in
  `Assoc (List.rev fields)

let findings_json ~posted_comments (report : Review_engine.report) =
  let rec add_findings posted_comments acc = function
    | [] -> List.rev acc
    | routed :: rest ->
      let finding_id, posted_comments =
        match routed.Review_engine.outcome, posted_comments with
        | Review_engine.Routed_inline _, posted :: remaining -> Some posted.finding_id, remaining
        | Review_engine.Routed_inline _, [] -> None, []
        | ( ( Review_engine.Routed_unchanged | Review_engine.Routed_anchor_failed
            | Review_engine.Routed_dropped_unchanged_low_severity ),
            _ ) ->
          None, posted_comments
      in
      add_findings posted_comments (routed_finding_to_json ~finding_id routed :: acc) rest
  in
  `Assoc [ "schema", `Int schema_version; "findings", `List (add_findings posted_comments [] report.routed_findings) ]

let review_costs_json costs =
  `Assoc [ "schema", `Int schema_version; "review_costs", `List (List.map Cost_tracking.review_cost_to_json costs) ]

let fetched_file_json (path, contents) =
  `Assoc
    [
      json_string "path" path;
      json_int "byte_count" (String.length contents);
      json_string "sha256" (sha256_hex contents);
    ]

let fetched_files_json file_contents =
  `Assoc [ "schema", `Int schema_version; "files", `List (List.map fetched_file_json file_contents) ]

let json_type_name = function
  | `Assoc _ -> "object"
  | `Bool _ -> "bool"
  | `Float _ -> "float"
  | `Int _ -> "int"
  | `List _ -> "list"
  | `Null -> "null"
  | `String _ -> "string"

let redacted_prompt_json = function
  | `Null -> `Null
  | `String value ->
    `Assoc [ "redacted", `Bool true; "byte_count", `Int (String.length value); "sha256", `String (sha256_hex value) ]
  | (`Assoc _ | `Bool _ | `Float _ | `Int _ | `List _) as json ->
    `Assoc [ "redacted", `Bool true; "original_type", `String (json_type_name json) ]

let rec redact_prompt_overrides = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
           match String.equal key "system_prompt_override" with
           | true -> key, redacted_prompt_json value
           | false -> key, redact_prompt_overrides value)
         fields)
  | `List values -> `List (List.map redact_prompt_overrides values)
  | (`Bool _ | `Float _ | `Int _ | `Null | `String _) as json -> json

let review_config_json config = Config_types.config_to_json config |> redact_prompt_overrides

let manifest_json ~review_batch_id ~created_at ~repo_url ~pr_number ~head_sha ~review_id ~(job : Review_job.t)
  ~posted_comments =
  `Assoc
    [
      "schema", `Int schema_version;
      "review_batch_id", `String review_batch_id;
      "created_at", `String (Feedback_store.utc_string created_at);
      "repo_url", `String repo_url;
      "pr_number", `Int pr_number;
      "head_sha", `String head_sha;
      "source_kind", `String (Review_job.source_kind_to_string job.source_kind);
      "trigger", `String (Review_job.trigger_to_string job.trigger);
      "reviewotron_version", `Null;
      "config_sha256", `String (Review_job.config_sha256 job);
      "diff_sha256", `String (Review_job.diff_sha256 job);
      "comment_count", `Int (List.length posted_comments);
      "github_review_id", `Int review_id;
    ]

let write_bundle ~evidence_root ~review_batch_id ~created_at ~repo_url ~pr_number ~head_sha ~review_id ~review_body
  ~(job : Review_job.t) ~(report : Review_engine.report) ~posted_comments =
  ensure_dir evidence_root;
  let dir = bundle_dir ~evidence_root ~review_batch_id in
  ensure_dir dir;
  write_json (Filename.concat dir "manifest.json")
    (manifest_json ~review_batch_id ~created_at ~repo_url ~pr_number ~head_sha ~review_id ~job ~posted_comments);
  write_file (Filename.concat dir "filtered_diff.patch") job.diff_text;
  write_json
    (Filename.concat dir "posted_review.json")
    (posted_review_json ~review_id ~pr_number ~head_sha ~review_body ~posted_comments);
  write_json (Filename.concat dir "findings.json") (findings_json ~posted_comments report);
  write_json (Filename.concat dir "review_costs.json") (review_costs_json report.review_costs);
  write_json (Filename.concat dir "review_config.json") (review_config_json job.config);
  write_json (Filename.concat dir "fetched_files.json") (fetched_files_json job.file_contents);
  dir
