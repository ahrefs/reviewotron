open Devkit

let log = Log.from "api_remote"

let log_context_prefix = function
  | None -> ""
  | Some context -> context ^ " "

(** {2 HTTP helpers — following monorobot's util.ml pattern} *)

let repo_url_re = Re2.create_exn {|github\.com/([^/]+)/([^/]+)|}

let http_request = Http_util.http_request

(** Extract owner/repo from a GitHub URL like "https://github.com/owner/repo" *)
let parse_repo repo_url =
  try
    match Re2.find_submatches_exn repo_url_re repo_url with
    | [| _; Some owner; Some repo |] -> Some (owner, repo)
    | _ -> None
  with exn ->
    ignore (exn : exn);
    None

(** Parse a JSON array of pull_request_file objects.
    Tries strict parsing first; falls back to per-item parsing so one bad entry
    doesn't crash the whole list. *)
let parse_pr_files_json body =
  match Melange_json.of_string body with
  | exception _exn ->
    log#warn "failed to parse PR files JSON: %s" body;
    []
  | json ->
  try Melange_json.Primitives.list_of_json Github_types.pull_request_file_of_json json
  with _exn ->
    log#warn "strict PR files parse failed, trying per-item fallback";
    (match json with
    | `List items ->
      List.filter_map
        (fun item ->
          try Some (Github_types.pull_request_file_of_json item)
          with exn ->
            log#warn "skipping malformed PR file entry: %s" (Exn.str exn);
            None)
        items
    | _ -> [])

(** {2 GitHub API request plumbing} *)

let build_headers ~auth_header ~accept = [ auth_header; Printf.sprintf "Accept: %s" accept ]

let resolve_auth ~ctx ~repo_url =
  match Context.get_repo_auth ctx ~repo_url with
  | None -> Lwt.return (Error (Printf.sprintf "no auth configured for repo %s" repo_url))
  | Some auth ->
    let%lwt result = Github_auth.auth_header auth in
    Lwt.return (Result.map (fun (k, v) -> Printf.sprintf "%s: %s" k v) result)

(* A non-HTTP failure local to request setup (auth, URL parsing). *)
let local_error message : Http_util.error = Http_util.Local message

let github_request ~ctx ~repo_url ~path ?(accept = "application/json") ?body ?log_context meth =
  let%lwt auth = resolve_auth ~ctx ~repo_url in
  match auth with
  | Error msg -> Lwt.return (Error (local_error msg))
  | Ok auth_header ->
  match parse_repo repo_url with
  | None -> Lwt.return (Error (local_error (Printf.sprintf "cannot parse owner/repo from %s" repo_url)))
  | Some (owner, repo) ->
    let url = Printf.sprintf "https://api.github.com/repos/%s/%s%s" owner repo path in
    let headers = build_headers ~auth_header ~accept in
    let label = Printf.sprintf "%s%s %s" (log_context_prefix log_context) (Web.string_of_http_action meth) url in
    Github_retry.with_retry ~label (fun () -> http_request ~headers ?body meth url)
    |> Lwt.map (Result.map_error (Http_util.query_error_msg url))

let github_get ~ctx ~repo_url ~path ?accept ?log_context () =
  github_request ~ctx ~repo_url ~path ?accept ?log_context `GET

let github_post ~ctx ~repo_url ~path ?accept ?log_context ~body () =
  github_request ~ctx ~repo_url ~path ?accept ?log_context ~body:(`Raw ("application/json; charset=utf-8", body)) `POST

let github_delete ~ctx ~repo_url ~path ?accept ?log_context () =
  github_request ~ctx ~repo_url ~path ?accept ?log_context `DELETE

(* Flatten a typed-error github result to the string-error result the
   [Api.Github] signature uses, mapping the response body with [f]. *)
let flatten_result f result = result |> Result.map_error Http_util.error_to_string |> Result.map f

(* Specialisation for the common write call that ignores the response body. *)
let ignore_body_result result = flatten_result (fun (_body : string) -> ()) result

let parse_created_pr_review body =
  try Ok (Github_types.created_pr_review_of_json (Melange_json.of_string body))
  with exn -> Error (Printf.sprintf "failed to parse created PR review response: %s" (Exn.str exn))

let parse_pr_review_comments body =
  try Ok (Melange_json.Primitives.list_of_json Github_types.pr_review_comment_of_json (Melange_json.of_string body))
  with exn -> Error (Printf.sprintf "failed to parse PR review comments response: %s" (Exn.str exn))

let parse_reactions body =
  try Ok (Melange_json.Primitives.list_of_json Github_types.reaction_of_json (Melange_json.of_string body))
  with exn -> Error (Printf.sprintf "failed to parse reactions response: %s" (Exn.str exn))

let github_page_size = 100

let paginated_path ~page_size ~page path =
  let separator =
    match String.contains path '?' with
    | true -> "&"
    | false -> "?"
  in
  Printf.sprintf "%s%sper_page=%d&page=%d" path separator page_size page

let collect_paginated_list ~page_size ~fetch_page ~parse =
  if page_size < 1 then invalid_arg "page_size must be positive"
  else (
    let rec loop page acc =
      let%lwt result = fetch_page page in
      match result with
      | Error e -> Lwt.return (Error (Http_util.error_to_string e))
      | Ok body ->
      match parse body with
      | Error msg -> Lwt.return (Error msg)
      | Ok items ->
        let acc = List.rev_append items acc in
        (match List.compare_length_with items page_size < 0 with
        | true -> Lwt.return (Ok (List.rev acc))
        | false -> loop (page + 1) acc)
    in
    loop 1 [])

(** {2 Github module implementation} *)

module Github : Api.Github = struct
  let get_config ~ctx ~repo_url =
    let config_filename = Context.config_filename ctx in
    let path = Printf.sprintf "/contents/%s" config_filename in
    let%lwt result = github_get ~ctx ~repo_url ~path () in
    match result with
    | Error (Http_util.Status (404, _)) ->
      log#info "no %s found in %s, using defaults" config_filename repo_url;
      Lwt.return (Ok (Context.default_config ()))
    | Error e ->
      Lwt.return (Error (Printf.sprintf "failed to fetch config from %s: %s" repo_url (Http_util.error_to_string e)))
    | Ok body ->
    match Github_types.content_api_response_of_json (Melange_json.of_string body) with
    | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse content API response: %s" (Exn.str exn)))
    | response ->
    match response.encoding with
    | "base64" ->
      let cleaned = Stre.replace_all ~str:response.content ~sub:"\n" ~by:"" in
      (match Base64.decode cleaned with
      | Ok decoded ->
        (match Config_types.config_of_json (Melange_json.of_string decoded) with
        | config -> Lwt.return (Ok config)
        | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse config JSON: %s" (Exn.str exn))))
      | Error (`Msg msg) -> Lwt.return (Error (Printf.sprintf "failed to decode base64 config: %s" msg)))
    | encoding -> Lwt.return (Error (Printf.sprintf "unexpected encoding '%s' in config response" encoding))

  let get_pr_files ~ctx ~repo_url ~number =
    let path = Printf.sprintf "/pulls/%d/files" number in
    let%lwt result = github_get ~ctx ~repo_url ~path () in
    Lwt.return (flatten_result parse_pr_files_json result)

  let get_pr_diff ~ctx ~repo_url ~number ?log_context () =
    let path = Printf.sprintf "/pulls/%d" number in
    github_get ~ctx ~repo_url ~path ~accept:"application/vnd.github.v3.diff" ?log_context ()

  let get_pull_request ~ctx ~repo_url ~number =
    let path = Printf.sprintf "/pulls/%d" number in
    let%lwt result = github_get ~ctx ~repo_url ~path () in
    match result with
    | Error e -> Lwt.return (Error (Http_util.error_to_string e))
    | Ok body ->
    try Lwt.return (Ok (Github_types.pull_request_of_json (Melange_json.of_string body)))
    with exn -> Lwt.return (Error (Printf.sprintf "failed to parse pull_request response: %s" (Exn.str exn)))

  let get_compare_diff ~ctx ~repo_url ~base ~head ?log_context () =
    let path = Printf.sprintf "/compare/%s...%s" (Web.urlencode base) (Web.urlencode head) in
    github_get ~ctx ~repo_url ~path ~accept:"application/vnd.github.v3.diff" ?log_context ()

  let get_file_content ~ctx ~repo_url ~path:file_path ~ref_ ?log_context () =
    let log_prefix = log_context_prefix log_context in
    let path = Printf.sprintf "/contents/%s?ref=%s" file_path (Web.urlencode ref_) in
    let%lwt result = github_get ~ctx ~repo_url ~path ~accept:"application/vnd.github.v3.raw" ?log_context () in
    match result with
    | Ok body -> Lwt.return (Ok (Some body))
    | Error e ->
      log#warn "%sget_file_content failed for %s (ref %s): %s" log_prefix file_path ref_ (Http_util.error_to_string e);
      Lwt.return (Ok None)

  let create_pr_review ~ctx ~repo_url ~number ?log_context review =
    let path = Printf.sprintf "/pulls/%d/reviews" number in
    let body = Melange_json.to_string (Github_types.create_review_req_to_json review) in
    let%lwt result = github_post ~ctx ~repo_url ~path ~accept:"application/vnd.github+json" ?log_context ~body () in
    Lwt.return
      (match result with
      | Error e -> Error (Http_util.error_to_string e)
      | Ok body -> parse_created_pr_review body)

  let create_commit_comment ~ctx ~repo_url ~sha ?log_context comment =
    let path = Printf.sprintf "/commits/%s/comments" sha in
    let body = Melange_json.to_string (Github_types.commit_comment_req_to_json comment) in
    let%lwt result = github_post ~ctx ~repo_url ~path ?log_context ~body () in
    Lwt.return (ignore_body_result result)

  let create_issue_comment ~ctx ~repo_url ~number ?log_context comment =
    let path = Printf.sprintf "/issues/%d/comments" number in
    let body = Melange_json.to_string (Github_types.issue_comment_req_to_json comment) in
    let%lwt result = github_post ~ctx ~repo_url ~path ?log_context ~body () in
    Lwt.return (ignore_body_result result)

  let list_pr_review_comments ~ctx ~repo_url ~number ~review_id =
    let path = Printf.sprintf "/pulls/%d/reviews/%d/comments" number review_id in
    collect_paginated_list ~page_size:github_page_size ~parse:parse_pr_review_comments ~fetch_page:(fun page ->
      github_get ~ctx ~repo_url
        ~path:(paginated_path ~page_size:github_page_size ~page path)
        ~accept:"application/vnd.github+json" ())

  let list_pr_review_comment_reactions ~ctx ~repo_url ~comment_id =
    let path = Printf.sprintf "/pulls/comments/%d/reactions" comment_id in
    collect_paginated_list ~page_size:github_page_size ~parse:parse_reactions ~fetch_page:(fun page ->
      github_get ~ctx ~repo_url
        ~path:(paginated_path ~page_size:github_page_size ~page path)
        ~accept:"application/vnd.github+json" ())

  let create_reaction ~ctx ~repo_url ~path ~content ?log_context () =
    let body = Melange_json.to_string (Github_types.reaction_req_to_json { content }) in
    let%lwt result = github_post ~ctx ~repo_url ~path ?log_context ~body () in
    match result with
    | Error e -> Lwt.return (Error (Http_util.error_to_string e))
    | Ok body ->
    match Github_types.reaction_of_json (Melange_json.of_string body) with
    | reaction -> Lwt.return (Ok reaction.id)
    | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse reaction response: %s" (Exn.str exn)))

  let create_issue_reaction ~ctx ~repo_url ~number ~content ?log_context () =
    let path = Printf.sprintf "/issues/%d/reactions" number in
    create_reaction ~ctx ~repo_url ~path ~content ?log_context ()

  let create_issue_comment_reaction ~ctx ~repo_url ~comment_id ~content ?log_context () =
    let path = Printf.sprintf "/issues/comments/%d/reactions" comment_id in
    create_reaction ~ctx ~repo_url ~path ~content ?log_context ()

  let delete_issue_reaction ~ctx ~repo_url ~number ~reaction_id ?log_context () =
    let path = Printf.sprintf "/issues/%d/reactions/%d" number reaction_id in
    let%lwt result = github_delete ~ctx ~repo_url ~path ~accept:"application/vnd.github+json" ?log_context () in
    Lwt.return (ignore_body_result result)

  let delete_issue_comment_reaction ~ctx ~repo_url ~comment_id ~reaction_id ?log_context () =
    let path = Printf.sprintf "/issues/comments/%d/reactions/%d" comment_id reaction_id in
    let%lwt result = github_delete ~ctx ~repo_url ~path ~accept:"application/vnd.github+json" ?log_context () in
    Lwt.return (ignore_body_result result)
end

(** {2 Agent runner — wraps ocaml-ai-sdk for AI agent execution} *)

module Agent_runner : Api.Agent_runner = struct
  let run ~ctx ~repo_url ?model_id ?tools ?debug_dir ?log_context ~config ~input () =
    let secrets = Context.secrets ctx in
    ignore (repo_url : string);
    match Llm_provider.resolve secrets with
    | Error msg -> Lwt.return_error msg
    | Ok provider ->
      let base_model_id = Option.default (Agent_runner.default_model_id config.Agent_runner.model_tier) model_id in
      let model_id = Llm_provider.normalize_model_id provider base_model_id in
      let model = Llm_provider.language_model provider ~secrets ~model_id in
      Agent_runner.run_agent ~provider ~model ?tools ?debug_dir ?log_context ~config ~input ()
end

(** {2 Slack API} *)

module Slack : Api.Slack = struct
  let post_message ~ctx ~channel ~text ?attachments () =
    let secrets = Context.secrets ctx in
    match secrets.slack_access_token with
    | None ->
      log#info "Slack access token not configured, skipping message";
      Lwt.return_unit
    | Some access_token ->
      let msg : Slack_types.slack_message = { channel; text; attachments } in
      let body_str = Melange_json.to_string (Slack_types.slack_message_to_json msg) in
      let headers = [ Printf.sprintf "Authorization: Bearer %s" access_token ] in
      let%lwt result =
        http_request ~headers ~body:(`Raw ("application/json", body_str)) `POST "https://slack.com/api/chat.postMessage"
      in
      (match result with
      | Ok response_str ->
        (try
           let resp = Slack_types.slack_api_response_of_json (Melange_json.of_string response_str) in
           match resp.ok with
           | true -> log#info "Slack message sent to %s" channel
           | false ->
             let err = Option.default "unknown" resp.error in
             log#error "Slack API error: %s" err
         with _exn -> log#warn "could not parse Slack response: %s" response_str)
      | Error e -> log#error "Slack request failed: %s" (Http_util.error_to_string e));
      Lwt.return_unit
end
