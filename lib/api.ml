(** Module type signatures for the functor-based API architecture.
    Real implementations live in {!Api_remote}, mock implementations in {!Api_local}. *)

module type Github = sig
  val get_config : ctx:Context.t -> repo_url:string -> (Config_types.config, string) result Lwt.t

  val get_pr_files :
    ctx:Context.t -> repo_url:string -> number:int -> (Github_types_t.pull_request_file list, string) result Lwt.t

  val get_pr_diff : ctx:Context.t -> repo_url:string -> number:int -> (string, string) result Lwt.t

  val get_compare_diff : ctx:Context.t -> repo_url:string -> base:string -> head:string -> (string, string) result Lwt.t

  val get_file_content :
    ctx:Context.t -> repo_url:string -> path:string -> ref_:string -> (string option, string) result Lwt.t

  val create_pr_review :
    ctx:Context.t -> repo_url:string -> number:int -> Github_types_t.create_review_req -> (unit, string) result Lwt.t

  val create_commit_comment :
    ctx:Context.t -> repo_url:string -> sha:string -> Github_types_t.commit_comment_req -> (unit, string) result Lwt.t
end

module type Claude = sig
  val review_code :
    ctx:Context.t ->
    repo_url:string ->
    diff:string ->
    files:(string * string) list ->
    pr_title:string ->
    description:string ->
    (Review_types_t.review_output, string) result Lwt.t
end

module type Slack = sig
  val post_message :
    ctx:Context.t ->
    channel:string ->
    text:string ->
    ?attachments:Slack_types.slack_attachment list ->
    unit ->
    unit Lwt.t
end
