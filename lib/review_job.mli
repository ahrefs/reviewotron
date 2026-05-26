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

(** A prepared review job.

    [diff_text] is the diff text passed to agents. In the current staged
    migration this is the filtered, annotated diff produced by
    {!Diff_parser.to_string_annotated}. *)
type t = {
  repo_key : string;
  change_key : string;
  title : string;
  description : string;
  head_sha : string;
  diff_text : string;
  config : Config_types.config;
  file_contents : (string * string) list;
  fetch_file : fetch_file;
  trigger : trigger;
  source_kind : source_kind;
}
