(** Shared HTTP request helper for the reviewotron application.
    Wraps [Web.http_request_lwt] with common curl settings. *)

val http_request :
  ?verbose:bool ->
  ?headers:string list ->
  ?body:[ `Form of (string * string) list | `Raw of string * string ] ->
  Devkit.Web.http_action ->
  string ->
  (string, string) result Lwt.t

(** [query_error_msg url error] formats an HTTP error message. *)
val query_error_msg : string -> string -> string
