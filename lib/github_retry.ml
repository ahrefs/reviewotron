open Devkit

let log = Log.from "github_retry"

(* curl failures raised before any request bytes reach GitHub: name
   resolution, TCP connect, and the TLS handshake. *)
let is_unsent_curl_code = function
  | Curl.CURLE_COULDNT_RESOLVE_PROXY | Curl.CURLE_COULDNT_RESOLVE_HOST | Curl.CURLE_COULDNT_CONNECT
  | Curl.CURLE_SSL_CONNECT_ERROR ->
    true
  | _ -> false

(* curl failures after the request may have reached GitHub: timeouts and
   dropped or partial transfers. The binding has ~90 constructors, so we
   enumerate the retryable set; the rest (malformed URL, auth, ...) are
   deterministic and fall through. *)
let is_in_flight_curl_code = function
  | Curl.CURLE_OPERATION_TIMEOUTED | Curl.CURLE_PARTIAL_FILE | Curl.CURLE_GOT_NOTHING | Curl.CURLE_SEND_ERROR
  | Curl.CURLE_RECV_ERROR ->
    true
  | _ -> false

let is_retryable ~idempotent = function
  | Http_util.Transport code -> is_unsent_curl_code code || (idempotent && is_in_flight_curl_code code)
  | Http_util.Status (429, _) -> true
  | Http_util.Status (code, _) -> idempotent && code >= 500 && code <= 599
  | Http_util.Local _ -> false

(** [with_retry ~idempotent ~label f] runs the thunk [f], retrying on transient
    failures (per {!is_retryable}) with exponential backoff. [f] re-runs from
    scratch each attempt.

    Up to [max_attempts] total attempts (default 4); the delay starts at
    [base_delay] (default 1s) and doubles each time (1s, 2s, 4s). Returns on the
    first [Ok], on the first non-retryable [Error], or with the final [Error]
    once attempts are exhausted. *)
let with_retry ?(max_attempts = 4) ?(base_delay = 1.0) ~idempotent ~label f =
  let rec attempt n delay =
    match%lwt f () with
    | Ok _ as ok -> Lwt.return ok
    | Error err as error ->
    match () with
    | () when n >= max_attempts ->
      log#warn "%s failed after %d attempts: %s" label n (Http_util.error_to_string err);
      Lwt.return error
    | () when not (is_retryable ~idempotent err) ->
      log#warn "%s failed with non-retryable error: %s" label (Http_util.error_to_string err);
      Lwt.return error
    | () ->
      log#warn "%s failed (attempt %d/%d, retrying in %.0fs): %s" label n max_attempts delay
        (Http_util.error_to_string err);
      let%lwt () = Lwt_unix.sleep delay in
      attempt (n + 1) (delay *. 2.0)
  in
  attempt 1 base_delay
