(** Memory curator agent — post-review maintenance of the repo's architectural brief.

    Builds the agent configuration and user input for the memory curator
    stage of the security review pipeline.  The curator agent takes a small
    set of architectural observations from a completed review (language
    hints, reviewed file list, triage vuln-class distribution) and updates
    a short markdown brief describing the shape of the repository.

    The brief is deliberately scoped to stable architectural facts — it
    contains no per-finding details, no line numbers, and no suppression
    entries.  Findings are never passed to the curator.

    The curator runs as a single-shot call (no tools, [max_steps = 1])
    using a fast model tier.  It runs asynchronously after the review is
    posted — not in the critical path. *)

(** Build the memory curator agent configuration.

    [model_tier] controls which model is used — typically [Fast] (Haiku). *)
val config : model_tier:Agent_runner.model_tier -> Agent_runner.agent_config

(** Build the user message for the memory curator agent.

    Assembles the repository name, current brief contents (if any), the
    token budget, and a set of architectural observations from the
    completed review.

    @param repo_name Repository identifier (e.g. ["ahrefs-monorepo"]).
    @param memory_max_tokens Maximum number of tokens for the brief.
    @param observations Architectural observations extracted from the review.
    @param current_memory Optional existing brief contents. *)
val build_input :
  repo_name:string ->
  memory_max_tokens:int ->
  observations:Security_types.architectural_observations ->
  ?current_memory:string ->
  unit ->
  string

(** Rough token estimate: ~4 characters per token. *)
val estimate_tokens : string -> int
