(** Best-effort security pipeline artifact writer.

    Metrics artifacts are compact and should not contain source code or prompt
    bodies. Debug artifacts may contain redacted model inputs and outputs and
    are therefore controlled by a separate opt-in flag. *)

type t

val create : debug_dir:string -> metrics_artifacts:bool -> debug_artifacts:bool -> t
val enabled : t -> bool
val metrics_enabled : t -> bool
val debug_enabled : t -> bool
val root : t -> string

(** Best-effort redaction for full debug artifacts. This reduces accidental
    leakage but does not make artifacts safe for broad retention. *)
val redact_text : string -> string

val write_manifest : t -> repo_url:string -> unit
val write_metrics : t -> Yojson.Basic.t -> unit
val write_fetch_stats : t -> Cost_tracking.agent_cost list -> unit
val write_debug_text : t -> filename:string -> string -> unit
val write_debug_json : t -> filename:string -> Yojson.Basic.t -> unit

val signal_counts_json : Security_types.candidate_signal list -> Yojson.Basic.t
val agent_costs_json : Cost_tracking.agent_cost list -> Yojson.Basic.t
val final_findings_json : Review_types.finding list -> Yojson.Basic.t
