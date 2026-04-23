(** Core review orchestration functor.
    Dispatches webhook events to the appropriate review flow. *)

(** Origin of a finding.  Deduplication prefers [From_security] on same-line
    collisions because security findings carry source/sink/flow evidence. *)
type finding_source =
  | From_general
  | From_security

(** Deduplicate findings across plugins.  Two passes:
    1. exact [(path, line)] collisions → security-plugin finding wins; otherwise
       higher severity wins.
    2. same source, same [category], lines within 3 of each other → keep the
       most severe.  Security-plugin findings are exempted from pass 2 because
       the validator agent already filters for uniqueness. *)
val deduplicate_findings : (finding_source * Review_types.finding) list -> Review_types.finding list

module Make (_ : Api.Github) (_ : Api.Agent_runner) (_ : Api.Slack) : sig
  (** Dispatch a webhook event: check filters, run review, post results.
      Errors are logged but do not propagate — the caller gets [unit]. *)
  val process_event : Context.t -> event:Github.event -> unit Lwt.t
end
