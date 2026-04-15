(** Configuration types for Reviewotron: per-repo settings, auth, and secrets. *)

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
  system_prompt_override : string option;
  slack_channel : string option;
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
  config_override : config option;
}

val repo_config_to_json : repo_config -> Yojson.Basic.t
val repo_config_of_json : Yojson.Basic.t -> repo_config

type secrets = {
  repos : repo_config list;
  anthropic_api_key : string;
  slack_access_token : string option;
}
[@@deriving json]
