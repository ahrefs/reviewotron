(** Core review orchestration functor.
    Dispatches webhook events to the appropriate review flow. *)

module Make (_ : Api.Github) (_ : Api.Claude) (_ : Api.Slack) : sig
  (** Dispatch a webhook event: check filters, run review, post results.
      Errors are logged but do not propagate — the caller gets [unit]. *)
  val process_event : Context.t -> event:Github.event -> unit Lwt.t
end
