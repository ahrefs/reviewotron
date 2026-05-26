(** Local diff review orchestration.

    This module proves the review core can run without GitHub acquisition or
    GitHub publication. *)

module Make (_ : Api.Agent_runner) : sig
  (** Review a local unified diff and return markdown output. *)
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
end
