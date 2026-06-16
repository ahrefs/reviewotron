open Devkit

let log = Log.from "review_engine"

type finding_source =
  | From_general
  | From_security

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

let pick_for_same_line (sa, fa) (sb, fb) =
  match sa, sb with
  | From_security, From_general -> sa, fa
  | From_general, From_security -> sb, fb
  | From_general, From_general | From_security, From_security ->
    if severity_rank fa.Review_types.severity >= severity_rank fb.Review_types.severity then sa, fa else sb, fb

let collapse_same_line sourced_findings =
  let tbl = Hashtbl.create (List.length sourced_findings) in
  List.iter
    (fun (source, (f : Review_types.finding)) ->
      let key = f.path, f.line in
      match Hashtbl.find_opt tbl key with
      | None -> Hashtbl.add tbl key (source, f)
      | Some existing -> Hashtbl.replace tbl key (pick_for_same_line existing (source, f)))
    sourced_findings;
  Hashtbl.fold (fun _ v acc -> v :: acc) tbl []

let near_line_window = 3

let collapse_near_lines sourced_findings =
  let by_path = Hashtbl.create 16 in
  List.iter
    (fun ((_, f) as sf : finding_source * Review_types.finding) ->
      let bucket = try Hashtbl.find by_path f.path with Not_found -> [] in
      Hashtbl.replace by_path f.path (sf :: bucket))
    sourced_findings;
  let keep = ref [] in
  Hashtbl.iter
    (fun _path bucket ->
      let sorted = List.sort (fun (_, a) (_, b) -> Int.compare a.Review_types.line b.Review_types.line) bucket in
      let collides (src, f) (src', f') =
        same_source src' src
        && same_category f'.Review_types.category f.Review_types.category
        && abs (f'.Review_types.line - f.line) <= near_line_window
      in
      let pick_more_severe (bsrc, bf) (csrc, cf) =
        if severity_rank cf.Review_types.severity > severity_rank bf.Review_types.severity then csrc, cf else bsrc, bf
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
        | ((From_security, _) as finding) :: rest -> sweep (finding :: acc) rest
        | finding :: rest ->
          let best, others = collect_near_lines finding rest in
          sweep (best :: acc) others
      in
      let kept = sweep [] sorted in
      keep := kept @ !keep)
    by_path;
  !keep

let deduplicate_findings sourced_findings =
  sourced_findings
  |> collapse_same_line
  |> collapse_near_lines
  |> List.map snd
  |> List.sort (fun (a : Review_types.finding) (b : Review_types.finding) ->
    match String.compare a.path b.path with
    | 0 -> Int.compare a.line b.line
    | n -> n)

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

let valid_multiline_range fd (finding : Review_types.finding) ~resolved_line =
  match finding.end_line with
  | None -> None
  | Some end_line ->
  match () with
  | () when end_line <= resolved_line -> None
  | () when not (Diff_anchor.single_hunk_contains fd ~start_line:resolved_line ~end_line) ->
    log#info "degrading multi-line finding to single-line (range %s:%d..%d crosses hunk boundary or is out of diff)"
      finding.path resolved_line end_line;
    None
  | () -> Some (resolved_line, end_line)

type finding_routing =
  | Positioned of Review_comment.t
  | File_not_in_diff
  | Anchor_failed

let route_finding ~diff (finding : Review_types.finding) =
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
      match valid_multiline_range fd finding ~resolved_line with
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

let finding_to_review_comment ~diff finding =
  match route_finding ~diff finding with
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
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
}

type report = {
  schema_version : int;
  review_status : string;
  reviewed_root : string option;
  change_key : string option;
  body : string;
  comments : Review_comment.t list;
  findings : Review_types.finding list;
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

let review_body ~change_label ~general_output ~findings ~unchanged_findings ~anchor_failed_findings ~review_costs
  ~security_error ~(config : Config_types.config) =
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
    log#error "review failed for %s: no review output produced" change_label;
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
    | None -> failure_notice None
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

  let metadata_of_job (job : Review_job.t) =
    Review_plugin.
      {
        change_title = job.title;
        change_description = job.description;
        file_contents = job.file_contents;
        fetch_file = job.fetch_file;
      }

  let run_plugins ~ctx ~job ~debug_dir =
    let repo_url = job.Review_job.repo_key in
    let config = job.config in
    let diff = job.filtered_diff in
    let metadata = metadata_of_job job in
    let plugins_config = config.Config_types.review_plugins in
    let general_promise =
      if plugins_config.general.enabled then begin
        let%lwt result, costs =
          General_plugin.run_review ~ctx ~repo_url ~config ~diff_text:job.diff_text ~metadata ~debug_dir ()
        in
        (match result with
        | Ok _ -> ()
        | Error msg -> log#error "general review plugin failed: %s" msg);
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
              plugin.fp_run ~ctx ~repo_url ~config ~diff ~diff_text:job.diff_text ~metadata ~debug_dir
            in
            Lwt.return (plugin, findings, costs, false))
          (fun exn ->
            log#error "%s review plugin raised: %s" plugin.fp_name (Exn.str exn);
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
    if security_error then log#warn "a findings plugin encountered an error; results may be incomplete";
    let general_findings =
      match general_output with
      | Some (Ok (r : Review_types.review_output)) -> r.findings
      | Some (Error _) | None -> []
    in
    let plugin_findings =
      List.concat_map
        (fun (plugin, findings, _costs, _errored) -> List.map (fun f -> plugin.fp_source, f) findings)
        findings_results
    in
    let sourced = List.map (fun f -> From_general, f) general_findings @ plugin_findings in
    let findings = deduplicate_findings sourced in
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
    Lwt.return { general_output; findings; review_costs; security_error }

  let route_findings ~change_label ~filtered_diff findings =
    List.fold_left
      (fun (comments, unchanged, anchor_failed) (finding : Review_types.finding) ->
        match route_finding ~diff:filtered_diff finding with
        | Positioned comment -> comment :: comments, unchanged, anchor_failed
        | File_not_in_diff ->
          (match surfaces_in_unchanged_section finding with
          | true -> comments, finding :: unchanged, anchor_failed
          | false ->
            log#info "%s: dropping low-severity finding on unchanged file %s:%d (%s)" change_label finding.path
              finding.line
              (Review_types.severity_to_string finding.severity);
            comments, unchanged, anchor_failed)
        | Anchor_failed ->
          log#warn "%s: finding on changed file %s:%d could not be anchored — surfacing for investigation" change_label
            finding.path finding.line;
          comments, unchanged, finding :: anchor_failed)
      ([], [], []) findings

  let review_status ~security_error ~general_failed =
    match general_failed || security_error with
    | true -> "partial"
    | false -> "completed"

  let run_review ~ctx ~(job : Review_job.t) =
    let debug_dir =
      let slug = Security_memory.repo_slug job.repo_key in
      let sha_prefix = String.sub job.head_sha 0 (min 8 (String.length job.head_sha)) in
      Printf.sprintf "debug/%s/%s" slug sha_prefix
    in
    let filtered_diff = job.filtered_diff in
    let%lwt plugin_result = run_plugins ~ctx ~job ~debug_dir in
    Cost_tracking.log_review_costs plugin_result.review_costs;
    let comments_rev, unchanged_rev, anchor_failed_rev =
      route_findings ~change_label:job.change_label ~filtered_diff plugin_result.findings
    in
    let comments = List.rev comments_rev in
    let unchanged_findings = List.rev unchanged_rev in
    let anchor_failed_findings = List.rev anchor_failed_rev in
    let body =
      review_body ~change_label:job.change_label ~general_output:plugin_result.general_output
        ~findings:plugin_result.findings ~unchanged_findings ~anchor_failed_findings
        ~review_costs:plugin_result.review_costs ~security_error:plugin_result.security_error ~config:job.config
    in
    let general_failed =
      match plugin_result.general_output with
      | Some (Error _) -> true
      | Some (Ok _) | None -> false
    in
    Lwt.return
      {
        schema_version = 1;
        review_status = review_status ~security_error:plugin_result.security_error ~general_failed;
        reviewed_root = job.reviewed_root;
        change_key = Some job.change_key;
        body;
        comments;
        findings = plugin_result.findings;
        unchanged_findings;
        anchor_failed_findings;
        review_costs = plugin_result.review_costs;
        security_error = plugin_result.security_error;
        general_failed;
      }
end
