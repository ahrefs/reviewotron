open Devkit

let log = Log.from "github_sink"

let github_side_of_review_comment = function
  | Review_comment.Left -> Github_types.Left
  | Review_comment.Right -> Github_types.Right

let review_comment_req_of_comment (comment : Review_comment.t) : Github_types.review_comment_req =
  {
    path = comment.path;
    position = None;
    line = Some comment.line;
    side = Some (github_side_of_review_comment comment.side);
    start_line = comment.start_line;
    start_side = Option.map github_side_of_review_comment comment.start_side;
    body = comment.body;
  }

module Make (SNK : Api.Github_review_sink) = struct
  let publish_pr_review ~ctx ~(job : Review_job.t) ~number (report : Review_engine.report) =
    let comments = List.map review_comment_req_of_comment report.comments in
    let short_sha = if String.length job.head_sha >= 7 then String.sub job.head_sha 0 7 else job.head_sha in
    let body = Printf.sprintf "%s\n\n**Reviewed commit:** `%s`" report.body short_sha in
    let review_req = Github_types.{ commit_id = Some job.head_sha; body; event = Comment; comments } in
    let%lwt post_result = SNK.create_pr_review ~ctx ~repo_url:job.repo_key ~number review_req in
    match post_result with
    | Ok () ->
      log#info "posted review for PR #%d (%s): %d inline comments" number job.title (List.length comments);
      Lwt.return (Ok ())
    | Error msg ->
      log#error "failed to post review for PR #%d: %s" number msg;
      Lwt.return (Error msg)

  (** Post an issue comment explaining why a review could not be produced.
      Returns the post result so the caller can decide whether to record the PR
      as reviewed (only a successfully delivered notice should suppress retries). *)
  let publish_failure_comment ~ctx ~repo_url ~number failure =
    let body = Review_failure.to_comment failure in
    let%lwt result = SNK.create_issue_comment ~ctx ~repo_url ~number { body } in
    match result with
    | Ok () ->
      log#info "posted review-failure comment on PR #%d" number;
      Lwt.return (Ok ())
    | Error msg ->
      log#error "failed to post review-failure comment on PR #%d: %s" number msg;
      Lwt.return (Error msg)

  let publish_success_comment ~ctx ~repo_url ~number =
    let body = "LGTM :+1:" in
    let%lwt result = SNK.create_issue_comment ~ctx ~repo_url ~number { body } in
    match result with
    | Ok () ->
      log#info "posted quiet-success comment on PR #%d" number;
      Lwt.return (Ok ())
    | Error msg ->
      log#error "failed to post quiet-success comment on PR #%d: %s" number msg;
      Lwt.return (Error msg)

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
          let%lwt result = SNK.create_commit_comment ~ctx ~repo_url ~sha comment in
          (match result with
          | Ok () -> ()
          | Error msg -> log#error "failed to post commit comment on %s: %s" sha msg);
          Lwt.return_unit
        | Suggestion | Nitpick | Praise | Other _ -> Lwt.return_unit)
      findings
end
