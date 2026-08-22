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
    OpenRouter's Anthropic slugs, and preserve already-prefixed custom slugs. *)
val normalize_model_id : t -> string -> string

(** Extended-thinking / reasoning options for [model_id]. Direct Anthropic uses
    a manual [budget_tokens] value where supported, enables adaptive thinking on
    adaptive-only models, and emits no option for unknown or unsupported models.
    OpenRouter always emits its existing budgeted reasoning configuration. *)
val thinking_options : t -> model_id:string -> budget_tokens:int -> Ai_provider.Provider_options.t

(** OpenRouter reasoning-effort options. On the direct Anthropic path this
    returns empty options because ocaml-ai-sdk 0.4 cannot encode native
    [output_config.effort] yet. *)
val effort_options : t -> effort:Config_types.Effort.t -> Ai_provider.Provider_options.t

(** Cache-control marker for the cached input prefix. *)
val cached_input_options : t -> Ai_provider.Provider_options.t

(** Cross-lab fallback model for each supported default Claude model. Custom
    model overrides receive no implicit fallback. *)
val openrouter_fallback_models : string -> string list

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
    {!Openrouter} it is the reported cost when present, plus upstream inference
    cost when OpenRouter reports BYOK metadata. *)
type usage = {
  cache_read : int;
  cache_write : int;
  cost : float option;
}

val usage_metadata : t -> Ai_provider.Provider_options.t option -> usage

(** Combine two optional USD costs. [None] is "no figure reported": [None]/[None]
    stays [None], a lone figure passes through, and two figures sum. Used to total
    the per-step OpenRouter costs and to fold in upstream BYOK cost, so both leave
    the result [None] when nothing was reported (and {!Cost_tracking} then falls
    back to the pricing table). *)
val sum_cost : float option -> float option -> float option
