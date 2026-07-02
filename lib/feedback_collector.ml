open Devkit

let log = Log.from "feedback_collector"

let is_not_found_error msg = CCString.find ~sub:"http 404" (String.lowercase_ascii msg) >= 0

module Make (FB : Api.Github_feedback) = struct
  let marker_matches (target : Feedback_store.target) (comment : Github_types.pr_review_comment) =
    match Feedback_store.extract_marker comment.Github_types.body with
    | Some feedback_id -> String.equal feedback_id target.Feedback_store.feedback_id
    | None -> false

  let resolve_comment_id ~ctx ~store ~now target =
    match target.Feedback_store.comment_id with
    | Some comment_id -> Lwt.return (Some comment_id)
    | None ->
      let%lwt result =
        FB.list_pr_review_comments ~ctx ~repo_url:target.repo_url ~number:target.pr_number ~review_id:target.review_id
      in
      (match result with
      | Ok comments ->
        (match List.find_opt (marker_matches target) comments with
        | Some comment ->
          log#info "feedback collection: resolved target %s to review comment %d" target.feedback_id comment.id;
          let%lwt () =
            Feedback_store.resolve_comment_id store ~now ~feedback_id:target.feedback_id ~comment_id:comment.id
          in
          Lwt.return (Some comment.id)
        | None ->
          log#warn "feedback target %s was not found among review %d comments" target.feedback_id target.review_id;
          let%lwt () = Feedback_store.mark_missing store ~now ~feedback_id:target.feedback_id in
          Lwt.return None)
      | Error msg ->
      match is_not_found_error msg with
      | true ->
        log#warn "feedback target %s review comments returned not found" target.feedback_id;
        let%lwt () = Feedback_store.mark_missing store ~now ~feedback_id:target.feedback_id in
        Lwt.return None
      | false ->
        log#warn "failed to resolve feedback target %s comment_id: %s" target.feedback_id msg;
        Lwt.return None)

  let collect_inline_target ~ctx ~store ~now (target : Feedback_store.target) =
    Lwt.catch
      (fun () ->
        let%lwt comment_id = resolve_comment_id ~ctx ~store ~now target in
        match comment_id with
        | None -> Lwt.return_unit
        | Some comment_id ->
          let%lwt result = FB.list_pr_review_comment_reactions ~ctx ~repo_url:target.repo_url ~comment_id in
          (match result with
          | Ok reactions ->
            let counts = Feedback_store.counts_of_reactions reactions in
            log#info "feedback collection: target %s comment %d counts +1=%d -1=%d" target.feedback_id comment_id
              counts.plus_one counts.minus_one;
            Feedback_store.update_after_poll store ~now ~feedback_id:target.feedback_id ~counts
          | Error msg ->
          match is_not_found_error msg with
          | true ->
            log#warn "feedback target %s comment %d returned not found" target.feedback_id comment_id;
            Feedback_store.mark_missing store ~now ~feedback_id:target.feedback_id
          | false ->
            log#warn "failed to collect reactions for feedback target %s comment %d: %s" target.feedback_id comment_id
              msg;
            Lwt.return_unit))
      (fun exn ->
        log#error "feedback target %s collection raised: %s" target.feedback_id (Exn.str exn);
        Lwt.return_unit)

  let collect_body_target ~ctx ~store ~now (target : Feedback_store.target) =
    Lwt.catch
      (fun () ->
        match target.Feedback_store.review_node_id with
        | None ->
          log#warn "feedback body target %s is missing review_node_id" target.feedback_id;
          Feedback_store.mark_missing store ~now ~feedback_id:target.feedback_id
        | Some review_node_id ->
          let%lwt result = FB.get_pr_review_reaction_counts ~ctx ~repo_url:target.repo_url ~review_node_id in
          (match result with
          | Ok (Some counts) ->
            let counts = Feedback_store.counts_of_github_counts counts in
            log#info "feedback collection: body target %s review_node_id=%s counts +1=%d -1=%d" target.feedback_id
              review_node_id counts.plus_one counts.minus_one;
            Feedback_store.update_after_poll store ~now ~feedback_id:target.feedback_id ~counts
          | Ok None ->
            log#warn "feedback body target %s review_node_id=%s returned no GraphQL node" target.feedback_id
              review_node_id;
            Feedback_store.mark_missing store ~now ~feedback_id:target.feedback_id
          | Error msg ->
            log#warn "failed to collect review body reactions for feedback target %s review_node_id=%s: %s"
              target.feedback_id review_node_id msg;
            Lwt.return_unit))
      (fun exn ->
        log#error "feedback body target %s collection raised: %s" target.feedback_id (Exn.str exn);
        Lwt.return_unit)

  let collect_target ~ctx ~store ~now (target : Feedback_store.target) =
    match target.Feedback_store.target_kind with
    | Feedback_store.Pr_review_comment -> collect_inline_target ~ctx ~store ~now target
    | Feedback_store.Pr_review_body -> collect_body_target ~ctx ~store ~now target

  let collect ?poll_interval_seconds ~ctx ~store ~now () =
    let%lwt targets = Feedback_store.pollable_targets ?poll_interval_seconds store ~now in
    let tracked_count = List.length (Feedback_store.data store).targets in
    log#info "feedback collection: %d due targets (%d tracked)" (List.length targets) tracked_count;
    Lwt_list.iter_s (collect_target ~ctx ~store ~now) targets
end
