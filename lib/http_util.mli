(** Shared HTTP request helper for the reviewotron application.
    Wraps [Web.http_request_lwt'] with common curl settings, surfacing a typed
    error so callers (e.g. {!Github_retry}) can classify failures without
    parsing rendered strings. *)

type error =
  | Transport of Curl.curlCode  (** curl-level failure with no HTTP response: DNS, connect, timeout, TLS. *)
  | Status of int * string  (** a completed request with a non-2xx status code, carrying its body. *)

(** Render an {!error} for logging — ["(<errno>) <strerror>"] or ["http <code>: <body>"]. *)
val error_to_string : error -> string

val http_request :
  ?verbose:bool ->
  ?headers:string list ->
  ?body:[ `Form of (string * string) list | `Raw of string * string ] ->
  Devkit.Web.http_action ->
  string ->
  (string, error) result Lwt.t

(** [query_error_msg url error] formats an HTTP error message for a given URL. *)
val query_error_msg : string -> error -> string
