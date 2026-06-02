open Devkit

let log = Log.from "reviewer"

(** Origin of a finding, used to break ties during deduplication. *)
type finding_source =
  | From_general
  | From_security

(** Numeric rank for severity — higher means more severe.  Shared between dedup
    and the legacy {!module-type:Make} functor. *)
let severity_rank = function
  | Review_types.Critical -> 5
  | Warning -> 4
  | Suggestion -> 3
  | Nitpick -> 2
  | Praise -> 1
  | Other _ -> 0

(** Prefer the security-plugin finding when two findings land on the same
    (path, line).  Security findings go through triage → analysis → validator
    and carry a source/sink/flow evidence chain; if both plugins spotted the
    same line, the security plugin's rendering is strictly more useful. *)
let pick_for_same_line (_sa, fa) (sb, fb) =
  match _sa, sb with
  | From_security, From_general -> _sa, fa
  | From_general, From_security -> sb, fb
  | From_general, From_general | From_security, From_security ->
    if severity_rank fa.Review_types.severity >= severity_rank fb.Review_types.severity then _sa, fa else sb, fb

(** First pass: collapse duplicates at the exact same (path, line). *)
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

(** Two findings from the same source, same path, and same category are
    treated as describing one issue when their lines are within [window]
    of each other.  The more severe one survives.  The security plugin is
    exempted — validated findings are already filtered for uniqueness. *)
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

(** Deduplicate findings across plugins.  Two passes:
    1. exact same [(path, line)] → prefer the security plugin's finding if
       present, else keep the more severe one.
    2. same source, same path, same [category], lines within {!near_line_window}
       → keep only the highest-severity one.  Security-plugin findings are
       exempted since the validator already filters them. *)
let deduplicate_findings sourced_findings =
  sourced_findings
  |> collapse_same_line
  |> collapse_near_lines
  |> List.map snd
  |> List.sort (fun (a : Review_types.finding) (b : Review_types.finding) ->
    match String.compare a.path b.path with
    | 0 -> Int.compare a.line b.line
    | n -> n)

module Make (GH : Api.Github) (AI : Api.Agent_runner) (SL : Api.Slack) = struct
  type reaction_target =
    | Pull_request of int
    | Issue_comment of int

  type progress_reaction = {
    target : reaction_target;
    reaction_id : int;
  }

  type pr_review_outcome =
    | Review_posted
    | Review_quiet

  (** Retry an Lwt operation once after a 1-second delay on failure.
      The operation is passed as a thunk to ensure the retry executes fresh. *)
  let retry_once ~label f =
    match%lwt f () with
    | Ok () as ok -> Lwt.return ok
    | Error msg ->
      log#warn "%s failed (will retry once): %s" label msg;
      let%lwt () = Lwt_unix.sleep 1.0 in
      f ()

  let create_reaction ~ctx ~repo_url target ~content =
    match target with
    | Pull_request number -> GH.create_issue_reaction ~ctx ~repo_url ~number ~content
    | Issue_comment comment_id -> GH.create_issue_comment_reaction ~ctx ~repo_url ~comment_id ~content

  let start_progress_reaction ~ctx ~repo_url = function
    | None -> Lwt.return None
    | Some target ->
      let%lwt result = create_reaction ~ctx ~repo_url target ~content:"eyes" in
      (match result with
      | Ok reaction_id -> Lwt.return (Some { target; reaction_id })
      | Error msg ->
        log#warn "failed to add review progress reaction: %s" msg;
        Lwt.return None)

  let remove_progress_reaction ~ctx ~repo_url = function
    | None -> Lwt.return_unit
    | Some { target; reaction_id } ->
      let%lwt result =
        match target with
        | Pull_request number -> GH.delete_issue_reaction ~ctx ~repo_url ~number ~reaction_id
        | Issue_comment comment_id -> GH.delete_issue_comment_reaction ~ctx ~repo_url ~comment_id ~reaction_id
      in
      (match result with
      | Ok () -> Lwt.return_unit
      | Error msg ->
        log#warn "failed to remove review progress reaction %d: %s" reaction_id msg;
        Lwt.return_unit)

  (** Add a [+1] reaction directly to a [reaction_target] to signal a
      successful review.  Used both to swap the in-flight "eyes" reaction
      ({!finish_progress_reaction}) and when a review is a no-op (nothing to
      review after filtering) and there is no progress reaction to swap.  A
      no-op when there is no target. *)
  let add_success_reaction ~ctx ~repo_url = function
    | None -> Lwt.return_unit
    | Some target ->
      let%lwt result = create_reaction ~ctx ~repo_url target ~content:"+1" in
      (match result with
      | Ok _reaction_id -> Lwt.return_unit
      | Error msg ->
        log#warn "failed to add success reaction: %s" msg;
        Lwt.return_unit)

  let finish_progress_reaction ~ctx ~repo_url progress ~quiet_success =
    let%lwt () = remove_progress_reaction ~ctx ~repo_url progress in
    match quiet_success with
    | false -> Lwt.return_unit
    | true -> add_success_reaction ~ctx ~repo_url (Option.map (fun { target; _ } -> target) progress)

  (** Post an issue comment to the PR explaining why the review could not run.
      Retries once on transient failure, mirroring the other post paths. *)
  let post_review_failure ~ctx ~repo_url ~number failure =
    let body = Review_failure.to_comment failure in
    let%lwt result =
      retry_once ~label:(Printf.sprintf "create_issue_comment PR #%d" number) (fun () ->
        GH.create_issue_comment ~ctx ~repo_url ~number { body })
    in
    (match result with
    | Ok () -> log#info "posted review-failure comment on PR #%d" number
    | Error msg -> log#error "failed to post review-failure comment on PR #%d after retry: %s" number msg);
    Lwt.return_unit

  (** Fetch config from the repo and cache it in context. *)
  let fetch_config ~ctx ~repo_url =
    match%lwt GH.get_config ~ctx ~repo_url with
    | Ok config ->
      Context.set_repo_config ctx ~repo_url config;
      Lwt.return (Ok ())
    | Error e -> Lwt.return (Error e)

  (** Fetch config if not cached, or re-fetch if a push modified the config file. *)
  let refresh_repo_config ctx event =
    let repo_url = Github.repo_url_of_event event in
    match Context.find_repo_config ctx ~repo_url with
    | None -> fetch_config ~ctx ~repo_url
    | Some _ ->
    match event with
    | Github.Push push ->
      let modified_files = List.concat_map (fun (c : Github_types.commit) -> c.added @ c.modified) push.commits in
      let config_modified = List.exists (String.equal (Context.config_filename ctx)) modified_files in
      if config_modified then fetch_config ~ctx ~repo_url else Lwt.return (Ok ())
    | Pull_request _ | Issue_comment _ | Unknown _ -> Lwt.return (Ok ())

  (** Check whether a PR event should trigger a review.
      Returns [None] if it should, [Some reason] if it should be skipped. *)
  let is_bot_sender login = CCString.suffix ~suf:"[bot]" login

  let pr_skip_reason ~ctx (pr : Github_types.pr_notification) =
    let config = Context.get_config ctx ~repo_url:pr.repository.url in
    let state = Context.state ctx in
    let head_sha = pr.pull_request.head.sha in
    if is_bot_sender pr.sender.login then Some (Printf.sprintf "bot sender %s" pr.sender.login)
    else if List.exists (fun a -> String.equal a pr.sender.login) config.ignored_authors then
      Some (Printf.sprintf "ignored author %s" pr.sender.login)
    else (
      let is_reviewable_action =
        match Github.pr_action_of_string pr.action with
        | Opened | Reopened | Ready_for_review -> config.auto_review_pr_open
        | Synchronize -> config.auto_review_pr_sync
        | Closed | Edited | Other _ -> false
      in
      if not is_reviewable_action then Some (Printf.sprintf "action %s not reviewable" pr.action)
      else if pr.pull_request.draft && not config.review_draft_prs then Some "draft PR"
      else if State.is_pr_reviewed state ~repo_url:pr.repository.url ~pr_number:pr.number ~head_sha then
        Some (Printf.sprintf "already reviewed at %s" (String.sub head_sha 0 (min 8 (String.length head_sha))))
      else None)

  (** Check whether a push event should trigger a review.
      Returns [None] if it should, [Some reason] if it should be skipped. *)
  let push_skip_reason ~ctx (push : Github_types.commit_pushed_notification) =
    let config = Context.get_config ctx ~repo_url:push.repository.url in
    let state = Context.state ctx in
    let is_develop = String.equal push.ref_ "refs/heads/develop" in
    let is_ignored_author = List.exists (fun a -> String.equal a push.sender.login) config.ignored_authors in
    let is_duplicate = State.is_push_reviewed state ~repo_url:push.repository.url ~after_sha:push.after in
    if is_bot_sender push.sender.login then Some (Printf.sprintf "bot sender %s" push.sender.login)
    else if not config.review_pushes_to_develop then Some "push reviews disabled"
    else if not is_develop then Some (Printf.sprintf "ref %s is not develop" push.ref_)
    else if push.created then Some "branch creation"
    else if push.deleted then Some "branch deletion"
    else if is_ignored_author then Some (Printf.sprintf "ignored author %s" push.sender.login)
    else if is_duplicate then
      Some (Printf.sprintf "already reviewed at %s" (String.sub push.after 0 (min 8 (String.length push.after))))
    else None

  (** Check whether an [issue_comment] event with body [REVIEW] should
      trigger a review.  The trigger-phrase check is performed at the
      dispatch site {e before} this function is called, so the body is
      not re-checked here.  Returns [None] if a review should run,
      [Some reason] if it should be skipped (with a log line).

      Order matters: structural checks (action, comment-on-PR-vs-issue,
      PR state) come before the config gate so a misconfigured payload
      surfaces a clear reason rather than the generic "disabled".
      Author filters come last because they only matter once we've
      decided the request is otherwise valid. *)
  let comment_skip_reason ~ctx (n : Github_types.issue_comment_notification) =
    let config = Context.get_config ctx ~repo_url:n.repository.url in
    if not (String.equal n.action "created") then Some (Printf.sprintf "comment action %s not reviewable" n.action)
    else if Option.is_none n.issue.pull_request then Some "comment is on an issue, not a PR"
    else if not (String.equal n.issue.state "open") then Some (Printf.sprintf "PR state is %s" n.issue.state)
    else if not config.auto_review_on_comment then Some "auto_review_on_comment disabled"
    else if is_bot_sender n.sender.login then Some (Printf.sprintf "bot sender %s" n.sender.login)
    else if List.exists (fun a -> String.equal a n.sender.login) config.ignored_authors then
      Some (Printf.sprintf "ignored author %s" n.sender.login)
    else None

  (** Fetch a small number of key file contents for additional context. *)
  let fetch_key_files ~ctx ~repo_url ~diff ~ref_ =
    let paths =
      diff
      |> List.filter (fun (fd : Diff_parser.file_diff) ->
        match fd.status with
        | Diff_parser.Added -> true
        | Diff_parser.Modified -> true
        | Diff_parser.Renamed -> false
        | Diff_parser.Deleted -> false)
      |> List.map (fun (fd : Diff_parser.file_diff) -> fd.path)
    in
    (* Limit to 5 files to avoid blowing up the prompt *)
    let paths = CCList.take 5 paths in
    match ref_ with
    | None -> Lwt.return []
    | Some sha ->
      Lwt_list.filter_map_p
        (fun path ->
          let%lwt result = GH.get_file_content ~ctx ~repo_url ~path ~ref_:sha in
          match result with
          | Ok (Some content) -> Lwt.return (Some (path, content))
          | Ok None -> Lwt.return None
          | Error msg ->
            log#warn "failed to fetch %s: %s" path msg;
            Lwt.return None)
        paths

  (** Parse a raw diff, filter ignored paths, and check size limits.

      Returns [Ok (filtered_diff, annotated_diff_text)] or [Error reason].
      The returned text is annotated with per-line new-file line numbers so
      agents can anchor findings by lookup rather than by counting.  See
      {!Diff_parser.to_string_annotated}. *)
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
      (match total_lines with
      | n when n > config.max_diff_lines -> Error (`Too_large n)
      | _ -> Ok (filtered_diff, Diff_parser.to_string_annotated filtered_diff))

  (** Decide whether a finding can be rendered as a multi-line comment.

      Returns [Some (start, end_)] when [end_line] is present, strictly above
      [line], and the whole [line..end_line] span fits inside one right-side
      hunk.  Returns [None] for single-line findings or whenever the range
      fails any check — the caller falls back to the single-line path. *)
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

  (** Outcome of attempting to render a finding as an inline review comment.

      - [Positioned] — successfully mapped to a line in the diff.
      - [File_not_in_diff] — the finding's [path] doesn't match any changed file.
        Legitimate findings on unchanged code land here.
      - [Anchor_failed] — the path matched a changed file but we couldn't
        derive a usable line (line ≤ 0, or the file has no right-side hunks).
        Treated as a bug report for prompt tuning. *)
  type finding_routing =
    | Positioned of Github_types.review_comment_req
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
        | Some (s, e) -> Some s, Some Github_types.Right, e
        | None -> None, None, resolved_line
      in
      Positioned
        Github_types.
          {
            path = fd.path;
            position = None;
            line = Some end_line;
            side = Some Right;
            start_line;
            start_side;
            body = Review_format.format_finding_body finding;
          }

  let finding_to_comment ~diff finding =
    match route_finding ~diff finding with
    | Positioned c -> Some c
    | File_not_in_diff | Anchor_failed -> None

  module General_plugin = General_review_plugin.Make (AI)
  module Security_plugin = Security_review_plugin.Make (GH) (AI)

  (** Run all enabled review plugins and collect findings and costs.
      Returns the general review output (if the general plugin is enabled),
      a deduplicated list of findings from all plugins, per-plugin review costs,
      and a boolean indicating whether the security plugin encountered an error. *)
  let run_plugins ~ctx ~repo_url ~config ~diff ~diff_text ~metadata ~debug_dir ~head_sha =
    let plugins_config = config.Config_types.review_plugins in
    (* Run enabled plugins concurrently — they are independent. *)
    let general_promise =
      if plugins_config.general.enabled then begin
        let%lwt result, costs = General_plugin.run_review ~ctx ~repo_url ~diff_text ~metadata ~debug_dir () in
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
              Security_plugin.run ~ctx ~repo_url ~diff ~diff_text ~metadata ~debug_dir ~head_sha
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
    (* Detect security plugin failure: either it raised an exception, or it was
       enabled but the triage agent failed entirely (no costs produced at all). *)
    let security_error =
      security_exn
      || plugins_config.security.enabled
         &&
         match security_costs with
         | [] -> true
         | _ :: _ -> false
    in
    if security_error then log#warn "security review plugin encountered an error; results may be incomplete";
    (* Merge general review findings with additional plugin findings, tagging
       each with its source so deduplication can prefer the security plugin. *)
    let general_findings = Option.map (fun (r : Review_types.review_output) -> r.findings) general_result in
    let sourced =
      List.map (fun f -> From_general, f) (Option.default [] general_findings)
      @ List.map (fun f -> From_security, f) security_findings
    in
    let deduplicated = deduplicate_findings sourced in
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
    Lwt.return (general_result, deduplicated, review_costs, security_error)

  let security_error_notice =
    "\n\n\
     _Note: The security review plugin encountered an error and may not have completed. Security analysis may be \
     incomplete._"

  (** Run the plugin orchestrator and post the result as a GitHub PR review. *)
  let execute_and_post_review ~progress ~ctx ~repo_url ~config ~number ~pr_title ~diff_text ~filtered_diff
    ~file_contents ~description ~head_sha =
    let metadata = Review_plugin.{ pr_number = number; pr_title; pr_description = description; file_contents } in
    let debug_dir =
      let slug = Security_memory.repo_slug repo_url in
      let sha_prefix = String.sub head_sha 0 (min 8 (String.length head_sha)) in
      Printf.sprintf "debug/%s/%s" slug sha_prefix
    in
    let%lwt general_result, findings, review_costs, security_error =
      run_plugins ~ctx ~repo_url ~config ~diff:filtered_diff ~diff_text ~metadata ~debug_dir ~head_sha
    in
    Cost_tracking.log_review_costs review_costs;
    (* Route each finding to an inline comment, a main-body section, or /dev/null. *)
    let surfaces_in_unchanged_section (f : Review_types.finding) =
      match f.severity with
      | Critical | Warning -> true
      | Suggestion | Nitpick | Praise | Other _ -> false
    in
    let comments_rev, unchanged_rev, anchor_failed_rev =
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
    in
    let comments = List.rev comments_rev in
    let unchanged_findings = List.rev unchanged_rev in
    let anchor_failed_findings = List.rev anchor_failed_rev in
    let surfaced_findings_count =
      List.length comments + List.length unchanged_findings + List.length anchor_failed_findings
    in
    let review_has_surface = surfaced_findings_count > 0 in
    let general_failed = Option.is_none general_result in
    let to_bullet (f : Review_types.finding) = Printf.sprintf "- `%s:%d` %s" f.path f.line f.message in
    let render_section ~title ~lead = function
      | [] -> ""
      | _ :: _ as fs ->
        let bullets = String.concat "\n" (List.map to_bullet fs) in
        Printf.sprintf "\n\n%s\n%s\n%s" title lead bullets
    in
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
    let state = Context.state ctx in
    let record_reviewed () =
      State.record_pr_review state ~repo_url ~pr_number:number ~head_sha ~review_costs;
      State.save state
    in
    match review_has_surface || general_failed || security_error with
    | false ->
      let%lwt () = finish_progress_reaction ~ctx ~repo_url progress ~quiet_success:true in
      log#info "PR #%d (%s): review completed with no findings; not posting a PR review" number pr_title;
      record_reviewed ();
      Lwt.return Review_quiet
    | true ->
      let review_body =
        match general_result with
        | Some review ->
          (match String.trim review.summary with
          | "" -> ":robot: **REVIEW**"
          | summary -> Printf.sprintf ":robot: **REVIEW**\n\nMinor:\n%s" summary)
        | None ->
          log#error "review failed for PR #%d: no review output produced" number;
          (match findings with
          | _ :: _ ->
            "\xE2\x9A\xA0\xEF\xB8\x8F **Review partially failed** \xE2\x80\x94 the general code review agent \
             encountered an error. Security findings (if any) are shown below. You may want to re-trigger the review."
          | [] ->
            "\xE2\x9A\xA0\xEF\xB8\x8F **Review failed** \xE2\x80\x94 the code review encountered an error and could \
             not produce results. Please re-trigger the review. If this persists, check the service logs.")
      in
      let review_body = review_body ^ unchanged_section ^ anchor_failed_section in
      let review_body = if security_error then review_body ^ security_error_notice else review_body in
      let review_body =
        if config.show_review_cost then review_body ^ Cost_tracking.format_footer review_costs else review_body
      in
      let short_sha = if String.length head_sha >= 7 then String.sub head_sha 0 7 else head_sha in
      let review_body = Printf.sprintf "%s\n\n**Reviewed commit:** `%s`" review_body short_sha in
      let review_req = Github_types.{ commit_id = Some head_sha; body = review_body; event = Comment; comments } in
      let%lwt () = finish_progress_reaction ~ctx ~repo_url progress ~quiet_success:false in
      let%lwt post_result =
        retry_once ~label:(Printf.sprintf "create_pr_review PR #%d" number) (fun () ->
          GH.create_pr_review ~ctx ~repo_url ~number review_req)
      in
      (match post_result with
      | Ok () -> log#info "posted review for PR #%d (%s): %d inline comments" number pr_title (List.length comments)
      | Error msg -> log#error "failed to post review for PR #%d after retry: %s" number msg);
      record_reviewed ();
      Lwt.return Review_posted

  (** Orchestrate a full PR review: fetch diff, run review agent, post review. *)
  let review_pr ?reaction_target ~ctx (pr_notif : Github_types.pr_notification) =
    let repo_url = pr_notif.repository.url in
    let number = pr_notif.number in
    let pr = pr_notif.pull_request in
    log#info "reviewing PR #%d in %s" number pr_notif.repository.full_name;
    let%lwt diff_result = GH.get_pr_diff ~ctx ~repo_url ~number in
    match diff_result with
    | Error fetch_error ->
      log#error "failed to fetch diff for PR #%d: %s" number fetch_error.Http_util.message;
      post_review_failure ~ctx ~repo_url ~number (Review_failure.classify_fetch_error fetch_error)
    | Ok diff_text ->
      let config = Context.get_config ctx ~repo_url in
      (match prepare_diff ~config diff_text with
      | Error `Empty ->
        (* Nothing to review after filtering — a successful no-op, not a
           failure.  Signal "looked, all good" with a thumbs-up. *)
        log#info "PR #%d: all files filtered out, nothing to review" number;
        add_success_reaction ~ctx ~repo_url reaction_target
      | Error (`Too_large total_lines) ->
        log#info "PR #%d skipped: %d diff lines exceeds limit of %d" number total_lines config.max_diff_lines;
        post_review_failure ~ctx ~repo_url ~number
          (Review_failure.Too_many_lines { actual = total_lines; limit = config.max_diff_lines })
      | Error (`Too_many_files file_count) ->
        log#info "PR #%d skipped: %d files exceeds limit of %d" number file_count config.max_files;
        post_review_failure ~ctx ~repo_url ~number
          (Review_failure.Too_many_files { actual = file_count; limit = config.max_files })
      | Ok (filtered_diff, filtered_text) ->
        let head_sha = pr.head.sha in
        let%lwt progress = start_progress_reaction ~ctx ~repo_url reaction_target in
        (* The review pipeline can raise (network errors, SDK schema drift,
           etc.).  Ensure the progress reaction is cleared even when the
           pipeline crashes — otherwise the "eyes" reaction is orphaned on the
           PR / comment and the user has no signal that the bot gave up. *)
        (try%lwt
           let%lwt file_contents = fetch_key_files ~ctx ~repo_url ~diff:filtered_diff ~ref_:(Some head_sha) in
           let description = CCOption.get_or ~default:"" pr.body in
           let%lwt (_outcome : pr_review_outcome) =
             execute_and_post_review ~progress ~ctx ~repo_url ~config ~number ~pr_title:pr.title
               ~diff_text:filtered_text ~filtered_diff ~file_contents ~description ~head_sha
           in
           Lwt.return_unit
         with exn ->
           log#error "review pipeline for PR #%d raised: %s" number (Exn.str exn);
           let%lwt () = remove_progress_reaction ~ctx ~repo_url progress in
           Lwt.fail exn))

  (** Review the PR referenced by an [issue_comment] webhook.

      The [issue_comment] payload only carries the [issue] shape, not the
      [pull_request] shape — crucially it lacks [head.sha] which the review
      pipeline uses as the git ref for file-content fetches.  We fetch the
      full PR via [get_pull_request], synthesise a [pr_notification] around
      it (using the comment payload's repository/sender/installation), and
      delegate to [review_pr].

      [pr_skip_reason] is intentionally bypassed: [comment_skip_reason] has
      already gated the request, and the [State.is_pr_reviewed] dedup that
      [pr_skip_reason] applies is exactly the behaviour we want to skip on
      a manual [REVIEW] trigger.  The synthesised [action] field is set to
      a sentinel that no [pr_action_of_string] arm matches; nothing in
      [review_pr] reads it. *)
  let review_pr_from_comment ~ctx (n : Github_types.issue_comment_notification) =
    let repo_url = n.repository.url in
    let%lwt result = GH.get_pull_request ~ctx ~repo_url ~number:n.issue.number in
    match result with
    | Error msg ->
      log#error "failed to fetch PR #%d for REVIEW comment trigger: %s" n.issue.number msg;
      Lwt.return_unit
    | Ok pr ->
      let synthesised : Github_types.pr_notification =
        {
          action = "comment_review";
          number = n.issue.number;
          pull_request = pr;
          repository = n.repository;
          sender = n.sender;
          installation = n.installation;
        }
      in
      review_pr ~reaction_target:(Issue_comment n.comment.id) ~ctx synthesised

  (** Post commit comments for critical/warning findings from a push review. *)
  let post_push_comments ~ctx ~repo_url ~sha findings =
    Lwt_list.iter_s
      (fun (finding : Review_types.finding) ->
        match finding.severity with
        | Critical | Warning ->
          let comment : Github_types.commit_comment_req =
            {
              body = Review_format.format_finding_body finding;
              path = Some finding.path;
              position = None;
              line = Some finding.line;
            }
          in
          let%lwt result =
            retry_once ~label:(Printf.sprintf "create_commit_comment %s" sha) (fun () ->
              GH.create_commit_comment ~ctx ~repo_url ~sha comment)
          in
          (match result with
          | Ok () -> ()
          | Error msg -> log#error "failed to post commit comment on %s after retry: %s" sha msg);
          Lwt.return_unit
        | Suggestion | Nitpick | Praise | Other _ ->
          (* Only post commit comments for critical/warning *)
          Lwt.return_unit)
      findings

  (** Orchestrate a full push review: fetch diff, run review agent, post comments + Slack. *)
  let review_push ~ctx (push : Github_types.commit_pushed_notification) =
    let repo_url = push.repository.url in
    log#info "reviewing push to %s in %s" push.ref_ push.repository.full_name;
    let%lwt diff_result = GH.get_compare_diff ~ctx ~repo_url ~base:push.before ~head:push.after in
    (* Unlike the PR path, push failures are not surfaced to the user here:
       a push has no PR/issue to comment on, only a branch.  We log and drop;
       the existing Slack failure path (below) covers produced-but-failed
       reviews. *)
    match diff_result with
    | Error fetch_error ->
      log#error "failed to fetch compare diff for push %s...%s: %s" push.before push.after fetch_error.Http_util.message;
      Lwt.return_unit
    | Ok diff_text ->
      let config = Context.get_config ctx ~repo_url in
      (match prepare_diff ~config diff_text with
      | Error `Empty ->
        log#info "push %s skipped: all files ignored" push.after;
        Lwt.return_unit
      | Error (`Too_large total_lines) ->
        log#info "push %s skipped: %d diff lines exceeds limit of %d" push.after total_lines config.max_diff_lines;
        Lwt.return_unit
      | Error (`Too_many_files file_count) ->
        log#info "push %s skipped: %d files exceeds limit of %d" push.after file_count config.max_files;
        Lwt.return_unit
      | Ok (filtered_diff, filtered_text) ->
        let description =
          push.commits
          |> List.map (fun (c : Github_types.commit) -> Printf.sprintf "- %s" c.message)
          |> String.concat "\n"
        in
        let pr_title = Printf.sprintf "Push to %s" push.ref_ in
        let metadata = Review_plugin.{ pr_number = 0; pr_title; pr_description = description; file_contents = [] } in
        let debug_dir =
          let slug = Security_memory.repo_slug repo_url in
          let sha_prefix = String.sub push.after 0 (min 8 (String.length push.after)) in
          Printf.sprintf "debug/%s/%s" slug sha_prefix
        in
        let%lwt general_result, findings, review_costs, security_error =
          run_plugins ~ctx ~repo_url ~config ~diff:filtered_diff ~diff_text:filtered_text ~metadata ~debug_dir
            ~head_sha:push.after
        in
        Cost_tracking.log_review_costs review_costs;
        let%lwt () = post_push_comments ~ctx ~repo_url ~sha:push.after findings in
        let security_note = String.trim security_error_notice in
        let slack_text, attachment =
          match general_result with
          | Some review ->
            let text = Printf.sprintf ":robot_face: *Code Review* for push to `develop` by %s" push.pusher.name in
            let att =
              Review_format.format_slack_attachment ~compare_url:push.compare ~pusher_name:push.pusher.name
                ~num_commits:(List.length push.commits) ~review
            in
            let att = if security_error then Slack_types.{ att with text = att.text ^ "\n" ^ security_note } else att in
            text, att
          | None ->
            log#error "review failed for push %s: no review output produced" push.after;
            let text = Printf.sprintf ":warning: *Code Review Failed* for push to `develop` by %s" push.pusher.name in
            let failure_text =
              match findings with
              | _ :: _ ->
                "\xE2\x9A\xA0\xEF\xB8\x8F Review partially failed \xE2\x80\x94 the general code review agent \
                 encountered an error. Security findings were posted as commit comments."
              | [] ->
                "\xE2\x9A\xA0\xEF\xB8\x8F Review failed \xE2\x80\x94 the code review encountered an error and could \
                 not produce results. Check the service logs."
            in
            let failure_text = if security_error then failure_text ^ " " ^ security_note else failure_text in
            let att =
              Slack_types.
                {
                  color = "#dc3545";
                  title =
                    Printf.sprintf "Push by %s \xE2\x80\x94 %d commits" push.pusher.name (List.length push.commits);
                  title_link = push.compare;
                  text = failure_text;
                  fields = [];
                  footer = Some "reviewotron";
                }
            in
            text, att
        in
        let%lwt () =
          match config.slack_channel with
          | None -> Lwt.return_unit
          | Some channel -> SL.post_message ~ctx ~channel ~text:slack_text ~attachments:[ attachment ] ()
        in
        let state = Context.state ctx in
        State.record_push_review state ~repo_url ~after_sha:push.after;
        State.save state;
        Lwt.return_unit)

  let process_event ctx ~event =
    let%lwt () =
      match event with
      | Github.Unknown _ -> Lwt.return_unit
      | _ ->
      match%lwt refresh_repo_config ctx event with
      | Ok () -> Lwt.return_unit
      | Error msg ->
        log#warn "failed to refresh repo config: %s" msg;
        Lwt.return_unit
    in
    match event with
    | Github.Pull_request pr ->
      (match pr_skip_reason ~ctx pr with
      | None -> review_pr ~reaction_target:(Pull_request pr.number) ~ctx pr
      | Some reason ->
        log#info "PR #%d skipped: %s" pr.number reason;
        Lwt.return_unit)
    | Github.Push push ->
      (match push_skip_reason ~ctx push with
      | None -> review_push ~ctx push
      | Some reason ->
        log#info "push %s skipped: %s" push.after reason;
        Lwt.return_unit)
    | Github.Issue_comment n ->
      (* Trigger phrase: the comment body, after trimming, must equal
         exactly "REVIEW".  Skip silently for any other body — most PR
         comments are conversation, and we don't want to log a skip
         reason for every one of them. *)
      (match String.equal (String.trim n.comment.body) "REVIEW" with
      | false -> Lwt.return_unit
      | true ->
      match comment_skip_reason ~ctx n with
      | None ->
        log#info "REVIEW comment on PR #%d by %s: triggering review" n.issue.number n.sender.login;
        review_pr_from_comment ~ctx n
      | Some reason ->
        log#info "REVIEW comment on PR #%d skipped: %s" n.issue.number reason;
        Lwt.return_unit)
    | Github.Unknown kind ->
      log#debug "ignoring unhandled event type: %s" kind;
      Lwt.return_unit
end
