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
  thinking_budget : int option;
    (** Extended-thinking budget for this agent.  Set to give the model a private
        reasoning channel that does not leak into structured output.  [None]
        leaves the provider default untouched on both backends.

        OpenRouter sends the budget verbatim. Direct Anthropic honors it as a
        manual budget on catalog-known models that accept one, and translates it
        to the nearest adaptive effort level on adaptive-only models, which
        reject manual budgets. Sub-1024 values are clamped to the Anthropic
        minimum. *)
  effort : Config_types.Effort.t option;
    (** Reasoning effort. Direct Anthropic emits native effort with adaptive
        thinking when the SDK catalog supports the requested level; unsupported
        semantics are omitted with a warning. OpenRouter uses its reasoning
        effort encoding. Mutually exclusive with [thinking_budget]. *)
}

(** Result of a successful agent run. *)
type agent_result = {
  output : Yojson.Basic.t;
  usage : Ai_provider.Usage.t;
  cache_read_input_tokens : int;
  cache_creation_input_tokens : int;
  steps_count : int;
  tool_calls_count : int;
    (** Number of tool calls requested by the model, including any final calls
        that could not execute because the step budget was exhausted. *)
  tool_results_count : int;
    (** Number of completed tool results returned to the model. For agents whose
        only tool is [get_file_content], this is the number of file-fetch
        attempts that actually ran. *)
  model_id : string;
    (** Model that produced the final structured output. This differs from the
        requested model when OpenRouter used a cross-lab fallback. *)
  reported_cost_usd : float option;
    (** The provider's actual billed USD cost for the run, when it reports one
          (OpenRouter). [None] on the Anthropic path, where {!Cost_tracking}
          estimates from its pricing table instead. *)
  refused_attempt : agent_result option;
    (** The run a 5.5 safety classifier refused before this result's model
        took over. Its tokens stay out of the fields above, since they belong to
        another model; {!Cost_tracking} prices it at that model's rates. *)
}

(** Default model ID for a tier under [provider].

    - [Fast] → [claude-haiku-5-5] / [~anthropic/claude-haiku-latest]
    - [Standard] → [claude-sonnet-5-5] / [~anthropic/claude-sonnet-latest]
    - [Strong] → [claude-opus-5-5] / [~anthropic/claude-opus-latest]

    OpenRouter gets its [latest] aliases, which follow each family's newest
    release. The direct Anthropic API has no such alias, and a new ID also needs
    an ocaml-ai-sdk catalog entry, so those IDs are pinned and bumped by hand. *)
val default_model_id : Llm_provider.t -> model_tier -> string

(** Model to retry on when [model_id] refuses a request: the 5.5 model's
    predecessor, which has no safety classifier. [model_id] is the provider's
    normalized ID, so OpenRouter's [latest] aliases map too. [None] for any
    other model, which is not retried.

    - [claude-opus-5-5] → [claude-opus-4-8]; [claude-sonnet-5-5] →
      [claude-sonnet-5]; [claude-haiku-5-5] → [claude-haiku-4-5-20251001]
    - [~anthropic/claude-opus-latest] or [anthropic/claude-opus-5.5] →
      [anthropic/claude-opus-4.8], and likewise for Sonnet ([claude-sonnet-5])
      and Haiku ([claude-haiku-4.5]) *)
val refusal_fallback_model_id : string -> string option

(** Non-cached prompt tokens, keeping the three prompt buckets
    ([input_tokens], [cache_read_input_tokens], [cache_creation_input_tokens])
    disjoint so downstream cost sums do not double-count the prompt.

    Anthropic already reports [input_tokens] excluding the cached portion, so it
    is returned unchanged. OpenRouter reports the full prompt in [input_tokens]
    and repeats the cached portion in the cache buckets, so the cache portion is
    subtracted out (clamped at 0). Exposed for testing; applied automatically
    when building an {!agent_result}. *)
val disjoint_input_tokens :
  provider:Llm_provider.t -> input_tokens:int -> cache_read_input_tokens:int -> cache_creation_input_tokens:int -> int

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

(** Translate an agent's provider-specific knobs into a [Provider_options.t]
    payload for [Ai_core.Generate_text.generate_text].  The [provider] selects
    which backend's option encoding is emitted.  Exposed so the plumbing is
    unit-testable without dispatching a live agent run. *)
val build_provider_options :
  provider:Llm_provider.t -> model_id:string -> agent_config -> Ai_provider.Provider_options.t

(** [Provider_options.t] carrying the [provider]'s ephemeral [cache_control]
    breakpoint.  Attached to the long, stable user-input text block so that
    every turn after the first within an agent run cache-hits on the
    [tools + system + input] prefix (per the provider's prefix caching rules).
    Exposed for unit testing. *)
val cached_input_provider_options : Llm_provider.t -> Ai_provider.Provider_options.t

(** Select the model used for result attribution. OpenRouter reports the model
    it actually served; direct Anthropic retains the requested model ID. *)
val response_model_id : provider:Llm_provider.t -> requested_model_id:string -> string option -> string

(** Render a provider failure with HTTP status and retryability.

    For OpenRouter, appends [likely_type=<t>] when the message ends in a
    parenthesized token — usually the gateway's [metadata.error_type], but the
    flattened message cannot distinguish that from an unrelated trailing
    parenthetical, so the value is reported as a guess and omitted entirely when
    there is none. *)
val format_provider_error : Ai_provider.Provider_error.t -> string

(** [true] only for OpenRouter's unclassified 403 response
    [[Anthropic] Request not allowed]. The SDK marks all 403s non-retryable,
    but this specific response has been observed to be transient. *)
val should_retry_generic_openrouter_403 : Ai_provider.Provider_error.t -> bool

(** Retry one provider request after the specific transient OpenRouter 403.
    [sleep] is injectable for tests. *)
val retry_generic_openrouter_403_once :
  ?sleep:(float -> unit Lwt.t) -> log_prefix:string -> agent_name:string -> (unit -> 'a Lwt.t) -> 'a Lwt.t

(** Run an agent with the given configuration and input prompt.

    Creates structured output from [config.output_schema], executes
    the tool loop up to [config.max_steps], and returns parsed output
    with token usage.

    @param provider
      Which LLM backend the call routes through; selects the provider-specific
      option encoding and usage parsing.  [model] must have been built for this
      same provider (see {!Llm_provider.language_model}).
    @param model Language model instance (create via provider, e.g.
      [Ai_provider_anthropic.language_model ~model:"claude-sonnet-5-5" ()])
    @param refusal_fallback
      Model to rerun the agent on, once, when [model] refuses the request
      ([stop_reason: "refusal"], surfaced as a content-filter finish). The
      refused attempt's tokens and cost are added to the result.
    @param tools Named tool definitions for context expansion
    @param max_retries Per-call retry count (default 2)
    @param debug_dir Directory for debug dumps on parse failure
    @param log_context Review identifier prefix for correlating concurrent logs
    @param config Agent configuration (prompt, schema, limits)
    @param input User message content *)
val run_agent :
  provider:Llm_provider.t ->
  model:Ai_provider.Language_model.t ->
  ?refusal_fallback:Ai_provider.Language_model.t ->
  ?tools:(string * Ai_core.Core_tool.t) list ->
  ?max_retries:int ->
  ?debug_dir:string ->
  ?log_context:string ->
  config:agent_config ->
  input:string ->
  unit ->
  (agent_result, string) result Lwt.t

(** Serialize a list of completed steps as a replay-able message history.

    Each step produces an [Assistant] message (text + tool calls) followed by
    a [Tool] message (the tool results), matching how the SDK stitches the
    multi-turn conversation back together.  Steps whose tool calls were never
    executed (typically the final step when [max_steps] is exhausted) are
    dropped — re-sending an Assistant turn with unanswered [tool_use] blocks
    would be a protocol violation at the provider API layer. This structured
    replay is used for OpenRouter.

    Exposed for unit testing the budget-exhaustion recovery path. *)
val messages_of_steps : Ai_core.Generate_text_result.step list -> Ai_provider.Prompt.message list

(** Select the provider's safe recovery transcript. Direct Anthropic flattens
    completed visible text and tool results into fresh [User] messages because
    steps can omit reasoning and tool protocol state. OpenRouter preserves
    {!messages_of_steps}. *)
val recovery_messages_of_steps :
  provider:Llm_provider.t -> Ai_core.Generate_text_result.step list -> Ai_provider.Prompt.message list
