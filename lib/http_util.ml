(** Shared HTTP request helper for the reviewotron application. *)

open Devkit

type error = {
  status : int option;
  message : string;
}

let error_to_string e = e.message

(* Build the message for a completed-but-non-2xx response, mirroring devkit's
   [Web.show_result ~verbose:true] so log output is unchanged from before. *)
let http_error ~status ~body = { status = Some status; message = Printf.sprintf "http %d: %s" status body }

let http_request ?(verbose = true) ?headers ?body meth url =
  let setup h =
    Curl.set_followlocation h true;
    Curl.set_maxredirs h 1
  in
  match%lwt Web.http_request_lwt' ~setup ~ua:"reviewotron" ~verbose ?headers ?body meth url with
  | `Ok (code, body) when code / 100 = 2 -> Lwt.return (Ok body)
  | `Ok (code, body) -> Lwt.return (Error (http_error ~status:code ~body))
  | `Error curl_code -> Lwt.return (Error { status = None; message = Web.show_result ~verbose (`Error curl_code) })

let query_error_msg url e = { e with message = Printf.sprintf "error while querying %s: %s" url e.message }
