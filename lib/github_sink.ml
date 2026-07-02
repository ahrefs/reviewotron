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

let process_nonce = lazy (Printf.sprintf "%d:%f:%d" (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ()))

let nonce_counter = ref 0

let next_nonce () =
  incr nonce_counter;
  Printf.sprintf "%s:%d" (Lazy.force process_nonce) !nonce_counter

let with_reviewed_commit ~head_sha body =
  Printf.sprintf "%s\n\n**Reviewed commit:** `%s`" body (Review_job.short_display_id head_sha)

let with_feedback_marker ~feedback_id (comment : Review_comment.t) =
  { comment with body = Feedback_store.append_marker ~feedback_id comment.body }

let prepare_feedback_targets ~repo_url ~number ~head_sha ~created_at ~evidence_root report =
  let review_batch_id =
    Feedback_store.make_review_batch_id ~repo_url ~pr_number:number ~head_sha ~now:created_at ~nonce:(next_nonce ())
  in
  let evidence_dir = Feedback_evidence.bundle_dir ~evidence_root ~review_batch_id in
  let marked =
    report.Review_engine.inline_findings
    |> List.mapi (fun index (inline : Review_engine.inline_finding) ->
      let comment = inline.comment in
      let finding = inline.sourced.finding in
      let feedback_id =
        Feedback_store.make_feedback_id ~review_batch_id ~index ~path:comment.path ~line:comment.line
          ~comment_body:comment.body
      in
      let marked_comment = with_feedback_marker ~feedback_id comment in
      let finding_json = Review_types.finding_to_json finding in
      let finding_id =
        Feedback_store.make_finding_id ~review_batch_id ~index ~path:comment.path ~line:comment.line ~finding_json
          ~comment_body:marked_comment.body
      in
      let finding_source = Review_engine.finding_source_to_string inline.sourced.source in
      let plugin_name = inline.sourced.plugin_name in
      let input : Feedback_store.target_input =
        {
          feedback_id;
          comment = marked_comment;
          finding;
          comment_body = marked_comment.body;
          evidence_dir = Some evidence_dir;
          finding_id = Some finding_id;
          finding_source = Some finding_source;
          plugin_name = Some plugin_name;
        }
      in
      let evidence_comment : Feedback_evidence.posted_comment =
        {
          feedback_id;
          finding_id;
          finding_source;
          plugin_name;
          comment = marked_comment;
          finding;
          comment_body = marked_comment.body;
        }
      in
      marked_comment, input, evidence_comment)
  in
  let comments = List.map (fun (comment, _input, _evidence_comment) -> comment) marked in
  let inputs = List.map (fun (_comment, input, _evidence_comment) -> input) marked in
  let evidence_comments = List.map (fun (_comment, _input, evidence_comment) -> evidence_comment) marked in
  review_batch_id, evidence_dir, comments, inputs, evidence_comments

module Make (SNK : Api.Github_review_sink) = struct
  let write_feedback_evidence ~evidence_root ~review_batch_id ~created_at ~repo_url ~number ~head_sha ~review_id
    ~review_body ~job ~report ~posted_comments =
    Lwt.catch
      (fun () ->
        let dir =
          Feedback_evidence.write_bundle ~evidence_root ~review_batch_id ~created_at ~repo_url ~pr_number:number
            ~head_sha ~review_id ~review_body ~job ~report ~posted_comments
        in
        log#info "wrote feedback evidence for PR #%d review_batch_id=%s dir=%s" number review_batch_id dir;
        Lwt.return_unit)
      (fun exn ->
        log#error "failed to write feedback evidence for PR #%d: %s" number (Exn.str exn);
        Lwt.return_unit)

  let record_feedback_targets store ~repo_url ~number ~head_sha ~review_id ~review_batch_id ~created_at inputs =
    Lwt.catch
      (fun () ->
        let%lwt () =
          Feedback_store.record_posted_pr_review_targets store ~repo_url ~pr_number:number ~head_sha ~review_id
            ~review_batch_id ~created_at inputs
        in
        log#info "recorded %d feedback targets for PR #%d review_batch_id=%s" (List.length inputs) number
          review_batch_id;
        Lwt.return_unit)
      (fun exn ->
        log#error "failed to record feedback targets for PR #%d: %s" number (Exn.str exn);
        Lwt.return_unit)

  let publish_pr_review ~ctx ~(job : Review_job.t) ~number (report : Review_engine.report) =
    let feedback_store = Context.feedback_store ctx in
    let created_at = Ptime_clock.now () in
    let feedback_plan =
      match feedback_store, report.inline_findings with
      | Some store, _ :: _ ->
        let paths = Feedback_store.paths store in
        let review_batch_id, evidence_dir, comments, inputs, evidence_comments =
          prepare_feedback_targets ~repo_url:job.repo_key ~number ~head_sha:job.head_sha ~created_at
            ~evidence_root:paths.evidence_root report
        in
        Some (store, paths.evidence_root, review_batch_id, evidence_dir, comments, inputs, evidence_comments)
      | Some _, [] | None, _ -> None
    in
    let review_comments =
      match feedback_plan with
      | Some (_store, _evidence_root, _review_batch_id, _evidence_dir, comments, _inputs, _evidence_comments) ->
        comments
      | None -> report.comments
    in
    let comments = List.map review_comment_req_of_comment review_comments in
    let body = with_reviewed_commit ~head_sha:job.head_sha report.body in
    let review_req = Github_types.{ commit_id = Some job.head_sha; body; event = Comment; comments } in
    let%lwt post_result = SNK.create_pr_review ~ctx ~repo_url:job.repo_key ~number review_req in
    match post_result with
    | Ok created_review ->
      let%lwt () =
        match feedback_plan with
        | Some (store, evidence_root, review_batch_id, _evidence_dir, _comments, inputs, evidence_comments) ->
          let%lwt () =
            write_feedback_evidence ~evidence_root ~review_batch_id ~created_at ~repo_url:job.repo_key ~number
              ~head_sha:job.head_sha ~review_id:created_review.id ~review_body:body ~job ~report
              ~posted_comments:evidence_comments
          in
          record_feedback_targets store ~repo_url:job.repo_key ~number ~head_sha:job.head_sha
            ~review_id:created_review.id ~review_batch_id ~created_at inputs
        | None -> Lwt.return_unit
      in
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

  let publish_success_comment ~head_sha ~ctx ~repo_url ~number =
    let body =
      match head_sha with
      | None -> "LGTM :+1:"
      | Some head_sha -> with_reviewed_commit ~head_sha "LGTM :+1:"
    in
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
