(** Retry helper for HTTP calls that distinguishes transient failures (network
    errors, 5xx, rate limits) from permanent ones (4xx, malformed requests),
    retrying only the former with exponential backoff. Classification matches on
    the typed {!Http_util.error}, not on rendered strings. *)

(** [is_retryable ~idempotent err] is [true] when a later attempt can plausibly
    succeed without risking a duplicate mutation. A curl failure before the
    request is sent (DNS, proxy, TCP connect, TLS handshake) and an HTTP 429 are
    always retryable. When [idempotent], so are in-flight curl failures
    (timeout, dropped or partial transfer) and HTTP 5xx, since GitHub may have
    applied the request before failing. Other curl codes and 4xx statuses are
    never retryable. *)
val is_retryable : idempotent:bool -> Http_util.error -> bool

(** [with_retry ~idempotent ~label f] runs the thunk [f], retrying on transient failures
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
  idempotent:bool ->
  label:string ->
  (unit -> ('a, Http_util.error) result Lwt.t) ->
  ('a, Http_util.error) result Lwt.t
