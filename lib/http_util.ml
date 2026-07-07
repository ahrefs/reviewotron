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

type url_parts = {
  scheme : string;
  host : string;
  path : string;
}

let find_index_from s ~start ~f =
  let len = String.length s in
  let rec loop i =
    match i >= len with
    | true -> None
    | false ->
    match f s.[i] with
    | true -> Some i
    | false -> loop (i + 1)
  in
  loop start

let is_authority_separator = function
  | '/' | '?' | '#' -> true
  | _ -> false

let is_query_separator = function
  | '?' | '#' -> true
  | _ -> false

let substring_from s start = String.sub s start (String.length s - start)

let split_scheme url =
  match String.index_opt url ':' with
  | None -> "", url
  | Some colon ->
    let scheme = String.sub url 0 colon in
    let rest = substring_from url (colon + 1) in
    scheme, rest

let path_without_query value =
  match value with
  | "" -> "/"
  | value ->
  match value.[0] with
  | '/' ->
    (match find_index_from value ~start:0 ~f:is_query_separator with
    | None -> value
    | Some stop -> String.sub value 0 stop)
  | '?' | '#' -> "/"
  | _ -> "/"

let url_parts url =
  let scheme, rest = split_scheme url in
  match String.starts_with ~prefix:"//" rest with
  | false -> { scheme; host = ""; path = path_without_query rest }
  | true ->
    let authority_and_path = substring_from rest 2 in
    let host, path =
      match find_index_from authority_and_path ~start:0 ~f:is_authority_separator with
      | None -> authority_and_path, "/"
      | Some stop -> String.sub authority_and_path 0 stop, path_without_query (substring_from authority_and_path stop)
    in
    { scheme; host; path }

let http_status_class code =
  match code / 100 with
  | 2 -> "ok"
  | _ -> "status_error"

let http_request ?(verbose = true) ?headers ?body meth url =
  let setup h =
    Curl.set_followlocation h true;
    Curl.set_maxredirs h 1
  in
  ignore (verbose : bool);
  let parts = url_parts url in
  let attrs =
    [
      "http.request.method", `String (Web.string_of_http_action meth);
      "url.scheme", `String parts.scheme;
      "server.address", `String parts.host;
      "url.path", `String parts.path;
    ]
  in
  Telemetry.span ~kind:Opentelemetry.Span.Span_kind_client ~attrs "reviewotron.http.client" (fun () ->
    match%lwt Web.http_request_lwt' ~setup ~ua:"reviewotron" ?headers ?body meth url with
    | `Ok (code, body) when Int.equal (code / 100) 2 ->
      Telemetry.add_attrs
        [ "http.response.status_code", `Int code; "reviewotron.http.status_class", `String (http_status_class code) ];
      Lwt.return (Ok body)
    | `Ok (code, body) ->
      Telemetry.add_attrs
        [
          "http.response.status_code", `Int code;
          "reviewotron.http.status_class", `String (http_status_class code);
          "reviewotron.http.error_class", `String "status";
        ];
      Telemetry.set_error (Printf.sprintf "http %d" code);
      Lwt.return (Error (Status (code, body)))
    | `Error code ->
      Telemetry.add_attrs
        [
          "reviewotron.http.error_class", `String "transport";
          "error.type", `String (Printf.sprintf "curl.%d" (Curl.errno code));
        ];
      Telemetry.set_error (Curl.strerror code);
      Lwt.return (Error (Transport code)))

let query_error_msg url e =
  match e with
  | Status (code, body) -> Status (code, Printf.sprintf "error while querying %s: %s" url body)
  | Transport _ | Local _ -> Local (Printf.sprintf "error while querying %s: %s" url (error_to_string e))
