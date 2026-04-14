(** GitHub authentication: personal tokens and GitHub App installation tokens. *)

(** A resolved authorization header value (e.g. ["token ghp_..."] or ["Bearer ghs_..."]). *)
type token = string

(** [get_token auth] returns an authorization token string suitable for the
    [Authorization] header.  For [GH_token] it returns immediately; for
    [AppInstallation] it generates a JWT, exchanges it for an installation
    access token (cached for up to 50 minutes), and returns the result. *)
val get_token : Config_t.repo_auth -> (token, string) result Lwt.t

(** [auth_header auth] is a convenience wrapper that returns a complete
    [("Authorization", "<scheme> <token>")] pair. *)
val auth_header : Config_t.repo_auth -> (string * string, string) result Lwt.t

(** [invalidate_cache ()] clears all cached installation tokens.
    Useful for testing or when a token is known to be revoked. *)
val invalidate_cache : unit -> unit
