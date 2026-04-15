(** Security review plugin — multi-agent static analysis pipeline.

    Runs a triage agent to identify security-relevant regions in the diff,
    then routes signals to per-class analysis agents based on confidence
    and repo configuration.  Analysis agents run in parallel (one per
    vulnerability class).  Candidate findings are passed through a
    validator agent that adversarially filters false positives; only
    confirmed findings are converted to review findings.

    The plugin follows a two-gate structure:
    - Signals at or above the confidence threshold always trigger analysis.
    - Signals below the threshold only trigger if the vulnerability class
      is explicitly listed in the repo's [vuln_classes] config. *)

(** Numeric rank for confidence levels — higher means more confident.

    {[High -> 3, Medium -> 2, Low -> 1]} *)
val confidence_rank : Config_types.confidence -> int

(** Compare two {!Config_types.vuln_class} values for equality.

    Uses exhaustive pattern matching — the compiler warns when a new
    variant is added to {!Config_types.vuln_class}. *)
val vuln_class_equal : Config_types.vuln_class -> Config_types.vuln_class -> bool

(** Convert a config model tier to the agent runner's model tier type.

    These types are structurally identical but defined in separate modules
    to avoid a circular dependency. *)
val agent_model_tier : Config_types.model_tier -> Agent_runner.model_tier

(** Determine whether a triage signal should trigger a full analysis agent.

    Returns [true] if the signal's confidence is at or above the configured
    threshold, or if the signal's vulnerability class appears in the repo's
    [vuln_classes] list. *)
val should_analyze : security_config:Config_types.security_plugin_config -> Security_types.triage_signal -> bool

(** Security review plugin functor.

    Takes a GitHub API module (for file content fetching during analysis
    agent context expansion) and an agent runner. *)
module Make (_ : Api.Github) (_ : Api.Agent_runner) : sig
  val name : string

  val run :
    ctx:Context.t ->
    repo_url:string ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:Review_plugin.review_metadata ->
    debug_dir:string ->
    head_sha:string ->
    (Review_types.finding list * Cost_tracking.agent_cost list) Lwt.t

  (** Process the memory update queue: read pending entries, run the
      curator agent to incorporate them, save the updated memory file,
      and truncate the queue.

      Returns the curator agent cost, or an empty list if there were
      no pending updates or the curator failed. *)
  val process_memory_queue :
    ctx:Context.t ->
    repo_url:string ->
    memory_dir:string ->
    security_config:Config_types.security_plugin_config ->
    ?debug_dir:string ->
    unit ->
    Cost_tracking.agent_cost list Lwt.t
end
