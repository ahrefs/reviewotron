(** Shared HTTP request helper for the reviewotron application.
    Wraps [Web.http_request_lwt'] with common curl settings, surfacing a typed
    error so callers can classify failures without parsing rendered strings. *)

type error =
  | Transport of Curl.curlCode  (** curl-level failure with no HTTP response: DNS, connect, timeout, TLS. *)
  | Status of int * string  (** a completed request with a non-2xx status code, carrying its body. *)
  | Local of string  (** request setup failure before HTTP, such as missing auth or an unparseable repo URL. *)

(** Render an {!error} for logging. *)
val error_to_string : error -> string

val http_request :
  ?verbose:bool ->
  ?headers:string list ->
  ?body:[ `Form of (string * string) list | `Raw of string * string ] ->
  Devkit.Web.http_action ->
  string ->
  (string, error) result Lwt.t

(** [query_error_msg url error] wraps [error]'s rendered message with the queried
    URL, preserving HTTP status codes for callers that branch on them. *)
val query_error_msg : string -> error -> error
