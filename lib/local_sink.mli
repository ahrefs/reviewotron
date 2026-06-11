(** Local stdout sink for neutral review reports. *)

(** Render a review report as markdown suitable for stdout or file output. *)
val render_markdown : Review_engine.report -> string

(** Render a review report as agent-ingestible JSON. *)
val render_json : Review_engine.report -> string
