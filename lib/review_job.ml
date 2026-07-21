let log = Devkit.Log.from "review_job"

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

(* The deep reviewer is preloaded with the full contents of a few files the
   change touches, so it can verify leads it cannot ground in the diff alone.
   Only the first [max_key_files] added/modified files are embedded; deletions
   have no post-change content and renames are followed via their diff. *)
let max_key_files = 5

let key_file_paths ~diff =
  diff
  |> List.filter (fun (fd : Diff_parser.file_diff) ->
    match fd.status with
    | Diff_parser.Added | Diff_parser.Modified -> true
    | Diff_parser.Renamed | Diff_parser.Deleted -> false)
  |> List.map (fun (fd : Diff_parser.file_diff) -> fd.path)
  |> fun paths -> CCList.take max_key_files paths

(* Select and fetch the deep reviewer's preloaded file contents. Source
   adapters differ only in [fetch] — GitHub reads from the PR head SHA over the
   API, local mode reads the worktree or a git revision — so the selection
   (added/modified, first [max_key_files]) and the drop policy (an unavailable
   or unreadable file is skipped, matching each [fetch]'s embeddable guard) live
   here once. Fetches run concurrently, mirroring the GitHub source; the local
   fetchers are internally synchronous, so this is at worst a no-op there. *)
let select_key_files ?(log_context = "") ~diff ~(fetch : fetch_file) () =
  Lwt_list.filter_map_p
    (fun path ->
      match%lwt fetch ~path with
      | Ok (Some content) -> Lwt.return (Some (path, content))
      | Ok None -> Lwt.return None
      | Error msg ->
        log#warn "%sfailed to fetch %s: %s" log_context path msg;
        Lwt.return None)
    (key_file_paths ~diff)

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

let span_attrs ?fetched_files (job : t) =
  let attrs =
    [
      "reviewotron.repo_key", `String job.repo_key;
      "reviewotron.change_label", `String job.change_label;
      "reviewotron.head_sha", `String job.head_sha;
      "reviewotron.review.trigger", `String (trigger_to_string job.trigger);
      "reviewotron.review.source", `String (source_kind_to_string job.source_kind);
      "reviewotron.review.files", `Int (List.length job.filtered_diff);
      "reviewotron.review.diff_lines", `Int (Diff_parser.total_lines job.filtered_diff);
      "reviewotron.review.diff_bytes", `Int (String.length job.diff_text);
    ]
  in
  match fetched_files with
  | None -> attrs
  | Some count -> attrs @ [ "reviewotron.review.fetched_files", `Int count ]
