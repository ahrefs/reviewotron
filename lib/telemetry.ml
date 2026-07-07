open Devkit

let log = Log.from "telemetry"

let default_otlp_endpoint = "http://127.0.0.1:4318"

let base_endpoint_var = "OTEL_EXPORTER_OTLP_ENDPOINT"
let traces_endpoint_var = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"

type env = string -> string option

let nonempty value =
  match String.trim value with
  | "" -> None
  | value -> Some value

let parse_bool value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" -> Some true
  | "0" | "false" | "no" | "off" -> Some false
  | _ -> None

let env_bool lookup name = Stdlib.Option.bind (lookup name) parse_bool

let env_nonempty lookup name = Stdlib.Option.bind (lookup name) nonempty

let strip_trailing_slashes value =
  let rec loop len =
    match len with
    | 0 -> 0
    | len when Char.equal value.[len - 1] '/' -> loop (len - 1)
    | len -> len
  in
  String.sub value 0 (loop (String.length value))

let is_some = function
  | Some _ -> true
  | None -> false

let endpoint_env_set lookup =
  is_some (env_nonempty lookup base_endpoint_var) || is_some (env_nonempty lookup traces_endpoint_var)

(* A var is "blank" when it is present in the environment but trims to empty.
   [Unix.putenv name ""] cannot unset it, and the OTLP client reads such a var
   verbatim (base endpoint yields base "" -> "/v1/traces"; a blank traces
   endpoint is used as-is), so every export POSTs to an invalid URL. We repair
   this by re-exporting the intended value.

   The OTLP client also reads [OTEL_EXPORTER_OTLP_TRACES_ENDPOINT] before its
   [~url_traces] argument, so a CLI traces endpoint must be re-exported over an
   existing traces env var before config construction. *)
let is_blank lookup name =
  match lookup name with
  | None -> false
  | Some value ->
  match String.trim value with
  | "" -> true
  | _ -> false

(* Pure decision for which endpoint env vars must be re-exported, and to what
   value, before handing the environment to the OTLP client. Returns the
   (name, value) pairs the caller should [Unix.putenv]; an empty list means the
   environment is already sane. Testable without touching the process env. *)
let endpoint_overrides_of_env ?traces_endpoint lookup =
  let resolved_base =
    match env_nonempty lookup base_endpoint_var with
    | Some base -> strip_trailing_slashes base
    | None -> default_otlp_endpoint
  in
  let base_override =
    match is_blank lookup base_endpoint_var with
    | true -> [ base_endpoint_var, default_otlp_endpoint ]
    | false -> []
  in
  let traces_override =
    match traces_endpoint with
    | Some endpoint ->
      (match lookup traces_endpoint_var with
      | Some _ -> [ traces_endpoint_var, endpoint ]
      | None -> [])
    | None ->
    match is_blank lookup traces_endpoint_var with
    | true -> [ traces_endpoint_var, resolved_base ^ "/v1/traces" ]
    | false -> []
  in
  base_override @ traces_override

let apply_endpoint_overrides ?traces_endpoint () =
  let put_with_blank_log name value =
    log#warn "%s is set but blank; normalizing to %s so traces are exported" name value;
    Unix.putenv name value
  in
  List.iter
    (fun (name, value) ->
      match traces_endpoint with
      | Some endpoint when String.equal name traces_endpoint_var && String.equal value endpoint ->
        Unix.putenv name value
      | Some _ -> put_with_blank_log name value
      | None -> put_with_blank_log name value)
    (endpoint_overrides_of_env ?traces_endpoint Sys.getenv_opt)

(* An explicit [--otel-traces-endpoint] flag is treated like an endpoint
   environment variable being set: it enables tracing on its own, but
   [OTEL_SDK_DISABLED=true] and [REVIEWOTRON_OTEL=0|off] still override it so an
   operator can force telemetry off without removing the flag. *)
let enabled_of_env ?traces_endpoint lookup =
  let sdk_disabled =
    match env_bool lookup "OTEL_SDK_DISABLED" with
    | Some true -> true
    | Some false | None -> false
  in
  match sdk_disabled, env_bool lookup "REVIEWOTRON_OTEL" with
  | true, _ -> false
  | false, Some true -> true
  | false, Some false -> false
  | false, None -> is_some traces_endpoint || endpoint_env_set lookup

let enabled ?traces_endpoint () = enabled_of_env ?traces_endpoint Sys.getenv_opt

let tracer = Opentelemetry.Sdk.get_tracer ~name:"reviewotron" ~__MODULE__ ()

let resource_initialized = ref false
let resource_command = ref None

let secret_value_flags = [ "--anthropic-api-key"; "--openrouter-api-key" ]

let redact_command_line argv =
  let rec loop acc = function
    | [] -> List.rev acc
    | flag :: _value :: rest when List.exists (String.equal flag) secret_value_flags ->
      loop ("<redacted>" :: flag :: acc) rest
    | arg :: rest ->
      let redacted =
        match List.find_opt (fun flag -> String.starts_with ~prefix:(flag ^ "=") arg) secret_value_flags with
        | Some flag -> flag ^ "=<redacted>"
        | None -> arg
      in
      loop (redacted :: acc) rest
  in
  argv |> Array.to_list |> loop [] |> String.concat " "

let safe_getcwd () =
  match Sys.getcwd () with
  | cwd -> cwd
  | exception _ -> ""

let safe_hostname () =
  match Unix.gethostname () with
  | hostname -> hostname
  | exception _ -> ""

let add_global_attrs attrs = List.iter (fun (key, value) -> Opentelemetry.Globals.add_global_attribute key value) attrs

let setup_resource_attrs ~command =
  (match Sys.getenv_opt "OTEL_SERVICE_NAME" with
  | Some _ -> ()
  | None -> Opentelemetry.Globals.service_name := "reviewotron");
  (match !resource_initialized with
  | true -> ()
  | false ->
    resource_initialized := true;
    add_global_attrs
      [
        "process.pid", `Int (Unix.getpid ());
        "process.cwd", `String (safe_getcwd ());
        "process.command_line", `String (redact_command_line Sys.argv);
        "host.name", `String (safe_hostname ());
      ]);
  match !resource_command with
  | Some _ -> ()
  | None ->
    resource_command := Some command;
    Opentelemetry.Globals.add_global_attribute "reviewotron.command" (`String command)

(* Precedence for the traces endpoint: the explicit [--otel-traces-endpoint]
   flag (passed verbatim as [~url_traces]) wins over any environment variable;
   otherwise fall back to env-based resolution, defaulting the base URL to
   loopback when no endpoint variable is set. *)
let config_with_traces_endpoint endpoint =
  let config = Opentelemetry_client_ocurl_lwt.Config.make ~url_traces:endpoint () in
  { config with Opentelemetry_client.Exporter_config.url_traces = endpoint }

let config ?traces_endpoint () =
  match traces_endpoint with
  | Some endpoint -> config_with_traces_endpoint endpoint
  | None ->
  match endpoint_env_set Sys.getenv_opt with
  | true -> Opentelemetry_client_ocurl_lwt.Config.make ()
  | false -> Opentelemetry_client_ocurl_lwt.Config.make ~url:default_otlp_endpoint ()

let current_span () = Opentelemetry.Ambient_span.get ()

let add_attrs attrs =
  match current_span () with
  | None -> ()
  | Some span -> Opentelemetry.Span.add_attrs span attrs

let set_error message =
  let status = Opentelemetry.Span_status.make ~message ~code:Opentelemetry.Span_status.Status_code_error in
  match current_span () with
  | None -> ()
  | Some span -> Opentelemetry.Span.set_status span status

let span ?kind ?attrs name f = Opentelemetry_lwt.Tracer.with_ ~tracer ?kind ?attrs name (fun _span -> f ())

let span_result ?kind ?attrs ?(error_to_string = fun _ -> "error") name f =
  span ?kind ?attrs name (fun () ->
    let%lwt result = f () in
    (match result with
    | Ok _ -> ()
    | Error error -> set_error (error_to_string error));
    Lwt.return result)

(* Wrap the traced body in a root "reviewotron.command" span only when the
   command is short-lived. Long-running commands (the server) must not sit under
   a root that only exports at shutdown, so their webhook spans reach the
   collector as they complete. The [reviewotron.command] global attribute is set
   either way, so server spans stay tagged with the command name. *)
let with_command_span ~root_span ~command f =
  match root_span with
  | false -> f ()
  | true -> span ~attrs:[ "reviewotron.command", `String command ] "reviewotron.command" f

let with_setup ?(root_span = true) ?traces_endpoint ~command f =
  match enabled ?traces_endpoint () with
  | false -> f ()
  | true ->
  (* Telemetry initialization must never crash the app. Environment
       normalization, config construction, and the synchronous exporter install
       are all guarded; on any failure the body runs untraced. Exceptions from
       the body itself flow through untouched (the exporter's own [Lwt.catch]
       flushes and reraises), so this must not wrap [f]'s execution. *)
  match
    setup_resource_attrs ~command;
    apply_endpoint_overrides ?traces_endpoint ();
    config ?traces_endpoint ()
  with
  | exception exn ->
    log#error "telemetry setup failed, running untraced: %s" (Printexc.to_string exn);
    f ()
  | config ->
  match
    Opentelemetry_client_ocurl_lwt.with_setup ~config ~enable:true () (fun () ->
      with_command_span ~root_span ~command f)
  with
  | promise -> promise
  | exception exn ->
    log#error "telemetry exporter install failed, running untraced: %s" (Printexc.to_string exn);
    f ()
