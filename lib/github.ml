open Devkit

let log = Log.from "github"

type pr_action =
  | Opened
  | Closed
  | Synchronize
  | Reopened
  | Edited
  | Ready_for_review
  | Other of string

let pr_action_of_string = function
  | "opened" -> Opened
  | "closed" -> Closed
  | "synchronize" -> Synchronize
  | "reopened" -> Reopened
  | "edited" -> Edited
  | "ready_for_review" -> Ready_for_review
  | s -> Other s

type event =
  | Pull_request of Github_types.pr_notification
  | Push of Github_types.commit_pushed_notification
  | Unknown of string

let repo_url_of_event = function
  | Pull_request n -> n.repository.url
  | Push n -> n.repository.url
  | Unknown _ -> ""

let validate_signature ~secret ~signature ~body =
  match String.split_on_char '=' signature with
  | [ "sha256"; hex_sig ] ->
    let expected = Digestif.SHA256.hmac_string ~key:secret body in
    (match Digestif.SHA256.of_hex hex_sig with
    | received -> if Digestif.SHA256.equal expected received then Ok () else Error "HMAC signature mismatch"
    | exception _ -> Error "HMAC signature: invalid hex encoding")
  | _ -> Error "HMAC signature: unsupported format"

let parse_event ~event_type ~body =
  match event_type with
  | "pull_request" ->
    (try
       let n = Github_types.pr_notification_of_json (Melange_json.of_string body) in
       log#info "[%s] PR #%d: action=%s, title=%s, user=%s" n.repository.full_name n.pull_request.number n.action
         n.pull_request.title n.pull_request.user.login;
       Ok (Pull_request n)
     with exn -> Error (Printf.sprintf "failed to parse pull_request payload: %s" (Exn.str exn)))
  | "push" ->
    (try
       let n = Github_types.commit_pushed_notification_of_json (Melange_json.of_string body) in
       let num_commits = List.length n.commits in
       log#info "[%s] push: ref=%s, commits=%d, pusher=%s" n.repository.full_name n.ref_ num_commits n.pusher.name;
       Ok (Push n)
     with exn -> Error (Printf.sprintf "failed to parse push payload: %s" (Exn.str exn)))
  | other -> Ok (Unknown other)
