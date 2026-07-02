(** Selects which LLM backend agent calls route through.

    Selection is credential-driven (see {!resolve}); there is no explicit
    provider flag. To add a provider: add a variant to {!t}, then let the
    compiler point you at every match below to fill in — none use a catch-all. *)

type t =
  | Anthropic  (** Direct api.anthropic.com. Backwards-compatible path. *)
  | Openrouter  (** openrouter.ai, pinned to the Anthropic upstream. *)

(** A key is usable only if it is non-blank: trims surrounding whitespace and
    maps the empty string to [None]. The single definition of "blank key" shared
    by {!resolve} and the CLI key-precedence chains. *)
val nonempty : string -> string option

(** Credential-driven selection, ignoring blank keys:
    - [openrouter_api_key] present -> [Openrouter]
    - else [anthropic_api_key] present -> [Anthropic]
    - else [Error] naming both env vars. *)
val resolve : Config_types.secrets -> (t, string) result

(** Build the language model for [model_id] under this provider.
    [Openrouter] uses only the OpenRouter API key and pins routing to the
    Anthropic upstream. It does not inject provider BYOK keys; OpenRouter account
    credits are sufficient for normal routing. *)
val language_model : t -> secrets:Config_types.secrets -> model_id:string -> Ai_provider.Language_model.t

(** Namespace a model ID for this provider. Funnels BOTH tier-derived defaults
    and user-supplied overrides through one point.
    [Anthropic]: unchanged. [Openrouter]: canonicalize known Claude API IDs to
    OpenRouter's Anthropic slugs, and preserve already-prefixed custom slugs. *)
val normalize_model_id : t -> string -> string

(** Extended-thinking / reasoning options carrying [budget_tokens]. *)
val thinking_options : t -> budget_tokens:int -> Ai_provider.Provider_options.t

(** Cache-control marker for the cached input prefix. *)
val cached_input_options : t -> Ai_provider.Provider_options.t

(** OpenRouter provider routing preferences used by {!language_model}. Exposed
    for tests and operational introspection: Reviewotron relies on structured
    output, so OpenRouter must route only to providers that accept every
    requested parameter. *)
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
