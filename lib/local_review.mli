(** Local diff review orchestration.

    This module proves the review core can run without GitHub acquisition or
    GitHub publication. *)

module Make (_ : Api.Agent_runner) : sig
  (** Review a local unified diff, record the generic [change_key] in state,
      and return markdown output. *)
  val review_diff :
    ctx:Context.t ->
    root:string ->
    repo_key:string ->
    ?change_key:string ->
    title:string ->
    description:string ->
    diff_path:string ->
    config:Config_types.config ->
    unit ->
    (string, string) result Lwt.t

  (** Review raw unified diff text, record the generic [change_key] in state,
      and return markdown output. *)
  val review_diff_text :
    ctx:Context.t ->
    root:string ->
    repo_key:string ->
    ?change_key:string ->
    title:string ->
    description:string ->
    diff_text:string ->
    config:Config_types.config ->
    unit ->
    (string, string) result Lwt.t

  (** Review a local unified diff and return the neutral report for caller-owned
      rendering. *)
  val review_diff_report :
    ctx:Context.t ->
    root:string ->
    repo_key:string ->
    ?change_key:string ->
    title:string ->
    description:string ->
    diff_path:string ->
    config:Config_types.config ->
    unit ->
    (Review_engine.report, string) result Lwt.t

  (** Review raw unified diff text and return the neutral report for caller-owned
      rendering. *)
  val review_diff_text_report :
    ctx:Context.t ->
    root:string ->
    repo_key:string ->
    ?change_key:string ->
    title:string ->
    description:string ->
    diff_text:string ->
    config:Config_types.config ->
    unit ->
    (Review_engine.report, string) result Lwt.t
end
