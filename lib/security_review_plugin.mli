(** Security review plugin — multi-agent static analysis pipeline.

    Runs a triage agent to identify security-relevant regions in the diff,
    then routes signals to per-class analysis agents based on confidence
    and repo configuration.  Analysis agents run in parallel (one per
    vulnerability class).  Candidate findings are passed through a
    validator agent that adversarially filters false positives; only
    confirmed findings are converted to review findings.

    The plugin follows a two-gate structure:
    - A class is enabled if it appears in [vuln_classes] or in
      [always_analyze_vuln_classes].
    - For enabled classes, signals at or above the confidence threshold trigger
      analysis. Signals below the threshold only trigger if the class is listed
      in [always_analyze_vuln_classes]. *)

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

    A class is enabled if it appears in [vuln_classes] or in
    [always_analyze_vuln_classes]. Returns [true] only when the class is
    enabled and either the signal's confidence is at or above the configured
    threshold, or the class is explicitly listed in
    [always_analyze_vuln_classes]. *)
val should_analyze : security_config:Config_types.security_plugin_config -> Security_types.triage_signal -> bool

(** Step budget for a per-class analysis agent after routing.

    High-confidence signals still get enough room for multi-file evidence
    tracing. Medium/low-confidence or broad classes get a bounded verification
    pass so speculative routes do not consume the full global agent budget. *)
val analysis_step_budget : vuln_class:Config_types.vuln_class -> triage_signals:Security_types.triage_signal list -> int

(** Return [true] when a validator proof has the concrete fields required for
    a confirmed result. Trace steps must contain file:line evidence, and
    unresolved assumptions must be empty. *)
val proof_is_concrete : Security_types.exploitation_proof -> bool

(** Outcome of joining one validator response against that call's candidates. *)
type validator_join = {
  matched : Security_types.validated_finding list;
    (** Proof-enforced results, each re-attached to its ORIGINAL candidate. *)
  confirmed_before_proof_enforcement : int;
    (** Confirmed results that joined to a candidate, counted before proof
        enforcement ran. Subtracting the confirmed count of [matched] from this
        yields the number downgraded for lacking a concrete proof, without
        counting results dropped as unknown or duplicate. *)
  missing : (int * Security_types.candidate_finding) list;
    (** Candidates that received no verdict, with their call-local id. *)
  unknown_ids : int list;  (** Ids in the response matching no candidate. *)
  duplicate_ids : int list;  (** Repeated ids; the first occurrence wins. *)
}

(** Join validator results to the candidates of a single call by
    [candidate_id] (the zero-based position within that call's candidate list).

    Unanswered candidates are reported through [missing] so the caller can
    retry them; a malformed or short response therefore degrades to "these
    candidates are missing" and never discards results for other candidates.
    Verdicts are always re-attached to the original candidate, because the
    model's echoed [finding] may be paraphrased. *)
val validator_results_for_candidates :
  candidate_findings:Security_types.candidate_finding list -> Security_types.validator_output -> validator_join

(** Enforce the validator invariant that [Confirmed] results must include a
    concrete [proof_by_construction]. Confirmed results with missing or empty
    proof are downgraded to [Rejected] with an evidence note. *)
val enforce_validator_proofs : Security_types.validated_finding list -> Security_types.validated_finding list

(** Security review plugin functor. File content fetching is supplied through
    {!Review_plugin.review_metadata}, so the plugin is independent of any
    specific source adapter. *)
module Make (_ : Api.Agent_runner) : sig
  val name : string

  (** Run the security pipeline, returning findings, costs, and whether any
      required stage failed. *)
  val run :
    ctx:Context.t ->
    repo_url:string ->
    config:Config_types.config ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:Review_plugin.review_metadata ->
    log_context:string option ->
    debug_dir:string ->
    memory_dir:string ->
    (Review_types.finding list * Cost_tracking.agent_cost list * bool) Lwt.t

  (** Convert a validated security finding into a review finding, choosing the
      inline anchor from the evidence chain so that findings whose sink lives
      in unchanged code still land on a changed line when the flow traces
      through one.  Exposed for testing the anchor-snapping logic. *)
  val validated_to_finding :
    ?log_context:string -> diff:Diff_parser.file_diff list -> Security_types.validated_finding -> Review_types.finding

  (** Collapse candidate findings that share the same [(sink.path, sink.line)].

      Per-class analysis agents independently flag the same defect under
      different vuln_class labels.  This pass keeps one canonical candidate
      per sink line — picked by highest confidence, then longest flow, then
      first-seen — so the validator sees each defect exactly once.  Distinct
      sink lines are always preserved; merging only happens at literally the
      same file and line.  Exposed for testing. *)
  val dedup_candidates :
    ?log_context:string -> Security_types.candidate_finding list -> Security_types.candidate_finding list

  (** Build the architectural observations passed to the memory curator.

      Exposed for testing: these observations are deliberately derived
      only from the shape of the review (language hints, reviewed files,
      triage vuln-class distribution).  No per-finding information is
      ever included. *)
  val build_observations :
    triage_output:Security_types.triage_output -> file_paths:string list -> Security_types.architectural_observations
end
