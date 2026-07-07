(** Opt-in OpenTelemetry tracing for Reviewotron.

    Tracing is disabled by default and enabled only by environment. *)

type env = string -> string option

(** Decide whether tracing should be enabled for an environment lookup.

    [REVIEWOTRON_OTEL=1|true|yes|on] enables tracing, standard OTLP endpoint
    variables enable tracing, and [REVIEWOTRON_OTEL=0|false|no|off] or
    [OTEL_SDK_DISABLED=true] disables it. *)
val enabled_of_env : env -> bool

val enabled : unit -> bool

(** Decide which OTLP endpoint environment variables must be re-exported before
    the exporter reads them.

    A set-but-blank [OTEL_EXPORTER_OTLP_ENDPOINT] or
    [OTEL_EXPORTER_OTLP_TRACES_ENDPOINT] (common in templated env files) is read
    verbatim by the OTLP client, producing an invalid export URL that silently
    drops every trace. [Unix.putenv name ""] cannot unset a variable, so the fix
    is to overwrite each blank variable with the value the app intends: a blank
    base endpoint becomes the default endpoint, and a blank traces endpoint
    becomes the resolved base with ["/v1/traces"] appended.

    Returns the [(name, value)] pairs the caller should re-export; the empty list
    means nothing needs fixing. Pure and testable without touching the process
    environment. *)
val endpoint_overrides_of_env : env -> (string * string) list

(** Initialize the OTLP exporter around a command body when tracing is enabled.

    When [root_span] is [true] (the default) the body runs inside a root
    ["reviewotron.command"] span, appropriate for short-lived CLI commands. Pass
    [~root_span:false] for long-running commands (the server): a root span that
    only exports at shutdown would orphan every child span at the collector.
    The [reviewotron.command] global attribute is set regardless, so spans stay
    tagged with the command name.

    Telemetry initialization never crashes the caller: an exception while
    normalizing the environment or installing the exporter is logged and [f]
    runs untraced. *)
val with_setup : ?root_span:bool -> command:string -> (unit -> 'a Lwt.t) -> 'a Lwt.t

val span :
  ?kind:Opentelemetry.Span.kind -> ?attrs:Opentelemetry.key_value list -> string -> (unit -> 'a Lwt.t) -> 'a Lwt.t

val span_result :
  ?kind:Opentelemetry.Span.kind ->
  ?attrs:Opentelemetry.key_value list ->
  ?error_to_string:('e -> string) ->
  string ->
  (unit -> ('a, 'e) result Lwt.t) ->
  ('a, 'e) result Lwt.t

(** Add attributes to the current ambient span, if any. *)
val add_attrs : Opentelemetry.key_value list -> unit

(** Mark the current ambient span as failed with the given message, if any. *)
val set_error : string -> unit
