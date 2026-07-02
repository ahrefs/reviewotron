(** Tools for security analysis agents.

    Provides typed wrappers around {!Ai_core.Core_tool.t} for use
    with {!Agent_runner.run_agent}. Tool parameters and results are
    derived from OCaml types via [melange-json-native] and
    [ppx_deriving_jsonschema] — no manual JSON. *)

open Melange_json.Primitives
open Ppx_deriving_jsonschema_runtime.Primitives.Melange_json

(** {2 get_file_content tool} *)

type get_file_content_params = { path : string [@jsonschema.description "File path relative to repo root"] }
[@@deriving json, jsonschema]

type get_file_content_result = {
  content : string option; [@json.option] [@jsonschema.description "File content if found"]
  error : string option; [@json.option] [@jsonschema.description "Error message if fetch failed"]
}
[@@deriving json, jsonschema]

let make_get_file_content ~fetch_file =
  let execute args =
    let params =
      try Ok (get_file_content_params_of_json args)
      with Melange_json.Of_json_error (Json_error msg | Unexpected_variant msg) ->
        Error (Printf.sprintf "Invalid parameters: %s" msg)
    in
    match params with
    | Error msg -> Lwt.return (get_file_content_result_to_json { content = None; error = Some msg })
    | Ok { path } ->
      let%lwt result = fetch_file path in
      let response =
        match result with
        | Ok (Some content) -> { content = Some (Diff_parser.annotate_file_content ~path content); error = None }
        | Ok None -> { content = None; error = Some (Printf.sprintf "File not found: %s" path) }
        | Error msg -> { content = None; error = Some msg }
      in
      Lwt.return (get_file_content_result_to_json response)
  in
  let tool =
    Ai_core.Core_tool.create
      ~description:
        "Fetch the content of a file from the repository. Use this to trace data flows, check function \
         implementations, or examine code outside the current diff."
      ~parameters:get_file_content_params_jsonschema ~execute ()
  in
  "get_file_content", tool
