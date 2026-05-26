open Devkit

let log = Log.from "reviewer"

(** Origin of a finding, kept here as a compatibility alias for existing
    callers. The implementation lives in {!Review_engine}. *)
type finding_source = Review_engine.finding_source =
  | From_general
  | From_security

let deduplicate_findings = Review_engine.deduplicate_findings

module Make (SRC : Api.Review_source) (SNK : Api.Review_sink) (AI : Api.Agent_runner) (SL : Api.Slack) = struct
  module Engine = Review_engine.Make (AI)

  (** Retry an Lwt operation once after a 1-second delay on failure.
      The operation is passed as a thunk to ensure the retry executes fresh. *)
  let retry_once ~label f =
    match%lwt f () with
    | Ok () as ok -> Lwt.return ok
    | Error msg ->
      log#warn "%s failed (will retry once): %s" label msg;
      let%lwt () = Lwt_unix.sleep 1.0 in
      f ()

  (** Fetch config from the repo and cache it in context. *)
  let fetch_config ~ctx ~repo_url =
    match%lwt SRC.get_config ~ctx ~repo_url with
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
          let%lwt result = SRC.get_file_content ~ctx ~repo_url ~path ~ref_:sha in
          match result with
          | Ok (Some content) -> Lwt.return (Some (path, content))
          | Ok None -> Lwt.return None
          | Error msg ->
            log#warn "failed to fetch %s: %s" path msg;
            Lwt.return None)
        paths

  let github_side_of_review_comment = function
    | Review_comment.Left -> Github_types.Left
    | Review_comment.Right -> Github_types.Right

  let github_comment_of_review_comment (comment : Review_comment.t) : Github_types.review_comment_req =
    {
      path = comment.path;
      position = None;
      line = Some comment.line;
      side = Some (github_side_of_review_comment comment.side);
      start_line = comment.start_line;
      start_side = Option.map github_side_of_review_comment comment.start_side;
      body = comment.body;
    }

  type finding_routing = Review_engine.finding_routing =
    | Positioned of Review_comment.t
    | File_not_in_diff
    | Anchor_failed

  let route_finding = Review_engine.route_finding

  let finding_to_comment ~diff finding =
    Option.map github_comment_of_review_comment (Review_engine.finding_to_review_comment ~diff finding)

  (** Run the plugin orchestrator and post the result as a GitHub PR review. *)
  let fetch_file_at_ref ~ctx ~repo_url ~ref_ ~path = SRC.get_file_content ~ctx ~repo_url ~path ~ref_

  let execute_and_post_review ~ctx ~job ~number ~filtered_diff =
    let%lwt report = Engine.run_pr_review ~ctx ~job ~number ~filtered_diff in
    let github_comments = List.map github_comment_of_review_comment report.comments in
    let review_req =
      Github_types.{ commit_id = Some job.head_sha; body = report.body; event = Comment; comments = github_comments }
    in
    let%lwt post_result =
      retry_once ~label:(Printf.sprintf "create_pr_review PR #%d" number) (fun () ->
        SNK.create_pr_review ~ctx ~repo_url:job.repo_key ~number review_req)
    in
    (match post_result with
    | Ok () ->
      log#info "posted review for PR #%d (%s): %d inline comments" number job.title (List.length report.comments)
    | Error msg -> log#error "failed to post review for PR #%d after retry: %s" number msg);
    let state = Context.state ctx in
    State.record_pr_review state ~repo_url:job.repo_key ~pr_number:number ~head_sha:job.head_sha
      ~review_costs:report.review_costs;
    State.save state;
    Lwt.return_unit

  (** Orchestrate a full PR review: fetch diff, run review agent, post review. *)
  let review_pr ~ctx (pr_notif : Github_types.pr_notification) =
    let repo_url = pr_notif.repository.url in
    let number = pr_notif.number in
    let pr = pr_notif.pull_request in
    log#info "reviewing PR #%d in %s" number pr_notif.repository.full_name;
    let%lwt diff_result = SRC.get_pr_diff ~ctx ~repo_url ~number in
    match diff_result with
    | Error msg ->
      log#error "failed to fetch diff for PR #%d: %s" number msg;
      Lwt.return_unit
    | Ok diff_text ->
      let config = Context.get_config ctx ~repo_url in
      (match Review_engine.prepare_diff ~config diff_text with
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
        let fetch_file = fetch_file_at_ref ~ctx ~repo_url ~ref_:head_sha in
        let job =
          Review_job.
            {
              repo_key = repo_url;
              change_key = Printf.sprintf "pr/%d/%s" number head_sha;
              title = pr.title;
              description;
              head_sha;
              diff_text = filtered_text;
              config;
              file_contents;
              fetch_file;
              trigger = Pull_request;
              source_kind = Github;
            }
        in
        execute_and_post_review ~ctx ~job ~number ~filtered_diff)

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
    let%lwt result = SRC.get_pull_request ~ctx ~repo_url ~number:n.issue.number in
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
      review_pr ~ctx synthesised

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
              SNK.create_commit_comment ~ctx ~repo_url ~sha comment)
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
    let%lwt diff_result = SRC.get_compare_diff ~ctx ~repo_url ~base:push.before ~head:push.after in
    match diff_result with
    | Error msg ->
      log#error "failed to fetch compare diff for push %s...%s: %s" push.before push.after msg;
      Lwt.return_unit
    | Ok diff_text ->
      let config = Context.get_config ctx ~repo_url in
      (match Review_engine.prepare_diff ~config diff_text with
      | Error `Empty ->
        log#info "push %s skipped: all files ignored" push.after;
        Lwt.return_unit
      | Error (`Too_large total_lines) ->
        log#info "push %s skipped: %d diff lines exceeds limit of %d" push.after total_lines config.max_diff_lines;
        Lwt.return_unit
      | Ok (filtered_diff, filtered_text) ->
        let description =
          push.commits
          |> List.map (fun (c : Github_types.commit) -> Printf.sprintf "- %s" c.message)
          |> String.concat "\n"
        in
        let pr_title = Printf.sprintf "Push to %s" push.ref_ in
        let fetch_file = fetch_file_at_ref ~ctx ~repo_url ~ref_:push.after in
        let job =
          Review_job.
            {
              repo_key = repo_url;
              change_key = push.after;
              title = pr_title;
              description;
              head_sha = push.after;
              diff_text = filtered_text;
              config;
              file_contents = [];
              fetch_file;
              trigger = Push;
              source_kind = Github;
            }
        in
        let debug_dir =
          let slug = Security_memory.repo_slug repo_url in
          let sha_prefix = String.sub push.after 0 (min 8 (String.length push.after)) in
          Printf.sprintf "debug/%s/%s" slug sha_prefix
        in
        let%lwt plugin_result = Engine.run_plugins ~ctx ~job ~number:0 ~diff:filtered_diff ~debug_dir in
        let Review_engine.{ general_result; findings; review_costs; security_error } = plugin_result in
        Cost_tracking.log_review_costs review_costs;
        let%lwt () = post_push_comments ~ctx ~repo_url ~sha:push.after findings in
        let security_note = String.trim Review_engine.security_error_notice in
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
