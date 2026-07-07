open Devkit
open Reviewotron_lib

let log = Log.from "request_handler"

(** Instantiate the reviewer with real implementations *)
module R =
  Reviewer.Make (Api_remote.Github) (Api_remote.Github) (Api_remote.Github) (Api_remote.Agent_runner) (Api_remote.Slack)

let extract_repo_url body =
  match Github_types.webhook_envelope_of_json (Melange_json.of_string body) with
  | envelope -> envelope.repository.url
  | exception exn ->
    log#warn "failed to extract repo URL from body: %s" (Exn.str exn);
    ""

let check_signature ctx ~repo_url ~signature_header ~body =
  match Context.get_hook_secret ctx ~repo_url, signature_header with
  | None, _ ->
    log#debug "no webhook secret configured for %s, skipping signature check" repo_url;
    true
  | Some _secret, None ->
    log#warn "webhook secret configured but no signature header received";
    false
  | Some secret, Some signature ->
  match Github.validate_signature ~secret ~signature ~body with
  | Ok () -> true
  | Error msg ->
    log#warn "signature validation failed: %s" msg;
    false

let webhook_base_attrs request =
  [
    "http.request.method", `String (Httpev.show_method request.Httpev.meth);
    "url.path", `String request.path;
    "http.request.body.size", `Int (String.length request.body);
  ]

let start ~ctx ~addr ~port =
  let open Httpev in
  let ip = Unix.inet_addr_of_string addr in
  let signature = Printf.sprintf "listen %s:%d" (Unix.string_of_inet_addr ip) port in
  let connection = Unix.ADDR_INET (ip, port) in
  Httpev.setup_lwt { default with name = "reviewotron"; connection; access_log_enabled = false } (fun _http request ->
    let body r = Lwt.return (`Body r) in
    let ret ?(status = `Ok) ?(typ = "text/plain") ?extra r = body @@ serve ~status ?extra request typ r in
    let ret_err status s = body @@ serve_text ~status request s in
    try%lwt
      let path =
        match String.split_on_char '/' request.path with
        | "" :: p -> p
        | _ -> Exn.fail "invalid path"
      in
      match request.meth, List.map Web.urldecode path with
      | _, [ "ping" ] | _, [ "external"; "ping" ] ->
        ret (Printf.sprintf "%s uptime %s\n" signature Devkit.Action.uptime#get_str)
      | _, [ "github" ] | _, [ "external"; "github" ] ->
        Telemetry.span ~kind:Opentelemetry.Span.Span_kind_server ~attrs:(webhook_base_attrs request)
          "reviewotron.webhook.accept" (fun () ->
          if String.length request.body > 10_000_000 then (
            Telemetry.set_error "payload too large";
            ret_err `Request_too_large "payload too large")
          else (
            let headers = request.headers in
            let event_type =
              match List.assoc_opt "x-github-event" headers with
              | Some ev -> ev
              | None ->
                log#warn "missing x-github-event header";
                "unknown"
            in
            let signature_header = List.assoc_opt "x-hub-signature-256" headers in
            let repo_url = extract_repo_url request.body in
            let signature_ok = check_signature ctx ~repo_url ~signature_header ~body:request.body in
            Telemetry.add_attrs
              [
                "github.event.name", `String event_type;
                "reviewotron.repo_url", `String repo_url;
                "reviewotron.webhook.signature.present", `Bool (Option.is_some signature_header);
                "reviewotron.webhook.signature.valid", `Bool signature_ok;
              ];
            if not signature_ok then (
              Telemetry.set_error "signature validation failed";
              ret_err `Forbidden "signature validation failed")
            else
              begin match Github.parse_event ~event_type ~body:request.body with
              | Ok event ->
                (* Process asynchronously so we return 200 within GitHub's timeout *)
                Lwt.async (fun () ->
                  Lwt.catch
                    (fun () ->
                      Telemetry.span
                        ~attrs:[ "github.event.name", `String event_type; "reviewotron.repo_url", `String repo_url ]
                        "reviewotron.webhook.process"
                        (fun () -> R.process_event ctx ~event))
                    (fun exn ->
                      log#error ~exn "error processing %s event" event_type;
                      Lwt.return_unit));
                ret "accepted"
              | Error msg ->
                log#error "failed to parse event: %s" msg;
                Telemetry.set_error msg;
                ret_err `Bad_request (Printf.sprintf "parse error: %s" msg)
              end))
      | _, _ ->
        log#error "unknown path: %s" request.path;
        ret_err `Not_found "not found"
    with
    | Failure s ->
      log#error "internal error: %s" s;
      ret_err `Internal_server_error s
    | exn ->
      log#error ~exn "internal error: %s" (Httpev.show_request request);
      ret_err `Internal_server_error (Exn.str exn))
