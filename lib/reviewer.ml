open Devkit

let log = Log.from "reviewer"

(** Origin of a finding, kept here as a compatibility alias for existing
    callers. The implementation lives in {!Review_engine}. *)
type finding_source = Review_engine.finding_source =
  | From_general
  | From_security

let deduplicate_findings = Review_engine.deduplicate_findings

(** Where an in-progress / quiet-success reaction is attached. PR-triggered
    reviews react on the pull request; REVIEW-comment-triggered reviews react on
    the triggering comment. *)
type reaction_target =
  | Pull_request of int
  | Issue_comment of int

type progress_reaction = {
  target : reaction_target;
  reaction_id : int;
}

module Make
    (SRC : Api.Github_review_source)
    (SNK : Api.Github_review_sink)
    (RX : Api.Reactions)
    (AI : Api.Agent_runner)
    (SL : Api.Slack) =
struct
  module Source = Github_source.Make (SRC)
  module Sink = Github_sink.Make (SNK)
  module Engine = Review_engine.Make (AI)

  type finding_routing = Review_engine.finding_routing =
    | Positioned of Review_comment.t
    | File_not_in_diff
    | Anchor_failed

  let route_finding = Review_engine.route_finding

  let finding_to_comment ~diff finding =
    Option.map Github_sink.review_comment_req_of_comment (Review_engine.finding_to_review_comment ~diff finding)

  (* {2 GitHub emoji reactions}

     The review pipeline drops an "eyes" reaction when work starts and clears it
     when work finishes.  When a review completes with nothing worth posting we
     leave a "+1" instead of an empty PR review, so the author still gets a
     signal that the bot ran.  All reaction failures are logged and swallowed —
     a missing reaction must never abort or fail a review. *)

  let create_reaction ~ctx ~repo_url target ~content =
    match target with
    | Pull_request number -> RX.create_issue_reaction ~ctx ~repo_url ~number ~content
    | Issue_comment comment_id -> RX.create_issue_comment_reaction ~ctx ~repo_url ~comment_id ~content

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
        | Pull_request number -> RX.delete_issue_reaction ~ctx ~repo_url ~number ~reaction_id
        | Issue_comment comment_id -> RX.delete_issue_comment_reaction ~ctx ~repo_url ~comment_id ~reaction_id
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
    | true -> add_success_reaction ~ctx ~repo_url (Option.map (fun { target; _ } -> target) progress)
    | false -> Lwt.return_unit

  (** A report is worth posting as a PR review when it surfaces any inline
      comment, any out-of-diff finding section, a security-plugin error, or a
      general-review failure that the author must be told about.  Otherwise the
      review stays quiet — we acknowledge it with a reaction instead. *)
  let report_has_surface (report : Review_engine.report) =
    (match report.comments with
      | [] -> false
      | _ :: _ -> true)
    || (match report.unchanged_findings with
      | [] -> false
      | _ :: _ -> true)
    || (match report.anchor_failed_findings with
      | [] -> false
      | _ :: _ -> true)
    || report.security_error
    || report.general_failed

  let record_pr_reviewed ~ctx ~repo_url ~number ~head_sha ~review_costs =
    let state = Context.state ctx in
    State.record_pr_review state ~repo_url ~pr_number:number ~head_sha ~review_costs;
    State.save state

  let run_prepared_pr_review ?reaction_target ~ctx (prepared : Github_source.prepared_pr_review) =
    let Github_source.{ number; job } = prepared in
    let%lwt progress = start_progress_reaction ~ctx ~repo_url:job.repo_key reaction_target in
    (* The review pipeline can raise (network errors, SDK schema drift, etc.).
       Ensure the progress reaction is cleared even when the pipeline crashes —
       otherwise the "eyes" reaction is orphaned and the author has no signal
       that the bot gave up. *)
    try%lwt
      let%lwt report = Engine.run_review ~ctx ~job in
      let%lwt () =
        match report_has_surface report with
        | false ->
          let%lwt () = finish_progress_reaction ~ctx ~repo_url:job.repo_key progress ~quiet_success:true in
          log#info "PR #%d (%s): review completed with no findings; not posting a PR review" number job.title;
          Lwt.return_unit
        | true ->
          let%lwt () = finish_progress_reaction ~ctx ~repo_url:job.repo_key progress ~quiet_success:false in
          Sink.publish_pr_review ~ctx ~job ~number report
      in
      record_pr_reviewed ~ctx ~repo_url:job.repo_key ~number ~head_sha:job.head_sha ~review_costs:report.review_costs;
      Lwt.return_unit
    with exn ->
      log#error "review pipeline for PR #%d raised: %s" number (Exn.str exn);
      let%lwt () = remove_progress_reaction ~ctx ~repo_url:job.repo_key progress in
      Lwt.fail exn

  (** Surface a PR-preparation failure to the author instead of silently
      dropping it.  An [Empty] diff is a successful no-op (acknowledge with a
      [+1]); the size/limit and fetch failures get an explanatory issue comment.

      The PR is recorded as reviewed — suppressing retries on the same head SHA
      — only for terminal outcomes whose notice was actually delivered: a
      successfully posted limit/too-large comment, or the empty no-op.  A failed
      comment post, or a transient ([Fetch_failed]) error, leaves the PR
      un-recorded so the next webhook retries. *)
  let handle_pr_prepare_error ?reaction_target ~ctx ~repo_url ~number ~head_sha (error : Github_source.prepare_error) =
    let post_then_record_if_delivered failure =
      let%lwt post_result = Sink.publish_failure_comment ~ctx ~repo_url ~number failure in
      (match post_result with
      | Ok () -> record_pr_reviewed ~ctx ~repo_url ~number ~head_sha ~review_costs:[]
      | Error _ -> ());
      Lwt.return_unit
    in
    match error with
    | Empty ->
      (* Nothing to review after filtering — a successful no-op, not a failure.
         Signal "looked, all good" with a thumbs-up. *)
      let%lwt () = add_success_reaction ~ctx ~repo_url reaction_target in
      record_pr_reviewed ~ctx ~repo_url ~number ~head_sha ~review_costs:[];
      Lwt.return_unit
    | Too_large total_lines ->
      let config = Context.get_config ctx ~repo_key:repo_url in
      post_then_record_if_delivered (Too_many_lines { actual = total_lines; limit = config.max_diff_lines })
    | Too_many_files file_count ->
      let config = Context.get_config ctx ~repo_key:repo_url in
      post_then_record_if_delivered (Too_many_files { actual = file_count; limit = config.max_files })
    | Fetch_failed fetch_error ->
      let failure = Review_failure.classify_fetch_error fetch_error in
      let%lwt post_result = Sink.publish_failure_comment ~ctx ~repo_url ~number failure in
      (* A remote-too-large diff is a permanent property of this head SHA, so
         record it once the notice lands.  Any other fetch failure may be
         transient — never record it, so the review is retried. *)
      (match failure with
      | Diff_too_large_remote _ ->
        (match post_result with
        | Ok () -> record_pr_reviewed ~ctx ~repo_url ~number ~head_sha ~review_costs:[]
        | Error _ -> ())
      | Fetch_failed _ | Too_many_lines _ | Too_many_files _ -> ());
      Lwt.return_unit

  let ignore_prepare_error (_ : Github_source.prepare_error) = Lwt.return_unit

  let review_pr ?reaction_target ~ctx ~config (pr_notif : Github_types.pr_notification) =
    match%lwt Source.prepare_pr_review ~ctx ~config pr_notif with
    | Ok prepared -> run_prepared_pr_review ?reaction_target ~ctx prepared
    | Error error ->
      handle_pr_prepare_error ?reaction_target ~ctx ~repo_url:pr_notif.repository.url ~number:pr_notif.number
        ~head_sha:pr_notif.pull_request.head.sha error

  let review_pr_from_comment ?reaction_target ~ctx ~config (n : Github_types.issue_comment_notification) =
    match%lwt Source.prepare_pr_review_from_comment ~ctx ~config n with
    | Ok prepared -> run_prepared_pr_review ?reaction_target ~ctx prepared
    | Error error -> ignore_prepare_error error

  let review_push ~ctx ~config (push : Github_types.commit_pushed_notification) =
    match%lwt Source.prepare_push_review ~ctx ~config push with
    | Error error -> ignore_prepare_error error
    | Ok prepared ->
      let Github_source.{ job; push } = prepared in
      let debug_dir =
        let slug = Security_memory.repo_slug job.repo_key in
        let sha_prefix = String.sub job.head_sha 0 (min 8 (String.length job.head_sha)) in
        Printf.sprintf "debug/%s/%s" slug sha_prefix
      in
      let%lwt plugin_result = Engine.run_plugins ~ctx ~job ~debug_dir in
      let Review_engine.{ general_output; findings; review_costs; security_error } = plugin_result in
      Cost_tracking.log_review_costs review_costs;
      let%lwt () = Sink.post_push_comments ~ctx ~repo_url:job.repo_key ~sha:job.head_sha findings in
      let security_note = String.trim Review_engine.security_error_notice in
      let failure_attachment reason =
        log#error "review failed for push %s: no review output produced" push.after;
        let text = Printf.sprintf ":warning: *Code Review Failed* for push to `develop` by %s" push.pusher.name in
        let failure_text =
          match findings with
          | _ :: _ ->
            "\xE2\x9A\xA0\xEF\xB8\x8F Review partially failed \xE2\x80\x94 the general code review agent encountered \
             an error. Security findings were posted as commit comments."
          | [] ->
            "\xE2\x9A\xA0\xEF\xB8\x8F Review failed \xE2\x80\x94 the code review encountered an error and could not \
             produce results. Check the service logs."
        in
        let failure_text =
          match reason with
          | None -> failure_text
          | Some reason -> Printf.sprintf "%s\n```\n%s\n```" failure_text reason
        in
        let failure_text = if security_error then failure_text ^ " " ^ security_note else failure_text in
        let att =
          Slack_types.
            {
              color = "#dc3545";
              title = Printf.sprintf "Push by %s \xE2\x80\x94 %d commits" push.pusher.name (List.length push.commits);
              title_link = push.compare;
              text = failure_text;
              fields = [];
              footer = Some "reviewotron";
            }
        in
        text, att
      in
      let slack_text, attachment =
        match general_output with
        | Some (Ok _) ->
          let text = Printf.sprintf ":robot_face: *Code Review* for push to `develop` by %s" push.pusher.name in
          let att =
            Review_format.format_slack_attachment ~compare_url:push.compare ~pusher_name:push.pusher.name
              ~num_commits:(List.length push.commits) ~findings
          in
          let att = if security_error then Slack_types.{ att with text = att.text ^ "\n" ^ security_note } else att in
          text, att
        | Some (Error reason) -> failure_attachment (Some reason)
        | None -> failure_attachment None
      in
      let%lwt () =
        match job.config.slack_channel with
        | None -> Lwt.return_unit
        | Some channel -> SL.post_message ~ctx ~channel ~text:slack_text ~attachments:[ attachment ] ()
      in
      let state = Context.state ctx in
      State.record_push_review state ~repo_url:job.repo_key ~after_sha:job.head_sha;
      State.save state;
      Lwt.return_unit

  let event_config ctx event =
    let repo_key = Github.repo_url_of_event event in
    match%lwt Source.refresh_repo_config ctx event with
    | Ok config -> Lwt.return config
    | Error msg ->
      log#warn "failed to refresh repo config: %s" msg;
      Lwt.return (Context.get_config ctx ~repo_key)

  let process_event ctx ~event =
    let%lwt config =
      match event with
      | Github.Unknown _ -> Lwt.return (Context.default_config ())
      | Github.Pull_request _ | Github.Push _ | Github.Issue_comment _ -> event_config ctx event
    in
    match event with
    | Github.Pull_request pr ->
      (match Source.pr_skip_reason ~ctx ~config pr with
      | None -> review_pr ~reaction_target:(Pull_request pr.number) ~ctx ~config pr
      | Some reason ->
        log#info "PR #%d skipped: %s" pr.number reason;
        Lwt.return_unit)
    | Github.Push push ->
      (match Source.push_skip_reason ~ctx ~config push with
      | None -> review_push ~ctx ~config push
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
      match Source.comment_skip_reason ~ctx ~config n with
      | None ->
        log#info "REVIEW comment on PR #%d by %s: triggering review" n.issue.number n.sender.login;
        review_pr_from_comment ~reaction_target:(Issue_comment n.comment.id) ~ctx ~config n
      | Some reason ->
        log#info "REVIEW comment on PR #%d skipped: %s" n.issue.number reason;
        Lwt.return_unit)
    | Github.Unknown kind ->
      log#debug "ignoring unhandled event type: %s" kind;
      Lwt.return_unit
end
