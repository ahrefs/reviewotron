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

let po = Ai_provider.Provider_options.empty

(** Convert a list of completed steps into a replay-able message history.

    Each step becomes an [Assistant] message (any text produced + any tool
    calls made) followed by a [Tool] message (the tool results).

    Steps with empty [tool_results] are dropped: these represent model turns
    whose tool calls never executed (typically because [max_steps] ran out
    mid-loop), and re-sending them as an Assistant turn with unanswered
    [tool_use] blocks would be a protocol violation.  The preserved turns
    still contain every file the model actually saw, so the replay faithfully
    represents the model's accumulated knowledge. *)
let messages_of_steps (steps : Ai_core.Generate_text_result.step list) =
  List.concat_map
    (fun (step : Ai_core.Generate_text_result.step) ->
      match step.tool_calls, step.tool_results with
      | [], _ -> [ Ai_provider.Prompt.Assistant { content = [ Text { text = step.text; provider_options = po } ] } ]
      | _ :: _, [] -> []
      | _ :: _, _ :: _ ->
        let assistant_text =
          match step.text with
          | "" -> []
          | text -> [ Ai_provider.Prompt.Text { text; provider_options = po } ]
        in
        let assistant_tool_calls =
          List.map
            (fun (tc : Ai_core.Generate_text_result.tool_call) ->
              Ai_provider.Prompt.Tool_call
                { id = tc.tool_call_id; name = tc.tool_name; args = tc.args; provider_options = po })
            step.tool_calls
        in
        let tool_parts =
          List.map
            (fun (tr : Ai_core.Generate_text_result.tool_result) ->
              {
                Ai_provider.Prompt.tool_call_id = tr.tool_call_id;
                tool_name = tr.tool_name;
                result = tr.result;
                is_error = tr.is_error;
                content = [ Result_text (Yojson.Basic.to_string tr.result) ];
                provider_options = po;
              })
            step.tool_results
        in
        [
          Ai_provider.Prompt.Assistant { content = assistant_text @ assistant_tool_calls };
          Ai_provider.Prompt.Tool { content = tool_parts };
        ])
    steps

let finalization_instruction =
  "You have reached the tool-use budget for this task. Do NOT request any more tool calls. Based solely on the \
   evidence you already gathered in the turns above, produce your final answer now as a single JSON object matching \
   the declared output schema. If you do not have enough evidence to confirm any finding, return an empty [findings] \
   array and note the reason in the [notes] field (or equivalent field of your schema) — this is the correct \
   behaviour when evidence is incomplete, and is strictly preferred over reporting unverified findings."

(** Attempt a budget-exhaustion recovery: on [finish_reason = tool-calls] with
    no structured output, replay the completed turns plus a trailing user
    instruction asking the model to produce its JSON from what it has, and
    run a single no-tools turn.

    Returns [Some finalized_result] on success with combined usage/steps,
    [None] when the recovery itself fails (the caller then errors out as
    before). *)
let finalize_after_budget_exhaustion ~model ~config ~input ~output_spec ~max_retries
  ~(first : Ai_core.Generate_text_result.t) =
  let base_messages =
    Ai_provider.Prompt.User { content = [ Text { text = input; provider_options = po } ] } :: messages_of_steps first.steps
  in
  let follow_up =
    Ai_provider.Prompt.User { content = [ Text { text = finalization_instruction; provider_options = po } ] }
  in
  let messages = base_messages @ [ follow_up ] in
  log#info "agent %s: budget exhausted, attempting graceful finalization with %d replayed turns" config.name
    (List.length base_messages - 1);
  try%lwt
    let%lwt second =
      Ai_core.Generate_text.generate_text ~model ~system:config.system_prompt ~messages ~tools:[] ~output:output_spec
        ~max_steps:1 ~max_retries ()
    in
    match second.output with
    | Some _ ->
      log#info "agent %s: finalization produced structured output (%d additional input tokens, %d output tokens)"
        config.name second.usage.input_tokens second.usage.output_tokens;
      Lwt.return (Some second)
    | None ->
      log#warn "agent %s: finalization still returned no structured output (finish_reason=%s); giving up" config.name
        (Ai_provider.Finish_reason.to_string second.finish_reason);
      Lwt.return None
  with
  | Ai_core.Retry.Retry_error err ->
    log#warn "agent %s: finalization retries exhausted (%s): %s" config.name
      (Ai_core.Retry.reason_to_string err.reason)
      err.message;
    Lwt.return None
  | Ai_provider.Provider_error.Provider_error err ->
    log#warn "agent %s: finalization provider error: %s" config.name (Ai_provider.Provider_error.to_string err);
    Lwt.return None

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
    let make_result ~output ~usage ~extra_cache_read ~extra_cache_write ~extra_steps =
      {
        output;
        usage;
        cache_read_input_tokens = cache_read_input_tokens + extra_cache_read;
        cache_creation_input_tokens = cache_creation_input_tokens + extra_cache_write;
        steps_count = steps_count + extra_steps;
        model_id;
      }
    in
    match result.output with
    | Some output ->
      Lwt.return_ok
        (make_result ~output ~usage:result.usage ~extra_cache_read:0 ~extra_cache_write:0 ~extra_steps:0)
    | None ->
      let tool_calls_exhaustion =
        match result.finish_reason with
        | Ai_provider.Finish_reason.Tool_calls -> true
        | _ -> false
      in
      (match tool_calls_exhaustion with
      | false ->
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
      | true ->
        let%lwt recovered =
          finalize_after_budget_exhaustion ~model ~config ~input ~output_spec ~max_retries ~first:result
        in
        (match recovered with
        | Some second ->
          let usage = Ai_core.Generate_text_result.add_usage result.usage second.usage in
          let extra_cache_read, extra_cache_write = extract_cache_tokens second.response.body in
          (match second.output with
          | Some output ->
            Lwt.return_ok
              (make_result ~output ~usage ~extra_cache_read ~extra_cache_write
                 ~extra_steps:(List.length second.steps))
          | None ->
            (* Impossible: finalize returns Some only when second.output is Some. *)
            let msg = Printf.sprintf "agent %s: finalization returned empty output" config.name in
            log#error "%s" msg;
            Lwt.return_error msg)
        | None ->
          let msg =
            Printf.sprintf
              "agent %s: no structured output returned (finish_reason=tool-calls; finalization also failed)"
              config.name
          in
          (match debug_dir with
          | Some dir ->
            (match
               write_debug_dump ~dir ~config ~finish_reason:result.finish_reason ~steps:result.steps
                 ~usage:result.usage
             with
            | Some filepath -> log#warn "agent %s: parse failed, debug dump at %s" config.name filepath
            | None -> log#warn "%s" msg)
          | None -> log#warn "%s" msg);
          Lwt.return_error msg))
  with
  | Ai_core.Retry.Retry_error err ->
    fail
      (Printf.sprintf "agent %s: retries exhausted (%s): %s" config.name
         (Ai_core.Retry.reason_to_string err.reason)
         err.message)
  | Ai_provider.Provider_error.Provider_error err ->
    fail (Printf.sprintf "agent %s: provider error: %s" config.name (Ai_provider.Provider_error.to_string err))
