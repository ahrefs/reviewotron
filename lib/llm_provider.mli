(** Selects which LLM backend agent calls route through.

    Selection is credential-driven (see {!resolve}); there is no explicit
    provider flag. To add a provider: add a variant to {!t}, then let the
    compiler point you at every match below to fill in — none use a catch-all. *)

type t =
  | Anthropic  (** Direct api.anthropic.com. Backwards-compatible path. *)
  | Openrouter  (** openrouter.ai, with an independent OpenAI fallback. *)

(** A key is usable only if it is non-blank: trims surrounding whitespace and
    maps the empty string to [None]. The single definition of "blank key" shared
    by {!resolve} and the CLI key-precedence chains. *)
val nonempty : string -> string option

(** Resolve an OpenRouter base-URL override from a raw environment value.
    Blank or whitespace-only maps to [None] (indistinguishable from unset), and
    trailing slashes are stripped because the SDK appends ["/chat/completions"]
    directly. A value of only slashes is therefore also [None]. *)
val base_url_of_env : string option -> string option

(** [base_url_of_env] applied to [OPENROUTER_BASE_URL]. [None] leaves the SDK
    default ([https://openrouter.ai/api/v1]) untouched. Deployment-only knob for
    routing through an OpenAI-compatible proxy; there is no CLI flag or config
    field for it. *)
val openrouter_base_url : unit -> string option

(** Credential-driven selection, ignoring blank keys:
    - [openrouter_api_key] present -> [Openrouter]
    - else [anthropic_api_key] present -> [Anthropic]
    - else [Error] naming both env vars. *)
val resolve : Config_types.secrets -> (t, string) result

(** Build the language model for [model_id] under this provider.
    [Openrouter] uses only the OpenRouter API key and restricts routing to the
    Anthropic and OpenAI labs' endpoints. It does not inject provider BYOK keys;
    OpenRouter account credits are sufficient for normal routing. *)
val language_model : t -> secrets:Config_types.secrets -> model_id:string -> Ai_provider.Language_model.t

(** Namespace a model ID for this provider. Funnels BOTH tier-derived defaults
    and user-supplied overrides through one point.
    [Anthropic]: unchanged. [Openrouter]: canonicalize known Claude API IDs to
    OpenRouter's Anthropic slugs, and preserve already-prefixed custom slugs and
    [~]-prefixed OpenRouter aliases such as [~anthropic/claude-sonnet-latest]. *)
val normalize_model_id : t -> string -> string

(** Extended-thinking / reasoning options carrying [budget_tokens].

    Direct Anthropic sends the budget as manual thinking on catalog-known models
    that accept one (the pre-adaptive generation). Adaptive-only models reject
    manual budgets outright, so there the budget is translated to the nearest
    adaptive effort level rather than dropped; unknown and non-thinking models
    emit no option. OpenRouter always receives that translated effort as
    [reasoning.effort], because it drops [reasoning.max_tokens] for
    adaptive-only models. *)
val thinking_options : t -> model_id:string -> budget_tokens:int -> Ai_provider.Provider_options.t

(** Reasoning-effort options for [model_id]. Direct Anthropic emits native
    effort with adaptive thinking only when the SDK catalog supports both;
    OpenRouter emits its existing reasoning-effort configuration. *)
val effort_options : t -> model_id:string -> effort:Config_types.Effort.t -> Ai_provider.Provider_options.t

(** Cache-control marker for the cached input prefix. *)
val cached_input_options : t -> Ai_provider.Provider_options.t

(** Cross-lab fallback model for each [latest] alias and for the listed concrete
    Claude slugs, which a [model] override can still select. Any other model ID
    receives no implicit fallback. *)
val openrouter_fallback_models : string -> string list

(** Whether OpenRouter answered with a fallback model: the served model belongs
    to a different lab than the requested one. An alias resolves to a concrete
    model of its own lab, so a [latest] alias answered by its target is not a
    fallback. Direct Anthropic IDs name no lab, so they never count. *)
val served_by_fallback : requested_model_id:string -> served_model_id:string -> bool

(** OpenRouter provider routing preferences used by {!language_model}. Routing
    is restricted to Anthropic and OpenAI's own endpoints, requires every
    requested parameter, and excludes providers that may collect prompts. *)
val openrouter_provider_prefs : Ai_provider_openrouter.Openrouter_options.provider_prefs

(** Deprecated compatibility alias for {!openrouter_provider_prefs}. *)
val anthropic_upstream_prefs : Ai_provider_openrouter.Openrouter_options.provider_prefs

(** Usage read from a step's [provider_metadata]. Carries the cache token counts
    and, when the provider reports it, the actual billed USD [cost] for the
    generation. Costing policy lives in {!Cost_tracking}; this only carries the
    raw figures.

    [cost] is always [None] on the {!Anthropic} path (the direct API reports no
    USD figure; {!Cost_tracking} estimates it from the pricing table). On
    {!Openrouter} it is the larger of the reported [cost] and upstream inference
    cost: without BYOK the two repeat the same charge, and with BYOK the upstream
    figure is the provider's charge. *)
type usage = {
  cache_read : int;
  cache_write : int;
  cost : float option;
}

val usage_metadata : t -> Ai_provider.Provider_options.t option -> usage

(** Combine two optional USD costs. [None] is "no figure reported": [None]/[None]
    stays [None], a lone figure passes through, and two figures sum. Used to total
    the per-step OpenRouter costs, leaving the result [None] when nothing was
    reported (and {!Cost_tracking} then falls back to the pricing table). *)
val sum_cost : float option -> float option -> float option
