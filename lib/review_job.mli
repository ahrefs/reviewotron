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

(** SHA-256 of the filtered diff text that is sent to review agents. *)
val diff_sha256 : t -> string

(** SHA-256 of the review configuration JSON. *)
val config_sha256 : t -> string
