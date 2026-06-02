(** Shared HTTP request helper for the reviewotron application.
    Wraps [Web.http_request_lwt'] with common curl settings, preserving the
    HTTP status code so callers can branch on it without parsing error text. *)

(** An HTTP failure.  [status] is the HTTP status code when the request
    completed with a non-2xx response, or [None] for transport/curl errors
    (DNS, connection refused, timeout) where no HTTP status was received.
    [message] is a human-readable rendering for logs and string-only callers. *)
type error = {
  status : int option;
  message : string;
}

(** Human-readable rendering of an HTTP error (the [message] field). *)
val error_to_string : error -> string

val http_request :
  ?verbose:bool ->
  ?headers:string list ->
  ?body:[ `Form of (string * string) list | `Raw of string * string ] ->
  Devkit.Web.http_action ->
  string ->
  (string, error) result Lwt.t

(** [query_error_msg url error] wraps [error]'s message with the queried URL,
    preserving the status code. *)
val query_error_msg : string -> error -> error
