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

type review_command =
  | Current
  | Commit of string

let review_command_whitespace_re = Re2.create_exn {|\s+|}
let review_command_sha_re = Re2.create_exn {|(?i)^[0-9a-f]{7,40}$|}

let parse_review_command body =
  let body = String.trim body in
  let tokens =
    match String.equal body "" with
    | true -> []
    | false -> Re2.split review_command_whitespace_re body
  in
  match tokens with
  | [ "REVIEW" ] -> Some Current
  | [ "REVIEW"; sha ] when Re2.matches review_command_sha_re sha -> Some (Commit sha)
  | _ -> None

let github_event_kind = function
  | Github.Pull_request _ -> "pull_request"
  | Github.Push _ -> "push"
  | Github.Issue_comment _ -> "issue_comment"
  | Github.Pull_request_review _ -> "pull_request_review"
  | Github.Pull_request_review_comment _ -> "pull_request_review_comment"
  | Github.Unknown kind -> kind

let github_event_action = function
  | Github.Pull_request n -> Some n.action
  | Github.Push _ -> None
  | Github.Issue_comment n -> Some n.action
  | Github.Pull_request_review n -> Some n.action
  | Github.Pull_request_review_comment n -> Some n.action
  | Github.Unknown _ -> None

let github_event_attrs event =
  let attrs =
    [
      "github.event.name", `String (github_event_kind event);
      "reviewotron.repo_url", `String (Github.repo_url_of_event event);
    ]
  in
  match github_event_action event with
  | None -> attrs
  | Some action -> ("github.event.action", `String action) :: attrs

let prepare_error_to_string = function
  | Github_source.Fetch_failed error -> Printf.sprintf "fetch_failed: %s" (Http_util.error_to_string error)
  | Github_source.Target_commit_not_in_pr requested -> Printf.sprintf "target_commit_not_in_pr: %s" requested
  | Github_source.Ambiguous_target_commit requested -> Printf.sprintf "ambiguous_target_commit: %s" requested
  | Github_source.Empty -> "no_reviewable_files"
  | Github_source.Too_large total_lines -> Printf.sprintf "too_large: %d lines" total_lines
  | Github_source.Too_many_files file_count -> Printf.sprintf "too_many_files: %d files" file_count

let pr_prepare_error_to_string (error : Github_source.pr_prepare_error) = prepare_error_to_string error.error

(* Structured attributes describing why a review was dropped before it ran, so
   drop rate can be grouped by category and the diff size at rejection can be
   histogrammed — rather than string-parsing [prepare.reason]. [Too_large]
   carries a line count and [Too_many_files] a file count: they are different
   rejection dimensions, so only the relevant size/limit pair is emitted and the
   other is left unset. *)
let prepare_error_attrs ~(config : Config_types.config) = function
  | Github_source.Empty -> [ "reviewotron.prepare.reject_category", `String "no_reviewable_files" ]
  | Github_source.Fetch_failed _ -> [ "reviewotron.prepare.reject_category", `String "fetch_failed" ]
  | Github_source.Target_commit_not_in_pr requested ->
    [
      "reviewotron.prepare.reject_category", `String "target_commit_not_in_pr";
      "reviewotron.prepare.target_commit", `String requested;
    ]
  | Github_source.Ambiguous_target_commit requested ->
    [
      "reviewotron.prepare.reject_category", `String "ambiguous_target_commit";
      "reviewotron.prepare.target_commit", `String requested;
    ]
  | Github_source.Too_large total_lines ->
    [
      "reviewotron.prepare.reject_category", `String "too_large";
      "reviewotron.prepare.diff_lines", `Int total_lines;
      "reviewotron.prepare.limit_lines", `Int config.max_diff_lines;
    ]
  | Github_source.Too_many_files file_count ->
    [
      "reviewotron.prepare.reject_category", `String "too_many_files";
      "reviewotron.prepare.diff_files", `Int file_count;
      "reviewotron.prepare.limit_files", `Int config.max_files;
    ]

let pr_prepare_error_attrs ~config (error : Github_source.pr_prepare_error) = prepare_error_attrs ~config error.error

let target_commit_not_found_message requested =
  Printf.sprintf
    "The commit `%s` was not found in the list of commits returned by GitHub's API for this PR. Please check that the \
     commit SHA is correct and that the commit belongs to this PR. If the PR contains more than 250 commits, GitHub \
     only returns the last 250 through this endpoint, so the requested commit must be among those 250; older commits \
     cannot be fetched here."
    requested

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

  let route_finding ~diff finding = Review_engine.route_finding ~diff finding

  let finding_to_comment ~diff finding =
    Option.map Github_sink.review_comment_req_of_comment (Review_engine.finding_to_review_comment ~diff finding)

  let log_context_prefix = function
    | None -> ""
    | Some context -> context ^ " "

  let pr_notice_log_context ~repo_url ~number = function
    | None -> None
    | Some head_sha ->
      Some (Review_job.log_context_for ~repo_key:repo_url ~change_label:(Printf.sprintf "PR #%d" number) ~head_sha)

  let push_log_context (push : Github_types.commit_pushed_notification) =
    Review_job.log_context_for ~repo_key:push.repository.url
      ~change_label:(Printf.sprintf "push %s" (Review_job.short_display_id push.after))
      ~head_sha:push.after

  (* {2 GitHub emoji reactions}

     The review pipeline drops an "eyes" reaction when work starts and clears it
     when work finishes. All reaction failures are logged and swallowed — a
     missing reaction must never abort or fail a review. *)

  let create_reaction ?log_context ~ctx ~repo_url target ~content =
    match target with
    | Pull_request number -> RX.create_issue_reaction ~ctx ~repo_url ~number ~content ?log_context ()
    | Issue_comment comment_id -> RX.create_issue_comment_reaction ~ctx ~repo_url ~comment_id ~content ?log_context ()

  let start_progress_reaction ?log_context ~ctx ~repo_url = function
    | None -> Lwt.return None
    | Some target ->
      let log_prefix = log_context_prefix log_context in
      let%lwt result = create_reaction ?log_context ~ctx ~repo_url target ~content:"eyes" in
      (match result with
      | Ok reaction_id -> Lwt.return (Some { target; reaction_id })
      | Error msg ->
        log#warn "%sfailed to add review progress reaction: %s" log_prefix msg;
        Lwt.return None)

  let remove_progress_reaction ?log_context ~ctx ~repo_url = function
    | None -> Lwt.return_unit
    | Some { target; reaction_id } ->
      let log_prefix = log_context_prefix log_context in
      let%lwt result =
        match target with
        | Pull_request number -> RX.delete_issue_reaction ~ctx ~repo_url ~number ~reaction_id ?log_context ()
        | Issue_comment comment_id ->
          RX.delete_issue_comment_reaction ~ctx ~repo_url ~comment_id ~reaction_id ?log_context ()
      in
      (match result with
      | Ok () -> Lwt.return_unit
      | Error msg ->
        log#warn "%sfailed to remove review progress reaction %d: %s" log_prefix reaction_id msg;
        Lwt.return_unit)

  let publish_success_comment ~log_context ~head_sha ~ctx ~repo_url ~number =
    Sink.publish_success_comment ~log_context ~head_sha ~ctx ~repo_url ~number

  (** A report is worth posting as a PR review when it surfaces any inline
      comment, any out-of-diff finding section, a security-plugin error, or a
      general-review failure that the author must be told about.  Otherwise the
      review stays quiet — we acknowledge it with an issue comment instead. *)
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
    ||
    match report.status with
    | Review_engine.Success -> false
    | Review_engine.Partial_failure | Review_engine.Failure -> true

  let record_pr_reviewed ~ctx ~repo_url ~number ~head_sha ~review_costs =
    let state = Context.state ctx in
    State.record_pr_review state ~repo_url ~pr_number:number ~head_sha ~review_costs;
    State.save state

  let log_pr_review_identity ~number (job : Review_job.t) =
    log#info
      "PR #%d (%s): review input identity head_sha=%s trigger=%s source=%s diff_sha256=%s config_sha256=%s \
       filtered_files=%d fetched_files=%d diff_bytes=%d"
      number job.title job.head_sha
      (Review_job.trigger_to_string job.trigger)
      (Review_job.source_kind_to_string job.source_kind)
      (Review_job.diff_sha256 job) (Review_job.config_sha256 job) (List.length job.filtered_diff)
      (List.length job.file_contents) (String.length job.diff_text)

  let record_pr_reviewed_if_head_known ~ctx ~repo_url ~number ~head_sha ~review_costs =
    match head_sha with
    | None -> ()
    | Some head_sha -> record_pr_reviewed ~ctx ~repo_url ~number ~head_sha ~review_costs

  let record_pr_notice_if_delivered ~ctx ~repo_url ~number ~head_sha result =
    match result with
    | Ok () -> record_pr_reviewed_if_head_known ~ctx ~repo_url ~number ~head_sha ~review_costs:[]
    | Error _ -> ()

  let record_push_reviewed ~ctx ~repo_url ~after_sha =
    let state = Context.state ctx in
    State.record_push_review state ~repo_url ~after_sha;
    State.save state

  (* Sum the per-plugin estimated costs of a completed review so the run cost is
     queryable as a single span attribute. *)
  let report_cost_usd (report : Review_engine.report) =
    List.fold_left
      (fun acc (c : Cost_tracking.review_cost) -> acc +. c.total_estimated_cost_usd)
      0.0 report.review_costs

  (* Stamp the outcome of a PR review onto the ambient [review.pr.execute] span:
     what (if anything) was posted to GitHub, whether the post succeeded, how
     many inline comments landed, whether the PR was recorded as reviewed, and
     the run cost. [publish_kind]/[publish_outcome] use fixed string enums so
     they can be grouped in trace queries. *)
  let record_pr_outcome ~publish_kind ~publish_outcome ~published ~inline_comments_posted ~recorded_reviewed ~cost_usd
    () =
    Telemetry.add_attrs
      [
        "reviewotron.review.published", `Bool published;
        "reviewotron.review.publish_kind", `String publish_kind;
        "reviewotron.review.publish_outcome", `String publish_outcome;
        "reviewotron.review.inline_comments_posted", `Int inline_comments_posted;
        "reviewotron.review.recorded_reviewed", `Bool recorded_reviewed;
        "reviewotron.review.cost_usd", `Float cost_usd;
      ]

  (* Wrap a single GitHub publish call in a child span so its latency and
     failure are visible and semantically tied to the review submission (rather
     than surfacing only as a generic [reviewotron.http.client] span). *)
  let publish_span ~kind f =
    Telemetry.span
      ~attrs:[ "reviewotron.review.publish_kind", `String kind ]
      "reviewotron.review.publish"
      (fun () ->
        let%lwt result = f () in
        (match result with
        | Ok () -> ()
        | Error msg -> Telemetry.set_error msg);
        Lwt.return result)

  let run_prepared_pr_review ?reaction_target ~ctx (prepared : Github_source.prepared_pr_review) =
    Telemetry.span
      ~attrs:(("github.pull_request.number", `Int prepared.number) :: Review_job.span_attrs prepared.job)
      "reviewotron.review.pr.execute"
      (fun () ->
        let Github_source.{ number; job } = prepared in
        let log_context = Review_job.log_context job in
        let log_prefix = log_context ^ " " in
        log_pr_review_identity ~number job;
        let%lwt progress = start_progress_reaction ~log_context ~ctx ~repo_url:job.repo_key reaction_target in
        (* The review pipeline can raise (network errors, SDK schema drift, etc.).
       Ensure the progress reaction is cleared even when the pipeline crashes —
       otherwise the "eyes" reaction is orphaned and the author has no signal
       that the bot gave up. *)
        try%lwt
          let%lwt report = Engine.run_review ~ctx ~job in
          let%lwt () =
            match report_has_surface report with
            | false ->
              let%lwt () = remove_progress_reaction ~log_context ~ctx ~repo_url:job.repo_key progress in
              let%lwt post_result =
                publish_span ~kind:"no_findings_comment" (fun () ->
                  publish_success_comment ~log_context:(Some log_context) ~head_sha:(Some job.head_sha) ~ctx
                    ~repo_url:job.repo_key ~number)
              in
              (match post_result with
              | Ok () ->
                record_pr_reviewed ~ctx ~repo_url:job.repo_key ~number ~head_sha:job.head_sha
                  ~review_costs:report.review_costs;
                log#info "%sPR #%d (%s): review completed with no findings; not posting a PR review" log_prefix number
                  job.title;
                record_pr_outcome ~publish_kind:"no_findings_comment" ~publish_outcome:"ok" ~published:true
                  ~inline_comments_posted:0 ~recorded_reviewed:true ~cost_usd:(report_cost_usd report) ()
              | Error _ ->
                record_pr_outcome ~publish_kind:"no_findings_comment" ~publish_outcome:"failed" ~published:false
                  ~inline_comments_posted:0 ~recorded_reviewed:false ~cost_usd:(report_cost_usd report) ());
              Lwt.return_unit
            | true ->
              let inline_comments = List.length report.comments in
              let%lwt () = remove_progress_reaction ~log_context ~ctx ~repo_url:job.repo_key progress in
              let%lwt post_result =
                publish_span ~kind:"pr_review" (fun () -> Sink.publish_pr_review ~ctx ~job ~number report)
              in
              (match post_result with
              | Ok () ->
                record_pr_reviewed ~ctx ~repo_url:job.repo_key ~number ~head_sha:job.head_sha
                  ~review_costs:report.review_costs;
                record_pr_outcome ~publish_kind:"pr_review" ~publish_outcome:"ok" ~published:true
                  ~inline_comments_posted:inline_comments ~recorded_reviewed:true ~cost_usd:(report_cost_usd report) ();
                Lwt.return_unit
              | Error msg ->
                let%lwt fallback_result =
                  publish_span ~kind:"failure_comment" (fun () ->
                    Sink.publish_failure_comment ~log_context ~ctx ~repo_url:job.repo_key ~number (Publish_failed msg))
                in
                (match fallback_result with
                | Ok () ->
                  record_pr_reviewed ~ctx ~repo_url:job.repo_key ~number ~head_sha:job.head_sha
                    ~review_costs:report.review_costs;
                  record_pr_outcome ~publish_kind:"failure_comment" ~publish_outcome:"fallback_ok" ~published:true
                    ~inline_comments_posted:0 ~recorded_reviewed:true ~cost_usd:(report_cost_usd report) ()
                | Error _ ->
                  record_pr_outcome ~publish_kind:"failure_comment" ~publish_outcome:"failed" ~published:false
                    ~inline_comments_posted:0 ~recorded_reviewed:false ~cost_usd:(report_cost_usd report) ());
                Lwt.return_unit)
          in
          Lwt.return_unit
        with exn ->
          log#error "%sreview pipeline for PR #%d raised: %s" log_prefix number (Exn.str exn);
          let%lwt () = remove_progress_reaction ~log_context ~ctx ~repo_url:job.repo_key progress in
          Lwt.fail exn)

  (** Surface a PR-preparation non-review outcome to the author instead of
      silently dropping it.  An [Empty] diff gets an explicit skip comment; the
      size/limit and fetch failures get an explanatory issue comment.

      The PR is recorded as reviewed — suppressing retries on the same head SHA
      — only when a terminal notice was actually delivered.  A failed comment
      post, or a transient ([Fetch_failed]) error, leaves the PR un-recorded so
      the next webhook retries. *)
  let handle_pr_prepare_error ~ctx ~repo_url ~number (pr_error : Github_source.pr_prepare_error) =
    let Github_source.{ error; head_sha } = pr_error in
    let log_context = pr_notice_log_context ~repo_url ~number head_sha in
    (* No agents run on the prepare-failure path, so the review cost is zero and
       no inline comments are posted; [publish_kind] records which notice this
       outcome produced. *)
    let record_notice_outcome ~publish_kind post_result recorded_reviewed =
      let published, publish_outcome =
        match post_result with
        | Ok () -> true, "ok"
        | Error _ -> false, "failed"
      in
      record_pr_outcome ~publish_kind ~publish_outcome ~published ~inline_comments_posted:0 ~recorded_reviewed
        ~cost_usd:0.0 ()
    in
    let post_then_record_if_delivered ~publish_kind failure =
      let%lwt post_result =
        publish_span ~kind:publish_kind (fun () ->
          Sink.publish_failure_comment ?log_context ~ctx ~repo_url ~number failure)
      in
      record_pr_notice_if_delivered ~ctx ~repo_url ~number ~head_sha post_result;
      record_notice_outcome ~publish_kind post_result (Result.is_ok post_result);
      Lwt.return_unit
    in
    let post_invalid_target detail =
      let%lwt post_result =
        publish_span ~kind:"invalid_target_comment" (fun () ->
          Sink.publish_failure_comment ~ctx ~repo_url ~number (Invalid_target detail))
      in
      record_notice_outcome ~publish_kind:"invalid_target_comment" post_result false;
      Lwt.return_unit
    in
    match error with
    | Target_commit_not_in_pr requested -> post_invalid_target (target_commit_not_found_message requested)
    | Ambiguous_target_commit requested ->
      post_invalid_target
        (Printf.sprintf "The abbreviated commit `%s` matches multiple commits in this PR; use a longer SHA." requested)
    | Empty ->
      let%lwt post_result =
        publish_span ~kind:"filtered_out_comment" (fun () ->
          Sink.publish_failure_comment ?head_sha ?log_context ~ctx ~repo_url ~number No_reviewable_files)
      in
      record_pr_notice_if_delivered ~ctx ~repo_url ~number ~head_sha post_result;
      record_notice_outcome ~publish_kind:"filtered_out_comment" post_result (Result.is_ok post_result);
      Lwt.return_unit
    | Too_large total_lines ->
      let config = Context.get_config ctx ~repo_key:repo_url in
      post_then_record_if_delivered ~publish_kind:"too_large_comment"
        (Too_many_lines { actual = total_lines; limit = config.max_diff_lines })
    | Too_many_files file_count ->
      let config = Context.get_config ctx ~repo_key:repo_url in
      post_then_record_if_delivered ~publish_kind:"too_many_files_comment"
        (Too_many_files { actual = file_count; limit = config.max_files })
    | Fetch_failed fetch_error ->
      let failure = Review_failure.classify_fetch_error fetch_error in
      let%lwt post_result =
        publish_span ~kind:"fetch_failed_comment" (fun () ->
          Sink.publish_failure_comment ?log_context ~ctx ~repo_url ~number failure)
      in
      (* A remote-too-large diff is a permanent property of this head SHA, so
         record it once the notice lands.  Any other fetch failure may be
         transient — never record it, so the review is retried. *)
      let recorded_reviewed =
        match failure with
        | Diff_too_large_remote _ ->
          record_pr_notice_if_delivered ~ctx ~repo_url ~number ~head_sha post_result;
          Result.is_ok post_result
        | Invalid_target _ | No_reviewable_files | Fetch_failed _ | Too_many_lines _ | Too_many_files _
        | Publish_failed _ ->
          false
      in
      record_notice_outcome ~publish_kind:"fetch_failed_comment" post_result recorded_reviewed;
      Lwt.return_unit

  let prepare_error_reason ~(config : Config_types.config) (error : Github_source.prepare_error) =
    match error with
    | Target_commit_not_in_pr requested -> target_commit_not_found_message requested
    | Ambiguous_target_commit requested ->
      Printf.sprintf "The abbreviated commit `%s` matches multiple commits in this PR; use a longer SHA." requested
    | Empty ->
      "All changed files were excluded by the configured path, file-regex, or generated-file filters; no code was \
       analyzed or approved."
    | Too_large total_lines ->
      Printf.sprintf "The diff is %d lines, which is over reviewotron's limit of %d." total_lines config.max_diff_lines
    | Too_many_files file_count ->
      Printf.sprintf "The diff touches %d files, which is over reviewotron's limit of %d." file_count config.max_files
    | Fetch_failed fetch_error ->
    match Review_failure.classify_fetch_error fetch_error with
    | Diff_too_large_remote detail -> Printf.sprintf "The diff is too large for the GitHub API to serve.\n\n%s" detail
    | Fetch_failed detail -> Printf.sprintf "I couldn't fetch the diff from GitHub.\n\n%s" detail
    | Invalid_target _ | No_reviewable_files | Too_many_lines _ | Too_many_files _ | Publish_failed _ ->
      Http_util.error_to_string fetch_error

  let push_failure_message ~(push : Github_types.commit_pushed_notification) ~findings ~security_error ?reason ?guidance
    () =
    let text = Printf.sprintf ":warning: *Code Review Failed* for push to `develop` by %s" push.pusher.name in
    let failure_text =
      match findings with
      | _ :: _ ->
        "\xE2\x9A\xA0\xEF\xB8\x8F Review partially failed \xE2\x80\x94 the general code review agent encountered an \
         error. Security findings were posted as commit comments."
      | [] ->
        "\xE2\x9A\xA0\xEF\xB8\x8F Review failed \xE2\x80\x94 the code review encountered an error and could not \
         produce results. Check the service logs."
    in
    let failure_text =
      match reason with
      | None -> failure_text
      | Some reason -> Printf.sprintf "%s\n```\n%s\n```" failure_text reason
    in
    let failure_text =
      match guidance with
      | None -> failure_text
      | Some guidance -> Printf.sprintf "%s\n\n%s" failure_text guidance
    in
    let failure_text =
      if security_error then failure_text ^ "\n" ^ String.trim Review_engine.security_error_notice else failure_text
    in
    let attachment =
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
    text, attachment

  let post_push_failure_to_slack ~ctx ~(config : Config_types.config) ~push ~findings ~security_error ?reason () =
    match config.slack_channel with
    | None -> Lwt.return_unit
    | Some channel ->
      let text, attachment = push_failure_message ~push ~findings ~security_error ?reason () in
      SL.post_message ~ctx ~channel ~text ~attachments:[ attachment ] ()

  let push_skip_message ~(push : Github_types.commit_pushed_notification) ~reason () =
    let text =
      Printf.sprintf ":information_source: *Code Review Skipped* for push to `develop` by %s" push.pusher.name
    in
    let attachment =
      Slack_types.
        {
          color = "#6c757d";
          title = Printf.sprintf "Push by %s — %d commits" push.pusher.name (List.length push.commits);
          title_link = push.compare;
          text = reason;
          fields = [];
          footer = Some "reviewotron";
        }
    in
    text, attachment

  let post_push_skip_to_slack ~ctx ~(config : Config_types.config) ~push ~reason () =
    match config.slack_channel with
    | None -> Lwt.return_unit
    | Some channel ->
      let text, attachment = push_skip_message ~push ~reason () in
      SL.post_message ~ctx ~channel ~text ~attachments:[ attachment ] ()

  let handle_push_prepare_error ~ctx ~(config : Config_types.config) (push : Github_types.commit_pushed_notification)
    (error : Github_source.prepare_error) =
    let log_context = push_log_context push in
    let log_prefix = log_context ^ " " in
    let record_terminal () =
      record_push_reviewed ~ctx ~repo_url:push.repository.url ~after_sha:push.after;
      Lwt.return_unit
    in
    let post_terminal_failure ?reason () =
      let%lwt () = post_push_failure_to_slack ~ctx ~config ~push ~findings:[] ~security_error:false ?reason () in
      record_terminal ()
    in
    match error with
    | Target_commit_not_in_pr _ | Ambiguous_target_commit _ ->
      (* Targeted-commit resolution only runs on the PR comment path, which
         supplies [?commit]; the push path never does, so these variants cannot
         reach here. *)
      invalid_arg "handle_push_prepare_error: targeted-commit error on push path"
    | Empty ->
      let reason = prepare_error_reason ~config error in
      log#info "%spush %s skipped: %s" log_prefix push.after reason;
      let%lwt () = post_push_skip_to_slack ~ctx ~config ~push ~reason () in
      record_terminal ()
    | Too_large _ | Too_many_files _ ->
      let reason = prepare_error_reason ~config error in
      post_terminal_failure ~reason ()
    | Fetch_failed fetch_error ->
    match Review_failure.classify_fetch_error fetch_error with
    | Diff_too_large_remote _ ->
      let reason = prepare_error_reason ~config error in
      post_terminal_failure ~reason ()
    | Invalid_target _ | No_reviewable_files | Fetch_failed _ | Too_many_lines _ | Too_many_files _ | Publish_failed _
      ->
      let reason = prepare_error_reason ~config error in
      post_push_failure_to_slack ~ctx ~config ~push ~findings:[] ~security_error:false ~reason ()

  let prepare_span ~name ~attrs ~error_to_string ?(error_attrs = fun _ -> []) f =
    Telemetry.span ~attrs name (fun () ->
      let%lwt result = f () in
      (match result with
      | Ok _ -> Telemetry.add_attrs [ "reviewotron.prepare.outcome", `String "ok" ]
      | Error error ->
        Telemetry.add_attrs
          (("reviewotron.prepare.outcome", `String "not_prepared")
          :: ("reviewotron.prepare.reason", `String (error_to_string error))
          :: error_attrs error));
      Lwt.return result)

  let review_pr ?reaction_target ~ctx ~config (pr_notif : Github_types.pr_notification) =
    Telemetry.span
      ~attrs:
        [
          "reviewotron.repo_url", `String pr_notif.repository.url;
          "github.pull_request.number", `Int pr_notif.number;
          "github.event.action", `String pr_notif.action;
        ]
      "reviewotron.review.pr"
      (fun () ->
        match%lwt
          prepare_span ~name:"reviewotron.review.pr.prepare"
            ~attrs:
              [
                "reviewotron.repo_url", `String pr_notif.repository.url;
                "github.pull_request.number", `Int pr_notif.number;
              ]
            ~error_to_string:pr_prepare_error_to_string ~error_attrs:(pr_prepare_error_attrs ~config)
            (fun () -> Source.prepare_pr_review ~ctx ~config pr_notif)
        with
        | Ok prepared -> run_prepared_pr_review ?reaction_target ~ctx prepared
        | Error error -> handle_pr_prepare_error ~ctx ~repo_url:pr_notif.repository.url ~number:pr_notif.number error)

  let review_pr_from_comment ?reaction_target ?commit ~ctx ~config (n : Github_types.issue_comment_notification) =
    Telemetry.span
      ~attrs:
        [
          "reviewotron.repo_url", `String n.repository.url;
          "github.pull_request.number", `Int n.issue.number;
          "github.comment.id", `Int n.comment.id;
        ]
      "reviewotron.review.comment"
      (fun () ->
        match%lwt
          prepare_span ~name:"reviewotron.review.comment.prepare"
            ~attrs:
              [
                "reviewotron.repo_url", `String n.repository.url;
                "github.pull_request.number", `Int n.issue.number;
                "github.comment.id", `Int n.comment.id;
              ]
            ~error_to_string:pr_prepare_error_to_string ~error_attrs:(pr_prepare_error_attrs ~config)
            (fun () -> Source.prepare_pr_review_from_comment ?commit ~ctx ~config n)
        with
        | Ok prepared -> run_prepared_pr_review ?reaction_target ~ctx prepared
        | Error error -> handle_pr_prepare_error ~ctx ~repo_url:n.repository.url ~number:n.issue.number error)

  let review_push ~ctx ~config (push : Github_types.commit_pushed_notification) =
    Telemetry.span
      ~attrs:
        [
          "reviewotron.repo_url", `String push.repository.url;
          "github.ref", `String push.ref_;
          "github.commit.after", `String push.after;
          "github.push.commits", `Int (List.length push.commits);
        ]
      "reviewotron.review.push"
      (fun () ->
        match%lwt
          prepare_span ~name:"reviewotron.review.push.prepare"
            ~attrs:
              [
                "reviewotron.repo_url", `String push.repository.url;
                "github.ref", `String push.ref_;
                "github.commit.after", `String push.after;
              ]
            ~error_to_string:prepare_error_to_string
            (fun () -> Source.prepare_push_review ~ctx ~config push)
        with
        | Error error -> handle_push_prepare_error ~ctx ~config push error
        | Ok prepared ->
          let Github_source.{ job; push } = prepared in
          Telemetry.span ~attrs:(Review_job.span_attrs job) "reviewotron.review.push.execute" (fun () ->
            let log_context = Review_job.log_context job in
            let log_prefix = log_context ^ " " in
            let debug_dir = Engine.debug_dir_for_job ~ctx job in
            let%lwt plugin_result = Engine.run_plugins ~ctx ~job ~debug_dir in
            let Review_engine.{ general_output; findings; review_costs; security_error; _ } = plugin_result in
            Cost_tracking.log_review_costs ~log_context review_costs;
            let%lwt () = Sink.post_push_comments ~log_context ~ctx ~repo_url:job.repo_key ~sha:job.head_sha findings in
            let security_note = String.trim Review_engine.security_error_notice in
            let failure_attachment ?guidance reason =
              log#error "%sreview failed for push %s: no review output produced" log_prefix push.after;
              push_failure_message ~push ~findings ~security_error ?reason ?guidance ()
            in
            let slack_text, attachment =
              match general_output with
              | Some (General_review_plugin.Completed review) ->
                let text = Printf.sprintf ":robot_face: *Code Review* for push to `develop` by %s" push.pusher.name in
                let att =
                  Review_format.format_slack_attachment ~compare_url:push.compare ~pusher_name:push.pusher.name
                    ~num_commits:(List.length push.commits) ~review
                in
                let att =
                  if security_error then Slack_types.{ att with text = att.text ^ "\n" ^ security_note } else att
                in
                text, att
              | Some (General_review_plugin.Validation_failed { candidates_withheld; reason = provider_reason; _ }) ->
                let reason =
                  Printf.sprintf "general-validator failed; withheld %d unvalidated candidate finding(s): %s"
                    candidates_withheld provider_reason
                in
                failure_attachment ~guidance:(Review_engine.retry_guidance provider_reason) (Some reason)
              | Some (General_review_plugin.Failed reason) ->
                failure_attachment ?guidance:(Review_engine.retry_guidance_for_403 reason) (Some reason)
              | None -> failure_attachment None
            in
            let%lwt () =
              match job.config.slack_channel with
              | None -> Lwt.return_unit
              | Some channel -> SL.post_message ~ctx ~channel ~text:slack_text ~attachments:[ attachment ] ()
            in
            record_push_reviewed ~ctx ~repo_url:job.repo_key ~after_sha:job.head_sha;
            Lwt.return_unit))

  let event_config ctx event =
    let repo_key = Github.repo_url_of_event event in
    match%lwt Source.refresh_repo_config ctx event with
    | Ok config -> Lwt.return config
    | Error msg ->
      log#warn "failed to refresh repo config: %s" msg;
      Lwt.return (Context.get_config ctx ~repo_key)

  let handle_feedback_webhook_event ctx ~event =
    match Context.feedback_store ctx with
    | None -> Lwt.return_unit
    | Some store ->
      Lwt.catch
        (fun () -> Feedback_store.handle_webhook_event store ~event ~received_at:(Ptime_clock.now ()))
        (fun exn ->
          log#error "feedback webhook update failed: %s" (Exn.str exn);
          Lwt.return_unit)

  let process_event ctx ~event =
    Telemetry.span ~attrs:(github_event_attrs event) "reviewotron.github.event" (fun () ->
      let%lwt () = handle_feedback_webhook_event ctx ~event in
      let%lwt config =
        match event with
        | Github.Unknown _ -> Lwt.return (Context.default_config ())
        | Github.Pull_request _ | Github.Push _ | Github.Issue_comment _ | Github.Pull_request_review _
        | Github.Pull_request_review_comment _ ->
          event_config ctx event
      in
      match event with
      | Github.Pull_request pr ->
        (match Source.pr_skip_reason ~ctx ~config pr with
        | None ->
          Telemetry.add_attrs [ "reviewotron.event.outcome", `String "review_started" ];
          review_pr ~reaction_target:(Pull_request pr.number) ~ctx ~config pr
        | Some reason ->
          Telemetry.add_attrs
            [ "reviewotron.event.outcome", `String "skipped"; "reviewotron.skip.reason", `String reason ];
          log#info "PR #%d skipped: %s" pr.number reason;
          Lwt.return_unit)
      | Github.Push push ->
        (match Source.push_skip_reason ~ctx ~config push with
        | None ->
          Telemetry.add_attrs [ "reviewotron.event.outcome", `String "review_started" ];
          review_push ~ctx ~config push
        | Some reason ->
          Telemetry.add_attrs
            [ "reviewotron.event.outcome", `String "skipped"; "reviewotron.skip.reason", `String reason ];
          log#info "push %s skipped: %s" push.after reason;
          Lwt.return_unit)
      | Github.Issue_comment n ->
        (* Skip silently for ordinary comments — most PR comments are
           conversation, and we don't want to log a reason for every one. *)
        (match parse_review_command n.comment.body with
        | None ->
          Telemetry.add_attrs [ "reviewotron.event.outcome", `String "ignored" ];
          Lwt.return_unit
        | Some command ->
          let commit =
            match command with
            | Current -> None
            | Commit sha -> Some sha
          in
          (match Source.comment_skip_reason ~ctx ~config n with
          | None ->
            Telemetry.add_attrs [ "reviewotron.event.outcome", `String "review_started" ];
            log#info "REVIEW comment on PR #%d by %s: triggering review" n.issue.number n.sender.login;
            review_pr_from_comment ~reaction_target:(Issue_comment n.comment.id) ?commit ~ctx ~config n
          | Some reason ->
            Telemetry.add_attrs
              [ "reviewotron.event.outcome", `String "skipped"; "reviewotron.skip.reason", `String reason ];
            log#info "REVIEW comment on PR #%d skipped: %s" n.issue.number reason;
            Lwt.return_unit))
      | Github.Unknown kind ->
        Telemetry.add_attrs [ "reviewotron.event.outcome", `String "ignored" ];
        log#debug "ignoring unhandled event type: %s" kind;
        Lwt.return_unit
      | Github.Pull_request_review _ | Github.Pull_request_review_comment _ ->
        Telemetry.add_attrs [ "reviewotron.event.outcome", `String "ignored" ];
        Lwt.return_unit)
end
