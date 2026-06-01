(** Configuration types for Reviewotron: per-repo settings, auth, and secrets. *)

(** {2 Security pipeline enumerations} *)

(** Vulnerability class for security analysis routing. *)
type vuln_class =
  | Injection
  | Xss
  | Command_injection
  | Authn
  | Authz
  | Ssrf

val vuln_class_to_string : vuln_class -> string
val vuln_class_to_json : vuln_class -> Yojson.Basic.t
val vuln_class_of_json : Yojson.Basic.t -> vuln_class

(** All supported vulnerability classes. *)
val all_vuln_classes : vuln_class list

(** Confidence level for triage signals and analysis findings. *)
type confidence =
  | High
  | Medium
  | Low

(** All supported confidence levels. *)
val all_confidences : confidence list

(** Numeric rank for confidence levels — higher means more confident. *)
val confidence_rank : confidence -> int

val confidence_to_string : confidence -> string
val confidence_to_json : confidence -> Yojson.Basic.t
val confidence_of_json : Yojson.Basic.t -> confidence

(** Model performance tier for per-agent configuration in plugin settings.
    Structurally identical to {!Agent_runner.model_tier} but defined
    separately to avoid coupling config types to the agent runner. *)
type model_tier =
  | Fast
  | Standard
  | Strong

val model_tier_to_string : model_tier -> string
val model_tier_to_json : model_tier -> Yojson.Basic.t
val model_tier_of_json : Yojson.Basic.t -> model_tier

(** {2 Plugin configuration} *)

(** Configuration for the general review plugin. *)
type general_plugin_config = {
  enabled : bool;
  system_prompt_override : string option;
}

val general_plugin_config_to_json : general_plugin_config -> Yojson.Basic.t
val general_plugin_config_of_json : Yojson.Basic.t -> general_plugin_config
val default_general_plugin_config : general_plugin_config

(** Configuration for the security review plugin. *)
type security_plugin_config = {
  enabled : bool;
  vuln_classes : vuln_class list;
  always_analyze_vuln_classes : vuln_class list;
  triage_model_tier : model_tier;
  analysis_model_tier : model_tier;
  validator_model_tier : model_tier;
  confidence_threshold : confidence;
  memory_max_tokens : int;
}

val security_plugin_config_to_json : security_plugin_config -> Yojson.Basic.t
val security_plugin_config_of_json : Yojson.Basic.t -> security_plugin_config
val default_security_plugin_config : security_plugin_config

(** Aggregated review plugin configuration. *)
type review_plugins_config = {
  general : general_plugin_config;
  security : security_plugin_config;
}

val review_plugins_config_to_json : review_plugins_config -> Yojson.Basic.t
val review_plugins_config_of_json : Yojson.Basic.t -> review_plugins_config
val default_review_plugins_config : review_plugins_config

(** {2 Core configuration} *)

type config = {
  max_diff_lines : int;
  max_files : int;
  max_tokens_per_review : int;
  model : string;
  ignored_paths : string list;
  ignored_authors : string list;
  auto_review_pr_open : bool;
  auto_review_pr_sync : bool;
  review_pushes_to_develop : bool;
  auto_review_on_comment : bool;
  review_draft_prs : bool;
  system_prompt_override : string option;
  slack_channel : string option;
  show_review_cost : bool;
  review_plugins : review_plugins_config;
}
[@@deriving json]

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

type repo_config = {
  url : string;
  auth : repo_auth option;
  gh_hook_secret : string option;
}

val repo_config_to_json : repo_config -> Yojson.Basic.t
val repo_config_of_json : Yojson.Basic.t -> repo_config

type secrets = {
  repos : repo_config list;
  anthropic_api_key : string;
  slack_access_token : string option;
}
[@@deriving json]
