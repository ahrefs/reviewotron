(** Plugin interface for the review pipeline.

    Each plugin produces findings from a PR diff. Plugins are independent —
    the orchestrator runs enabled plugins, collects their findings, and posts
    a single aggregated review. *)

(** Metadata about the pull request that supplements the diff. *)
type review_metadata = {
  pr_number : int;  (** PR number, used for logging and cost tracking. *)
  pr_title : string;  (** Title of the pull request. *)
  pr_description : string;  (** Body/description of the pull request. *)
  file_contents : (string * string) list;
    (** [(path, content)] pairs for key changed files, fetched by the
          orchestrator before plugin invocation. Plugins that expand context
          on demand (e.g. via tools) may ignore this field. *)
}

(** Signature that every review plugin must implement. *)
module type S = sig
  (** Human-readable plugin name, used in logs and cost tracking. *)
  val name : string

  (** Run the plugin against a PR diff.

      Returns a list of findings. An empty list means the plugin found nothing
      noteworthy. Plugins handle their own errors internally — a failing plugin
      returns an empty list rather than propagating exceptions. *)
  val run :
    ctx:Context.t ->
    repo_url:string ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:review_metadata ->
    Review_types.finding list Lwt.t
end
