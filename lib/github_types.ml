(** GitHub webhook and API types.

    {2 JSON encoding}

    Most types use [[@@deriving json]] from melange-json-native.

    [diff_side] and [review_event] are string enums in GitHub's API
    (e.g. ["LEFT"], ["APPROVE"]).  This bare-string encoding is incompatible
    with melange-json-native's derived variant format, so these two types have
    manual [to_json]/[of_json] (justified under PRD rule "no manual JSON
    unless impossible"). *)

open Melange_json.Primitives

(** {2 Scalar aliases} *)

type commit_hash = string [@@deriving json]

type pr_action = string [@@deriving json]

(** {2 Core user types} *)

type git_user = {
  name : string;
  email : string;
  username : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type github_user = {
  login : string;
  id : int;
  url : string;
  html_url : string;
  avatar_url : string;
  type_ : string option; [@json.key "type"] [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type github_app = { id : int } [@@deriving json] [@@json.allow_extra_fields]

type label = { name : string } [@@deriving json] [@@json.allow_extra_fields]

(** {2 Repository} *)

type repository = {
  name : string;
  full_name : string;
  url : string; [@json.key "html_url"]
  commits_url : string;
  contents_url : string;
  pulls_url : string;
  issues_url : string;
  compare_url : string;
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 Commit types} *)

type commit = {
  id : commit_hash;
  distinct : bool;
  message : string;
  timestamp : string;
  url : string;
  author : git_user;
  committer : git_user;
  added : string list;
  removed : string list;
  modified : string list;
}
[@@deriving json] [@@json.allow_extra_fields]

type commit_pushed_notification = {
  ref_ : string; [@json.key "ref"]
  before : commit_hash;
  after : commit_hash;
  base_ref : string option; [@json.option]
  created : bool;
  deleted : bool;
  forced : bool;
  commits : commit list;
  head_commit : commit option; [@json.option]
  repository : repository;
  compare : string;
  pusher : git_user;
  sender : github_user;
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 Pull request types} *)

type pr_branch = {
  sha : commit_hash;
  ref_ : string; [@json.key "ref"]
  label : string;
  repo : repository option; [@json.option]
  user : github_user option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type pull_request = {
  number : int;
  title : string;
  body : string option; [@json.option]
  html_url : string;
  diff_url : string;
  state : string;
  user : github_user;
  head : pr_branch;
  base : pr_branch;
  draft : bool; [@json.default false]
  merged : bool; [@json.default false]
  labels : label list; [@json.default []]
  comments : int; [@json.default 0]
  additions : int;
  deletions : int;
  changed_files : int;
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type webhook_pull_request_ref = {
  number : int;
  title : string;
}
[@@deriving json] [@@json.allow_extra_fields]

type installation = { id : int } [@@deriving json] [@@json.allow_extra_fields]

type pr_notification = {
  action : pr_action;
  number : int;
  pull_request : pull_request;
  repository : repository;
  sender : github_user;
  installation : installation option; [@json.option]
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 Issue comment types}

    The [issue_comment] webhook event covers comments on both regular issues
    and pull requests.  GitHub delivers the [issue] shape (not the
    [pull_request] shape) regardless of which one the comment lives on; the
    [issue.pull_request] sub-field is non-null exactly when the underlying
    issue is a PR.

    The inner [issue_pull_request_ref] carries [url], [html_url], [diff_url],
    [patch_url], and [merged_at] in the wire format — none of which we read.
    The single [url] field below is a placeholder so the record decodes
    cleanly; everything else is dropped via [allow_extra_fields].

    [user] fields are nullable in GitHub's schema (e.g. when an account has
    been deleted), so we model them as [github_user option] even though
    freshly-created comments and issues normally carry a populated user. *)

type issue_pull_request_ref = { url : string } [@@deriving json] [@@json.allow_extra_fields]

type issue = {
  number : int;
  title : string;
  state : string;
  user : github_user option; [@json.option]
  html_url : string;
  pull_request : issue_pull_request_ref option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type issue_comment = {
  id : int;
  body : string;
  user : github_user option; [@json.option]
  html_url : string;
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type issue_comment_notification = {
  action : string;
  issue : issue;
  comment : issue_comment;
  repository : repository;
  sender : github_user;
  installation : installation option; [@json.option]
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 Pull request review webhook types} *)

type pull_request_review = {
  id : int;
  body : string option; [@json.option]
  state : string;
  user : github_user option; [@json.option]
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type pull_request_review_notification = {
  action : string;
  review : pull_request_review;
  pull_request : webhook_pull_request_ref;
  repository : repository;
  sender : github_user;
  installation : installation option; [@json.option]
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type pull_request_review_comment = {
  id : int;
  body : string;
  path : string option; [@json.option]
  line : int option; [@json.option]
  user : github_user option; [@json.option]
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

type pull_request_review_comment_notification = {
  action : string;
  comment : pull_request_review_comment;
  pull_request : webhook_pull_request_ref;
  repository : repository;
  sender : github_user;
  installation : installation option; [@json.option]
  performed_via_github_app : github_app option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 GitHub API response types} *)

type pull_request_file = {
  sha : string option; [@json.option]
  filename : string;
  status : string;
  additions : int;
  deletions : int;
  changes : int;
  blob_url : string;
  raw_url : string;
  contents_url : string;
  patch : string option; [@json.option]
  previous_filename : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 Diff side — bare string enum} *)

type diff_side =
  | Left
  | Right

let diff_side_to_string = function
  | Left -> "LEFT"
  | Right -> "RIGHT"

let diff_side_of_string = function
  | "LEFT" -> Left
  | "RIGHT" -> Right
  | s -> invalid_arg (Printf.sprintf "unknown diff_side: %s" s)

let diff_side_to_json side = `String (diff_side_to_string side)

let diff_side_of_json = function
  | `String s -> diff_side_of_string s
  | json -> Melange_json.of_json_error ~json "expected a string for diff_side"

(** {2 Review event — bare string enum} *)

type review_event =
  | Comment
  | Approve
  | Request_changes

let review_event_to_string = function
  | Comment -> "COMMENT"
  | Approve -> "APPROVE"
  | Request_changes -> "REQUEST_CHANGES"

let review_event_of_string = function
  | "COMMENT" -> Comment
  | "APPROVE" -> Approve
  | "REQUEST_CHANGES" -> Request_changes
  | s -> invalid_arg (Printf.sprintf "unknown review_event: %s" s)

let review_event_to_json ev = `String (review_event_to_string ev)

let review_event_of_json = function
  | `String s -> review_event_of_string s
  | json -> Melange_json.of_json_error ~json "expected a string for review_event"

(** {2 Review request types} *)

type review_comment_req = {
  path : string;
  position : int option; [@json.option] [@json.drop_default]
  line : int option; [@json.option] [@json.drop_default]
  side : diff_side option; [@json.option] [@json.drop_default]
  start_line : int option; [@json.option] [@json.drop_default]
  start_side : diff_side option; [@json.option] [@json.drop_default]
  body : string;
}
[@@deriving json]

type create_review_req = {
  commit_id : string option; [@json.option] [@json.drop_default]
  body : string;
  event : review_event;
  comments : review_comment_req list; [@json.default []]
}
[@@deriving of_json]

type created_pr_review = {
  id : int;
  node_id : string option; [@json.option]
  html_url : string option; [@json.option]
}
[@@deriving json] [@@json.allow_extra_fields]

(** Manual [to_json]: omits [comments] when empty (matching ATD's behavior
    of dropping default-valued fields). *)
let create_review_req_to_json req =
  let fields = [ "body", `String req.body; "event", review_event_to_json req.event ] in
  let fields =
    match req.commit_id with
    | None -> fields
    | Some id -> ("commit_id", `String id) :: fields
  in
  let fields =
    match req.comments with
    | [] -> fields
    | comments -> ("comments", `List (List.map review_comment_req_to_json comments)) :: fields
  in
  `Assoc fields

type commit_comment_req = {
  body : string;
  path : string option; [@json.option] [@json.drop_default]
  position : int option; [@json.option] [@json.drop_default]
  line : int option; [@json.option] [@json.drop_default]
}
[@@deriving json]

(** Request body for an issue (PR) comment: [POST /issues/{number}/comments]. *)
type issue_comment_req = { body : string } [@@deriving json]

(** {2 Reactions} *)

type reaction_req = { content : string } [@@deriving json]

type reaction = {
  id : int;
  content : string;
}
[@@deriving json] [@@json.allow_extra_fields]

type reaction_counts = {
  plus_one : int;
  minus_one : int;
}
[@@deriving json]

type pr_review_comment = {
  id : int;
  body : string;
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 Webhook envelope} *)

type webhook_envelope = { repository : repository } [@@deriving json] [@@json.allow_extra_fields]

(** {2 GitHub Contents API response} *)

type content_api_response = {
  content : string;
  encoding : string;
  name : string;
  path : string;
}
[@@deriving json] [@@json.allow_extra_fields]

(** {2 GitHub App installation token} *)

type installation_token_response = {
  token : string;
  expires_at : string;
}
[@@deriving json] [@@json.allow_extra_fields]
