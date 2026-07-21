(** Normalized review input shared by source adapters and the core engine. *)

(** What triggered the review. *)
type trigger =
  | Pull_request
  | Push
  | Manual
  | Local
  | Other of string

(** Where the reviewed change came from. *)
type source_kind =
  | Github
  | Local
  | Other of string

(** Fetch file content by repository-relative path for context expansion.

    Source adapters close over the correct revision. For GitHub PRs this should
    fetch from the PR head SHA; for pushes it should fetch from the after SHA. *)
type fetch_file = path:string -> (string option, string) result Lwt.t

(** [is_embeddable content] is [true] when [content] is safe to put in a model
    prompt: well-formed UTF-8 (no NUL byte or malformed sequence, including the
    unpaired surrogates the JSON request encoder rejects) and within a byte cap.
    Source adapters use it to drop binary or oversized blobs before they reach
    the agent, where they would otherwise fail JSON serialization or bloat the
    request. *)
val is_embeddable : string -> bool

(** [key_file_paths ~diff] is the repository-relative paths of the files whose
    full contents the deep reviewer is preloaded with: the first few
    added/modified files of [diff], in diff order (deletions and renames are
    excluded). Shared by every source adapter so selection cannot drift between
    them. *)
val key_file_paths : diff:Diff_parser.file_diff list -> string list

(** [select_key_files ~diff ~fetch ()] fetches the contents of
    {!key_file_paths} through [fetch] and returns [(path, content)] pairs for
    the files that came back available and embeddable. A file that [fetch]
    reports as unavailable ([Ok None]) or that errors is skipped, so the review
    proceeds on the diff and the remaining files. [fetch] closes over the
    reviewed revision and applies its own embeddable guard (see {!fetch_file}).
    Fetches run concurrently. [log_context] prefixes the fetch-failure warning. *)
val select_key_files :
  ?log_context:string -> diff:Diff_parser.file_diff list -> fetch:fetch_file -> unit -> (string * string) list Lwt.t

(** Shorten an identifier for logs and labels. *)
val short_display_id : string -> string

(** Stable, filesystem-safe slug for a repository key or URL. *)
val repo_slug : string -> string

(** Stable string representation for review sources. *)
val source_kind_to_string : source_kind -> string

(** Stable string representation for review triggers. *)
val trigger_to_string : trigger -> string

(** A prepared review job.

    [change_key] is the stable identity used for deduplication. [change_label]
    is only for logs and user-facing text. [diff_text] is the filtered,
    annotated diff passed to agents, produced by
    {!Diff_parser.to_string_annotated}. *)
type t = {
  repo_key : string;
  change_key : string;
  change_label : string;
  title : string;
  description : string;
  head_sha : string;
  diff_text : string;
  filtered_diff : Diff_parser.file_diff list;
  config : Config_types.config;
  file_contents : (string * string) list;
  fetch_file : fetch_file;
  trigger : trigger;
  source_kind : source_kind;
}

(** Stable log context prefix for correlating concurrent review logs. *)
val log_context : t -> string

(** Stable log context prefix for a change before a full {!t} is available. *)
val log_context_for : repo_key:string -> change_label:string -> head_sha:string -> string

(** SHA-256 of the filtered diff text that is sent to review agents. *)
val diff_sha256 : t -> string

(** SHA-256 of the review configuration JSON. *)
val config_sha256 : t -> string

(** OTel span attributes describing a review job: repo, change identity,
    trigger/source kind, and diff size. Pass [fetched_files] to additionally
    report the count of fetched file contents (engine-level spans only). *)
val span_attrs : ?fetched_files:int -> t -> Opentelemetry.key_value list
