type t =
  | Anthropic
  | Openrouter

let nonempty s =
  match String.trim s with
  | "" -> None
  | s -> Some s

let normalize_key key = Stdlib.Option.bind key nonempty

(* The SDK builds request URLs as [base_url ^ "/chat/completions"], so a trailing
   slash would yield a double slash.  Strip them defensively; the second
   [nonempty] leaves an all-slashes value "absent" rather than "".  The captured
   URL also survives the {!route_openrouter_model} wrapper, so the cross-lab
   fallback routes through the same endpoint. *)
let base_url_of_env raw =
  Stdlib.Option.bind (normalize_key raw) (fun url -> nonempty (CCString.rdrop_while (Char.equal '/') url))

let openrouter_base_url () = base_url_of_env (Sys.getenv_opt "OPENROUTER_BASE_URL")

(* Combine two optional USD costs: [None] means "no figure reported", a lone
   figure passes through, and two figures sum.  Shared by the per-step OpenRouter
   totalling in {!Agent_runner} and the [cost]/[upstream_inference_cost]
   combination below, so both treat "no figure" identically. *)
let sum_cost a b =
  match a, b with
  | None, None -> None
  | Some c, None | None, Some c -> Some c
  | Some x, Some y -> Some (x +. y)

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
  | "claude-sonnet-5" | "anthropic/claude-sonnet-5" -> "anthropic/claude-sonnet-5"
  | "claude-opus-4-8" | "anthropic/claude-opus-4-8" -> "anthropic/claude-opus-4.8"
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

let openrouter_fallback_models = function
  | "anthropic/claude-opus-4.8" -> [ "openai/gpt-5.6-sol" ]
  | "anthropic/claude-sonnet-5" -> [ "openai/gpt-5.6-terra" ]
  | "anthropic/claude-haiku-4.5" -> [ "openai/gpt-5.6-luna" ]
  | _ -> []

(* Keep source-bearing review prompts on the model labs' own endpoints while
   allowing an independent OpenAI fallback when Anthropic is unavailable. *)
let openrouter_provider_prefs : Ai_provider_openrouter.Openrouter_options.provider_prefs =
  {
    order = [];
    allow_fallbacks = Some true;
    require_parameters = Some true;
    data_collection = Some "deny";
    only = [ "anthropic"; "openai" ];
    ignore_ = [];
    quantizations = [];
    sort = None;
    max_price = None;
    zdr = None;
    preferred_min_throughput = None;
    preferred_max_latency = None;
    enforce_distillable_text = None;
  }

let anthropic_upstream_prefs = openrouter_provider_prefs

(* The SDK's [Ai_provider_openrouter.language_model] does not accept default
   provider options at construction; options are attached per-call via
   [Call_options.provider_options]. Wrap the base model and merge the cross-lab
   fallback policy into every call, preserving other OpenRouter options such as
   reasoning config because they share the same provider-options key. *)
let route_openrouter_model (base : Ai_provider.Language_model.t) : Ai_provider.Language_model.t =
  let module Base = (val base : Ai_provider.Language_model.S) in
  let with_routing (opts : Ai_provider.Provider_options.t) =
    let existing =
      Option.default Ai_provider_openrouter.Openrouter_options.default
        (Ai_provider_openrouter.Openrouter_options.of_provider_options opts)
    in
    let routed =
      { existing with models = openrouter_fallback_models Base.model_id; provider = Some openrouter_provider_prefs }
    in
    Ai_provider_openrouter.Openrouter_options.to_provider_options routed
  in
  let route (call : Ai_provider.Call_options.t) = { call with provider_options = with_routing call.provider_options } in
  let module Routed = struct
    let specification_version = Base.specification_version
    let provider = Base.provider
    let model_id = Base.model_id
    let generate call = Base.generate (route call)
    let stream call = Base.stream (route call)
  end in
  (module Routed : Ai_provider.Language_model.S)

let language_model provider ~(secrets : Config_types.secrets) ~model_id =
  match provider with
  | Anthropic ->
    (* anthropic_api_key is guaranteed Some by resolve on this path. *)
    let api_key = api_key_exn secrets.anthropic_api_key in
    Ai_provider_anthropic.language_model ~api_key ~model:model_id ()
  | Openrouter ->
    let api_key = api_key_exn secrets.openrouter_api_key in
    (* [?base_url] absent keeps the SDK default (https://openrouter.ai/api/v1);
       set it to route through an OpenAI-compatible proxy on a restricted host. *)
    let base_url = openrouter_base_url () in
    let base = Ai_provider_openrouter.language_model ~api_key ?base_url ~model:model_id () in
    route_openrouter_model base

let thinking_options provider ~model_id ~budget_tokens =
  match provider with
  | Anthropic ->
    let capabilities = Ai_provider_anthropic.Model_catalog.(capabilities (of_model_id model_id)) in
    let thinking : Ai_provider_anthropic.Thinking.t option =
      match capabilities.thinking with
      | Some { manual = true; adaptive = true; _ } | Some { manual = true; adaptive = false; _ } ->
        Some (Enabled { budget_tokens = Ai_provider_anthropic.Thinking.budget_exn budget_tokens; display = None })
      | Some { manual = false; adaptive = true; _ } -> Some (Adaptive { display = None })
      | Some { manual = false; adaptive = false; _ } | None -> None
    in
    (match thinking with
    | None -> Ai_provider.Provider_options.empty
    | Some thinking ->
      let opts = { Ai_provider_anthropic.Anthropic_options.default with thinking = Some thinking } in
      Ai_provider_anthropic.Anthropic_options.to_provider_options opts)
  | Openrouter ->
    let reasoning : Ai_provider_openrouter.Openrouter_options.reasoning_config =
      { enabled = Some true; exclude = None; budget = Max_tokens budget_tokens }
    in
    let opts = { Ai_provider_openrouter.Openrouter_options.default with reasoning = Some reasoning } in
    Ai_provider_openrouter.Openrouter_options.to_provider_options opts

let openrouter_effort = function
  | Config_types.Effort.Low -> Ai_provider_openrouter.Openrouter_options.Low
  | Medium -> Medium
  | High -> High
  | Xhigh -> Xhigh

(* OpenRouter maps [reasoning.effort] to Anthropic [output_config.effort] for
   Claude 4.6+ models.  The direct Anthropic SDK path cannot encode effort
   until its typed [output_config] grows that field. *)
let effort_options provider ~effort =
  match provider with
  | Anthropic -> Ai_provider.Provider_options.empty
  | Openrouter ->
    let reasoning : Ai_provider_openrouter.Openrouter_options.reasoning_config =
      { enabled = Some true; exclude = None; budget = Effort (openrouter_effort effort) }
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
    let cost = sum_cost u.cost u.upstream_inference_cost in
    { cache_read = u.cache_read_tokens; cache_write = u.cache_write_tokens; cost }
