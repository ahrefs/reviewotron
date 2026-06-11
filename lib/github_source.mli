(** GitHub source/controller adapter.

    This module turns GitHub webhook payloads into normalized {!Review_job.t}
    values and owns GitHub-specific review policy such as action gating,
    ignored authors, duplicate checks, and config refresh. *)

type prepare_error =
  | Fetch_failed of Http_util.error
    (** The diff could not be fetched from GitHub.  Carries the typed HTTP error
        so the caller can distinguish a too-large diff (HTTP 406) from a
        transient failure and surface the right explanation. *)
  | Empty  (** Nothing to review after filtering — a successful no-op, not a failure. *)
  | Too_large of int  (** The filtered diff exceeds [Config_types.max_diff_lines]. *)
  | Too_many_files of int  (** The filtered diff touches more files than [Config_types.max_files]. *)

type prepared_pr_review = {
  number : int;
  job : Review_job.t;
}

type prepared_push_review = {
  job : Review_job.t;
  push : Github_types.commit_pushed_notification;
}

module Make (_ : Api.Github_review_source) : sig
  (** Fetch config if missing, or refresh it when a push modifies the config
      file. Returns the config captured for this event. *)
  val refresh_repo_config : Context.t -> Github.event -> (Config_types.config, string) result Lwt.t

  (** Return [None] when a PR should be reviewed, or [Some reason] when it
      should be skipped. *)
  val pr_skip_reason : ctx:Context.t -> config:Config_types.config -> Github_types.pr_notification -> string option

  (** Return [None] when a push should be reviewed, or [Some reason] when it
      should be skipped. *)
  val push_skip_reason :
    ctx:Context.t -> config:Config_types.config -> Github_types.commit_pushed_notification -> string option

  (** Return [None] when a REVIEW issue-comment should run, or [Some reason]
      when it should be skipped. The exact trigger phrase check remains at the
      dispatch site. *)
  val comment_skip_reason :
    ctx:Context.t -> config:Config_types.config -> Github_types.issue_comment_notification -> string option

  (** Build a normalized PR review job from a pull_request webhook. *)
  val prepare_pr_review :
    ctx:Context.t ->
    config:Config_types.config ->
    Github_types.pr_notification ->
    (prepared_pr_review, prepare_error) result Lwt.t

  (** Fetch the full PR referenced by an issue_comment webhook and build a
      normalized manual-review job. *)
  val prepare_pr_review_from_comment :
    ctx:Context.t ->
    config:Config_types.config ->
    Github_types.issue_comment_notification ->
    (prepared_pr_review, prepare_error) result Lwt.t

  (** Build a normalized push review job from a push webhook. *)
  val prepare_push_review :
    ctx:Context.t ->
    config:Config_types.config ->
    Github_types.commit_pushed_notification ->
    (prepared_push_review, prepare_error) result Lwt.t
end
