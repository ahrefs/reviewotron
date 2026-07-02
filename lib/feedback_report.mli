(** Local reporting over collected feedback targets and evidence bundles. *)

type totals = {
  target_count : int;
  reacted_count : int;
  plus_one : int;
  minus_one : int;
  positive_count : int;
  negative_count : int;
  mixed_count : int;
  unreacted_count : int;
}

type target_summary = {
  feedback_id : string;
  review_batch_id : string;
  target_kind : string;
  finding_id : string option;
  finding_source : string option;
  plugin_name : string option;
  status : string;
  repo_url : string;
  pr_number : int;
  review_id : int;
  review_node_id : string option;
  comment_id : int option;
  github_comment_url : string option;
  github_review_url : string option;
  path : string option;
  line : int option;
  severity : string option;
  category : string option;
  confidence : string option;
  message : string option;
  routing_outcome : string option;
  comment_body_sha256 : string option;
  review_body_sha256 : string option;
  plus_one : int;
  minus_one : int;
  sentiment : string;
  last_polled_at : string option;
  first_user_interaction_at : string option;
}

type review_summary = {
  review_batch_id : string;
  evidence_dir : string;
  repo_url : string option;
  pr_number : int option;
  head_sha : string option;
  trigger : string option;
  config_sha256 : string option;
  diff_sha256 : string option;
  github_review_id : int option;
  comment_count : int option;
  targets : target_summary list;
  totals : totals;
  warnings : string list;
}

type sentiment_filter =
  | All
  | Reacted
  | Positive
  | Negative
  | Mixed
  | Unreacted

type filter = {
  sentiment : sentiment_filter;
  review_batch_id : string option;
  pr_number : int option;
  limit : int option;
}

type t = {
  targets_file : string;
  events_file : string;
  evidence_root : string;
  event_count : int;
  reviews : review_summary list;
  totals : totals;
  warnings : string list;
}

val default_filter : filter
val load : Feedback_store.paths -> (t, string) result
val apply_filter : filter -> t -> t
val to_json : t -> Yojson.Basic.t
val render_markdown : ?include_messages:bool -> ?max_message_chars:int -> t -> string
