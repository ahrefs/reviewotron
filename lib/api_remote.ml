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
    Tries strict ATD parsing first; falls back to per-item parsing so one bad entry
    doesn't crash the whole list. *)
let parse_pr_files_json body =
  try Github_types_j.pull_request_file_list_of_string body
  with _exn ->
    log#warn "strict PR files parse failed, trying per-item fallback";
    (match Yojson.Safe.from_string body with
    | `List items ->
      List.filter_map
        (fun item ->
          try Some (Github_types_j.pull_request_file_of_string (Yojson.Safe.to_string item))
          with exn ->
            log#warn "skipping malformed PR file entry: %s" (Exn.str exn);
            None)
        items
    | _ -> []
    | exception Yojson.Json_error _ ->
      log#warn "failed to parse PR files JSON: %s" body;
      [])

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
    match Github_types_j.content_api_response_of_string body with
    | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse content API response: %s" (Exn.str exn)))
    | response ->
    match response.encoding with
    | "base64" ->
      let cleaned = Stre.replace_all ~str:response.content ~sub:"\n" ~by:"" in
      (match Base64.decode cleaned with
      | Ok decoded ->
        (match Config_j.config_of_string decoded with
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
    let body = Github_types_j.string_of_create_review_req review in
    let%lwt result = github_post ~ctx ~repo_url ~path ~body () in
    Lwt.return (Result.map (fun (_body : string) -> ()) result)

  let create_commit_comment ~ctx ~repo_url ~sha comment =
    let path = Printf.sprintf "/commits/%s/comments" sha in
    let body = Github_types_j.string_of_commit_comment_req comment in
    let%lwt result = github_post ~ctx ~repo_url ~path ~body () in
    Lwt.return (Result.map (fun (_body : string) -> ()) result)
end

(** {2 Anthropic Claude API}

    We make direct HTTP calls to the Anthropic Messages API rather than using
    the monorepo's [one_llm] library. [one_llm] has heavy internal dependencies
    (o11y tracing, logstash, etc.) that are difficult to import from [experimental/].
    When this app moves to [backend/], we should migrate to [one_llm]. *)

let anthropic_api_url = "https://api.anthropic.com/v1/messages"

(** Build the JSON request body for the Anthropic Messages API with tool_use. *)
let build_anthropic_request ~model ~system ~user_msg ~max_tokens =
  let tool =
    Anthropic_types_t.
      {
        name = "submit_review";
        description = Some "Submit a structured code review with findings for each issue found";
        input_schema = Review_prompt.review_schema;
      }
  in
  let tool_choice = Anthropic_types_t.{ type_ = "tool"; name = "submit_review" } in
  let message = Anthropic_types_t.{ role = User; content = user_msg } in
  let req =
    Anthropic_types_t.
      {
        model;
        messages = [ message ];
        max_tokens;
        system = Some system;
        tools = Some [ tool ];
        tool_choice = Some tool_choice;
      }
  in
  Anthropic_types_j.string_of_req req

(** Extract the tool_use input from Claude's response content blocks. *)
let extract_tool_use_input (response : Anthropic_types_t.response_message) =
  List.find_map
    (function
      | Anthropic_types_t.ToolUse tu when String.equal tu.name "submit_review" -> Some tu.input
      | Text _ | ToolUse _ -> None)
    response.content

module Claude : Api.Claude = struct
  (** Try to parse an error response from the Anthropic API.
      Returns [Some message] if it's an error, [None] otherwise. *)
  let try_parse_error response_str =
    try
      let resp = Anthropic_types_j.error_response_of_string response_str in
      match resp.type_ with
      | "error" -> Some resp.error.message
      | _ -> None
    with _exn -> None

  let review_code ~ctx ~repo_url ~diff ~files ~pr_title ~description =
    let secrets = Context.secrets ctx in
    let config = Context.get_config ctx ~repo_url in
    let system = Review_prompt.system_prompt ?override:config.system_prompt_override () in
    let user_msg =
      Review_prompt.build_user_message ~diff ~pr_title ~pr_description:description ~file_contents:files ()
    in
    let token_est = Review_prompt.estimate_prompt_tokens ~system ~user:user_msg in
    log#info "Claude review request: ~%d estimated tokens" token_est;
    let body_str = build_anthropic_request ~model:config.model ~system ~user_msg ~max_tokens:4096 in
    let headers =
      [
        Printf.sprintf "x-api-key: %s" secrets.anthropic_api_key;
        Printf.sprintf "anthropic-version: %s" secrets.anthropic_version;
      ]
    in
    let%lwt result =
      http_request ~verbose:false ~headers ~body:(`Raw ("application/json", body_str)) `POST anthropic_api_url
    in
    match result with
    | Error e -> Lwt.return (Error (Printf.sprintf "Anthropic API request failed: %s" e))
    | Ok response_str ->
    match try_parse_error response_str with
    | Some err_msg -> Lwt.return (Error (Printf.sprintf "Anthropic API error: %s" err_msg))
    | None ->
    match Anthropic_types_j.response_message_of_string response_str with
    | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse Anthropic response: %s" (Exn.str exn)))
    | response ->
    match extract_tool_use_input response with
    | None -> Lwt.return (Error "Claude did not return submit_review tool use")
    | Some input_json ->
      let json_str = Yojson.Safe.to_string input_json in
      (match Review_types_j.review_output_of_string json_str with
      | review ->
        log#info "Claude review: %d findings, summary length %d" (List.length review.findings)
          (String.length review.summary);
        Lwt.return (Ok review)
      | exception exn ->
        Lwt.return (Error (Printf.sprintf "failed to parse review_output from tool_use input: %s" (Exn.str exn))))
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
      let msg : Slack_types_t.slack_message = { channel; text; attachments } in
      let body_str = Slack_types_j.string_of_slack_message msg in
      let headers = [ Printf.sprintf "Authorization: Bearer %s" access_token ] in
      let%lwt result =
        http_request ~headers ~body:(`Raw ("application/json", body_str)) `POST "https://slack.com/api/chat.postMessage"
      in
      (match result with
      | Ok response_str ->
        (try
           let resp = Slack_types_j.slack_api_response_of_string response_str in
           match resp.ok with
           | true -> log#info "Slack message sent to %s" channel
           | false ->
             let err = Option.default "unknown" resp.error in
             log#error "Slack API error: %s" err
         with _exn -> log#warn "could not parse Slack response: %s" response_str)
      | Error e -> log#error "Slack request failed: %s" e);
      Lwt.return_unit
end
