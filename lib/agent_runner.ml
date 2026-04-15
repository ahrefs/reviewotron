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

let code_fence_re = Re2.create_exn {|```\w*\s*\n([\s\S]*?)\n```|}

(** Try to extract JSON from text that may be wrapped in markdown code fences.
    Models sometimes return [```json ... ```] despite being told not to, often
    preceded by reasoning text.  We extract the {b last} fenced JSON block since
    models typically reason first and output the structured result last. *)
let try_parse_json_text text =
  let try_parse s = try Some (Yojson.Basic.from_string s) with Yojson.Json_error _ -> None in
  let trimmed = String.trim text in
  match try_parse trimmed with
  | Some _ as ok -> ok
  | None ->
    (* Extract all ```...``` fenced blocks, try each from last to first *)
    let matches =
      match Re2.get_matches code_fence_re trimmed with
      | Error _ -> []
      | Ok ms -> List.filter_map (fun m -> Re2.Match.get ~sub:(`Index 1) m) ms
    in
    (* Try last match first — models output the structured result last *)
    matches |> List.rev |> List.find_map (fun inner -> try_parse (String.trim inner))

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
      (* SDK failed to parse — try stripping markdown code fences from raw text.
         For multi-step agents, the last step's text is most likely to contain
         the structured output (earlier steps may contain reasoning text).
         Try each step's text individually (reverse order = last first). *)
      let step_texts =
        result.steps
        |> List.rev
        |> List.filter_map (fun (s : Ai_core.Generate_text_result.step) ->
          if String.equal s.text "" then None else Some s.text)
      in
      (match List.find_map try_parse_json_text step_texts with
      | Some output ->
        log#info "agent %s: recovered structured output from code-fenced text" config.name;
        Lwt.return_ok { output; usage = result.usage; steps_count; model_id }
      | None ->
        let msg =
          Printf.sprintf "agent %s: no structured output returned (finish_reason=%s)" config.name
            (Ai_provider.Finish_reason.to_string result.finish_reason)
        in
        log#warn "%s" msg;
        Lwt.return_error msg)
  with
  | Ai_core.Retry.Retry_error err ->
    fail
      (Printf.sprintf "agent %s: retries exhausted (%s): %s" config.name
         (Ai_core.Retry.reason_to_string err.reason)
         err.message)
  | Ai_provider.Provider_error.Provider_error err ->
    fail (Printf.sprintf "agent %s: provider error: %s" config.name (Ai_provider.Provider_error.to_string err))
