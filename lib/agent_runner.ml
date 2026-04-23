open Devkit

let log = Log.from "agent_runner"

type model_tier =
  | Fast
  | Standard
  | Strong
[@@deriving json, jsonschema]

type agent_config = {
  name : string;
  system_prompt : string;
  model_tier : model_tier;
  output_schema : Yojson.Basic.t;
  max_steps : int;
}

type agent_result = {
  output : Yojson.Basic.t;
  usage : Ai_provider.Usage.t;
  cache_read_input_tokens : int;
  cache_creation_input_tokens : int;
  steps_count : int;
  model_id : string;
}

(** Extract cache token counts from the raw Anthropic response body.
    The SDK's [Usage.t] only has [input_tokens] and [output_tokens]; cache
    breakdowns live in the provider response JSON under [usage].

    TODO: get these from the provider response headers directly once
    ocaml-ai-sdk populates [response_info.headers] (currently empty). *)
let extract_cache_tokens (response_body : Yojson.Basic.t) =
  let int_field obj key =
    match List.assoc_opt key obj with
    | Some (`Int n) -> n
    | _ -> 0
  in
  match response_body with
  | `Assoc fields ->
    (match List.assoc_opt "usage" fields with
    | Some (`Assoc usage_fields) ->
      let cache_read = int_field usage_fields "cache_read_input_tokens" in
      let cache_creation = int_field usage_fields "cache_creation_input_tokens" in
      cache_read, cache_creation
    | _ -> 0, 0)
  | _ -> 0, 0

let default_model_id =
  let open Ai_provider_anthropic.Model_catalog in
  function
  | Fast -> to_model_id Claude_haiku_4_5
  | Standard -> to_model_id Claude_sonnet_4_6
  | Strong -> to_model_id Claude_opus_4_6

(** Recursively create a directory path, like [mkdir -p].
    Silently succeeds if the directory already exists. *)
let rec mkdir_p dir =
  match Unix.stat dir with
  | _ -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    mkdir_p (Filename.dirname dir);
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

(** Write a debug dump of agent output when structured parsing fails.

    Creates [dir/config.name.txt] with full step text for post-mortem
    analysis.  Wraps all I/O in try/with so it never crashes the caller. *)
let write_debug_dump ~dir ~config ~finish_reason ~(steps : Ai_core.Generate_text_result.step list)
  ~(usage : Ai_provider.Usage.t) =
  try
    mkdir_p dir;
    let filepath = Printf.sprintf "%s/%s.txt" dir config.name in
    let buf = Buffer.create 4096 in
    Buffer.add_string buf (Printf.sprintf "Agent: %s\n" config.name);
    Buffer.add_string buf (Printf.sprintf "Finish reason: %s\n" (Ai_provider.Finish_reason.to_string finish_reason));
    Buffer.add_string buf (Printf.sprintf "Tokens: %d input, %d output\n" usage.input_tokens usage.output_tokens);
    Buffer.add_string buf (Printf.sprintf "Steps: %d\n" (List.length steps));
    List.iteri
      (fun i (step : Ai_core.Generate_text_result.step) ->
        let text_len = String.length step.text in
        let tool_call_count = List.length step.tool_calls in
        Buffer.add_string buf
          (Printf.sprintf "\n=== Step %d (text=%d chars, tool_calls=%d) ===\n" i text_len tool_call_count);
        Buffer.add_string buf step.text;
        Buffer.add_char buf '\n')
      steps;
    let oc = open_out filepath in
    output_string oc (Buffer.contents buf);
    close_out oc;
    Some filepath
  with exn ->
    log#warn "failed to write debug dump for agent %s: %s" config.name (Printexc.to_string exn);
    None

let run_agent ~model ?tools ?(max_retries = 2) ?debug_dir ~config ~input () =
  let fail msg =
    log#error "%s" msg;
    Lwt.return_error msg
  in
  let output_spec = Ai_core.Output.object_ ~name:(config.name ^ "_output") ~schema:config.output_schema () in
  let model_id = Ai_provider.Language_model.model_id model in
  log#info "agent %s: starting (model=%s, max_steps=%d)" config.name model_id config.max_steps;
  let tools = Option.default [] tools in
  try%lwt
    let%lwt result =
      Ai_core.Generate_text.generate_text ~model ~system:config.system_prompt ~prompt:input ~tools ~output:output_spec
        ~max_steps:config.max_steps ~max_retries ()
    in
    let steps_count = List.length result.steps in
    let cache_read_input_tokens, cache_creation_input_tokens = extract_cache_tokens result.response.body in
    log#info "agent %s: finished (%d steps, %d input tokens, %d output tokens)" config.name steps_count
      result.usage.input_tokens result.usage.output_tokens;
    let make_result output =
      { output; usage = result.usage; cache_read_input_tokens; cache_creation_input_tokens; steps_count; model_id }
    in
    match result.output with
    | Some output -> Lwt.return_ok (make_result output)
    | None ->
      let msg =
        Printf.sprintf "agent %s: no structured output returned (finish_reason=%s)" config.name
          (Ai_provider.Finish_reason.to_string result.finish_reason)
      in
      (match debug_dir with
      | Some dir ->
        (match
           write_debug_dump ~dir ~config ~finish_reason:result.finish_reason ~steps:result.steps ~usage:result.usage
         with
        | Some filepath -> log#warn "agent %s: parse failed, debug dump at %s" config.name filepath
        | None -> log#warn "%s" msg)
      | None -> log#warn "%s" msg);
      Lwt.return_error msg
  with
  | Ai_core.Retry.Retry_error err ->
    fail
      (Printf.sprintf "agent %s: retries exhausted (%s): %s" config.name
         (Ai_core.Retry.reason_to_string err.reason)
         err.message)
  | Ai_provider.Provider_error.Provider_error err ->
    fail (Printf.sprintf "agent %s: provider error: %s" config.name (Ai_provider.Provider_error.to_string err))
