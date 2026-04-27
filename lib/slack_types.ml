(** Slack Web API payload types. *)

open Melange_json.Primitives

type slack_field = {
  title : string;
  value : string;
  short : bool;
}
[@@deriving json]

type slack_attachment = {
  color : string;
  title : string;
  title_link : string;
  text : string;
  fields : slack_field list; [@json.default []]
  footer : string option; [@json.option]
}
[@@deriving json]

type slack_message = {
  channel : string;
  text : string;
  attachments : slack_attachment list option; [@json.option]
}
[@@deriving json]

type slack_api_response = {
  ok : bool;
  error : string option; [@json.option]
}
[@@deriving json]
