(** Persistent feedback targets and aggregate reaction observations.

    Feedback data is deliberately separate from {!State}: the state file keeps
    review de-duplication, while this module owns sibling feedback files next
    to the configured state path. *)

type paths = {
  targets : string;
  events : string;
  evidence_root : string;
}

type reaction_counts = {
  plus_one : int;
  minus_one : int;
}

type target_status =
  | Active
  | Final_due
  | Closed
  | Expired
  | Missing
  | Error

type stop_reason =
  | Pr_closed
  | Poll_window_elapsed
  | Comment_missing
  | Api_error

type target_kind =
  | Pr_review_comment
  | Pr_review_body

type target = {
  feedback_id : string;
  review_batch_id : string;
  status : target_status;
  stop_reason : stop_reason option;
  repo_url : string;
  pr_number : int;
  head_sha : string;
  target_kind : target_kind;
  review_id : int;
  comment_id : int option;
  review_node_id : string option;
  created_at : string;
  poll_until : string;
  first_user_interaction_at : string option;
  last_polled_at : string option;
  final_polled_at : string option;
  path : string option;
  line : int option;
  start_line : int option;
  severity : string option;
  category : string option;
  confidence : string option;
  finding : Yojson.Basic.t option;
  comment_body_sha256 : string option;
  review_body_sha256 : string option;
  evidence_dir : string option;
  finding_id : string option;
  finding_source : string option;
  plugin_name : string option;
  last_counts : reaction_counts;
}

type file = {
  schema : int;
  targets : target list;
}

type t

type target_input = {
  feedback_id : string;
  comment : Review_comment.t;
  finding : Review_types.finding;
  comment_body : string;
  evidence_dir : string option;
  finding_id : string option;
  finding_source : string option;
  plugin_name : string option;
}

type review_body_target_input = {
  feedback_id : string;
  review_node_id : string;
  review_body : string;
  evidence_dir : string option;
}

val derive_paths : ?feedback_dir:string -> state_filepath:string -> unit -> paths
val create : ?feedback_dir:string -> state_filepath:string -> unit -> t
val paths : t -> paths
val data : t -> file

val utc_string : Ptime.t -> string
val parse_time : string -> (Ptime.t, string) result
val add_seconds : Ptime.t -> int -> Ptime.t

val target_status_to_string : target_status -> string
val stop_reason_to_string : stop_reason -> string
val target_kind_to_string : target_kind -> string
val target_to_json : target -> Yojson.Basic.t
val file_to_json : file -> Yojson.Basic.t
val file_of_json : Yojson.Basic.t -> file

val zero_counts : reaction_counts
val counts_of_reactions : Github_types.reaction list -> reaction_counts
val counts_of_github_counts : Github_types.reaction_counts -> reaction_counts

val make_review_batch_id : repo_url:string -> pr_number:int -> head_sha:string -> now:Ptime.t -> nonce:string -> string

val make_feedback_id : review_batch_id:string -> index:int -> path:string -> line:int -> comment_body:string -> string

val make_review_body_feedback_id : review_batch_id:string -> review_node_id:string -> review_body:string -> string

val make_finding_id :
  review_batch_id:string ->
  index:int ->
  path:string ->
  line:int ->
  finding_json:Yojson.Basic.t ->
  comment_body:string ->
  string

val append_marker : feedback_id:string -> string -> string
val extract_marker : string -> string option

val record_posted_pr_review_targets :
  t ->
  repo_url:string ->
  pr_number:int ->
  head_sha:string ->
  review_id:int ->
  review_batch_id:string ->
  created_at:Ptime.t ->
  ?review_body_target:review_body_target_input ->
  target_input list ->
  unit Lwt.t

val apply_user_interaction : t -> repo_url:string -> pr_number:int -> received_at:Ptime.t -> unit Lwt.t
val mark_pr_closed : t -> repo_url:string -> pr_number:int -> closed_at:Ptime.t -> unit Lwt.t
val handle_webhook_event : t -> event:Github.event -> received_at:Ptime.t -> unit Lwt.t

val pollable_targets : ?poll_interval_seconds:int -> t -> now:Ptime.t -> target list Lwt.t
val resolve_comment_id : t -> now:Ptime.t -> feedback_id:string -> comment_id:int -> unit Lwt.t
val update_after_poll : t -> now:Ptime.t -> feedback_id:string -> counts:reaction_counts -> unit Lwt.t
val mark_missing : t -> now:Ptime.t -> feedback_id:string -> unit Lwt.t
