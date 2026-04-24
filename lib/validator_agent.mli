(** Validator agent — adversarial false-positive filter.

    Reviews all candidate findings from analysis agents and makes a
    final accept/reject decision on each.  The validator is explicitly
    adversarial: its default posture is rejection.  Findings that
    cannot be fully substantiated with concrete source, sink, flow,
    and sanitization evidence are dropped.

    The validator uses [get_file_content] to spot-check evidence claims
    made by analysis agents — it does not search for new vulnerabilities. *)

(** Build the validator agent configuration.

    [model_tier] controls which model is used — must be at least
    [Standard] (Sonnet), matching or exceeding the analysis agents it
    checks.

    The returned config has [max_steps = 12] to allow spot-checking
    evidence via [get_file_content].  Sized for validator runs that carry
    ~10 candidate findings spanning several files. *)
val config : model_tier:Agent_runner.model_tier -> Agent_runner.agent_config

(** Build the user message for the validator agent.

    Assembles the candidate findings (rendered as readable text with
    full evidence chains), optional repository security memory, and
    the original diff into a structured prompt.

    @param diff_text Raw unified diff text.
    @param candidate_findings All candidate findings from analysis agents.
    @param security_memory Optional repo security memory contents. *)
val build_input :
  diff_text:string ->
  candidate_findings:Security_types.candidate_finding list ->
  ?security_memory:string ->
  unit ->
  string

(** Build the tool set for the validator agent.

    Returns a list containing [get_file_content] wired to the provided
    [fetch_file] callback.  Used for spot-checking evidence claims.

    @param fetch_file Callback that fetches file content from the repository
    (typically backed by the GitHub Contents API). *)
val tools : fetch_file:(string -> (string option, string) result Lwt.t) -> (string * Ai_core.Core_tool.t) list

(** The validator's system prompt.

    Exposed for testing.  Contains the adversarial validation
    methodology with the four validation criteria. *)
val system_prompt : string
