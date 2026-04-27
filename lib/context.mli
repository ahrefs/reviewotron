(** Application context: secrets and per-repo configuration management.
    Config is fetched from each repo's default branch (like monorobot). *)

(** The application context holding secrets and a per-repo config cache. *)
type t

(** Default path to the secrets file (["secrets.json"]). *)
val default_secrets_filepath : string

(** Default config filename fetched from repos ([".reviewotron.json"]). *)
val default_config_filename : string

(** Return a config with all defaults (equivalent to parsing ["{}"]). *)
val default_config : unit -> Config_types.config

(** Create a context by loading secrets and optionally state from disk.
    Config is fetched lazily from each repo via the GitHub API.
    Returns [Error] if secrets cannot be loaded or contain no repos. *)
val create : secrets_filepath:string -> ?config_filename:string -> ?state_filepath:string -> unit -> (t, string) result

(** Look up the cached config for a repository. Returns [None] if not yet fetched. *)
val find_repo_config : t -> repo_url:string -> Config_types.config option

(** Cache a fetched config for a repository. *)
val set_repo_config : t -> repo_url:string -> Config_types.config -> unit

(** Get the effective configuration for a repository.
    Returns the cached config if available, otherwise returns defaults. *)
val get_config : t -> repo_url:string -> Config_types.config

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
