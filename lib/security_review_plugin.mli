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

  (** Convert a validated security finding into a review finding, choosing the
      inline anchor from the evidence chain so that findings whose sink lives
      in unchanged code still land on a changed line when the flow traces
      through one.  Exposed for testing the anchor-snapping logic. *)
  val validated_to_finding :
    diff:Diff_parser.file_diff list -> Security_types.validated_finding -> Review_types.finding

  (** Collapse candidate findings that share the same [(sink.path, sink.line)].

      Per-class analysis agents independently flag the same defect under
      different vuln_class labels.  This pass keeps one canonical candidate
      per sink line — picked by highest confidence, then longest flow, then
      first-seen — so the validator sees each defect exactly once.  Distinct
      sink lines are always preserved; merging only happens at literally the
      same file and line.  Exposed for testing. *)
  val dedup_candidates : Security_types.candidate_finding list -> Security_types.candidate_finding list

  (** Build the architectural observations passed to the memory curator.

      Exposed for testing: these observations are deliberately derived
      only from the shape of the review (language hints, reviewed files,
      triage vuln-class distribution).  No per-finding information is
      ever included. *)
  val build_observations :
    triage_output:Security_types.triage_output ->
    file_paths:string list ->
    Security_types.architectural_observations
end
