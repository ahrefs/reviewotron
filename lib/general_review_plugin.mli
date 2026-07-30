(** General code review plugin.

    Wraps the general-purpose LLM review agent as a {!Review_plugin.S}
    implementation.  The functor takes an agent runner and produces a module
    that satisfies the plugin interface plus an extended [run_review] function
    that returns the full review output (summary + findings). *)

(** Build the general review agent's configuration.  Exposed so the
    Anthropic extended-thinking wiring is unit-testable. *)
val build_agent_config : system_prompt:string -> Agent_runner.agent_config

(** Outcome of the general-review pipeline.

    A validator outage is distinct from an unfinished review: the reviewers
    completed, but their provisional findings remain withheld rather than being
    posted without the adversarial validation gate. *)
type review_outcome =
  | Completed of Review_types.review_output
  | Validation_failed of {
      review : Review_types.review_output;
      candidates_withheld : int;
      reason : string;
    }
  | Failed of string

(** Build a general review plugin from an agent runner.

    The resulting module satisfies {!Review_plugin.S}.  It also exposes
    [run_review] which returns the full {!Review_types.review_output},
    including [summary] and [overall_assessment].  The orchestrator uses
    [run_review] while the full plugin pipeline is being built. *)
module Make (_ : Api.Agent_runner) : sig
  include Review_plugin.S

  (** Run the review agent and return the full structured output.

      Unlike {!run}, which returns only the findings list, this function
      returns the complete {!Review_types.review_output} including the
      LLM-generated summary and overall assessment.

      Returns [(outcome, costs)].  [Validation_failed] retains the completed
      review and the count of withheld provisional findings, while [Failed]
      means a review stage could not complete. Costs are always returned, even
      on failure, since tokens were still consumed. *)
  val run_review :
    ctx:Context.t ->
    repo_url:string ->
    config:Config_types.config ->
    diff_text:string ->
    metadata:Review_plugin.review_metadata ->
    ?debug_dir:string ->
    ?log_context:string ->
    unit ->
    (review_outcome * Cost_tracking.agent_cost list) Lwt.t
end
