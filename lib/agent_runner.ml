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
  steps_count : int;
  model_id : string;
}

let default_model_id = function
  | Fast -> "claude-haiku-4-5-20251001"
  | Standard -> "claude-sonnet-4-5-20250929"
  | Strong -> "claude-opus-4-6-20260414"

let run_agent ~model ?tools ?(max_retries = 2) ~config ~input () =
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
    log#info "agent %s: finished (%d steps, %d input tokens, %d output tokens)" config.name steps_count
      result.usage.input_tokens result.usage.output_tokens;
    match result.output with
    | Some output -> Lwt.return_ok { output; usage = result.usage; steps_count; model_id }
    | None ->
      let msg =
        Printf.sprintf "agent %s: no structured output returned (finish_reason=%s)" config.name
          (Ai_provider.Finish_reason.to_string result.finish_reason)
      in
      log#warn "%s" msg;
      Lwt.return_error msg
  with
  | Ai_core.Retry.Retry_error err ->
    fail
      (Printf.sprintf "agent %s: retries exhausted (%s): %s" config.name
         (Ai_core.Retry.reason_to_string err.reason)
         err.message)
  | Ai_provider.Provider_error.Provider_error err ->
    fail (Printf.sprintf "agent %s: provider error: %s" config.name (Ai_provider.Provider_error.to_string err))
