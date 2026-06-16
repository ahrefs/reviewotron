(** Local stdout sink for neutral review reports. *)

(** Render a review report as markdown suitable for stdout or file output. *)
val render_markdown : Review_engine.report -> string

(** Render a review report as agent-ingestible JSON.

    The stable fields are [summary], [findings], [schema_version],
    [review_status], [reviewed_root], and [change_key]. *)
val render_json : Review_engine.report -> string

(** Render a failure as the JSON envelope [{ "error": "<message>" }], the
    machine-readable counterpart of {!render_json} for callers that requested
    JSON output. *)
val render_error : string -> string
