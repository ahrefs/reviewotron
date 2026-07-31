open Devkit

let log = Log.from "agent_runner"

let log_context_prefix = function
  | None -> ""
  | Some context -> context ^ " "

type model_tier =
  | Fast
  | Standard
  | Strong
[@@deriving json, jsonschema]

let model_tier_to_string = function
  | Fast -> "fast"
  | Standard -> "standard"
  | Strong -> "strong"

type agent_config = {
  name : string;
  system_prompt : string;
  model_tier : model_tier;
  output_schema : Yojson.Basic.t;
  max_steps : int;
  thinking_budget : int option;
  effort : Config_types.Effort.t option;
}

let anthropic_min_thinking_budget = 1024

(* Sub-minimum budgets would be rejected by the Anthropic API; clamp up so a
   misconfiguration cannot crash the agent loop. *)
let clamp_thinking_budget n = max anthropic_min_thinking_budget n

let build_provider_options ~provider (config : agent_config) : Ai_provider.Provider_options.t =
  match config.effort, config.thinking_budget with
  | None, None -> Ai_provider.Provider_options.empty
  | None, Some n -> Llm_provider.thinking_options provider ~budget_tokens:(clamp_thinking_budget n)
  | Some effort, None -> Llm_provider.effort_options provider ~effort
  | Some _, Some _ -> invalid_arg "agent effort cannot be combined with thinking_budget"

(* Anthropic prompt caching is opt-in: without an explicit [cache_control]
   marker on a content block, no caching happens and every step re-bills the
   full accumulated context.  For our long-running tool-use agents this is the
   single biggest cost lever — one breakpoint on the (long, stable) user input
   caches [tools + system + input] across every subsequent turn of the run.
   Per Anthropic's docs the cached prefix is "everything up to and including"
   the marked block, so a single ephemeral breakpoint on the input is enough
   to amortize the system prompt and tool schemas too.

   ocaml-ai-sdk 0.5 now serializes provider cache-control options through the
   high-level generation API.  Keep this explicit breakpoint because it
   covers the stable user input while preserving the same prefix across the
   agent's follow-up turns. *)
let cached_input_provider_options provider = Llm_provider.cached_input_options provider

type agent_result = {
  output : Yojson.Basic.t;
  usage : Ai_provider.Usage.t;
  cache_read_input_tokens : int;
  cache_creation_input_tokens : int;
  steps_count : int;
  tool_calls_count : int;
  tool_results_count : int;
  model_id : string;
  reported_cost_usd : float option;
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

(** Read [(cache_read, cache_write, reported_cost_usd)] for a completed
    generation, picking the source the provider actually populates:
    - [Anthropic] reports cache counts in the raw response body's [usage] block,
      parsed by {!extract_cache_tokens}; it reports no USD cost, so the cost is
      [None] and {!Cost_tracking} estimates from the pricing table.
    - [Openrouter] reports them per-step in [provider_metadata]; sum the cache
      counts and the billed USD cost across all steps via
      {!Llm_provider.usage_metadata}. *)
let usage_of_result ~provider (result : Ai_core.Generate_text_result.t) =
  match provider with
  | Llm_provider.Anthropic ->
    let cache_read, cache_write = extract_cache_tokens result.response.body in
    cache_read, cache_write, None
  | Llm_provider.Openrouter ->
    List.fold_left
      (fun (r, w, cost) (step : Ai_core.Generate_text_result.step) ->
        let u = Llm_provider.usage_metadata Openrouter step.provider_metadata in
        r + u.cache_read, w + u.cache_write, Llm_provider.sum_cost cost u.cost)
      (0, 0, None) result.steps

(** Non-cached prompt tokens, so the three prompt buckets stay disjoint.

    On the Anthropic path [input_tokens] already excludes the cached portion
    (Anthropic reports cache-read/write in their own buckets), so it is returned
    unchanged. OpenRouter instead reports the FULL prompt in [input_tokens] AND
    repeats the cached portion in the cache buckets, so the raw [input_tokens]
    overlaps them; subtract the cache portion so any consumer summing
    input + cache_read + cache_write (the {!Cost_tracking} totals and the
    pricing estimate) does not double-count the prompt. Clamped at 0 in case a
    provider ever reports only partial overlap. *)
let disjoint_input_tokens ~provider ~input_tokens ~cache_read_input_tokens ~cache_creation_input_tokens =
  match provider with
  | Llm_provider.Anthropic -> input_tokens
  | Llm_provider.Openrouter -> max 0 (input_tokens - cache_read_input_tokens - cache_creation_input_tokens)

let missing_structured_output_message ~agent_name ~finish_reason ~finalization_failed =
  let suffix =
    match finalization_failed with
    | true -> "; finalization also failed"
    | false -> ""
  in
  match finish_reason with
  | Ai_provider.Finish_reason.Error ->
    Printf.sprintf "agent %s: provider/model returned finish_reason=error without structured output%s" agent_name suffix
  | Ai_provider.Finish_reason.Stop | Ai_provider.Finish_reason.Length | Ai_provider.Finish_reason.Tool_calls
  | Ai_provider.Finish_reason.Content_filter | Ai_provider.Finish_reason.Other _ | Ai_provider.Finish_reason.Unknown ->
    Printf.sprintf "agent %s: no structured output returned (finish_reason=%s%s)" agent_name
      (Ai_provider.Finish_reason.to_string finish_reason)
      suffix

(* Guesses OpenRouter's [metadata.error_type] from the trailing " (type)" suffix
   the SDK appends when the gateway supplied one
   (ai_provider_openrouter/openrouter_error.ml [message_of_error_json]).

   This is a guess, not a recovery: by the time we hold a [Provider_error.t] the
   structured envelope is gone — every construction path stores the flattened
   human message as [body] — and the SDK's other path ([of_response] falling
   back to [raw_error]) passes the upstream body through verbatim. A verbatim
   body ending in an unrelated parenthetical ("...access to model
   (claude-opus-4)") is therefore indistinguishable from a real classification,
   so callers must present the result as inferred. Delete this shim if a future
   ocaml-ai-sdk carries the classification on [Api_error] itself. *)
let openrouter_error_type_re = Re2.create_exn {|\(([A-Za-z0-9_-]+)\)$|}

let openrouter_error_type body =
  match Re2.find_submatches openrouter_error_type_re body with
  | Ok [| _; Some error_type |] -> Some error_type
  | Ok _ | Error _ -> None

let should_retry_generic_openrouter_403 (error : Ai_provider.Provider_error.t) =
  match error.kind with
  | Ai_provider.Provider_error.Api_error { status; body } ->
    String.equal error.provider "openrouter"
    && Int.equal status 403
    && String.equal (String.trim body) "[Anthropic] Request not allowed"
  | Ai_provider.Provider_error.Network_error _ | Ai_provider.Provider_error.Deserialization_error _
  | Ai_provider.Provider_error.Timeout _ ->
    false

let format_provider_error (error : Ai_provider.Provider_error.t) =
  let retryability = if error.is_retryable then "retryable" else "non-retryable" in
  match error.kind with
  | Ai_provider.Provider_error.Api_error { status; body } ->
    let classification =
      match String.equal error.provider "openrouter" with
      | false -> ""
      | true ->
      match openrouter_error_type body with
      | Some error_type -> Printf.sprintf ", likely_type=%s" error_type
      | None -> ""
    in
    Printf.sprintf "provider error from %s (HTTP %d, %s%s): %s" error.provider status retryability classification body
  | Ai_provider.Provider_error.Network_error _ | Ai_provider.Provider_error.Deserialization_error _
  | Ai_provider.Provider_error.Timeout _ ->
    Printf.sprintf "provider error from %s (%s): %s" error.provider retryability
      (Ai_provider.Provider_error.to_string error)

let provider_name = function
  | Llm_provider.Anthropic -> "anthropic"
  | Llm_provider.Openrouter -> "openrouter"

let retry_generic_openrouter_403_once ?(sleep = Lwt_unix.sleep) ~log_prefix ~agent_name f =
  Lwt.catch f (function
    | Ai_provider.Provider_error.Provider_error error when should_retry_generic_openrouter_403 error ->
      log#warn "%sagent %s: OpenRouter returned an unclassified HTTP 403; retrying once in 2s" log_prefix agent_name;
      let%lwt () = sleep 2.0 in
      f ()
    | exn -> Lwt.fail exn)

let retry_generic_openrouter_403_model ~log_prefix ~agent_name model =
  let module Retry_generic_openrouter_403 = struct
    let wrap_generate ~generate call =
      retry_generic_openrouter_403_once ~log_prefix ~agent_name (fun () -> generate call)
    let wrap_stream ~stream call = stream call
  end in
  Ai_provider.Middleware.apply (module Retry_generic_openrouter_403) model

let default_model_id =
  let open Ai_provider_anthropic.Model_catalog in
  function
  | Fast -> to_model_id Claude_haiku_4_5
  | Standard -> "claude-sonnet-5"
  | Strong -> "claude-opus-4-8"

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

let finalization_instruction ~reason =
  Printf.sprintf
    "Your previous response stopped because %s. Do NOT request any more tool calls. Based solely on the evidence you \
     already gathered in the turns above, produce your final answer now as a single JSON object matching the declared \
     output schema. Keep it concise and schema-complete. If the schema has an output array that corresponds to input \
     items, include one element for every input item; do not silently omit items. When evidence is incomplete, choose \
     the conservative schema-valid outcome: finding-producing schemas should return no findings, validation schemas \
     should reject unverifiable items and set proof fields to null when the schema defines them, and triage schemas \
     should emit no signals with a short skip reason. Reporting unverified findings is strictly worse than returning \
     the conservative empty or rejected result."
    reason

(** Attempt structured-output recovery: when a tool-use agent returns no
    structured output because it exhausted a budget, replay the completed turns
    plus a trailing user instruction asking the model to produce its JSON from
    what it has, and run a single no-tools turn.

    Returns [Some finalized_result] on success with combined usage/steps,
    [None] when the recovery itself fails (the caller then errors out as
    before). *)
let finalize_after_budget_exhaustion ~log_prefix ~provider ~model ~config ~provider_options ~input ~output_spec
  ~max_retries ~reason ~(first : Ai_core.Generate_text_result.t) =
  (* Reuse the same cache breakpoint on the input block we put there in
     [run_agent]: same prefix → same cache key, so this single-shot
     finalization call (fired immediately after the main loop) gets a cache
     hit on [tools + system + input], well within the 5-minute ephemeral TTL.
     The trailing [finalization_instruction] is uncached on purpose — it's
     only sent once, so caching it would be pure overhead. *)
  let base_messages =
    Ai_provider.Prompt.User
      { content = [ Text { text = input; provider_options = cached_input_provider_options provider } ] }
    :: messages_of_steps first.steps
  in
  let follow_up =
    let text = finalization_instruction ~reason in
    Ai_provider.Prompt.User { content = [ Text { text; provider_options = po } ] }
  in
  let messages = base_messages @ [ follow_up ] in
  log#info "%sagent %s: %s, attempting graceful finalization with %d replayed turns" log_prefix config.name reason
    (List.length base_messages - 1);
  try%lwt
    let%lwt second =
      Ai_core.Generate_text.generate_text ~model ~system:config.system_prompt ~messages ~tools:[] ~output:output_spec
        ~max_steps:1 ~max_retries ~provider_options ()
    in
    match second.output with
    | Some _ ->
      log#info "%sagent %s: finalization produced structured output (%d additional input tokens, %d output tokens)"
        log_prefix config.name second.usage.input_tokens second.usage.output_tokens;
      Lwt.return (Some second)
    | None ->
      log#warn "%sagent %s: finalization still returned no structured output (finish_reason=%s); giving up" log_prefix
        config.name
        (Ai_provider.Finish_reason.to_string second.finish_reason);
      Lwt.return None
  with
  | Ai_core.Retry.Retry_error err ->
    log#warn "%sagent %s: finalization retries exhausted (%s): %s" log_prefix config.name
      (Ai_core.Retry.reason_to_string err.reason)
      err.message;
    Lwt.return None
  | Ai_provider.Provider_error.Provider_error err ->
    log#warn "%sagent %s: finalization provider error: %s" log_prefix config.name (format_provider_error err);
    Lwt.return None

let run_agent_untraced ~provider ~model ?tools ?(max_retries = 2) ?debug_dir ?log_context ~config ~input () =
  let log_prefix = log_context_prefix log_context in
  let fail msg =
    log#error "%s%s" log_prefix msg;
    Lwt.return_error msg
  in
  let output_spec = Ai_core.Output.object_ ~name:(config.name ^ "_output") ~schema:config.output_schema () in
  let model_id = Ai_provider.Language_model.model_id model in
  let provider_options = build_provider_options ~provider config in
  let model = retry_generic_openrouter_403_model ~log_prefix ~agent_name:config.name model in
  let thinking_budget_str =
    match config.thinking_budget with
    | None -> "off"
    | Some n -> string_of_int (clamp_thinking_budget n)
  in
  let effort_str =
    match config.effort with
    | None -> "default"
    | Some effort -> Config_types.Effort.to_string effort
  in
  log#info "%sagent %s: starting (provider=%s, model=%s, max_steps=%d, thinking_budget=%s, effort=%s)" log_prefix
    config.name (provider_name provider) model_id config.max_steps thinking_budget_str effort_str;
  (match provider, config.effort with
  | Llm_provider.Anthropic, Some effort ->
    log#warn "%sagent %s: direct Anthropic cannot encode effort=%s with installed ocaml-ai-sdk; using provider default"
      log_prefix config.name (Config_types.Effort.to_string effort)
  | Anthropic, None | Openrouter, None | Openrouter, Some _ -> ());
  let tools = Option.default [] tools in
  (* Hand-build the [messages] list (instead of using [~prompt:input]) so we
     can attach a [cache_control] marker to the input text block.  The
     [~prompt] convenience path inside ocaml-ai-sdk hard-codes the part's
     [provider_options] to [Provider_options.empty], which would drop our
     cache breakpoint on the floor. *)
  let initial_messages =
    [
      Ai_provider.Prompt.User
        { content = [ Text { text = input; provider_options = cached_input_provider_options provider } ] };
    ]
  in
  try%lwt
    let%lwt result =
      Ai_core.Generate_text.generate_text ~model ~system:config.system_prompt ~messages:initial_messages ~tools
        ~output:output_spec ~max_steps:config.max_steps ~max_retries ~provider_options ()
    in
    let steps_count = List.length result.steps in
    let cache_read_input_tokens, cache_creation_input_tokens, reported_cost_usd = usage_of_result ~provider result in
    log#info "%sagent %s: finished (%d steps, %d input tokens, %d output tokens)" log_prefix config.name steps_count
      result.usage.input_tokens result.usage.output_tokens;
    let make_result ~output ~usage ~extra_cache_read ~extra_cache_write ~extra_cost ~extra_steps ~extra_tool_calls
      ~extra_tool_results =
      let total_cache_read = cache_read_input_tokens + extra_cache_read in
      let total_cache_write = cache_creation_input_tokens + extra_cache_write in
      (* Normalize prompt-token accounting to disjoint buckets so downstream
         cost sums do not double-count the prompt on OpenRouter (see
         {!disjoint_input_tokens}). The raw provider [input_tokens] was already
         logged above, unmodified. *)
      let usage : Ai_provider.Usage.t =
        {
          usage with
          Ai_provider.Usage.input_tokens =
            disjoint_input_tokens ~provider ~input_tokens:usage.Ai_provider.Usage.input_tokens
              ~cache_read_input_tokens:total_cache_read ~cache_creation_input_tokens:total_cache_write;
        }
      in
      {
        output;
        usage;
        cache_read_input_tokens = total_cache_read;
        cache_creation_input_tokens = total_cache_write;
        steps_count = steps_count + extra_steps;
        tool_calls_count = List.length result.tool_calls + extra_tool_calls;
        tool_results_count = List.length result.tool_results + extra_tool_results;
        model_id;
        reported_cost_usd = Llm_provider.sum_cost reported_cost_usd extra_cost;
      }
    in
    match result.output with
    | Some output ->
      Lwt.return_ok
        (make_result ~output ~usage:result.usage ~extra_cache_read:0 ~extra_cache_write:0 ~extra_cost:None
           ~extra_steps:0 ~extra_tool_calls:0 ~extra_tool_results:0)
    | None ->
      let recoverable_exhaustion =
        match result.finish_reason with
        | Ai_provider.Finish_reason.Tool_calls -> Some "it reached the tool-use budget"
        | Ai_provider.Finish_reason.Length -> Some "it reached the model output length limit"
        | Ai_provider.Finish_reason.Stop | Ai_provider.Finish_reason.Content_filter | Ai_provider.Finish_reason.Error
        | Ai_provider.Finish_reason.Other _ | Ai_provider.Finish_reason.Unknown ->
          None
      in
      (match recoverable_exhaustion with
      | None ->
        let msg =
          missing_structured_output_message ~agent_name:config.name ~finish_reason:result.finish_reason
            ~finalization_failed:false
        in
        (match debug_dir with
        | Some dir ->
          (match
             write_debug_dump ~dir ~config ~finish_reason:result.finish_reason ~steps:result.steps ~usage:result.usage
           with
          | Some filepath ->
            log#warn "%sagent %s: structured output missing, debug dump at %s" log_prefix config.name filepath
          | None -> log#warn "%s%s" log_prefix msg)
        | None -> log#warn "%s%s" log_prefix msg);
        Lwt.return_error msg
      | Some reason ->
        let%lwt recovered =
          finalize_after_budget_exhaustion ~log_prefix ~provider ~model ~config ~provider_options ~input ~output_spec
            ~max_retries ~reason ~first:result
        in
        (match recovered with
        | Some second ->
          let usage = Ai_core.Generate_text_result.add_usage result.usage second.usage in
          let extra_cache_read, extra_cache_write, extra_cost = usage_of_result ~provider second in
          (match second.output with
          | Some output ->
            Lwt.return_ok
              (make_result ~output ~usage ~extra_cache_read ~extra_cache_write ~extra_cost
                 ~extra_steps:(List.length second.steps) ~extra_tool_calls:(List.length second.tool_calls)
                 ~extra_tool_results:(List.length second.tool_results))
          | None ->
            (* Impossible: finalize returns Some only when second.output is Some. *)
            let msg = Printf.sprintf "agent %s: finalization returned empty output" config.name in
            log#error "%s%s" log_prefix msg;
            Lwt.return_error msg)
        | None ->
          let msg =
            missing_structured_output_message ~agent_name:config.name ~finish_reason:result.finish_reason
              ~finalization_failed:true
          in
          (match debug_dir with
          | Some dir ->
            (match
               write_debug_dump ~dir ~config ~finish_reason:result.finish_reason ~steps:result.steps ~usage:result.usage
             with
            | Some filepath ->
              log#warn "%sagent %s: structured output missing, debug dump at %s" log_prefix config.name filepath
            | None -> log#warn "%s%s" log_prefix msg)
          | None -> log#warn "%s%s" log_prefix msg);
          Lwt.return_error msg))
  with
  | Ai_core.Retry.Retry_error err ->
    fail
      (Printf.sprintf "agent %s: retries exhausted (%s): %s" config.name
         (Ai_core.Retry.reason_to_string err.reason)
         err.message)
  | Ai_provider.Provider_error.Provider_error err ->
    fail (Printf.sprintf "agent %s: %s" config.name (format_provider_error err))
  | exn -> fail (Printf.sprintf "agent %s: unexpected provider failure: %s" config.name (Printexc.to_string exn))

let add_reported_cost_attr = function
  | None -> ()
  | Some cost -> Telemetry.add_attrs [ "gen_ai.usage.reported_cost_usd", `Float cost ]

let run_agent ~provider ~model ?tools ?(max_retries = 2) ?debug_dir ?log_context ~config ~input () =
  let model_id = Ai_provider.Language_model.model_id model in
  let thinking_attrs =
    match config.thinking_budget with
    | None -> [ "reviewotron.agent.thinking_budget.enabled", `Bool false ]
    | Some budget ->
      [
        "reviewotron.agent.thinking_budget.enabled", `Bool true;
        "reviewotron.agent.thinking_budget", `Int (clamp_thinking_budget budget);
      ]
  in
  let effort_attrs =
    match config.effort with
    | None -> [ "reviewotron.agent.effort.enabled", `Bool false ]
    | Some effort ->
      [
        "reviewotron.agent.effort.enabled", `Bool true;
        "reviewotron.agent.effort", `String (Config_types.Effort.to_string effort);
      ]
  in
  let attrs =
    [
      "reviewotron.agent.name", `String config.name;
      "reviewotron.agent.model_tier", `String (model_tier_to_string config.model_tier);
      "gen_ai.request.model", `String model_id;
      "reviewotron.agent.max_steps", `Int config.max_steps;
    ]
    @ thinking_attrs
    @ effort_attrs
  in
  Telemetry.span_result ~error_to_string:Fun.id ~attrs "reviewotron.agent.run" (fun () ->
    let%lwt result =
      run_agent_untraced ~provider ~model ?tools ~max_retries ?debug_dir ?log_context ~config ~input ()
    in
    (match result with
    | Ok result ->
      Telemetry.add_attrs
        [
          "reviewotron.agent.steps", `Int result.steps_count;
          "reviewotron.agent.tool_calls", `Int result.tool_calls_count;
          "reviewotron.agent.tool_results", `Int result.tool_results_count;
          "gen_ai.usage.input_tokens", `Int result.usage.input_tokens;
          "gen_ai.usage.output_tokens", `Int result.usage.output_tokens;
          "gen_ai.usage.cache_read_input_tokens", `Int result.cache_read_input_tokens;
          "gen_ai.usage.cache_creation_input_tokens", `Int result.cache_creation_input_tokens;
        ];
      add_reported_cost_attr result.reported_cost_usd
    | Error msg -> Telemetry.add_attrs [ "error.message", `String msg ]);
    Lwt.return result)
