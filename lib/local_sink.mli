(** Local markdown sink for neutral review reports. *)

(** Render a review report as markdown suitable for stdout or file output. *)
val render_markdown : Review_engine.report -> string
