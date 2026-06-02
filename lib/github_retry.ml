open Devkit

let log = Log.from "github_retry"

(* Devkit's [Web.http_request] renders its error string in one of two shapes
   (see devkit/web.ml [show_result] / [simple_result]):

   - Transport failures (DNS, connect, timeout, TLS) come from curl and are
     rendered as ["(<errno>) <strerror>"], e.g. ["(6) Could not resolve host"].
   - A completed HTTP request with a non-2xx status is rendered as
     ["http <code>: <body>"], e.g. ["http 404: Not Found"].

   Everything else in this codebase that produces an [Error] string is a logic
   failure raised after a successful fetch — JSON parse errors, "no auth
   configured", "cannot parse owner/repo". Those are deterministic: retrying
   re-runs the same inputs and fails the same way, so we must not retry them. *)

(* A leading ["(<digits>)"] marks a curl transport error. Any such failure is
   worth retrying — DNS blips, dropped connections and timeouts are exactly the
   transient conditions retries exist for. *)
let is_curl_transport_error msg =
  match Stre.nsplitc msg ')' with
  | head :: _ ->
    String.length head >= 2
    && Char.equal head.[0] '('
    && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub head 1 (String.length head - 1))
  | [] -> false

(* The status token is rendered as ["http <code>: <body>"], so the code carries
   a trailing colon (e.g. ["404:"]); take its leading run of digits. *)
let leading_int s =
  let n = String.length s in
  let rec count i = if i < n && s.[i] >= '0' && s.[i] <= '9' then count (i + 1) else i in
  match count 0 with
  | 0 -> None
  | len -> int_of_string_opt (String.sub s 0 len)

(* GitHub returns 5xx on its own hiccups and 429 on secondary rate limits; both
   are expected to clear, so they are retryable. 4xx (404/401/403/422) are
   permanent for the same request and must fail fast. *)
let is_retryable_http_status msg =
  match Stre.nsplitc msg ' ' with
  | "http" :: code :: _ ->
    (match leading_int code with
    | Some 429 -> true
    | Some code -> code >= 500 && code <= 599
    | None -> false)
  | _ -> false

(** [is_retryable msg] decides whether an [Error] string from a GitHub API call
    represents a transient failure worth retrying. Network/transport errors and
    5xx/429 responses are retryable; client errors (4xx) and post-fetch logic
    errors (parse/auth) are not. *)
let is_retryable msg =
  match () with
  | () when is_curl_transport_error msg -> true
  | () when is_retryable_http_status msg -> true
  | () -> false

(** [with_retry ~label f] runs [f], retrying on transient failures with
    exponential backoff. [f] is a thunk so each attempt re-runs from scratch.

    Up to [max_attempts] total attempts (default 4) are made. Between attempts
    the delay is [base_delay] (default 1s) doubled each time: 1s, 2s, 4s. A
    non-retryable error (per {!is_retryable}) returns immediately without
    further attempts, as does success. The error from the final attempt is
    returned unchanged. *)
let with_retry ?(max_attempts = 4) ?(base_delay = 1.0) ~label f =
  let rec attempt n delay =
    match%lwt f () with
    | Ok _ as ok -> Lwt.return ok
    | Error msg as error ->
    match () with
    | () when n >= max_attempts ->
      log#warn "%s failed after %d attempts: %s" label n msg;
      Lwt.return error
    | () when not (is_retryable msg) ->
      log#warn "%s failed with non-retryable error: %s" label msg;
      Lwt.return error
    | () ->
      log#warn "%s failed (attempt %d/%d, retrying in %.0fs): %s" label n max_attempts delay msg;
      let%lwt () = Lwt_unix.sleep delay in
      attempt (n + 1) (delay *. 2.0)
  in
  attempt 1 base_delay
