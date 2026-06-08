open Devkit

let log = Log.from "github_retry"

(* curl transport failures worth retrying: transient network conditions that a
   later attempt can plausibly clear (DNS, connect, timeout, dropped/partial
   transfers, TLS handshake). Other curl codes (malformed URL, auth, etc.) are
   deterministic and must not be retried. The binding has ~90 constructors, so
   we enumerate the retryable set and let everything else fall through. *)
let is_retryable_curl_code = function
  | Curl.CURLE_COULDNT_RESOLVE_PROXY | Curl.CURLE_COULDNT_RESOLVE_HOST | Curl.CURLE_COULDNT_CONNECT
  | Curl.CURLE_OPERATION_TIMEOUTED | Curl.CURLE_PARTIAL_FILE | Curl.CURLE_GOT_NOTHING | Curl.CURLE_SEND_ERROR
  | Curl.CURLE_RECV_ERROR | Curl.CURLE_SSL_CONNECT_ERROR ->
    true
  | _ -> false

(** [is_retryable err] decides whether an {!Http_util.error} represents a
    transient failure worth retrying: a retryable curl transport error, an HTTP
    5xx (server hiccup), or a 429 (secondary rate limit). Client errors (4xx
    other than 429) are permanent for the same request and fail fast. *)
let is_retryable = function
  | Http_util.Transport code -> is_retryable_curl_code code
  | Http_util.Status (429, _) -> true
  | Http_util.Status (code, _) -> code >= 500 && code <= 599

(** [with_retry ~label f] runs the thunk [f], retrying on transient failures
    (per {!is_retryable}) with exponential backoff. [f] re-runs from scratch
    each attempt.

    Up to [max_attempts] total attempts (default 4); the delay starts at
    [base_delay] (default 1s) and doubles each time (1s, 2s, 4s). Returns on the
    first [Ok], on the first non-retryable [Error], or with the final [Error]
    once attempts are exhausted. *)
let with_retry ?(max_attempts = 4) ?(base_delay = 1.0) ~label f =
  let rec attempt n delay =
    match%lwt f () with
    | Ok _ as ok -> Lwt.return ok
    | Error err as error ->
    match () with
    | () when n >= max_attempts ->
      log#warn "%s failed after %d attempts: %s" label n (Http_util.error_to_string err);
      Lwt.return error
    | () when not (is_retryable err) ->
      log#warn "%s failed with non-retryable error: %s" label (Http_util.error_to_string err);
      Lwt.return error
    | () ->
      log#warn "%s failed (attempt %d/%d, retrying in %.0fs): %s" label n max_attempts delay
        (Http_util.error_to_string err);
      let%lwt () = Lwt_unix.sleep delay in
      attempt (n + 1) (delay *. 2.0)
  in
  attempt 1 base_delay
