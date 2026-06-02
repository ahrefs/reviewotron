(** Retry helper for GitHub API calls that distinguishes transient failures
    (network errors, 5xx, rate limits) from permanent ones (4xx, parse/auth
    errors), retrying only the former with exponential backoff. *)

(** [is_retryable msg] is [true] when the [Error] string from a GitHub API call
    represents a transient failure worth retrying: a curl transport error
    (DNS/connect/timeout, rendered as ["(<errno>) ..."]) or an HTTP 5xx/429
    response (rendered as ["http <code>: ..."]). Client errors (4xx) and
    post-fetch logic errors (JSON parse, missing auth) are not retryable. *)
val is_retryable : string -> bool

(** [with_retry ~label f] runs the thunk [f], retrying on transient failures
    (per {!is_retryable}) with exponential backoff.

    @param max_attempts total attempts including the first (default 4).
    @param base_delay seconds before the first retry, doubled each time
           (default 1.0, giving 1s/2s/4s).

    Returns on the first [Ok], on the first non-retryable [Error], or with the
    final [Error] once attempts are exhausted. [label] is used in log messages
    to identify the operation. *)
val with_retry :
  ?max_attempts:int ->
  ?base_delay:float ->
  label:string ->
  (unit -> ('a, string) result Lwt.t) ->
  ('a, string) result Lwt.t
