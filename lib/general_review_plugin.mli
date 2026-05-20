(** General code review plugin.

    Wraps the general-purpose LLM review agent as a {!Review_plugin.S}
    implementation.  The functor takes an agent runner and produces a module
    that satisfies the plugin interface plus an extended [run_review] function
    that returns the full review output (summary + findings). *)

(** Build the agent configuration for the general review agent.

    Exposed for testing the wiring of Anthropic extended-thinking — the
    config carries a non-trivial [thinking_budget] that the agent runner
    translates into a provider-options payload.  The system prompt is the
    only varying input; everything else (model tier, output schema, max
    steps, thinking budget) is fixed by this plugin's design. *)
val build_agent_config : system_prompt:string -> Agent_runner.agent_config

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

      Returns [(result, costs)] where [result] is [Error msg] on agent
      failure or output parse failure.  Costs are always returned, even
      on failure, since tokens were still consumed. *)
  val run_review :
    ctx:Context.t ->
    repo_url:string ->
    diff_text:string ->
    metadata:Review_plugin.review_metadata ->
    ?debug_dir:string ->
    unit ->
    ((Review_types.review_output, string) result * Cost_tracking.agent_cost list) Lwt.t
end
