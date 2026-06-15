type t =
  | Anthropic
  | Openrouter

let all = [ Anthropic; Openrouter ]

let to_string = function
  | Anthropic -> "anthropic"
  | Openrouter -> "openrouter"

let nonempty s =
  match String.trim s with
  | "" -> None
  | s -> Some s

let normalize_key key = Stdlib.Option.bind key nonempty

let resolve (secrets : Config_types.secrets) =
  match normalize_key secrets.openrouter_api_key, normalize_key secrets.anthropic_api_key with
  | Some _, _ -> Ok Openrouter
  | None, Some _ -> Ok Anthropic
  | None, None -> Error "no LLM API key found; set OPENROUTER_API_KEY (preferred) or ANTHROPIC_API_KEY"

let api_key_exn key = CCOption.get_exn_or __LOC__ (normalize_key key)

(* OpenRouter requires its own model slugs, not just the Anthropic API ID with an
   [anthropic/] prefix. Keep the mappings explicit for known Claude aliases so
   the OpenRouter path calls the same underlying Claude model family/version. *)
let normalize_anthropic_model_for_openrouter = function
  | "claude-opus-4-7" | "anthropic/claude-opus-4-7" -> "anthropic/claude-opus-4.7"
  | "claude-opus-4-6" | "anthropic/claude-opus-4-6" -> "anthropic/claude-opus-4.6"
  | "claude-sonnet-4-6" | "anthropic/claude-sonnet-4-6" -> "anthropic/claude-sonnet-4.6"
  | "claude-haiku-4-5-20251001" | "claude-haiku-4-5" | "anthropic/claude-haiku-4-5-20251001"
  | "anthropic/claude-haiku-4-5" ->
    "anthropic/claude-haiku-4.5"
  | "claude-sonnet-4-5-20250929" | "claude-sonnet-4-5" | "anthropic/claude-sonnet-4-5-20250929"
  | "anthropic/claude-sonnet-4-5" ->
    "anthropic/claude-sonnet-4.5"
  | "claude-opus-4-5-20251101" | "claude-opus-4-5" | "anthropic/claude-opus-4-5-20251101" | "anthropic/claude-opus-4-5"
    ->
    "anthropic/claude-opus-4.5"
  | "claude-opus-4-1-20250805" | "claude-opus-4-1" | "anthropic/claude-opus-4-1-20250805" | "anthropic/claude-opus-4-1"
    ->
    "anthropic/claude-opus-4.1"
  | "claude-sonnet-4-20250514" | "claude-sonnet-4-0" | "anthropic/claude-sonnet-4-20250514"
  | "anthropic/claude-sonnet-4-0" ->
    "anthropic/claude-sonnet-4"
  | "claude-opus-4-20250514" | "claude-opus-4-0" | "anthropic/claude-opus-4-20250514" | "anthropic/claude-opus-4-0" ->
    "anthropic/claude-opus-4"
  | model_id ->
  match String.starts_with ~prefix:"anthropic/" model_id with
  | true -> model_id
  | false -> "anthropic/" ^ model_id

let normalize_model_id provider model_id =
  match provider with
  | Anthropic -> model_id
  | Openrouter -> normalize_anthropic_model_for_openrouter model_id

(* Pin OpenRouter to Anthropic's own API: no third-party hosts, no quantized
   variants — keeps model behavior identical to the direct path. *)
let anthropic_upstream_prefs : Ai_provider_openrouter.Openrouter_options.provider_prefs =
  {
    order = [ "anthropic" ];
    allow_fallbacks = Some false;
    require_parameters = None;
    data_collection = None;
    only = [ "anthropic" ];
    ignore_ = [];
    quantizations = [];
    sort = None;
    max_price = None;
    zdr = None;
    preferred_min_throughput = None;
    preferred_max_latency = None;
    enforce_distillable_text = None;
  }

(* The SDK's [Ai_provider_openrouter.language_model] does not accept default
   provider options at construction; options are attached per-call via
   [Call_options.provider_options].  To pin every request to the Anthropic
   upstream regardless of what the caller passes, wrap the base model and merge
   our [provider_prefs] into each call's options.  We merge into any existing
   [Openrouter_options.t] (e.g. the reasoning config from {!thinking_options})
   rather than replacing it, since both share the single [Openrouter] key. *)
let pin_openrouter_model (base : Ai_provider.Language_model.t) : Ai_provider.Language_model.t =
  let module Base = (val base : Ai_provider.Language_model.S) in
  let with_pinning (opts : Ai_provider.Provider_options.t) =
    let existing =
      Option.default Ai_provider_openrouter.Openrouter_options.default
        (Ai_provider_openrouter.Openrouter_options.of_provider_options opts)
    in
    let pinned = { existing with provider = Some anthropic_upstream_prefs } in
    Ai_provider_openrouter.Openrouter_options.to_provider_options pinned
  in
  let pin (call : Ai_provider.Call_options.t) = { call with provider_options = with_pinning call.provider_options } in
  let module Pinned = struct
    let specification_version = Base.specification_version
    let provider = Base.provider
    let model_id = Base.model_id
    let generate call = Base.generate (pin call)
    let stream call = Base.stream (pin call)
  end in
  (module Pinned : Ai_provider.Language_model.S)

let language_model provider ~(secrets : Config_types.secrets) ~model_id =
  match provider with
  | Anthropic ->
    (* anthropic_api_key is guaranteed Some by resolve on this path. *)
    let api_key = api_key_exn secrets.anthropic_api_key in
    Ai_provider_anthropic.language_model ~api_key ~model:model_id ()
  | Openrouter ->
    let api_key = api_key_exn secrets.openrouter_api_key in
    let base = Ai_provider_openrouter.language_model ~api_key ~model:model_id () in
    pin_openrouter_model base

let thinking_options provider ~budget_tokens =
  match provider with
  | Anthropic ->
    let thinking : Ai_provider_anthropic.Thinking.t =
      { enabled = true; budget_tokens = Ai_provider_anthropic.Thinking.budget_exn budget_tokens }
    in
    let opts = { Ai_provider_anthropic.Anthropic_options.default with thinking = Some thinking } in
    Ai_provider_anthropic.Anthropic_options.to_provider_options opts
  | Openrouter ->
    let reasoning : Ai_provider_openrouter.Openrouter_options.reasoning_config =
      { enabled = Some true; exclude = None; budget = Max_tokens budget_tokens }
    in
    let opts = { Ai_provider_openrouter.Openrouter_options.default with reasoning = Some reasoning } in
    Ai_provider_openrouter.Openrouter_options.to_provider_options opts

let cached_input_options provider =
  match provider with
  | Anthropic ->
    Ai_provider_anthropic.Cache_control_options.with_cache_control
      ~cache_control:Ai_provider_anthropic.Cache_control.ephemeral Ai_provider.Provider_options.empty
  | Openrouter ->
    Ai_provider_openrouter.Cache_control_options.with_cache_control
      ~cache_control:Ai_provider_openrouter.Cache_control.ephemeral Ai_provider.Provider_options.empty

type usage = {
  cache_read : int;
  cache_write : int;
  cost : float option;
}

let empty_usage = { cache_read = 0; cache_write = 0; cost = None }

let usage_metadata provider meta =
  match provider with
  | Anthropic ->
    (* Anthropic cache counts are parsed from the raw body in agent_runner; see
       Task 5. There is no reported USD cost on the direct path. *)
    empty_usage
  | Openrouter ->
  match meta with
  | None -> empty_usage
  | Some m ->
  match Ai_provider.Provider_options.find Ai_provider_openrouter.Convert_usage.Openrouter_usage m with
  | None -> empty_usage
  | Some u ->
    let cost =
      match u.cost, u.upstream_inference_cost with
      | None, None -> None
      | Some c, None -> Some c
      | None, Some c -> Some c
      | Some c, Some upstream -> Some (c +. upstream)
    in
    { cache_read = u.cache_read_tokens; cache_write = u.cache_write_tokens; cost }
