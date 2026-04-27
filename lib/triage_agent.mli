(** Triage agent — fast security scan of PR diffs.

    Builds the agent configuration and user input for the triage stage
    of the security review pipeline.  The triage agent identifies
    security-relevant regions in the diff and routes them to per-class
    analysis agents.

    The triage agent runs as a single-shot call (no tools, [max_steps = 1])
    using a fast model tier by default.  It is biased toward over-flagging:
    spawning an unnecessary analysis agent is cheap, missing a real
    vulnerability is not. *)

(** Build the triage agent configuration.

    [model_tier] controls which model is used — typically [Fast] (Haiku)
    but configurable per-repo via {!Config_types.security_plugin_config}. *)
val config : model_tier:Agent_runner.model_tier -> Agent_runner.agent_config

(** Build the user message for the triage agent.

    Assembles the diff text, changed file paths (with auto-detected language
    hints), and optional repository security memory into a structured prompt.

    @param diff_text Raw unified diff text.
    @param file_paths List of changed file paths in the PR.
    @param security_memory Optional repo security memory contents. *)
val build_input : diff_text:string -> file_paths:string list -> ?security_memory:string -> unit -> string

(** Detect programming languages from file extensions.

    Returns a sorted, deduplicated list of language names inferred from
    the extensions of the given file paths.  Used internally by
    {!build_input} and also useful for passing language hints to
    analysis agents. *)
val detect_languages : string list -> string list
