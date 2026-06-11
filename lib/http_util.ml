(** Shared HTTP request helper for the reviewotron application. *)

open Devkit

type error =
  | Transport of Curl.curlCode  (** curl-level failure: DNS, connect, timeout, TLS — no HTTP response *)
  | Status of int * string  (** a completed request with a non-2xx status code and its body *)
  | Local of string  (** request setup failure before HTTP, such as missing auth or an unparseable repo URL *)

let error_to_string = function
  | Transport code -> Printf.sprintf "(%d) %s" (Curl.errno code) (Curl.strerror code)
  | Status (code, body) -> Printf.sprintf "http %d: %s" code body
  | Local message -> message

let http_request ?(verbose = true) ?headers ?body meth url =
  let setup h =
    Curl.set_followlocation h true;
    Curl.set_maxredirs h 1
  in
  ignore (verbose : bool);
  match%lwt Web.http_request_lwt' ~setup ~ua:"reviewotron" ?headers ?body meth url with
  | `Ok (code, body) when code / 100 = 2 -> Lwt.return (Ok body)
  | `Ok (code, body) -> Lwt.return (Error (Status (code, body)))
  | `Error code -> Lwt.return (Error (Transport code))

let query_error_msg url e =
  match e with
  | Status (code, body) -> Status (code, Printf.sprintf "error while querying %s: %s" url body)
  | Transport _ | Local _ -> Local (Printf.sprintf "error while querying %s: %s" url (error_to_string e))
