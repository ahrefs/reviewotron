(** Configuration types for Reviewotron: per-repo settings, auth, and secrets. *)

open Melange_json.Primitives

type config = {
  max_diff_lines : int; [@json.default 2000]
  max_files : int; [@json.default 50]
  max_tokens_per_review : int; [@json.default 100000]
  model : string; [@json.default "claude-sonnet-4-5-20250929"]
  ignored_paths : string list; [@json.default []]
  ignored_authors : string list; [@json.default []]
  auto_review_pr_open : bool; [@json.default true]
  auto_review_pr_sync : bool; [@json.default true]
  review_pushes_to_develop : bool; [@json.default true]
  system_prompt_override : string option; [@json.option]
  slack_channel : string option; [@json.option]
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
  config_override : config option;
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
  let fields = cons_opt_field "config_override" config_to_json rc.config_override fields in
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
    let config_override = nullable_field "config_override" config_of_json fields in
    { url; auth; gh_hook_secret; config_override }
  | _ -> Melange_json.of_json_error ~json "expected a JSON object"

type secrets = {
  repos : repo_config list;
  anthropic_api_key : string;
  slack_access_token : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]
