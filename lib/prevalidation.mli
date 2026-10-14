(** Structured candidates captured immediately before semantic validation. *)

type verdict =
  | Confirmed
  | Rejected
  | Forwarded
  | Unanswered

type t
type recorder = t -> unit

val empty : t
val snapshot : plugin:string -> candidates:Yojson.Basic.t list -> t

val call :
  plugin:string ->
  validator:string ->
  attempt:string ->
  candidates:Yojson.Basic.t list ->
  verdicts:(int * verdict) list ->
  costs:Cost_tracking.agent_cost list ->
  t

val merge : t -> t -> t
val to_json : t -> Yojson.Basic.t
