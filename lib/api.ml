(** Module type signatures for external integrations.
    Real implementations live in {!Api_remote}, mock implementations in {!Api_local}. *)

module type Github_review_source = sig
  val get_config : ctx:Context.t -> repo_url:string -> (Config_types.config, string) result Lwt.t

  val get_pr_files :
    ctx:Context.t -> repo_url:string -> number:int -> (Github_types.pull_request_file list, string) result Lwt.t

  val get_pr_diff : ctx:Context.t -> repo_url:string -> number:int -> (string, Http_util.error) result Lwt.t

  val get_pull_request :
    ctx:Context.t -> repo_url:string -> number:int -> (Github_types.pull_request, string) result Lwt.t

  val get_compare_diff :
    ctx:Context.t -> repo_url:string -> base:string -> head:string -> (string, Http_util.error) result Lwt.t

  val get_file_content :
    ctx:Context.t -> repo_url:string -> path:string -> ref_:string -> (string option, string) result Lwt.t
end

module type Github_review_sink = sig
  val create_pr_review :
    ctx:Context.t ->
    repo_url:string ->
    number:int ->
    Github_types.create_review_req ->
    (Github_types.created_pr_review, string) result Lwt.t

  val create_commit_comment :
    ctx:Context.t -> repo_url:string -> sha:string -> Github_types.commit_comment_req -> (unit, string) result Lwt.t

  val create_issue_comment :
    ctx:Context.t -> repo_url:string -> number:int -> Github_types.issue_comment_req -> (unit, string) result Lwt.t
end

module type Github_feedback = sig
  val list_pr_review_comments :
    ctx:Context.t ->
    repo_url:string ->
    number:int ->
    review_id:int ->
    (Github_types.pr_review_comment list, string) result Lwt.t

  val list_pr_review_comment_reactions :
    ctx:Context.t -> repo_url:string -> comment_id:int -> (Github_types.reaction list, string) result Lwt.t
end

(** GitHub-specific emoji reactions on PRs and issue comments. Kept separate
    from {!Github_review_sink} because reactions have no platform-neutral meaning —
    only the GitHub publishing path uses them (quiet-review acknowledgement and
    in-progress signalling). *)
module type Reactions = sig
  val create_issue_reaction :
    ctx:Context.t -> repo_url:string -> number:int -> content:string -> (int, string) result Lwt.t

  val create_issue_comment_reaction :
    ctx:Context.t -> repo_url:string -> comment_id:int -> content:string -> (int, string) result Lwt.t

  val delete_issue_reaction :
    ctx:Context.t -> repo_url:string -> number:int -> reaction_id:int -> (unit, string) result Lwt.t

  val delete_issue_comment_reaction :
    ctx:Context.t -> repo_url:string -> comment_id:int -> reaction_id:int -> (unit, string) result Lwt.t
end

module type Github = sig
  include Github_review_source
  include Github_review_sink
  include Github_feedback
  include Reactions
end

module type Agent_runner = sig
  val run :
    ctx:Context.t ->
    repo_url:string ->
    ?model_id:string ->
    ?tools:(string * Ai_core.Core_tool.t) list ->
    ?debug_dir:string ->
    config:Agent_runner.agent_config ->
    input:string ->
    unit ->
    (Agent_runner.agent_result, string) result Lwt.t
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
