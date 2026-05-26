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
