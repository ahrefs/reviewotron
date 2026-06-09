(** Plugin interface for the review pipeline.

    Each plugin produces findings from a change diff. Plugins are independent —
    the orchestrator runs enabled plugins, collects their findings, and posts
    a single aggregated review. *)

(** Metadata about the reviewed change that supplements the diff. *)
type review_metadata = {
  change_title : string;  (** Title of the reviewed change. *)
  change_description : string;  (** Description/body of the reviewed change. *)
  file_contents : (string * string) list;
    (** [(path, content)] pairs for key changed files, fetched by the
          orchestrator before plugin invocation. Plugins that expand context
          on demand (e.g. via tools) may ignore this field. *)
  fetch_file : Review_job.fetch_file;
    (** Fetch repository file content for demand-driven context expansion.
          Source adapters close over the correct revision. *)
}

(** Signature that every review plugin must implement. *)
module type S = sig
  (** Human-readable plugin name, used in logs and cost tracking. *)
  val name : string

  (** Run the plugin against a change diff using the config captured for this review.

      Returns a list of findings paired with per-agent cost records.
      An empty findings list means the plugin found nothing noteworthy.
      Plugins handle their own errors internally — a failing plugin
      returns an empty list rather than propagating exceptions. *)
  val run :
    ctx:Context.t ->
    repo_url:string ->
    config:Config_types.config ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:review_metadata ->
    (Review_types.finding list * Cost_tracking.agent_cost list) Lwt.t
end
