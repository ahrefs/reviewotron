(** GitHub webhook event parsing and signature validation. *)

(** Typed representation of the PR action field. *)
type pr_action =
  | Opened
  | Closed
  | Synchronize
  | Reopened
  | Edited
  | Ready_for_review
  | Other of string

(** Convert the raw [action] string from a PR webhook payload into a typed variant. *)
val pr_action_of_string : string -> pr_action

(** Supported webhook event types. *)
type event =
  | Pull_request of Github_types_t.pr_notification
  | Push of Github_types_t.commit_pushed_notification
  | Unknown of string

(** Extract the repository HTML URL from an event.
    Returns [""] for [Unknown] events. *)
val repo_url_of_event : event -> string

(** Validate a GitHub webhook HMAC-SHA256 signature.
    Uses constant-time comparison to prevent timing attacks. *)
val validate_signature : secret:string -> signature:string -> body:string -> (unit, string) result

(** Parse a GitHub webhook payload given its event type header and JSON body. *)
val parse_event : event_type:string -> body:string -> (event, string) result
