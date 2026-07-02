type trigger =
  | Pull_request
  | Push
  | Manual
  | Local
  | Other of string

type source_kind =
  | Github
  | Local
  | Other of string

type fetch_file = path:string -> (string option, string) result Lwt.t

let short_display_id id = String.sub id 0 (min 8 (String.length id))

let strip_trailing_slashes value =
  let rec length_without_trailing_slashes i =
    match i < 0 with
    | true -> 0
    | false ->
    match Char.equal value.[i] '/' with
    | true -> length_without_trailing_slashes (i - 1)
    | false -> i + 1
  in
  String.sub value 0 (length_without_trailing_slashes (String.length value - 1))

let repo_slug url =
  let url =
    match String.split_on_char '/' url with
    | ("https:" | "http:") :: "" :: _host :: parts -> String.concat "/" parts
    | _ -> url
  in
  let url = strip_trailing_slashes url in
  let url =
    match Filename.chop_suffix_opt ~suffix:".git" url with
    | Some without_suffix -> without_suffix
    | None -> url
  in
  String.map
    (function
      | '/' -> '-'
      | c -> c)
    url

let compact_change_label change_label =
  let label = String.trim change_label in
  let pr_prefix = "PR " in
  let label =
    match String.starts_with ~prefix:pr_prefix label with
    | true -> String.sub label (String.length pr_prefix) (String.length label - String.length pr_prefix)
    | false -> label
  in
  String.map
    (function
      | ' ' | '\t' | '\n' | '\r' | '/' -> '-'
      | c -> c)
    label

let source_kind_to_string = function
  | Github -> "github"
  | Local -> "local"
  | Other value -> value

let trigger_to_string = function
  | Pull_request -> "pull_request"
  | Push -> "push"
  | Manual -> "manual"
  | Local -> "local"
  | Other value -> value

let sha256_hex value = Digestif.SHA256.(digest_string value |> to_hex)

let max_embeddable_bytes = 256 * 1024

(* Well-formed UTF-8 with no NUL bytes. A NUL byte is git's own signal that a
   blob is binary, and the stdlib decoder flags any malformed sequence —
   including the unpaired surrogates the JSON encoder rejects. *)
let is_text content =
  let len = String.length content in
  let rec scan i =
    match i >= len with
    | true -> true
    | false ->
    match content.[i] with
    | '\000' -> false
    | _ ->
      let d = String.get_utf_8_uchar content i in
      (match Uchar.utf_decode_is_valid d with
      | false -> false
      | true -> scan (i + Uchar.utf_decode_length d))
  in
  scan 0

let is_embeddable content = String.length content <= max_embeddable_bytes && is_text content

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

let log_context_for ~repo_key ~change_label ~head_sha =
  Printf.sprintf "[%s/%s/%s]" (repo_slug repo_key) (compact_change_label change_label) (short_display_id head_sha)

let log_context job = log_context_for ~repo_key:job.repo_key ~change_label:job.change_label ~head_sha:job.head_sha

let diff_sha256 job = sha256_hex job.diff_text

let config_sha256 job = Config_types.config_to_json job.config |> Yojson.Basic.to_string |> sha256_hex
