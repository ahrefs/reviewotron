(** General deep reviewer — second stage of the general review pipeline.

    Receives the scout's investigation leads and verifies each one against
    the diff and the contents of the files the leads point at.  Disprove-first
    posture: a lead only becomes a finding when the reviewer fails to refute
    it and can ground it in visible code.  Emits the same
    [Review_types.review_output] as the legacy single-pass review, so the
    downstream candidate filter and validator are unchanged. *)

val config : model_tier:Agent_runner.model_tier -> system_prompt_override:string option -> Agent_runner.agent_config

(** Build the deep reviewer's user message: formatted leads, then change
    metadata, then contents of ONLY the files referenced by leads (drawn
    from [file_contents], which holds what was already fetched for the
    review), then the annotated diff. *)
val build_input :
  leads:Review_types.scout_lead list ->
  diff_text:string ->
  change_title:string ->
  change_description:string ->
  file_contents:(string * string) list ->
  unit ->
  string
