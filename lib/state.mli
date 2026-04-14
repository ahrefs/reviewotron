(** State persistence: tracks which PRs and pushes have been reviewed. *)

(** The mutable state handle. *)
type t

(** Create a new empty state, optionally bound to a file path for persistence. *)
val create : ?filepath:string -> unit -> t

(** Load state from a JSON file on disk. Returns empty state if file doesn't exist or is malformed. *)
val load : filepath:string -> t

(** Check if this exact PR + SHA combination was already reviewed. *)
val is_pr_reviewed : t -> repo_url:string -> pr_number:int -> head_sha:string -> bool

(** Record that a PR was reviewed. *)
val record_pr_review : t -> repo_url:string -> pr_number:int -> head_sha:string -> unit

(** Check if this push (by after SHA) was already reviewed. *)
val is_push_reviewed : t -> repo_url:string -> after_sha:string -> bool

(** Record that a push was reviewed. *)
val record_push_review : t -> repo_url:string -> after_sha:string -> unit

(** Persist state to disk atomically. No-op if no filepath was set. *)
val save : t -> unit

(** Access the underlying state data (for testing). *)
val data : t -> State_types.state
