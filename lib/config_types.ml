(** Configuration types for Reviewotron: per-repo settings, auth, and secrets. *)

open Melange_json.Primitives
open Ppx_deriving_jsonschema_runtime.Primitives.Melange_json

(** Vulnerability class for security analysis routing. *)
type vuln_class =
  | Injection
  | Xss
  | Command_injection
  | Authn
  | Authz
  | Ssrf
  | Policy_regression

let vuln_class_to_string = function
  | Injection -> "injection"
  | Xss -> "xss"
  | Command_injection -> "command_injection"
  | Authn -> "authn"
  | Authz -> "authz"
  | Ssrf -> "ssrf"
  | Policy_regression -> "policy_regression"

let vuln_class_to_json vc = `String (vuln_class_to_string vc)

let vuln_class_of_json = function
  | `String "injection" -> Injection
  | `String "xss" -> Xss
  | `String "command_injection" -> Command_injection
  | `String "authn" -> Authn
  | `String "authz" -> Authz
  | `String "ssrf" -> Ssrf
  | `String "policy_regression" -> Policy_regression
  | json -> Melange_json.of_json_error ~json "expected a vuln_class string"

(** All supported vulnerability classes. *)
let all_vuln_classes = [ Injection; Xss; Command_injection; Authn; Authz; Ssrf; Policy_regression ]

(* Schema for a variant serialized as one of a fixed set of lowercase strings. *)
let string_enum_jsonschema ~enum ~description : Yojson.Basic.t =
  `Assoc
    [ "type", `String "string"; "enum", `List (List.map (fun s -> `String s) enum); "description", `String description ]

let vuln_class_jsonschema =
  string_enum_jsonschema
    ~enum:(List.map vuln_class_to_string all_vuln_classes)
    ~description:"Vulnerability class scanned by the security plugin."

(** Confidence level for triage signals and analysis findings. *)
type confidence =
  | High
  | Medium
  | Low

let confidence_to_string = function
  | High -> "high"
  | Medium -> "medium"
  | Low -> "low"

let all_confidences = [ High; Medium; Low ]

(** Numeric rank for confidence levels — higher means more confident.
    Used to compare against a configured threshold. *)
let confidence_rank = function
  | High -> 3
  | Medium -> 2
  | Low -> 1

let confidence_to_json c = `String (confidence_to_string c)

let confidence_of_json = function
  | `String "high" -> High
  | `String "medium" -> Medium
  | `String "low" -> Low
  | json -> Melange_json.of_json_error ~json "expected a confidence string"

let confidence_jsonschema =
  string_enum_jsonschema
    ~enum:(List.map confidence_to_string all_confidences)
    ~description:"Confidence level: high, medium, or low."

(** Model performance tier for per-agent configuration in plugin settings.
    Structurally identical to {!Agent_runner.model_tier} but defined
    separately to avoid coupling config types to the agent runner. *)
type model_tier =
  | Fast
  | Standard
  | Strong

let model_tier_to_string = function
  | Fast -> "fast"
  | Standard -> "standard"
  | Strong -> "strong"

let model_tier_to_json mt = `String (model_tier_to_string mt)

let model_tier_of_json = function
  | `String "fast" -> Fast
  | `String "standard" -> Standard
  | `String "strong" -> Strong
  | json -> Melange_json.of_json_error ~json "expected a model_tier string"

let all_model_tiers = [ Fast; Standard; Strong ]

let model_tier_jsonschema =
  string_enum_jsonschema
    ~enum:(List.map model_tier_to_string all_model_tiers)
    ~description:"Model tier: fast (Haiku), standard (Sonnet), or strong (Opus)."

(** OpenRouter reasoning-effort levels supported by the installed SDK.

    [Max] is intentionally absent: ocaml-ai-sdk 0.4 cannot encode it yet.
    Direct Anthropic support will use its own native [output_config] path once
    the SDK exposes that field. *)
module Effort = struct
  type t =
    | Low
    | Medium
    | High
    | Xhigh

  let to_string = function
    | Low -> "low"
    | Medium -> "medium"
    | High -> "high"
    | Xhigh -> "xhigh"

  let t_to_json effort = `String (to_string effort)

  let to_json = t_to_json

  let t_of_json = function
    | `String "low" -> Low
    | `String "medium" -> Medium
    | `String "high" -> High
    | `String "xhigh" -> Xhigh
    | json -> Melange_json.of_json_error ~json "expected an effort string"

  let of_json = t_of_json

  let t_jsonschema =
    string_enum_jsonschema ~enum:[ "low"; "medium"; "high"; "xhigh" ] ~description:"OpenRouter reasoning effort level."
end

(** Configuration for the general review plugin.

    The raw [@@deriving json] codec lives inside {!General_plugin_config_codec}
    so that the top-level [general_plugin_config_of_json] below can wrap it with
    validation. This ordering matters: {!review_plugins_config} (defined further
    down) is itself derived, and its generated decoder resolves the field
    decoder by the name [general_plugin_config_of_json] via ordinary name
    resolution at that point in the file. Because the validating wrapper is
    defined BEFORE {!review_plugins_config}, every real load path
    ([config_of_json] → [review_plugins_config_of_json] →
    [general_plugin_config_of_json]) goes through the validation. *)
module General_plugin_config_codec = struct
  type t = {
    enabled : bool; [@json.default true] [@jsonschema.description "Run the general LLM code review (default true)."]
    system_prompt_override : string option;
       [@json.option] [@jsonschema.description "Replace the general review system prompt entirely."]
    scout_enabled : bool;
       [@json.default true]
       [@jsonschema.description
         "Run the scout → deep-reviewer pipeline (default true). When false, fall back to the legacy single-pass \
          general review."]
    scout_model_tier : model_tier;
       [@json.default Standard] [@jsonschema.description "Model tier for the general scout agent."]
    deep_reviewer_model_tier : model_tier;
       [@json.default Strong] [@jsonschema.description "Model tier for the general deep-reviewer agent."]
    max_leads : int;
       [@json.default 10]
       [@jsonschema.description "Maximum investigation leads passed from the scout to the deep reviewer."]
  }
  [@@deriving json, jsonschema] [@@json.allow_extra_fields]
end

type general_plugin_config = General_plugin_config_codec.t = {
  enabled : bool;
  system_prompt_override : string option;
  scout_enabled : bool;
  scout_model_tier : model_tier;
  deep_reviewer_model_tier : model_tier;
  max_leads : int;
}

let general_plugin_config_to_json = General_plugin_config_codec.to_json
let general_plugin_config_jsonschema = General_plugin_config_codec.t_jsonschema

(** Decode a {!general_plugin_config}, rejecting an out-of-range [max_leads].
    [max_leads] caps the investigation leads handed from the scout to the deep
    reviewer; a value below 1 is nonsensical: [0] silently disables the entire
    deep pass (the pipeline reads an empty lead list as "scout found nothing"),
    and a negative value silently defeats the cap. We fail fast at parse time
    rather than clamp, using the same [Melange_json.of_json_error] idiom the
    derived decoders use so the failure propagates on the normal config-load
    error channel. *)
let general_plugin_config_of_json (json : Yojson.Basic.t) : general_plugin_config =
  let cfg = General_plugin_config_codec.of_json json in
  match cfg.max_leads with
  | n when n < 1 ->
    Melange_json.of_json_error ~json
      (Printf.sprintf "max_leads must be >= 1 (got %d): 0 disables the deep review pass and negatives defeat the cap" n)
  | _ -> cfg

(** Configuration for the security review plugin. *)
type security_plugin_config = {
  enabled : bool;
     [@json.default false]
     [@jsonschema.description
       "Run the multi-agent security pipeline. Off by default for webhooks; on by default in local review-diff / \
        review-path mode (disable with --no-security)."]
  vuln_classes : vuln_class list;
     [@json.default all_vuln_classes] [@jsonschema.description "Vulnerability classes to scan for."]
  always_analyze_vuln_classes : vuln_class list;
     [@json.default []]
     [@jsonschema.description "Classes that bypass confidence_threshold (and are implicitly enabled)."]
  triage_model_tier : model_tier; [@json.default Fast] [@jsonschema.description "Model tier for the triage agent."]
  analysis_model_tier : model_tier;
     [@json.default Standard] [@jsonschema.description "Model tier for per-class analysis agents."]
  analysis_effort : Effort.t option;
     [@json.option]
     [@jsonschema.description
       "OpenRouter reasoning effort for per-class analysis agents. Unset keeps the provider default; direct Anthropic \
        calls cannot encode this until ocaml-ai-sdk adds native effort support."]
  validator_model_tier : model_tier;
     [@json.default Standard] [@jsonschema.description "Model tier for the adversarial validator."]
  confidence_threshold : confidence;
     [@json.default Medium] [@jsonschema.description "Minimum triage confidence to trigger analysis."]
  memory_max_tokens : int;
     [@json.default 5000] [@jsonschema.description "Target size limit for the repo security memory."]
  metrics_artifacts : bool;
     [@json.default false]
     [@jsonschema.description
       "Write compact security metrics artifacts (manifest.json, metrics.json, fetch_stats.json) under the per-review \
        debug directory. Off by default."]
  debug_artifacts : bool;
     [@json.default false]
     [@jsonschema.description
       "Write full redacted security debug artifacts, including stage inputs and outputs, under the per-review debug \
        directory. Sensitive and off by default."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

let default_general_plugin_config =
  {
    enabled = true;
    system_prompt_override = None;
    scout_enabled = true;
    scout_model_tier = Standard;
    deep_reviewer_model_tier = Strong;
    max_leads = 10;
  }

let default_security_plugin_config =
  {
    enabled = false;
    vuln_classes = all_vuln_classes;
    always_analyze_vuln_classes = [];
    triage_model_tier = Fast;
    analysis_model_tier = Standard;
    analysis_effort = None;
    validator_model_tier = Standard;
    confidence_threshold = Medium;
    memory_max_tokens = 5000;
    metrics_artifacts = false;
    debug_artifacts = false;
  }

(** Aggregated review plugin configuration. *)
type review_plugins_config = {
  general : general_plugin_config;
     [@json.default default_general_plugin_config] [@jsonschema.description "General code-review plugin settings."]
  security : security_plugin_config;
     [@json.default default_security_plugin_config] [@jsonschema.description "Security-analysis plugin settings."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

let default_review_plugins_config =
  { general = default_general_plugin_config; security = default_security_plugin_config }

type config = {
  max_diff_lines : int;
     [@json.default 2000]
     [@jsonschema.description
       "Maximum total diff lines to review; larger changes are skipped (raise for whole folders)."]
  max_files : int;
     [@json.default 50] [@jsonschema.description "Maximum number of files to review (raise for whole-folder reviews)."]
  max_tokens_per_review : int;
     [@json.default 100000] [@jsonschema.description "Token budget hint for the review agent."]
  model : string option;
     [@json.option]
     [@jsonschema.description
       "Explicit model ID override for the general deep reviewer. When absent, deep_reviewer_model_tier decides."]
  ignored_paths : string list;
     [@json.default []] [@jsonschema.description "Glob patterns (\\* wildcard) for files to exclude from review."]
  ignore_generated_files : bool;
     [@json.default true]
     [@jsonschema.description
       "Exclude conservatively detected generated files before file and line limits are enforced. Set false to review \
        generated artifacts."]
  ignored_authors : string list;
     [@json.default []] [@jsonschema.description "Authors whose changes are skipped (webhook mode)."]
  auto_review_pr_open : bool;
     [@json.default false] [@jsonschema.description "Review PRs on open/reopen (webhook mode)."]
  auto_review_pr_sync : bool;
     [@json.default false] [@jsonschema.description "Review PRs on new commits (webhook mode)."]
  review_pushes_to_develop : bool;
     [@json.default false] [@jsonschema.description "Review pushes to develop (webhook mode)."]
  auto_review_on_comment : bool;
     [@json.default false] [@jsonschema.description "Review on a REVIEW comment (webhook mode)."]
  review_draft_prs : bool;
     [@json.default false] [@jsonschema.description "Include draft PRs in auto-review (webhook mode)."]
  system_prompt_override : string option;
     [@json.option] [@jsonschema.description "Replace the default general review system prompt entirely."]
  slack_channel : string option;
     [@json.option] [@jsonschema.description "Slack channel for push review notifications (webhook mode)."]
  show_review_cost : bool; [@json.default false] [@jsonschema.description "Append a cost summary footer to the review."]
  review_plugins : review_plugins_config;
     [@json.default default_review_plugins_config] [@jsonschema.description "Per-plugin configuration."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

let config_help_json () = Yojson.Basic.pretty_to_string config_jsonschema

type app_installation_cfg = {
  installation_id : string;
  client_id : string;
  pem : string;
}
[@@deriving json]

type repo_auth =
  | GH_token of string
  | AppInstallation of app_installation_cfg
[@@deriving json]

(** [repo_config] uses manual serialization to handle the legacy [gh_token]
    field. Old config files may use [{"gh_token": "tok"}] instead of the
    current [{"auth": ["GH_token", "tok"]}] format. This adapter logic makes
    both formats work. Manual JSON is required here because the legacy format
    has a different structure — PRD rule "no manual JSON unless impossible". *)
type repo_config = {
  url : string;
  auth : repo_auth option;
  gh_hook_secret : string option;
}

(** Normalize legacy [gh_token] field into [auth] variant representation. *)
let normalize_repo_config_json (json : Yojson.Basic.t) : Yojson.Basic.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (k, v) ->
           match k with
           | "gh_token" -> "auth", `List [ `String "GH_token"; v ]
           | _ -> k, v)
         fields)
  | _ -> json

let cons_opt_field name to_json opt fields =
  match opt with
  | Some v -> (name, to_json v) :: fields
  | None -> fields

let repo_config_to_json (rc : repo_config) : Yojson.Basic.t =
  let fields = [ "url", `String rc.url ] in
  let fields = cons_opt_field "auth" repo_auth_to_json rc.auth fields in
  let fields = cons_opt_field "gh_hook_secret" string_to_json rc.gh_hook_secret fields in
  `Assoc (List.rev fields)

let nullable_field name parse fields =
  match List.assoc_opt name fields with
  | Some `Null | None -> None
  | Some v -> Some (parse v)

let repo_config_of_json (json : Yojson.Basic.t) : repo_config =
  let json = normalize_repo_config_json json in
  match json with
  | `Assoc fields ->
    let url =
      match List.assoc_opt "url" fields with
      | Some (`String s) -> s
      | _ -> Melange_json.of_json_error ~json "expected field \"url\""
    in
    let auth = nullable_field "auth" repo_auth_of_json fields in
    let gh_hook_secret = nullable_field "gh_hook_secret" string_of_json fields in
    { url; auth; gh_hook_secret }
  | _ -> Melange_json.of_json_error ~json "expected a JSON object"

type secrets = {
  repos : repo_config list;
  anthropic_api_key : string option; [@json.option]
  openrouter_api_key : string option; [@json.option]
  slack_access_token : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]
