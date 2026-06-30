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

let diff_sha256 job = sha256_hex job.diff_text

let config_sha256 job = Config_types.config_to_json job.config |> Yojson.Basic.to_string |> sha256_hex
