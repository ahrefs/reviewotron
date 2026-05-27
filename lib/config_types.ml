(** Configuration types for Reviewotron: per-repo settings, auth, and secrets. *)

open Melange_json.Primitives

(** Vulnerability class for security analysis routing. *)
type vuln_class =
  | Injection
  | Xss
  | Command_injection
  | Authn
  | Authz
  | Ssrf

let vuln_class_to_string = function
  | Injection -> "injection"
  | Xss -> "xss"
  | Command_injection -> "command_injection"
  | Authn -> "authn"
  | Authz -> "authz"
  | Ssrf -> "ssrf"

let vuln_class_to_json vc = `String (vuln_class_to_string vc)

let vuln_class_of_json = function
  | `String "injection" -> Injection
  | `String "xss" -> Xss
  | `String "command_injection" -> Command_injection
  | `String "authn" -> Authn
  | `String "authz" -> Authz
  | `String "ssrf" -> Ssrf
  | json -> Melange_json.of_json_error ~json "expected a vuln_class string"

(** All supported vulnerability classes. *)
let all_vuln_classes = [ Injection; Xss; Command_injection; Authn; Authz; Ssrf ]

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
let confidence_to_json c = `String (confidence_to_string c)

let confidence_of_json = function
  | `String "high" -> High
  | `String "medium" -> Medium
  | `String "low" -> Low
  | json -> Melange_json.of_json_error ~json "expected a confidence string"

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

(** Configuration for the general review plugin. *)
type general_plugin_config = {
  enabled : bool; [@json.default true]
  system_prompt_override : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

(** Configuration for the security review plugin. *)
type security_plugin_config = {
  enabled : bool; [@json.default false]
  vuln_classes : vuln_class list; [@json.default all_vuln_classes]
  always_analyze_vuln_classes : vuln_class list; [@json.default []]
  triage_model_tier : model_tier; [@json.default Fast]
  analysis_model_tier : model_tier; [@json.default Standard]
  validator_model_tier : model_tier; [@json.default Standard]
  confidence_threshold : confidence; [@json.default Medium]
  memory_max_tokens : int; [@json.default 5000]
}
[@@deriving json] [@@json.allow_extra_fields]

let default_general_plugin_config = { enabled = true; system_prompt_override = None }

let default_security_plugin_config =
  {
    enabled = false;
    vuln_classes = all_vuln_classes;
    always_analyze_vuln_classes = [];
    triage_model_tier = Fast;
    analysis_model_tier = Standard;
    validator_model_tier = Standard;
    confidence_threshold = Medium;
    memory_max_tokens = 5000;
  }

(** Aggregated review plugin configuration. *)
type review_plugins_config = {
  general : general_plugin_config; [@json.default default_general_plugin_config]
  security : security_plugin_config; [@json.default default_security_plugin_config]
}
[@@deriving json] [@@json.allow_extra_fields]

let default_review_plugins_config =
  { general = default_general_plugin_config; security = default_security_plugin_config }

type config = {
  max_diff_lines : int; [@json.default 2000]
  max_files : int; [@json.default 50]
  max_tokens_per_review : int; [@json.default 100000]
  model : string; [@json.default "claude-sonnet-4-6"]
  ignored_paths : string list; [@json.default []]
  ignored_authors : string list; [@json.default []]
  auto_review_pr_open : bool; [@json.default false]
  auto_review_pr_sync : bool; [@json.default false]
  review_pushes_to_develop : bool; [@json.default false]
  auto_review_on_comment : bool; [@json.default false]
  review_draft_prs : bool; [@json.default false]
  system_prompt_override : string option; [@json.option]
  slack_channel : string option; [@json.option]
  show_review_cost : bool; [@json.default false]
  review_plugins : review_plugins_config; [@json.default default_review_plugins_config]
}
[@@deriving json] [@@json.allow_extra_fields]

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
  anthropic_api_key : string;
  slack_access_token : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]
