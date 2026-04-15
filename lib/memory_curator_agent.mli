(** Memory curator agent — post-review maintenance of repo security memory.

    Builds the agent configuration and user input for the memory curator
    stage of the security review pipeline.  The curator agent incorporates
    learnings from a completed review into the repository's security memory
    file, compressing entries when the token budget is exceeded.

    The curator runs as a single-shot call (no tools, [max_steps = 1])
    using a fast model tier.  It runs asynchronously after the review is
    posted — not in the critical path. *)

(** Build the memory curator agent configuration.

    [model_tier] controls which model is used — typically [Fast] (Haiku). *)
val config : model_tier:Agent_runner.model_tier -> Agent_runner.agent_config

(** Build the user message for the memory curator agent.

    Assembles the repository name, current memory contents (if any), the
    token budget, and new learnings from the completed review into a
    structured prompt.

    @param repo_name Repository identifier (e.g. ["ahrefs/monorepo"]).
    @param memory_max_tokens Maximum number of tokens for the memory file.
    @param learnings List of observations from the completed review.
    @param current_memory Optional existing memory file contents. *)
val build_input :
  repo_name:string -> memory_max_tokens:int -> learnings:string list -> ?current_memory:string -> unit -> string
