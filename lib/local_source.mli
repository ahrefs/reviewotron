(** Local diff source adapter.

    This adapter turns a unified diff on disk into a normalized {!Review_job.t}
    without relying on GitHub webhooks or GitHub APIs. *)

type prepare_error =
  | Read_failed of string
  | Empty
  | Too_large of int

type prepared_review = {
  job : Review_job.t;
  filtered_diff : Diff_parser.file_diff list;
}

(** Human-readable error text for CLI and tests. *)
val string_of_prepare_error : prepare_error -> string

(** Build a local review job from [diff_path].

    [root] is used by the job's [fetch_file] callback for demand-driven file
    content lookup. [change_key] defaults to a digest of the diff content. *)
val prepare_review :
  root:string ->
  repo_key:string ->
  ?change_key:string ->
  title:string ->
  description:string ->
  diff_path:string ->
  config:Config_types.config ->
  unit ->
  (prepared_review, prepare_error) result Lwt.t

(** Build a local review job from raw unified diff text. *)
val prepare_review_from_text :
  root:string ->
  repo_key:string ->
  ?change_key:string ->
  title:string ->
  description:string ->
  diff_text:string ->
  config:Config_types.config ->
  unit ->
  (prepared_review, prepare_error) result Lwt.t
