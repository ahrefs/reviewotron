open Devkit

let log = Log.from "review_engine"

let log_context_prefix = function
  | None -> ""
  | Some context -> context ^ " "

type finding_source =
  | From_general
  | From_security

let finding_source_to_string = function
  | From_general -> "general"
  | From_security -> "security"

type sourced_finding = {
  source : finding_source;
  plugin_name : string;
  finding : Review_types.finding;
}

type routing_outcome =
  | Routed_inline of Review_comment.t
  | Routed_unchanged
  | Routed_anchor_failed
  | Routed_dropped_unchanged_low_severity

type routed_finding = {
  sourced : sourced_finding;
  outcome : routing_outcome;
}

type inline_finding = {
  comment : Review_comment.t;
  sourced : sourced_finding;
}

(** A findings-producing review plugin registered with the engine.

    The general plugin is handled separately because its summary becomes the
    review body; every other plugin only emits findings, and they are uniform.
    Adding a findings plugin is: implement its run function (a [Review_plugin.S]
    plus [~debug_dir]), give it a config slice, and add one entry to the
    [findings_plugins] list inside {!Make}. *)
type findings_plugin = {
  fp_name : string;  (** Plugin name; used for cost attribution and logs. *)
  fp_source : finding_source;  (** How dedup treats this plugin's findings on a line collision. *)
  fp_enabled : Config_types.config -> bool;  (** Whether the plugin runs, read from config. *)
  fp_run :
    ctx:Context.t ->
    repo_url:string ->
    config:Config_types.config ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:Review_plugin.review_metadata ->
    log_context:string option ->
    debug_dir:string ->
    (Review_types.finding list * Cost_tracking.agent_cost list) Lwt.t;
}

let severity_rank = function
  | Review_types.Critical -> 5
  | Warning -> 4
  | Suggestion -> 3
  | Nitpick -> 2
  | Praise -> 1
  | Other _ -> 0

let same_source a b =
  match a, b with
  | From_general, From_general | From_security, From_security -> true
  | From_general, From_security | From_security, From_general -> false

let same_category a b =
  String.equal (Review_types.finding_category_to_string a) (Review_types.finding_category_to_string b)

let sourced_of_pair (source, finding) = { source; plugin_name = finding_source_to_string source; finding }

let pick_for_same_line a b =
  match a.source, b.source with
  | From_security, From_general -> a
  | From_general, From_security -> b
  | From_general, From_general | From_security, From_security ->
    if severity_rank a.finding.Review_types.severity >= severity_rank b.finding.Review_types.severity then a else b

let collapse_same_line sourced_findings =
  let tbl = Hashtbl.create (List.length sourced_findings) in
  List.iter
    (fun sourced ->
      let f = sourced.finding in
      let key = f.Review_types.path, f.line in
      match Hashtbl.find_opt tbl key with
      | None -> Hashtbl.add tbl key sourced
      | Some existing -> Hashtbl.replace tbl key (pick_for_same_line existing sourced))
    sourced_findings;
  Hashtbl.fold (fun _ v acc -> v :: acc) tbl []

let near_line_window = 3

let collapse_near_lines sourced_findings =
  let by_path = Hashtbl.create 16 in
  List.iter
    (fun sourced ->
      let bucket = try Hashtbl.find by_path sourced.finding.path with Not_found -> [] in
      Hashtbl.replace by_path sourced.finding.path (sourced :: bucket))
    sourced_findings;
  let keep = ref [] in
  Hashtbl.iter
    (fun _path bucket ->
      let sorted = List.sort (fun a b -> Int.compare a.finding.Review_types.line b.finding.Review_types.line) bucket in
      let collides sourced other =
        same_source other.source sourced.source
        && same_category other.finding.Review_types.category sourced.finding.Review_types.category
        && abs (other.finding.Review_types.line - sourced.finding.line) <= near_line_window
      in
      let pick_more_severe best candidate =
        if severity_rank candidate.finding.Review_types.severity > severity_rank best.finding.Review_types.severity then
          candidate
        else best
      in
      let rec collect_near_lines best rest =
        let colliding, others = List.partition (collides best) rest in
        match colliding with
        | [] -> best, others
        | _ :: _ ->
          let best = List.fold_left pick_more_severe best colliding in
          collect_near_lines best others
      in
      let rec sweep acc = function
        | [] -> acc
        | ({ source = From_security; _ } as finding) :: rest -> sweep (finding :: acc) rest
        | finding :: rest ->
          let best, others = collect_near_lines finding rest in
          sweep (best :: acc) others
      in
      let kept = sweep [] sorted in
      keep := kept @ !keep)
    by_path;
  !keep

let deduplicate_sourced_findings sourced_findings =
  sourced_findings
  |> collapse_same_line
  |> collapse_near_lines
  |> List.sort (fun a b ->
    let a_finding = a.finding in
    let b_finding = b.finding in
    match String.compare a_finding.Review_types.path b_finding.Review_types.path with
    | 0 -> Int.compare a_finding.line b_finding.line
    | n -> n)

let deduplicate_findings sourced_findings =
  sourced_findings |> List.map sourced_of_pair |> deduplicate_sourced_findings |> List.map (fun sf -> sf.finding)

type prepare_diff_error =
  [ `Empty
  | `Too_large of int
  | `Too_many_files of int
  ]

let prepare_diff ~config diff_text =
  let parsed_diff = Diff_parser.parse diff_text in
  let filtered_diff = Diff_parser.filter_paths parsed_diff ~ignored:config.Config_types.ignored_paths in
  match filtered_diff with
  | [] -> Error `Empty
  | _ when List.compare_length_with filtered_diff config.max_files > 0 ->
    Error (`Too_many_files (List.length filtered_diff))
  | _ ->
    (* Counting lines folds over the whole diff; defer it past the cheaper
       file-count check so an over-[max_files] diff isn't fully traversed. *)
    let total_lines = Diff_parser.total_lines filtered_diff in
    if total_lines > config.max_diff_lines then Error (`Too_large total_lines)
    else Ok (filtered_diff, Diff_parser.to_string_annotated filtered_diff)

let valid_multiline_range ?log_context fd (finding : Review_types.finding) ~resolved_line =
  let log_prefix = log_context_prefix log_context in
  match finding.end_line with
  | None -> None
  | Some end_line ->
  match () with
  | () when end_line <= resolved_line -> None
  | () when not (Diff_anchor.single_hunk_contains fd ~start_line:resolved_line ~end_line) ->
    log#info "%sdegrading multi-line finding to single-line (range %s:%d..%d crosses hunk boundary or is out of diff)"
      log_prefix finding.path resolved_line end_line;
    None
  | () -> Some (resolved_line, end_line)

type finding_routing =
  | Positioned of Review_comment.t
  | File_not_in_diff
  | Anchor_failed

let route_finding ?log_context ~diff (finding : Review_types.finding) =
  let file_diff = Diff_anchor.find_file_diff_by_path ~diff finding.path in
  match file_diff with
  | None -> File_not_in_diff
  | Some fd ->
  match finding.line with
  | line when line <= 0 -> Anchor_failed
  | line ->
  match Diff_anchor.resolve_right_line fd ~target_line:line with
  | None -> Anchor_failed
  | Some resolved_line ->
    let start_line, start_side, end_line =
      match valid_multiline_range ?log_context fd finding ~resolved_line with
      | Some (s, e) -> Some s, Some Review_comment.Right, e
      | None -> None, None, resolved_line
    in
    Positioned
      Review_comment.
        {
          path = fd.path;
          line = end_line;
          side = Right;
          start_line;
          start_side;
          body = Review_format.format_finding_body finding;
        }

let finding_to_review_comment ?log_context ~diff finding =
  match route_finding ?log_context ~diff finding with
  | Positioned c -> Some c
  | File_not_in_diff | Anchor_failed -> None

let security_error_notice =
  "\n\n\
   _Note: The security review plugin encountered an error and may not have completed. Security analysis may be \
   incomplete._"

type plugin_result = {
  general_output : (Review_types.review_output, string) result option;
    (** The general plugin's outcome: [Some (Ok review)] on success,
          [Some (Error reason)] when it ran but failed (the reason is surfaced
          in the failure notice), or [None] when the plugin is disabled. *)
  findings : Review_types.finding list;
  sourced_findings : sourced_finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
}

type report = {
  body : string;
  comments : Review_comment.t list;
  inline_findings : inline_finding list;
  findings : Review_types.finding list;
  sourced_findings : sourced_finding list;
  routed_findings : routed_finding list;
  unchanged_findings : Review_types.finding list;
  anchor_failed_findings : Review_types.finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
  general_failed : bool;
    (** [true] when the general review plugin was expected to produce output
          but failed. Used by GitHub publishing to decide whether a no-finding
          review can stay quiet (just a reaction) or must still post a failure
          notice. *)
}

let surfaces_in_unchanged_section (f : Review_types.finding) =
  match f.severity with
  | Critical | Warning -> true
  | Suggestion | Nitpick | Praise | Other _ -> false

let to_bullet (f : Review_types.finding) = Printf.sprintf "- `%s:%d` %s" f.path f.line f.message

let render_section ~title ~lead = function
  | [] -> ""
  | _ :: _ as fs ->
    let bullets = String.concat "\n" (List.map to_bullet fs) in
    Printf.sprintf "\n\n%s\n%s\n%s" title lead bullets

(* Append the raw plugin error in a collapsed [<details>] block, matching the
   style of {!Review_failure} comments. Lets the author see the actual cause
   (e.g. a provider 400) without it dominating the notice. *)
let with_failure_details ~reason body =
  match reason with
  | None -> body
  | Some reason -> Printf.sprintf "%s\n\n<details><summary>Details</summary>\n\n```\n%s\n```\n\n</details>" body reason

let review_body ~log_context ~change_label ~general_output ~findings ~unchanged_findings ~anchor_failed_findings
  ~review_costs ~security_error ~(config : Config_types.config) =
  let log_prefix = log_context_prefix (Some log_context) in
  let unchanged_section =
    render_section ~title:"### Findings on unchanged code (please investigate)"
      ~lead:
        "These security-relevant findings reference files that were not changed here. Investigate whether they should \
         be addressed in this change or opened as a separate issue:"
      unchanged_findings
  in
  let anchor_failed_section =
    render_section ~title:"### Findings we couldn't anchor (please investigate)"
      ~lead:
        "These findings matched a changed file but could not be anchored to a line in the diff. Likely agent \
         mis-anchoring — please report:"
      anchor_failed_findings
  in
  let failure_notice reason =
    log#error "%sreview failed for %s: no review output produced" log_prefix change_label;
    let notice =
      match findings with
      | _ :: _ ->
        "\xE2\x9A\xA0\xEF\xB8\x8F **Review partially failed** \xE2\x80\x94 the general code review agent encountered \
         an error. Security findings (if any) are shown below. You may want to re-trigger the review."
      | [] ->
        "\xE2\x9A\xA0\xEF\xB8\x8F **Review failed** \xE2\x80\x94 the code review encountered an error and could not \
         produce results. Please re-trigger the review. If this persists, check the service logs."
    in
    with_failure_details ~reason notice
  in
  let body =
    match general_output with
    | Some (Ok review) ->
      (match String.trim review.Review_types.summary with
      | "" -> ":robot: **REVIEW**"
      | summary -> Printf.sprintf ":robot: **REVIEW**\n\nMinor:\n%s" summary)
    | Some (Error reason) -> failure_notice (Some reason)
    | None ->
    match config.review_plugins.general.enabled with
    | true -> failure_notice None
    | false -> ":robot: **REVIEW**"
  in
  let body = body ^ unchanged_section ^ anchor_failed_section in
  let body = if security_error then body ^ security_error_notice else body in
  if config.show_review_cost then body ^ Cost_tracking.format_footer review_costs else body

module Make (AI : Api.Agent_runner) = struct
  module General_plugin = General_review_plugin.Make (AI)
  module Security_plugin = Security_review_plugin.Make (AI)

  (* The registry of findings plugins. Add an entry to register a new plugin. *)
  let findings_plugins =
    [
      {
        fp_name = Security_plugin.name;
        fp_source = From_security;
        fp_enabled = (fun (c : Config_types.config) -> c.review_plugins.security.enabled);
        fp_run = Security_plugin.run;
      };
    ]

  let debug_root ~ctx =
    match Context.feedback_store ctx with
    | Some store ->
      let paths = Feedback_store.paths store in
      Filename.concat (Filename.dirname paths.evidence_root) "debug"
    | None -> "debug"

  let debug_dir_for_job ~ctx (job : Review_job.t) =
    let slug = Security_memory.repo_slug job.repo_key in
    let sha_prefix = String.sub job.head_sha 0 (min 8 (String.length job.head_sha)) in
    Filename.concat (Filename.concat (debug_root ~ctx) slug) sha_prefix

  let metadata_of_job (job : Review_job.t) =
    Review_plugin.
      {
        change_title = job.title;
        change_description = job.description;
        file_contents = job.file_contents;
        fetch_file = job.fetch_file;
      }

  let run_plugins ~ctx ~job ~debug_dir =
    let log_context = Review_job.log_context job in
    let log_prefix = log_context_prefix (Some log_context) in
    let repo_url = job.Review_job.repo_key in
    let config = job.config in
    let diff = job.filtered_diff in
    let metadata = metadata_of_job job in
    let plugins_config = config.Config_types.review_plugins in
    log#info "%splugins starting: general=%b security=%b files=%d diff_bytes=%d debug_dir=%s" log_prefix
      plugins_config.general.enabled plugins_config.security.enabled (List.length diff) (String.length job.diff_text)
      debug_dir;
    let general_promise =
      if plugins_config.general.enabled then begin
        let%lwt result, costs =
          General_plugin.run_review ~ctx ~repo_url ~config ~diff_text:job.diff_text ~metadata ~debug_dir ~log_context ()
        in
        (match result with
        | Ok _ -> ()
        | Error msg -> log#error "%sgeneral review plugin failed: %s" log_prefix msg);
        Lwt.return (Some result, costs)
      end
      else Lwt.return (None, [])
    in
    let run_findings_plugin (plugin : findings_plugin) =
      match plugin.fp_enabled config with
      | false -> Lwt.return (plugin, [], [], false)
      | true ->
        Lwt.catch
          (fun () ->
            let%lwt findings, costs =
              plugin.fp_run ~ctx ~repo_url ~config ~diff ~diff_text:job.diff_text ~metadata
                ~log_context:(Some log_context) ~debug_dir
            in
            Lwt.return (plugin, findings, costs, false))
          (fun exn ->
            log#error "%s%s review plugin raised: %s" log_prefix plugin.fp_name (Exn.str exn);
            Lwt.return (plugin, [], [], true))
    in
    let%lwt (general_output, general_costs), findings_results =
      Lwt.both general_promise (Lwt.all (List.map run_findings_plugin findings_plugins))
    in
    (* A findings plugin "errored" if it raised, or if it was enabled yet
       produced no cost record (its agents never ran). The security plugin is
       currently the only findings plugin, so this matches the prior
       [security_error] semantics and drives the same failure notice. *)
    let security_error =
      List.exists
        (fun (plugin, _findings, costs, errored) -> errored || (plugin.fp_enabled config && costs = []))
        findings_results
    in
    if security_error then log#warn "%sa findings plugin encountered an error; results may be incomplete" log_prefix;
    let general_findings =
      match general_output with
      | Some (Ok (r : Review_types.review_output)) -> r.findings
      | Some (Error _) | None -> []
    in
    let plugin_findings =
      List.concat_map
        (fun (plugin, findings, _costs, _errored) ->
          List.map (fun finding -> { source = plugin.fp_source; plugin_name = plugin.fp_name; finding }) findings)
        findings_results
    in
    let sourced =
      List.map (fun finding -> { source = From_general; plugin_name = General_plugin.name; finding }) general_findings
      @ plugin_findings
    in
    let sourced_findings = deduplicate_sourced_findings sourced in
    let findings = List.map (fun sourced -> sourced.finding) sourced_findings in
    let plugin_costs =
      List.map
        (fun (plugin, _findings, costs, _errored) -> Cost_tracking.aggregate ~plugin:plugin.fp_name costs)
        findings_results
    in
    let review_costs =
      Cost_tracking.aggregate ~plugin:"general" general_costs :: plugin_costs
      |> List.filter (fun (rc : Cost_tracking.review_cost) ->
        match rc.agents with
        | [] -> false
        | _ :: _ -> true)
    in
    let general_status =
      match general_output with
      | Some (Ok _) -> "ok"
      | Some (Error _) -> "error"
      | None -> "disabled"
    in
    log#info "%splugins complete: findings=%d general=%s findings_plugin_error=%b" log_prefix (List.length findings)
      general_status security_error;
    Lwt.return { general_output; findings; sourced_findings; review_costs; security_error }

  let route_findings ~log_context ~change_label ~filtered_diff findings =
    let log_prefix = log_context_prefix (Some log_context) in
    List.fold_left
      (fun (routed, inline_findings, unchanged, anchor_failed) sourced ->
        let finding = sourced.finding in
        match route_finding ~log_context ~diff:filtered_diff finding with
        | Positioned comment ->
          let inline = { comment; sourced } in
          { sourced; outcome = Routed_inline comment } :: routed, inline :: inline_findings, unchanged, anchor_failed
        | File_not_in_diff ->
          (match surfaces_in_unchanged_section finding with
          | true ->
            { sourced; outcome = Routed_unchanged } :: routed, inline_findings, finding :: unchanged, anchor_failed
          | false ->
            log#info "%s%s: dropping low-severity finding on unchanged file %s:%d (%s)" log_prefix change_label
              finding.path finding.line
              (Review_types.severity_to_string finding.severity);
            ( { sourced; outcome = Routed_dropped_unchanged_low_severity } :: routed,
              inline_findings,
              unchanged,
              anchor_failed ))
        | Anchor_failed ->
          log#warn "%s%s: finding on changed file %s:%d could not be anchored — surfacing for investigation" log_prefix
            change_label finding.path finding.line;
          { sourced; outcome = Routed_anchor_failed } :: routed, inline_findings, unchanged, finding :: anchor_failed)
      ([], [], [], []) findings

  let run_review ~ctx ~(job : Review_job.t) =
    let log_context = Review_job.log_context job in
    let log_prefix = log_context_prefix (Some log_context) in
    let debug_dir = debug_dir_for_job ~ctx job in
    let filtered_diff = job.filtered_diff in
    log#info "%sreview starting: trigger=%s source=%s files=%d diff_bytes=%d debug_dir=%s" log_prefix
      (Review_job.trigger_to_string job.trigger)
      (Review_job.source_kind_to_string job.source_kind)
      (List.length filtered_diff) (String.length job.diff_text) debug_dir;
    let%lwt plugin_result = run_plugins ~ctx ~job ~debug_dir in
    Cost_tracking.log_review_costs ~log_context plugin_result.review_costs;
    let routed_rev, inline_findings_rev, unchanged_rev, anchor_failed_rev =
      route_findings ~log_context ~change_label:job.change_label ~filtered_diff plugin_result.sourced_findings
    in
    let routed_findings = List.rev routed_rev in
    let inline_findings = List.rev inline_findings_rev in
    let comments = List.map (fun inline -> inline.comment) inline_findings in
    let unchanged_findings = List.rev unchanged_rev in
    let anchor_failed_findings = List.rev anchor_failed_rev in
    let body =
      review_body ~log_context ~change_label:job.change_label ~general_output:plugin_result.general_output
        ~findings:plugin_result.findings ~unchanged_findings ~anchor_failed_findings
        ~review_costs:plugin_result.review_costs ~security_error:plugin_result.security_error ~config:job.config
    in
    let general_failed =
      match plugin_result.general_output with
      | Some (Error _) -> true
      | Some (Ok _) | None -> false
    in
    log#info "%sreview routed: inline=%d unchanged=%d anchor_failed=%d total_findings=%d" log_prefix
      (List.length inline_findings) (List.length unchanged_findings) (List.length anchor_failed_findings)
      (List.length plugin_result.findings);
    Lwt.return
      {
        body;
        comments;
        inline_findings;
        findings = plugin_result.findings;
        sourced_findings = plugin_result.sourced_findings;
        routed_findings;
        unchanged_findings;
        anchor_failed_findings;
        review_costs = plugin_result.review_costs;
        security_error = plugin_result.security_error;
        general_failed;
      }
end
