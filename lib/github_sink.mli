(** GitHub sink adapter.

    Converts neutral review output into GitHub API payloads and performs the
    GitHub write operations through the supplied sink implementation. *)

(** Convert a neutral inline comment to GitHub's PR review comment request. *)
val review_comment_req_of_comment : Review_comment.t -> Github_types.review_comment_req

module Make (_ : Api.Github_review_sink) : sig
  (** Publish a PR-style report as a GitHub pull request review. Errors are
      logged and swallowed to preserve the historical reviewer behavior. *)
  val publish_pr_review : ctx:Context.t -> job:Review_job.t -> number:int -> Review_engine.report -> unit Lwt.t

  (** Post an issue comment to a PR explaining why a review could not be
      produced (diff fetch failure or size/file limit exceeded). Returns the
      post result so the caller can record the PR as reviewed only when the
      notice was actually delivered. *)
  val publish_failure_comment :
    ctx:Context.t -> repo_url:string -> number:int -> Review_failure.t -> (unit, string) result Lwt.t

  (** Post commit comments for critical/warning findings from a push review.
      Lower-severity findings are intentionally ignored. *)
  val post_push_comments : ctx:Context.t -> repo_url:string -> sha:string -> Review_types.finding list -> unit Lwt.t
end
