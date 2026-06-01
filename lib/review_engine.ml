open Devkit

let log = Log.from "review_engine"

type finding_source =
  | From_general
  | From_security

let severity_rank = function
  | Review_types.Critical -> 5
  | Warning -> 4
  | Suggestion -> 3
  | Nitpick -> 2
  | Praise -> 1
  | Other _ -> 0

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
      let rec sweep acc = function
        | [] -> acc
        | (src, f) :: rest when src = From_security -> sweep ((src, f) :: acc) rest
        | (src, f) :: rest ->
          let collides (src', f') =
            src' = src
            && f'.Review_types.category = f.Review_types.category
            && abs (f'.Review_types.line - f.line) <= near_line_window
          in
          let colliding, others = List.partition collides rest in
          let best =
            List.fold_left
              (fun (bsrc, bf) (csrc, cf) ->
                if severity_rank cf.Review_types.severity > severity_rank bf.Review_types.severity then csrc, cf
                else bsrc, bf)
              (src, f) colliding
          in
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
  ]

let prepare_diff ~config diff_text =
  let parsed_diff = Diff_parser.parse diff_text in
  let filtered_diff = Diff_parser.filter_paths parsed_diff ~ignored:config.Config_types.ignored_paths in
  let total_lines = Diff_parser.total_lines filtered_diff in
  match filtered_diff with
  | [] -> Error `Empty
  | _ when total_lines > config.max_diff_lines -> Error (`Too_large total_lines)
  | _ -> Ok (filtered_diff, Diff_parser.to_string_annotated filtered_diff)

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
  general_result : Review_types.review_output option;
  findings : Review_types.finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
}

type report = {
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

let review_body ~number ~general_result ~findings ~unchanged_findings ~anchor_failed_findings ~review_costs
  ~security_error ~(config : Config_types.config) =
  let unchanged_section =
    render_section ~title:"### Findings on unchanged code (please investigate)"
      ~lead:
        "These security-relevant findings reference files that were not changed in this PR. Investigate whether they \
         should be addressed in this PR or opened as a separate issue:"
      unchanged_findings
  in
  let anchor_failed_section =
    render_section ~title:"### Findings we couldn't anchor (please investigate)"
      ~lead:
        "These findings matched a changed file but could not be anchored to a line in the diff. Likely agent \
         mis-anchoring — please report:"
      anchor_failed_findings
  in
  let body =
    match general_result with
    | Some review ->
      (match String.trim review.Review_types.summary with
      | "" -> ":robot: **REVIEW**"
      | summary -> Printf.sprintf ":robot: **REVIEW**\n\nMinor:\n%s" summary)
    | None ->
      log#error "review failed for PR #%d: no review output produced" number;
      (match findings with
      | _ :: _ ->
        "\xE2\x9A\xA0\xEF\xB8\x8F **Review partially failed** \xE2\x80\x94 the general code review agent encountered \
         an error. Security findings (if any) are shown below. You may want to re-trigger the review."
      | [] ->
        "\xE2\x9A\xA0\xEF\xB8\x8F **Review failed** \xE2\x80\x94 the code review encountered an error and could not \
         produce results. Please re-trigger the review. If this persists, check the service logs.")
  in
  let body = body ^ unchanged_section ^ anchor_failed_section in
  let body = if security_error then body ^ security_error_notice else body in
  if config.show_review_cost then body ^ Cost_tracking.format_footer review_costs else body

module Make (AI : Api.Agent_runner) = struct
  module General_plugin = General_review_plugin.Make (AI)
  module Security_plugin = Security_review_plugin.Make (AI)

  let metadata_of_job ~number (job : Review_job.t) =
    Review_plugin.
      {
        pr_number = number;
        pr_title = job.title;
        pr_description = job.description;
        file_contents = job.file_contents;
        fetch_file = job.fetch_file;
      }

  let run_plugins ~ctx ~job ~number ~diff ~debug_dir =
    let repo_url = job.Review_job.repo_key in
    let config = job.config in
    let metadata = metadata_of_job ~number job in
    let plugins_config = config.Config_types.review_plugins in
    let general_promise =
      if plugins_config.general.enabled then begin
        let%lwt result, costs =
          General_plugin.run_review ~ctx ~repo_url ~config ~diff_text:job.diff_text ~metadata ~debug_dir ()
        in
        match result with
        | Ok review -> Lwt.return (Some review, costs)
        | Error msg ->
          log#error "general review plugin failed: %s" msg;
          Lwt.return (None, costs)
      end
      else Lwt.return (None, [])
    in
    let security_promise =
      if plugins_config.security.enabled then
        Lwt.catch
          (fun () ->
            let%lwt findings, costs =
              Security_plugin.run ~ctx ~repo_url ~config ~diff ~diff_text:job.diff_text ~metadata ~debug_dir
            in
            Lwt.return (findings, costs, false))
          (fun exn ->
            log#error "security review plugin raised: %s" (Exn.str exn);
            Lwt.return ([], [], true))
      else Lwt.return ([], [], false)
    in
    let%lwt (general_result, general_costs), (security_findings, security_costs, security_exn) =
      Lwt.both general_promise security_promise
    in
    let security_error =
      security_exn
      || plugins_config.security.enabled
         &&
         match security_costs with
         | [] -> true
         | _ :: _ -> false
    in
    if security_error then log#warn "security review plugin encountered an error; results may be incomplete";
    let general_findings = Option.map (fun (r : Review_types.review_output) -> r.findings) general_result in
    let sourced =
      List.map (fun f -> From_general, f) (Option.default [] general_findings)
      @ List.map (fun f -> From_security, f) security_findings
    in
    let findings = deduplicate_findings sourced in
    let review_costs =
      [
        Cost_tracking.aggregate ~plugin:"general" general_costs;
        Cost_tracking.aggregate ~plugin:"security" security_costs;
      ]
      |> List.filter (fun (rc : Cost_tracking.review_cost) ->
        match rc.agents with
        | [] -> false
        | _ :: _ -> true)
    in
    Lwt.return { general_result; findings; review_costs; security_error }

  let route_findings ~number ~filtered_diff findings =
    List.fold_left
      (fun (comments, unchanged, anchor_failed) (finding : Review_types.finding) ->
        match route_finding ~diff:filtered_diff finding with
        | Positioned comment -> comment :: comments, unchanged, anchor_failed
        | File_not_in_diff ->
          (match surfaces_in_unchanged_section finding with
          | true -> comments, finding :: unchanged, anchor_failed
          | false ->
            log#info "PR #%d: dropping low-severity finding on unchanged file %s:%d (%s)" number finding.path
              finding.line
              (Review_types.severity_to_string finding.severity);
            comments, unchanged, anchor_failed)
        | Anchor_failed ->
          log#warn "PR #%d: finding on changed file %s:%d could not be anchored — surfacing for investigation" number
            finding.path finding.line;
          comments, unchanged, finding :: anchor_failed)
      ([], [], []) findings

  let run_pr_review ~ctx ~(job : Review_job.t) ~number ~filtered_diff =
    let debug_dir =
      let slug = Security_memory.repo_slug job.repo_key in
      let sha_prefix = String.sub job.head_sha 0 (min 8 (String.length job.head_sha)) in
      Printf.sprintf "debug/%s/%s" slug sha_prefix
    in
    let%lwt plugin_result = run_plugins ~ctx ~job ~number ~diff:filtered_diff ~debug_dir in
    Cost_tracking.log_review_costs plugin_result.review_costs;
    let comments_rev, unchanged_rev, anchor_failed_rev = route_findings ~number ~filtered_diff plugin_result.findings in
    let comments = List.rev comments_rev in
    let unchanged_findings = List.rev unchanged_rev in
    let anchor_failed_findings = List.rev anchor_failed_rev in
    let body =
      review_body ~number ~general_result:plugin_result.general_result ~findings:plugin_result.findings
        ~unchanged_findings ~anchor_failed_findings ~review_costs:plugin_result.review_costs
        ~security_error:plugin_result.security_error ~config:job.config
    in
    let general_failed = job.config.review_plugins.general.enabled && Option.is_none plugin_result.general_result in
    Lwt.return
      {
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
