(** GitHub sink adapter.

    Converts neutral review output into GitHub API payloads and performs the
    GitHub write operations with the existing retry behavior. *)

(** Convert a neutral inline comment to GitHub's PR review comment request. *)
val review_comment_req_of_comment : Review_comment.t -> Github_types.review_comment_req

module Make (_ : Api.Github_review_sink) : sig
  (** Publish a PR-style report as a GitHub pull request review. Errors are
      logged and swallowed to preserve the historical reviewer behavior. *)
  val publish_pr_review : ctx:Context.t -> job:Review_job.t -> number:int -> Review_engine.report -> unit Lwt.t

  (** Post commit comments for critical/warning findings from a push review.
      Lower-severity findings are intentionally ignored. *)
  val post_push_comments : ctx:Context.t -> repo_url:string -> sha:string -> Review_types.finding list -> unit Lwt.t
end
