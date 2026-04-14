open Devkit

let log = Log.from "reviewer"

module Make (GH : Api.Github) (AI : Api.Claude) (SL : Api.Slack) = struct
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
    | Pull_request _ | Unknown _ -> Lwt.return (Ok ())

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
      else if pr.pull_request.draft then Some "draft PR"
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
      Returns [Ok (filtered_diff, filtered_diff_text)] or [Error reason]. *)
  let prepare_diff ~config diff_text =
    let parsed_diff = Diff_parser.parse diff_text in
    let filtered_diff = Diff_parser.filter_paths parsed_diff ~ignored:config.Config_types.ignored_paths in
    let total_lines = Diff_parser.total_lines filtered_diff in
    match filtered_diff with
    | [] -> Error `Empty
    | _ when total_lines > config.max_diff_lines -> Error (`Too_large total_lines)
    | _ -> Ok (filtered_diff, Diff_parser.to_string filtered_diff)

  (** Map a finding to a GitHub review comment, if it can be positioned in the diff. *)
  let finding_to_comment ~diff (finding : Review_types.finding) =
    let file_diff = List.find_opt (fun fd -> String.equal fd.Diff_parser.path finding.path) diff in
    match file_diff with
    | None -> None
    | Some fd ->
    match finding.line with
    | None -> None
    | Some line ->
      let position = Diff_parser.line_to_position fd ~line ~side:Right in
      Option.map
        (fun pos ->
          Github_types.
            {
              path = finding.path;
              position = Some pos;
              line = None;
              side = None;
              start_line = None;
              start_side = None;
              body = Review_format.format_finding_body finding;
            })
        position

  (** Call Claude for a review and post the result as a GitHub PR review. *)
  let execute_and_post_review ~ctx ~repo_url ~number ~pr_title ~diff_text ~filtered_diff ~file_contents ~description
    ~head_sha =
    let%lwt review_result = AI.review_code ~ctx ~repo_url ~diff:diff_text ~files:file_contents ~pr_title ~description in
    match review_result with
    | Error msg ->
      log#error "Claude review failed for PR #%d: %s" number msg;
      Lwt.return_unit
    | Ok review ->
      let comments = List.filter_map (finding_to_comment ~diff:filtered_diff) review.findings in
      let unpositioned = List.length review.findings - List.length comments in
      if unpositioned > 0 then log#info "PR #%d: %d findings could not be positioned in diff" number unpositioned;
      let review_body =
        match review.overall_assessment with
        | "" -> review.summary
        | assessment -> Printf.sprintf "%s\n\n**Overall**: %s" review.summary assessment
      in
      let review_req = Github_types.{ commit_id = Some head_sha; body = review_body; event = Comment; comments } in
      let%lwt post_result = GH.create_pr_review ~ctx ~repo_url ~number review_req in
      (match post_result with
      | Ok () -> log#info "posted review for PR #%d (%s): %d inline comments" number pr_title (List.length comments)
      | Error msg -> log#error "failed to post review for PR #%d: %s" number msg);
      (* Record in state *)
      let state = Context.state ctx in
      State.record_pr_review state ~repo_url ~pr_number:number ~head_sha;
      State.save state;
      Lwt.return_unit

  (** Orchestrate a full PR review: fetch diff, call Claude, post review. *)
  let review_pr ~ctx (pr_notif : Github_types.pr_notification) =
    let repo_url = pr_notif.repository.url in
    let number = pr_notif.number in
    let pr = pr_notif.pull_request in
    log#info "reviewing PR #%d in %s" number pr_notif.repository.full_name;
    let%lwt diff_result = GH.get_pr_diff ~ctx ~repo_url ~number in
    match diff_result with
    | Error msg ->
      log#error "failed to fetch diff for PR #%d: %s" number msg;
      Lwt.return_unit
    | Ok diff_text ->
      let config = Context.get_config ctx ~repo_url in
      (match prepare_diff ~config diff_text with
      | Error `Empty ->
        log#info "PR #%d skipped: all files filtered out" number;
        Lwt.return_unit
      | Error (`Too_large total_lines) ->
        log#info "PR #%d skipped: %d diff lines exceeds limit of %d" number total_lines config.max_diff_lines;
        Lwt.return_unit
      | Ok (filtered_diff, filtered_text) ->
        let head_sha = pr.head.sha in
        let%lwt file_contents = fetch_key_files ~ctx ~repo_url ~diff:filtered_diff ~ref_:(Some head_sha) in
        let description = CCOption.get_or ~default:"" pr.body in
        execute_and_post_review ~ctx ~repo_url ~number ~pr_title:pr.title ~diff_text:filtered_text ~filtered_diff
          ~file_contents ~description ~head_sha)

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
              line = finding.line;
            }
          in
          let%lwt result = GH.create_commit_comment ~ctx ~repo_url ~sha comment in
          (match result with
          | Ok () -> ()
          | Error msg -> log#error "failed to post commit comment on %s: %s" sha msg);
          Lwt.return_unit
        | Suggestion | Nitpick | Praise | Other _ ->
          (* Only post commit comments for critical/warning *)
          Lwt.return_unit)
      findings

  (** Orchestrate a full push review: fetch diff, call Claude, post comments + Slack. *)
  let review_push ~ctx (push : Github_types.commit_pushed_notification) =
    let repo_url = push.repository.url in
    log#info "reviewing push to %s in %s" push.ref_ push.repository.full_name;
    let%lwt diff_result = GH.get_compare_diff ~ctx ~repo_url ~base:push.before ~head:push.after in
    match diff_result with
    | Error msg ->
      log#error "failed to fetch compare diff for push %s...%s: %s" push.before push.after msg;
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
      | Ok (_filtered_diff, filtered_text) ->
        let description =
          push.commits
          |> List.map (fun (c : Github_types.commit) -> Printf.sprintf "- %s" c.message)
          |> String.concat "\n"
        in
        let pr_title = Printf.sprintf "Push to %s" push.ref_ in
        let%lwt review_result = AI.review_code ~ctx ~repo_url ~diff:filtered_text ~files:[] ~pr_title ~description in
        (match review_result with
        | Error msg ->
          log#error "Claude review failed for push %s: %s" push.after msg;
          Lwt.return_unit
        | Ok review ->
          let%lwt () = post_push_comments ~ctx ~repo_url ~sha:push.after review.findings in
          let slack_text = Printf.sprintf ":robot_face: *Code Review* for push to `develop` by %s" push.pusher.name in
          let attachment =
            Review_format.format_slack_attachment ~compare_url:push.compare ~pusher_name:push.pusher.name
              ~num_commits:(List.length push.commits) ~review
          in
          let%lwt () =
            match config.slack_channel with
            | None -> Lwt.return_unit
            | Some channel -> SL.post_message ~ctx ~channel ~text:slack_text ~attachments:[ attachment ] ()
          in
          let state = Context.state ctx in
          State.record_push_review state ~repo_url ~after_sha:push.after;
          State.save state;
          Lwt.return_unit))

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
      | None -> review_pr ~ctx pr
      | Some reason ->
        log#info "PR #%d skipped: %s" pr.number reason;
        Lwt.return_unit)
    | Github.Push push ->
      (match push_skip_reason ~ctx push with
      | None -> review_push ~ctx push
      | Some reason ->
        log#info "push %s skipped: %s" push.after reason;
        Lwt.return_unit)
    | Github.Unknown kind ->
      log#debug "ignoring unhandled event type: %s" kind;
      Lwt.return_unit
end
