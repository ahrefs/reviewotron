(** Local diff review orchestration.

    This module proves the review core can run without GitHub acquisition or
    GitHub publication. *)

(** [true] when a local review error string represents normal duplicate-skip
    behavior rather than a failed review. *)
val is_already_reviewed_message : string -> bool

module Make (_ : Api.Agent_runner) : sig
  (** Review a local unified diff, record [change_key] only when every enabled
      plugin completes, and return markdown output. Returns [Error _] if the
      change was already reviewed in the current state. *)
  val review_diff :
    ctx:Context.t ->
    root:string ->
    repo_key:string ->
    ?change_key:string ->
    ?revision:string ->
    title:string ->
    description:string ->
    diff_path:string ->
    config:Config_types.config ->
    unit ->
    (string, string) result Lwt.t

  (** Review raw unified diff text, record [change_key] only when every enabled
      plugin completes, and return markdown output. Returns [Error _] if the
      change was already reviewed in the current state. *)
  val review_diff_text :
    ctx:Context.t ->
    root:string ->
    repo_key:string ->
    ?change_key:string ->
    ?revision:string ->
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
    ?revision:string ->
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
    ?revision:string ->
    title:string ->
    description:string ->
    diff_text:string ->
    config:Config_types.config ->
    unit ->
    (Review_engine.report, string) result Lwt.t
end
