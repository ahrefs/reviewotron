(** Application context: secrets and per-repository configuration management.
    Config is fetched lazily by source adapters when they support remote
    configuration. *)

(** The application context holding secrets and a per-repo config cache. *)
type t

(** Default path to the secrets file (["secrets.json"]). *)
val default_secrets_filepath : string

(** Default config filename fetched from repos ([".reviewotron.json"]). *)
val default_config_filename : string

(** Return a config with all defaults (equivalent to parsing ["{}"]). *)
val default_config : unit -> Config_types.config

(** Load a repository config file from disk. *)
val load_config_file : filepath:string -> (Config_types.config, string) result

(** Load [config_filename] from [root], returning defaults when the file is not
    present. Absolute [config_filename] values are used as-is. *)
val load_local_config : root:string -> config_filename:string -> (Config_types.config, string) result

(** Create a context by loading secrets and optionally state from disk.
    Config is fetched lazily by source adapters.

    [require_repos] defaults to [true] for webhook/server safety. Local-only
    commands can set it to [false] so a secrets file with ["repos": []] is
    accepted. *)
val create :
  secrets_filepath:string ->
  ?config_filename:string ->
  ?state_filepath:string ->
  ?require_repos:bool ->
  unit ->
  (t, string) result

(** Look up cached config by neutral repository key. Returns [None] if not yet
    fetched or explicitly set. *)
val find_config : t -> repo_key:string -> Config_types.config option

(** Cache config by neutral repository key. *)
val set_config : t -> repo_key:string -> Config_types.config -> unit

(** Get the effective configuration for a repository key.
    Returns the cached config if available, otherwise returns defaults. *)
val get_config : t -> repo_key:string -> Config_types.config

(** Look up the cached config for a repository. Returns [None] if not yet fetched. *)
val find_repo_config : t -> repo_url:string -> Config_types.config option

(** Cache a fetched config for a repository. *)
val set_repo_config : t -> repo_url:string -> Config_types.config -> unit

(** Compatibility wrapper for GitHub URL-keyed configuration. *)
val get_repo_config : t -> repo_url:string -> Config_types.config

(** Get the webhook secret for a repository, if configured. *)
val get_hook_secret : t -> repo_url:string -> string option

(** Get the auth configuration for a repository, if configured.
    Supports both personal access tokens and GitHub App installation auth. *)
val get_repo_auth : t -> repo_url:string -> Config_types.repo_auth option

(** Get the GitHub personal access token for a repository, if configured.
    Returns [None] for App installation auth — use {!get_repo_auth} instead. *)
val get_gh_token : t -> repo_url:string -> string option

(** Access the secrets configuration. *)
val secrets : t -> Config_types.secrets

(** Access the state handle. *)
val state : t -> State.t

(** The config filename to look for in repos (e.g. [".reviewotron.json"]). *)
val config_filename : t -> string

(** Construct a context directly. Useful for testing. *)
val make : secrets:Config_types.secrets -> ?config_filename:string -> ?state:State.t -> unit -> t
