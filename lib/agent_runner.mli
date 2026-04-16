(** Generic agent runner for AI-powered analysis.

    Wraps [Ai_core.Generate_text.generate_text] with structured output,
    tool loops, token tracking, and retry handling. Agents are configured
    entirely through data — no agent-specific code paths. *)

(** Model performance tier for agent configuration.
    Maps to specific model IDs via {!default_model_id}. *)
type model_tier =
  | Fast
  | Standard
  | Strong
[@@deriving json]

val model_tier_jsonschema : Yojson.Basic.t

(** Static configuration for an agent.
    Tools are passed separately to {!run_agent} since they contain callbacks. *)
type agent_config = {
  name : string;
  system_prompt : string;
  model_tier : model_tier;
  output_schema : Yojson.Basic.t;
  max_steps : int;
}

(** Result of a successful agent run. *)
type agent_result = {
  output : Yojson.Basic.t;
  usage : Ai_provider.Usage.t;
  cache_read_input_tokens : int;
  cache_creation_input_tokens : int;
  steps_count : int;
  model_id : string;
}

(** Default model ID for a tier.

    - [Fast] → [claude-haiku-4-5-20251001]
    - [Standard] → [claude-sonnet-4-6-20260414]
    - [Strong] → [claude-opus-4-6-20260414] *)
val default_model_id : model_tier -> string

(** Write a debug dump of agent output when structured parsing fails.

    Creates [{dir}/{config.name}.txt] containing finish reason, token usage,
    and the full text of every step.  Returns [Some filepath] on success,
    [None] if the write fails (never raises).

    Exposed for unit testing. *)
val write_debug_dump :
  dir:string ->
  config:agent_config ->
  finish_reason:Ai_provider.Finish_reason.t ->
  steps:Ai_core.Generate_text_result.step list ->
  usage:Ai_provider.Usage.t ->
  string option

(** Run an agent with the given configuration and input prompt.

    Creates structured output from [config.output_schema], executes
    the tool loop up to [config.max_steps], and returns parsed output
    with token usage.

    @param model Language model instance (create via provider, e.g.
      [Ai_provider_anthropic.model "claude-sonnet-4-6-20260414"])
    @param tools Named tool definitions for context expansion
    @param max_retries Per-call retry count (default 2)
    @param debug_dir Directory for debug dumps on parse failure
    @param config Agent configuration (prompt, schema, limits)
    @param input User message content *)
val run_agent :
  model:Ai_provider.Language_model.t ->
  ?tools:(string * Ai_core.Core_tool.t) list ->
  ?max_retries:int ->
  ?debug_dir:string ->
  config:agent_config ->
  input:string ->
  unit ->
  (agent_result, string) result Lwt.t
