(** Shared HTTP request helper for the reviewotron application. *)

open Devkit

let http_request ?(verbose = true) ?headers ?body meth url =
  let setup h =
    Curl.set_followlocation h true;
    Curl.set_maxredirs h 1
  in
  match%lwt Web.http_request_lwt ~setup ~ua:"reviewotron" ~verbose ?headers ?body meth url with
  | `Ok s -> Lwt.return (Ok s)
  | `Error e -> Lwt.return (Error e)

let query_error_msg url e = Printf.sprintf "error while querying %s: %s" url e
