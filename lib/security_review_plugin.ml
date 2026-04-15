open Devkit

let log = Log.from "security_plugin"

(** Numeric rank for confidence levels — higher means more confident. *)
let confidence_rank = function
  | Config_types.High -> 3
  | Medium -> 2
  | Low -> 1

(** Compare two vuln_class values for equality.

    Exhaustive match ensures the compiler warns when a new variant is added. *)
let vuln_class_equal a b =
  match a, b with
  | Config_types.Injection, Config_types.Injection
  | Xss, Xss
  | Command_injection, Command_injection
  | Authn, Authn
  | Authz, Authz
  | Ssrf, Ssrf ->
    true
  | (Injection | Xss | Command_injection | Authn | Authz | Ssrf), _ -> false

(** Convert a config model tier to the agent runner's model tier type.

    These types are structurally identical but defined in separate modules
    to avoid a circular dependency. *)
let agent_model_tier : Config_types.model_tier -> Agent_runner.model_tier = function
  | Fast -> Fast
  | Standard -> Standard
  | Strong -> Strong

(** Determine whether a triage signal should trigger a full analysis agent.

    Signals at or above the configured confidence threshold always trigger
    analysis. Signals below the threshold only trigger if the vulnerability
    class is explicitly listed in the repo's [vuln_classes] config. *)
let should_analyze ~security_config (signal : Security_types.triage_signal) =
  let threshold = security_config.Config_types.confidence_threshold in
  confidence_rank signal.confidence >= confidence_rank threshold
  || List.exists (vuln_class_equal signal.vuln_class) security_config.vuln_classes

module Make (_ : Api.Github) (AI : Api.Agent_runner) = struct
  let name = "security"

  (** Run the triage agent and parse its structured output. *)
  let run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths =
    let triage_config =
      Triage_agent.config ~model_tier:(agent_model_tier security_config.Config_types.triage_model_tier)
    in
    let triage_input = Triage_agent.build_input ~diff_text ~file_paths () in
    let%lwt result = AI.run ~ctx ~repo_url ~config:triage_config ~input:triage_input () in
    match result with
    | Error msg ->
      log#error "triage agent failed: %s" msg;
      Lwt.return_none
    | Ok agent_result ->
    match Security_types.triage_output_of_json agent_result.output with
    | triage_output -> Lwt.return_some triage_output
    | exception exn ->
      log#error "failed to parse triage output: %s" (Exn.str exn);
      Lwt.return_none

  (** Route triage signals to analysis agents and collect findings.

      Currently stubbed — logs which agents would be spawned and returns
      an empty findings list. Will be implemented in Phase 4. *)
  let run_analysis ~security_config signals =
    let actionable = List.filter (should_analyze ~security_config) signals in
    match actionable with
    | [] ->
      log#info "triage: no actionable signals";
      Lwt.return []
    | _ :: _ ->
      log#info "triage: %d signals, %d actionable" (List.length signals) (List.length actionable);
      List.iter
        (fun (s : Security_types.triage_signal) ->
          log#info "would spawn analysis agent: %s (%s confidence)"
            (Security_types.vuln_class_to_string s.vuln_class)
            (Security_types.confidence_to_string s.confidence))
        actionable;
      (* Phase 4 will replace this with actual analysis agent invocations *)
      Lwt.return []

  let run ~ctx ~repo_url ~diff ~diff_text ~metadata:_ =
    let config = Context.get_config ctx ~repo_url in
    let security_config = config.review_plugins.security in
    let file_paths = List.map (fun (fd : Diff_parser.file_diff) -> fd.path) diff in
    let%lwt triage_result = run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths in
    match triage_result with
    | None -> Lwt.return []
    | Some triage_output ->
    match triage_output.skip_reason with
    | Some reason ->
      log#info "triage: skipped (%s)" reason;
      Lwt.return []
    | None -> run_analysis ~security_config triage_output.signals
end
