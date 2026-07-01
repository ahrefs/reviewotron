(** One-shot GitHub reaction collector for feedback targets. *)

module Make (_ : Api.Github_feedback) : sig
  val collect :
    ?poll_interval_seconds:int -> ctx:Context.t -> store:Feedback_store.t -> now:Ptime.t -> unit -> unit Lwt.t
end
