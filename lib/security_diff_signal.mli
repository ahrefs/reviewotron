(** Deterministic advisory signals extracted from changed diff hunks.

    These signals are hints for LLM triage only. They are never findings and
    do not route directly to analysis or validation. *)

val scan : Diff_parser.t -> Security_types.candidate_signal list
