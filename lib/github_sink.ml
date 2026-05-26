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

module Make (SNK : Api.Review_sink) = struct
  let retry_once ~label f =
    match%lwt f () with
    | Ok () as ok -> Lwt.return ok
    | Error msg ->
      log#warn "%s failed (will retry once): %s" label msg;
      let%lwt () = Lwt_unix.sleep 1.0 in
      f ()

  let publish_pr_review ~ctx ~(job : Review_job.t) ~number (report : Review_engine.report) =
    let comments = List.map review_comment_req_of_comment report.comments in
    let review_req = Github_types.{ commit_id = Some job.head_sha; body = report.body; event = Comment; comments } in
    let%lwt post_result =
      retry_once ~label:(Printf.sprintf "create_pr_review PR #%d" number) (fun () ->
        SNK.create_pr_review ~ctx ~repo_url:job.repo_key ~number review_req)
    in
    (match post_result with
    | Ok () -> log#info "posted review for PR #%d (%s): %d inline comments" number job.title (List.length comments)
    | Error msg -> log#error "failed to post review for PR #%d after retry: %s" number msg);
    Lwt.return_unit

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
        | Suggestion | Nitpick | Praise | Other _ -> Lwt.return_unit)
      findings
end
