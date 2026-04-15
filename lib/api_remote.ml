open Devkit

let log = Log.from "api_remote"

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

let github_request ~ctx ~repo_url ~path ?(accept = "application/json") ?body meth =
  let%lwt auth = resolve_auth ~ctx ~repo_url in
  match auth with
  | Error _ as e -> Lwt.return e
  | Ok auth_header ->
  match parse_repo repo_url with
  | None -> Lwt.return (Error (Printf.sprintf "cannot parse owner/repo from %s" repo_url))
  | Some (owner, repo) ->
    let url = Printf.sprintf "https://api.github.com/repos/%s/%s%s" owner repo path in
    let headers = build_headers ~auth_header ~accept in
    http_request ~headers ?body meth url |> Lwt.map (Result.map_error (Http_util.query_error_msg url))

let github_get ~ctx ~repo_url ~path ?accept () = github_request ~ctx ~repo_url ~path ?accept `GET

let github_post ~ctx ~repo_url ~path ~body () =
  github_request ~ctx ~repo_url ~path ~body:(`Raw ("application/json; charset=utf-8", body)) `POST

(** {2 Github module implementation} *)

module Github : Api.Github = struct
  let get_config ~ctx ~repo_url =
    let config_filename = Context.config_filename ctx in
    let path = Printf.sprintf "/contents/%s" config_filename in
    let%lwt result = github_get ~ctx ~repo_url ~path () in
    match result with
    | Error msg when CCString.find ~sub:"404" msg >= 0 ->
      log#info "no %s found in %s, using defaults" config_filename repo_url;
      Lwt.return (Ok (Context.default_config ()))
    | Error msg -> Lwt.return (Error (Printf.sprintf "failed to fetch config from %s: %s" repo_url msg))
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
    Lwt.return (Result.map parse_pr_files_json result)

  let get_pr_diff ~ctx ~repo_url ~number =
    let path = Printf.sprintf "/pulls/%d" number in
    github_get ~ctx ~repo_url ~path ~accept:"application/vnd.github.v3.diff" ()

  let get_compare_diff ~ctx ~repo_url ~base ~head =
    let path = Printf.sprintf "/compare/%s...%s" (Web.urlencode base) (Web.urlencode head) in
    github_get ~ctx ~repo_url ~path ~accept:"application/vnd.github.v3.diff" ()

  let get_file_content ~ctx ~repo_url ~path:file_path ~ref_ =
    let path = Printf.sprintf "/contents/%s?ref=%s" file_path (Web.urlencode ref_) in
    let%lwt result = github_get ~ctx ~repo_url ~path ~accept:"application/vnd.github.v3.raw" () in
    match result with
    | Ok body -> Lwt.return (Ok (Some body))
    | Error msg ->
      log#warn "get_file_content failed for %s (ref %s): %s" file_path ref_ msg;
      Lwt.return (Ok None)

  let create_pr_review ~ctx ~repo_url ~number review =
    let path = Printf.sprintf "/pulls/%d/reviews" number in
    let body = Melange_json.to_string (Github_types.create_review_req_to_json review) in
    let%lwt result = github_post ~ctx ~repo_url ~path ~body () in
    Lwt.return (Result.map (fun (_body : string) -> ()) result)

  let create_commit_comment ~ctx ~repo_url ~sha comment =
    let path = Printf.sprintf "/commits/%s/comments" sha in
    let body = Melange_json.to_string (Github_types.commit_comment_req_to_json comment) in
    let%lwt result = github_post ~ctx ~repo_url ~path ~body () in
    Lwt.return (Result.map (fun (_body : string) -> ()) result)
end

(** {2 Agent runner — wraps ocaml-ai-sdk for AI agent execution} *)

module Agent_runner : Api.Agent_runner = struct
  let run ~ctx ~repo_url ?model_id ?tools ~config ~input () =
    let secrets = Context.secrets ctx in
    let model_id = Option.default (Agent_runner.default_model_id config.Agent_runner.model_tier) model_id in
    ignore (repo_url : string);
    let model = Ai_provider_anthropic.language_model ~api_key:secrets.anthropic_api_key ~model:model_id () in
    Agent_runner.run_agent ~model ?tools ~config ~input ()
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
      | Error e -> log#error "Slack request failed: %s" e);
      Lwt.return_unit
end
