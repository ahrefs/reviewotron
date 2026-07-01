(** GitHub webhook and API types. *)

(** {2 Scalar aliases} *)

type commit_hash = string [@@deriving json]

type pr_action = string [@@deriving json]

(** {2 Core user types} *)

type git_user = {
  name : string;
  email : string;
  username : string option;
}
[@@deriving json]

type github_user = {
  login : string;
  id : int;
  url : string;
  html_url : string;
  avatar_url : string;
  type_ : string option;
}
[@@deriving json]

type github_app = { id : int } [@@deriving json]

type label = { name : string } [@@deriving json]

(** {2 Repository} *)

type repository = {
  name : string;
  full_name : string;
  url : string;
  commits_url : string;
  contents_url : string;
  pulls_url : string;
  issues_url : string;
  compare_url : string;
}
[@@deriving json]

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
[@@deriving json]

type commit_pushed_notification = {
  ref_ : string;
  before : commit_hash;
  after : commit_hash;
  base_ref : string option;
  created : bool;
  deleted : bool;
  forced : bool;
  commits : commit list;
  head_commit : commit option;
  repository : repository;
  compare : string;
  pusher : git_user;
  sender : github_user;
}
[@@deriving json]

(** {2 Pull request types} *)

type pr_branch = {
  sha : commit_hash;
  ref_ : string;
  label : string;
  repo : repository option;
  user : github_user option;
}
[@@deriving json]

type pull_request = {
  number : int;
  title : string;
  body : string option;
  html_url : string;
  diff_url : string;
  state : string;
  user : github_user;
  head : pr_branch;
  base : pr_branch;
  draft : bool;
  merged : bool;
  labels : label list;
  comments : int;
  additions : int;
  deletions : int;
  changed_files : int;
  performed_via_github_app : github_app option;
}
[@@deriving json]

type webhook_pull_request_ref = {
  number : int;
  title : string;
}
[@@deriving json]

type installation = { id : int } [@@deriving json]

type pr_notification = {
  action : pr_action;
  number : int;
  pull_request : pull_request;
  repository : repository;
  sender : github_user;
  installation : installation option;
  performed_via_github_app : github_app option;
}
[@@deriving json]

(** {2 Issue comment types}

    Webhook events for comments on issues and pull requests.  The
    [issue.pull_request] sub-field is non-null exactly when the underlying
    issue is a PR, so it is the discriminator the dispatch layer checks
    before treating an [issue_comment] event as a PR comment. *)

type issue_pull_request_ref = { url : string } [@@deriving json]

type issue = {
  number : int;
  title : string;
  state : string;
  user : github_user option;
  html_url : string;
  pull_request : issue_pull_request_ref option;
}
[@@deriving json]

type issue_comment = {
  id : int;
  body : string;
  user : github_user option;
  html_url : string;
  performed_via_github_app : github_app option;
}
[@@deriving json]

type issue_comment_notification = {
  action : string;
  issue : issue;
  comment : issue_comment;
  repository : repository;
  sender : github_user;
  installation : installation option;
  performed_via_github_app : github_app option;
}
[@@deriving json]

(** {2 Pull request review webhook types} *)

type pull_request_review = {
  id : int;
  body : string option;
  state : string;
  user : github_user option;
  performed_via_github_app : github_app option;
}
[@@deriving json]

type pull_request_review_notification = {
  action : string;
  review : pull_request_review;
  pull_request : webhook_pull_request_ref;
  repository : repository;
  sender : github_user;
  installation : installation option;
  performed_via_github_app : github_app option;
}
[@@deriving json]

type pull_request_review_comment = {
  id : int;
  body : string;
  path : string option;
  line : int option;
  user : github_user option;
  performed_via_github_app : github_app option;
}
[@@deriving json]

type pull_request_review_comment_notification = {
  action : string;
  comment : pull_request_review_comment;
  pull_request : webhook_pull_request_ref;
  repository : repository;
  sender : github_user;
  installation : installation option;
  performed_via_github_app : github_app option;
}
[@@deriving json]

(** {2 GitHub API response types} *)

type pull_request_file = {
  sha : string option;
  filename : string;
  status : string;
  additions : int;
  deletions : int;
  changes : int;
  blob_url : string;
  raw_url : string;
  contents_url : string;
  patch : string option;
  previous_filename : string option;
}
[@@deriving json]

(** {2 Diff side — bare string enum} *)

type diff_side =
  | Left
  | Right

val diff_side_to_string : diff_side -> string
val diff_side_of_string : string -> diff_side
val diff_side_to_json : diff_side -> Yojson.Basic.t
val diff_side_of_json : Yojson.Basic.t -> diff_side

(** {2 Review event — bare string enum} *)

type review_event =
  | Comment
  | Approve
  | Request_changes

val review_event_to_string : review_event -> string
val review_event_of_string : string -> review_event
val review_event_to_json : review_event -> Yojson.Basic.t
val review_event_of_json : Yojson.Basic.t -> review_event

(** {2 Review request types} *)

type review_comment_req = {
  path : string;
  position : int option;
  line : int option;
  side : diff_side option;
  start_line : int option;
  start_side : diff_side option;
  body : string;
}
[@@deriving json]

type create_review_req = {
  commit_id : string option;
  body : string;
  event : review_event;
  comments : review_comment_req list;
}

val create_review_req_to_json : create_review_req -> Yojson.Basic.t
val create_review_req_of_json : Yojson.Basic.t -> create_review_req

type created_pr_review = {
  id : int;
  html_url : string option;
}
[@@deriving json]

type commit_comment_req = {
  body : string;
  path : string option;
  position : int option;
  line : int option;
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
[@@deriving json]

type pr_review_comment = {
  id : int;
  body : string;
}
[@@deriving json]

(** {2 Webhook envelope} *)

type webhook_envelope = { repository : repository } [@@deriving json]

(** {2 GitHub Contents API response} *)

type content_api_response = {
  content : string;
  encoding : string;
  name : string;
  path : string;
}
[@@deriving json]

(** {2 GitHub App installation token} *)

type installation_token_response = {
  token : string;
  expires_at : string;
}
[@@deriving json]
