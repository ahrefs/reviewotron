open Devkit

let log = Log.from "github_source"

type prepare_error =
  | Fetch_failed of Http_util.error
  | Empty
  | Too_large of int
  | Too_many_files of int

type prepared_pr_review = {
  number : int;
  job : Review_job.t;
}

type prepared_push_review = {
  job : Review_job.t;
  push : Github_types.commit_pushed_notification;
}

module Make (SRC : Api.Github_review_source) = struct
  let fetch_config ~ctx ~repo_url =
    match%lwt SRC.get_config ~ctx ~repo_url with
    | Ok config ->
      Context.set_config ctx ~repo_key:repo_url config;
      Lwt.return (Ok config)
    | Error e -> Lwt.return (Error e)

  let refresh_repo_config ctx event =
    match event with
    | Github.Unknown _ -> Lwt.return (Ok (Context.default_config ()))
    | Github.Pull_request _ | Github.Push _ | Github.Issue_comment _ ->
      let repo_url = Github.repo_url_of_event event in
      (match Context.find_config ctx ~repo_key:repo_url with
      | None -> fetch_config ~ctx ~repo_url
      | Some config ->
      match event with
      | Github.Push push ->
        let modified_files = List.concat_map (fun (c : Github_types.commit) -> c.added @ c.modified) push.commits in
        let config_modified = List.exists (String.equal (Context.config_filename ctx)) modified_files in
        if config_modified then fetch_config ~ctx ~repo_url else Lwt.return (Ok config)
      | Github.Pull_request _ | Github.Issue_comment _ -> Lwt.return (Ok config)
      | Github.Unknown _ -> Lwt.return (Ok config))

  let is_bot_sender login = CCString.suffix ~suf:"[bot]" login

  let pr_skip_reason ~ctx ~(config : Config_types.config) (pr : Github_types.pr_notification) =
    let state = Context.state ctx in
    let head_sha = pr.pull_request.head.sha in
    let is_ignored_author = List.exists (fun a -> String.equal a pr.sender.login) config.ignored_authors in
    let is_reviewable_action =
      match Github.pr_action_of_string pr.action with
      | Opened | Reopened | Ready_for_review -> config.auto_review_pr_open
      | Synchronize -> config.auto_review_pr_sync
      | Closed | Edited | Other _ -> false
    in
    let is_duplicate = State.is_pr_reviewed state ~repo_url:pr.repository.url ~pr_number:pr.number ~head_sha in
    match () with
    | () when is_bot_sender pr.sender.login -> Some (Printf.sprintf "bot sender %s" pr.sender.login)
    | () when is_ignored_author -> Some (Printf.sprintf "ignored author %s" pr.sender.login)
    | () when not is_reviewable_action -> Some (Printf.sprintf "action %s not reviewable" pr.action)
    | () when pr.pull_request.draft && not config.review_draft_prs -> Some "draft PR"
    | () when is_duplicate ->
      Some (Printf.sprintf "already reviewed at %s" (String.sub head_sha 0 (min 8 (String.length head_sha))))
    | () -> None

  let push_skip_reason ~ctx ~(config : Config_types.config) (push : Github_types.commit_pushed_notification) =
    let state = Context.state ctx in
    let is_develop = String.equal push.ref_ "refs/heads/develop" in
    let is_ignored_author = List.exists (fun a -> String.equal a push.sender.login) config.ignored_authors in
    let is_duplicate = State.is_push_reviewed state ~repo_url:push.repository.url ~after_sha:push.after in
    match () with
    | () when is_bot_sender push.sender.login -> Some (Printf.sprintf "bot sender %s" push.sender.login)
    | () when not config.review_pushes_to_develop -> Some "push reviews disabled"
    | () when not is_develop -> Some (Printf.sprintf "ref %s is not develop" push.ref_)
    | () when push.created -> Some "branch creation"
    | () when push.deleted -> Some "branch deletion"
    | () when is_ignored_author -> Some (Printf.sprintf "ignored author %s" push.sender.login)
    | () when is_duplicate ->
      Some (Printf.sprintf "already reviewed at %s" (String.sub push.after 0 (min 8 (String.length push.after))))
    | () -> None

  let comment_skip_reason ~ctx:(_ : Context.t) ~(config : Config_types.config)
    (n : Github_types.issue_comment_notification) =
    let is_ignored_author = List.exists (fun a -> String.equal a n.sender.login) config.ignored_authors in
    match () with
    | () when not (String.equal n.action "created") -> Some (Printf.sprintf "comment action %s not reviewable" n.action)
    | () when Option.is_none n.issue.pull_request -> Some "comment is on an issue, not a PR"
    | () when not (String.equal n.issue.state "open") -> Some (Printf.sprintf "PR state is %s" n.issue.state)
    | () when not config.auto_review_on_comment -> Some "auto_review_on_comment disabled"
    | () when is_bot_sender n.sender.login -> Some (Printf.sprintf "bot sender %s" n.sender.login)
    | () when is_ignored_author -> Some (Printf.sprintf "ignored author %s" n.sender.login)
    | () -> None

  (* Fetch a file and keep it only if it is safe to feed to the model. Binary or
     oversized blobs (e.g. generated schemas) are dropped: embedding them in the
     prompt would fail JSON serialization or bloat the request. A dropped file
     becomes [Ok None], which both callers already treat as "unavailable", so
     the review proceeds on the diff and the remaining text files. *)
  let fetch_text_file ~ctx ~repo_url ~ref_ ~path =
    match%lwt SRC.get_file_content ~ctx ~repo_url ~path ~ref_ with
    | (Ok None | Error _) as result -> Lwt.return result
    | Ok (Some content) ->
    match Review_job.is_embeddable content with
    | true -> Lwt.return (Ok (Some content))
    | false ->
      log#warn "skipping %s: not embeddable (binary or too large)" path;
      Lwt.return (Ok None)

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
    let paths = CCList.take 5 paths in
    Lwt_list.filter_map_p
      (fun path ->
        let%lwt result = fetch_text_file ~ctx ~repo_url ~path ~ref_ in
        match result with
        | Ok (Some content) -> Lwt.return (Some (path, content))
        | Ok None -> Lwt.return None
        | Error msg ->
          log#warn "failed to fetch %s: %s" path msg;
          Lwt.return None)
      paths

  let fetch_file_at_ref ~ctx ~repo_url ~ref_ ~path = fetch_text_file ~ctx ~repo_url ~ref_ ~path

  let prepare_diff ~config diff_text =
    match Review_engine.prepare_diff ~config diff_text with
    | Ok prepared -> Ok prepared
    | Error `Empty -> Error Empty
    | Error (`Too_large total_lines) -> Error (Too_large total_lines)
    | Error (`Too_many_files file_count) -> Error (Too_many_files file_count)

  let prepare_pr_review_with_trigger ?(trigger = Review_job.Pull_request) ~ctx ~(config : Config_types.config)
    (pr_notif : Github_types.pr_notification) =
    let repo_url = pr_notif.repository.url in
    let number = pr_notif.number in
    let pr = pr_notif.pull_request in
    log#info "reviewing PR #%d in %s" number pr_notif.repository.full_name;
    let%lwt diff_result = SRC.get_pr_diff ~ctx ~repo_url ~number in
    match diff_result with
    | Error fetch_error ->
      log#error "failed to fetch diff for PR #%d: %s" number (Http_util.error_to_string fetch_error);
      Lwt.return (Error (Fetch_failed fetch_error))
    | Ok diff_text ->
    match prepare_diff ~config diff_text with
    | Error Empty ->
      log#info "PR #%d: all files filtered out, nothing to review" number;
      Lwt.return (Error Empty)
    | Error (Too_large total_lines) ->
      log#info "PR #%d skipped: %d diff lines exceeds limit of %d" number total_lines config.max_diff_lines;
      Lwt.return (Error (Too_large total_lines))
    | Error (Too_many_files file_count) ->
      log#info "PR #%d skipped: %d files exceeds limit of %d" number file_count config.max_files;
      Lwt.return (Error (Too_many_files file_count))
    | Error (Fetch_failed _ as e) -> Lwt.return (Error e)
    | Ok (filtered_diff, filtered_text) ->
      let head_sha = pr.head.sha in
      let%lwt file_contents = fetch_key_files ~ctx ~repo_url ~diff:filtered_diff ~ref_:head_sha in
      let description = CCOption.get_or ~default:"" pr.body in
      let fetch_file = fetch_file_at_ref ~ctx ~repo_url ~ref_:head_sha in
      let job =
        Review_job.
          {
            repo_key = repo_url;
            reviewed_root = None;
            change_key = Printf.sprintf "pr/%d/%s" number head_sha;
            change_label = Printf.sprintf "PR #%d" number;
            title = pr.title;
            description;
            head_sha;
            diff_text = filtered_text;
            filtered_diff;
            config;
            file_contents;
            fetch_file;
            trigger;
            source_kind = Github;
          }
      in
      Lwt.return (Ok { number; job })

  let prepare_pr_review_from_comment ~ctx ~(config : Config_types.config) (n : Github_types.issue_comment_notification)
      =
    let repo_url = n.repository.url in
    let%lwt result = SRC.get_pull_request ~ctx ~repo_url ~number:n.issue.number in
    match result with
    | Error msg ->
      log#error "failed to fetch PR #%d for REVIEW comment trigger: %s" n.issue.number msg;
      (* [get_pull_request] surfaces a plain string error with no HTTP status to
         classify, so this is a generic (retryable) fetch failure, never the
         too-large case. *)
      Lwt.return (Error (Fetch_failed (Http_util.Local msg)))
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
      prepare_pr_review_with_trigger ~trigger:Review_job.Manual ~ctx ~config synthesised

  let prepare_pr_review ~ctx ~config pr_notif = prepare_pr_review_with_trigger ~ctx ~config pr_notif

  let prepare_push_review ~ctx ~(config : Config_types.config) (push : Github_types.commit_pushed_notification) =
    let repo_url = push.repository.url in
    log#info "reviewing push to %s in %s" push.ref_ push.repository.full_name;
    let%lwt diff_result = SRC.get_compare_diff ~ctx ~repo_url ~base:push.before ~head:push.after in
    match diff_result with
    | Error fetch_error ->
      log#error "failed to fetch compare diff for push %s...%s: %s" push.before push.after
        (Http_util.error_to_string fetch_error);
      Lwt.return (Error (Fetch_failed fetch_error))
    | Ok diff_text ->
    match prepare_diff ~config diff_text with
    | Error Empty ->
      log#info "push %s skipped: all files ignored" push.after;
      Lwt.return (Error Empty)
    | Error (Too_large total_lines) ->
      log#info "push %s skipped: %d diff lines exceeds limit of %d" push.after total_lines config.max_diff_lines;
      Lwt.return (Error (Too_large total_lines))
    | Error (Too_many_files file_count) ->
      log#info "push %s skipped: %d files exceeds limit of %d" push.after file_count config.max_files;
      Lwt.return (Error (Too_many_files file_count))
    | Error (Fetch_failed _ as e) -> Lwt.return (Error e)
    | Ok (filtered_diff, filtered_text) ->
      let description =
        push.commits
        |> List.map (fun (c : Github_types.commit) -> Printf.sprintf "- %s" c.message)
        |> String.concat "\n"
      in
      let title = Printf.sprintf "Push to %s" push.ref_ in
      let fetch_file = fetch_file_at_ref ~ctx ~repo_url ~ref_:push.after in
      let job =
        Review_job.
          {
            repo_key = repo_url;
            reviewed_root = None;
            change_key = push.after;
            change_label = Printf.sprintf "push %s" (Review_job.short_display_id push.after);
            title;
            description;
            head_sha = push.after;
            diff_text = filtered_text;
            filtered_diff;
            config;
            file_contents = [];
            fetch_file;
            trigger = Push;
            source_kind = Github;
          }
      in
      Lwt.return (Ok { job; push })
end
