open Devkit

let log = Log.from "reviewer"

(** Origin of a finding, kept here as a compatibility alias for existing
    callers. The implementation lives in {!Review_engine}. *)
type finding_source = Review_engine.finding_source =
  | From_general
  | From_security

let deduplicate_findings = Review_engine.deduplicate_findings

module Make (SRC : Api.Review_source) (SNK : Api.Review_sink) (AI : Api.Agent_runner) (SL : Api.Slack) = struct
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

  let run_prepared_pr_review ~ctx (prepared : Github_source.prepared_pr_review) =
    let Github_source.{ number; job; filtered_diff } = prepared in
    let%lwt report = Engine.run_pr_review ~ctx ~job ~number ~filtered_diff in
    let%lwt () = Sink.publish_pr_review ~ctx ~job ~number report in
    let state = Context.state ctx in
    State.record_pr_review state ~repo_url:job.repo_key ~pr_number:number ~head_sha:job.head_sha
      ~review_costs:report.review_costs;
    State.save state;
    Lwt.return_unit

  let ignore_prepare_error (_ : Github_source.prepare_error) = Lwt.return_unit

  let review_pr ~ctx ~config (pr_notif : Github_types.pr_notification) =
    match%lwt Source.prepare_pr_review ~ctx ~config pr_notif with
    | Ok prepared -> run_prepared_pr_review ~ctx prepared
    | Error error -> ignore_prepare_error error

  let review_pr_from_comment ~ctx ~config (n : Github_types.issue_comment_notification) =
    match%lwt Source.prepare_pr_review_from_comment ~ctx ~config n with
    | Ok prepared -> run_prepared_pr_review ~ctx prepared
    | Error error -> ignore_prepare_error error

  let review_push ~ctx ~config (push : Github_types.commit_pushed_notification) =
    match%lwt Source.prepare_push_review ~ctx ~config push with
    | Error error -> ignore_prepare_error error
    | Ok prepared ->
      let Github_source.{ job; filtered_diff; push } = prepared in
      let debug_dir =
        let slug = Security_memory.repo_slug job.repo_key in
        let sha_prefix = String.sub job.head_sha 0 (min 8 (String.length job.head_sha)) in
        Printf.sprintf "debug/%s/%s" slug sha_prefix
      in
      let%lwt plugin_result = Engine.run_plugins ~ctx ~job ~number:0 ~diff:filtered_diff ~debug_dir in
      let Review_engine.{ general_result; findings; review_costs; security_error } = plugin_result in
      Cost_tracking.log_review_costs review_costs;
      let%lwt () = Sink.post_push_comments ~ctx ~repo_url:job.repo_key ~sha:job.head_sha findings in
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
              "\xE2\x9A\xA0\xEF\xB8\x8F Review partially failed \xE2\x80\x94 the general code review agent encountered \
               an error. Security findings were posted as commit comments."
            | [] ->
              "\xE2\x9A\xA0\xEF\xB8\x8F Review failed \xE2\x80\x94 the code review encountered an error and could not \
               produce results. Check the service logs."
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
      | None -> review_pr ~ctx ~config pr
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
        review_pr_from_comment ~ctx ~config n
      | Some reason ->
        log#info "REVIEW comment on PR #%d skipped: %s" n.issue.number reason;
        Lwt.return_unit)
    | Github.Unknown kind ->
      log#debug "ignoring unhandled event type: %s" kind;
      Lwt.return_unit
end
