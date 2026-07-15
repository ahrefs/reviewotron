(** General review scout — first stage of the general review pipeline.

    Reads the change diff and emits capped investigation leads for the
    deep reviewer.  Biased toward over-flagging: a missed lead is
    unrecoverable downstream; a bogus lead costs one paragraph of deep
    review.  Never emits style/naming/documentation leads, and skips
    security leads when the security plugin covers them. *)

(** Agent configuration for the scout.  [model_tier] comes from
    [general_plugin_config.scout_model_tier]. *)
val config : model_tier:Agent_runner.model_tier -> security_covered_elsewhere:bool -> Agent_runner.agent_config

(** Build the scout's user message from the annotated diff and change
    metadata.  File contents are deliberately excluded — the scout notices,
    the deep reviewer verifies. *)
val build_input : diff_text:string -> change_title:string -> change_description:string -> unit -> string

(** Truncate leads to [max_leads], keeping highest-confidence first (stable
    within a confidence band).  Logs what was dropped. *)
val cap_leads : ?log_context:string -> max_leads:int -> Review_types.scout_lead list -> Review_types.scout_lead list
