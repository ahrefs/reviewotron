(** Retry helper for HTTP calls that distinguishes transient failures (network
    errors, 5xx, rate limits) from permanent ones (4xx, malformed requests),
    retrying only the former with exponential backoff. Classification matches on
    the typed {!Http_util.error}, not on rendered strings. *)

(** [is_retryable err] is [true] when the error is a transient curl transport
    failure (DNS/connect/timeout/TLS/dropped transfer) or an HTTP 5xx/429
    response. Other curl codes and 4xx statuses are not retryable. *)
val is_retryable : Http_util.error -> bool

(** [with_retry ~label f] runs the thunk [f], retrying on transient failures
    (per {!is_retryable}) with exponential backoff.

    @param max_attempts total attempts including the first (default 4).
    @param base_delay seconds before the first retry, doubled each time
           (default 1.0, giving 1s/2s/4s).

    Returns on the first [Ok], on the first non-retryable [Error], or with the
    final [Error] once attempts are exhausted. [label] identifies the operation
    in log messages. *)
val with_retry :
  ?max_attempts:int ->
  ?base_delay:float ->
  label:string ->
  (unit -> ('a, Http_util.error) result Lwt.t) ->
  ('a, Http_util.error) result Lwt.t
