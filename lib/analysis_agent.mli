(** Analysis agent — deep source-sink-flow-sanitization reasoning.

    Builds the agent configuration, user input, and tool set for
    per-vulnerability-class analysis agents.  Each analysis agent runs in
    parallel, using the shared 4-step methodology but with vulnerability-class
    and language-specific source/sink catalogs.

    Analysis agents use [get_file_content] for demand-driven context expansion
    when tracing data flows beyond the diff. *)

(** Build the analysis agent configuration.

    [vuln_class] selects the vulnerability class this agent will analyze.
    [model_tier] controls which model is used — typically [Standard] (Sonnet).
    [language_hints] parameterizes source/sink catalogs for detected languages.

    The returned base config has [max_steps = 15] to allow multiple tool
    round-trips for demand-driven context expansion. The security plugin may
    apply a tighter per-class dynamic budget after triage. *)
val config :
  vuln_class:Security_types.vuln_class ->
  model_tier:Agent_runner.model_tier ->
  language_hints:string list ->
  Agent_runner.agent_config

(** Build the user message for an analysis agent.

    Assembles the triage signals (flagged regions for this agent's vuln class),
    changed file paths, and the full diff into a structured prompt.

    The analysis agent works from the diff, its triage signals, and its own
    methodology — no repository security memory is injected.  Memory priors
    bias analysis toward confirmation; the curated architectural brief is
    fed to triage only.

    @param diff_text Raw unified diff text.
    @param triage_signals Triage signals relevant to this agent's vuln class.
    @param file_paths List of changed file paths in the reviewed change. *)
val build_input :
  diff_text:string -> triage_signals:Security_types.triage_signal list -> file_paths:string list -> unit -> string

(** Build the tool set for analysis agents.

    Returns a list containing [get_file_content] wired to the provided
    [fetch_file] callback.  All analysis agents share the same tool set.

    @param fetch_file Callback that fetches file content from the repository
    (typically backed by the GitHub Contents API). *)
val tools : fetch_file:(string -> (string option, string) result Lwt.t) -> (string * Ai_core.Core_tool.t) list

(** Return the per-vulnerability-class prompt section.

    Exposed for testing.  Returns class-specific source/sink catalogs and
    sanitization criteria, parameterized by [language_hints]. *)
val vuln_class_section : Security_types.vuln_class -> language_hints:string list -> string

(** Return the shared analysis methodology prompt section.

    Exposed for testing.  Describes the 4-step source→sink→flow→sanitization
    reasoning chain that all analysis agents follow. *)
val shared_methodology : string
