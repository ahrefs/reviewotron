(** Immutable evidence bundles for posted GitHub PR reviews.

    Bundles are written beside feedback target files and are intentionally
    bounded: no raw prompts, transcripts, webhook payloads, tool outputs, or
    fetched file contents are stored. *)

type posted_comment = {
  feedback_id : string;
  finding_id : string;
  finding_source : string;
  plugin_name : string;
  comment : Review_comment.t;
  finding : Review_types.finding;
  comment_body : string;
}

val bundle_dir : evidence_root:string -> review_batch_id:string -> string

val write_bundle :
  evidence_root:string ->
  review_batch_id:string ->
  created_at:Ptime.t ->
  repo_url:string ->
  pr_number:int ->
  head_sha:string ->
  review_id:int ->
  review_body:string ->
  job:Review_job.t ->
  report:Review_engine.report ->
  posted_comments:posted_comment list ->
  string
