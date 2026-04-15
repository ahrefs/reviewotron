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

module Make (GH : Api.Github) (AI : Api.Agent_runner) = struct
  let name = "security"

  (** Run the triage agent and parse its structured output.
      Returns the parsed output (if successful) and any agent costs incurred. *)
  let run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths =
    let triage_config =
      Triage_agent.config ~model_tier:(agent_model_tier security_config.Config_types.triage_model_tier)
    in
    let triage_input = Triage_agent.build_input ~diff_text ~file_paths () in
    let%lwt result = AI.run ~ctx ~repo_url ~config:triage_config ~input:triage_input () in
    match result with
    | Error msg ->
      log#error "triage agent failed: %s" msg;
      Lwt.return (None, [])
    | Ok agent_result ->
      let cost = Cost_tracking.of_agent_result ~agent_name:"triage" ~files_fetched:0 agent_result in
      (match Security_types.triage_output_of_json agent_result.output with
      | triage_output -> Lwt.return (Some triage_output, [ cost ])
      | exception exn ->
        log#error "failed to parse triage output: %s" (Exn.str exn);
        Lwt.return (None, [ cost ]))

  (** Group triage signals by vulnerability class.

      Returns an association list of [(vuln_class, signals)] pairs.
      Uses exhaustive [vuln_class_equal] for comparison. *)
  let group_by_vuln_class signals =
    List.fold_left
      (fun groups (signal : Security_types.triage_signal) ->
        let vc = signal.vuln_class in
        let matching, others = List.partition (fun (v, _) -> vuln_class_equal v vc) groups in
        let existing =
          match matching with
          | (_, sigs) :: _ -> sigs
          | [] -> []
        in
        (vc, signal :: existing) :: others)
      [] signals

  (** Fetch file content from the repository via the GitHub API.

      Uses ["HEAD"] as the git ref, which resolves to the repo's default
      branch.  TODO: thread the PR head SHA for branch-accurate context
      expansion. *)
  let fetch_file ~ctx ~repo_url path = GH.get_file_content ~ctx ~repo_url ~path ~ref_:"HEAD"

  (** Run a single analysis agent for one vulnerability class.

      Returns the list of candidate findings and the agent cost on success,
      or an empty list with no cost if the agent fails. *)
  let run_single_analysis ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~language_hints ~vuln_class
    ~triage_signals =
    let vc_name = Security_types.vuln_class_to_string vuln_class in
    let model_tier = agent_model_tier security_config.Config_types.analysis_model_tier in
    let agent_config = Analysis_agent.config ~vuln_class ~model_tier ~language_hints in
    let input = Analysis_agent.build_input ~diff_text ~triage_signals ~file_paths () in
    let tools = Analysis_agent.tools ~fetch_file:(fetch_file ~ctx ~repo_url) in
    let%lwt result = AI.run ~ctx ~repo_url ~tools ~config:agent_config ~input () in
    match result with
    | Error msg ->
      log#error "analysis agent %s failed: %s" vc_name msg;
      Lwt.return ([], [])
    | Ok agent_result ->
      let agent_name = Printf.sprintf "%s_analysis" vc_name in
      let files_fetched = agent_result.steps_count - 1 |> max 0 in
      let cost = Cost_tracking.of_agent_result ~agent_name ~files_fetched agent_result in
      (match Security_types.analysis_output_of_json agent_result.output with
      | analysis ->
        log#info "analysis agent %s: %d findings, %d files examined" vc_name (List.length analysis.findings)
          (List.length analysis.files_examined);
        Lwt.return (analysis.findings, [ cost ])
      | exception exn ->
        log#error "failed to parse analysis output for %s: %s" vc_name (Exn.str exn);
        Lwt.return ([], [ cost ]))

  (** Map confidence from a candidate finding to review severity.

      Per PRD §4.3: High → Critical, Medium → Warning.  Low is not
      specified in the PRD; mapped to Warning as the conservative
      default — if a finding survives adversarial validation despite
      low confidence, it warrants a warning. *)
  let severity_of_confidence : Security_types.confidence -> Review_types.severity = function
    | High -> Critical
    | Medium | Low -> Warning

  (** Convert a validated finding into a review finding.

      Only called for findings with a [Confirmed] verdict.  Severity is
      derived from the inner candidate's confidence level.
      [evidence_notes] from the validator is not surfaced in the PR
      comment — it is available in logs for prompt tuning. *)
  let validated_to_finding (vf : Security_types.validated_finding) : Review_types.finding =
    let f = vf.finding in
    {
      path = f.sink.path;
      line = Some f.sink.line;
      end_line = None;
      severity = severity_of_confidence f.confidence;
      category = Security;
      message = f.description;
      suggested_fix = f.suggested_fix;
    }

  (** Run the validator agent on candidate findings and parse its output.

      Returns the list of validated findings and the agent cost on success.
      If the validator agent fails or its output cannot be parsed, returns
      an empty list — unvalidated findings are never reported. *)
  let run_validator ~ctx ~repo_url ~security_config ~diff_text ~candidate_findings =
    let model_tier = agent_model_tier security_config.Config_types.validator_model_tier in
    let agent_config = Validator_agent.config ~model_tier in
    let input = Validator_agent.build_input ~diff_text ~candidate_findings () in
    let tools = Validator_agent.tools ~fetch_file:(fetch_file ~ctx ~repo_url) in
    let%lwt result = AI.run ~ctx ~repo_url ~tools ~config:agent_config ~input () in
    match result with
    | Error msg ->
      log#error "validator agent failed: %s" msg;
      Lwt.return ([], [])
    | Ok agent_result ->
      let files_fetched = agent_result.steps_count - 1 |> max 0 in
      let cost = Cost_tracking.of_agent_result ~agent_name:"validator" ~files_fetched agent_result in
      (match Security_types.validator_output_of_json agent_result.output with
      | output ->
        log#info "validator: %d results" (List.length output.results);
        Lwt.return (output.results, [ cost ])
      | exception exn ->
        log#error "failed to parse validator output: %s" (Exn.str exn);
        Lwt.return ([], [ cost ]))

  (** Log each rejected finding for offline prompt tuning. *)
  let log_rejected (results : Security_types.validated_finding list) =
    List.iter
      (fun (vf : Security_types.validated_finding) ->
        match vf.verdict with
        | Confirmed -> ()
        | Rejected reason ->
          let vc = Security_types.vuln_class_to_string vf.finding.vuln_class in
          log#info "validator rejected %s finding at %s:%d: %s" vc vf.finding.sink.path vf.finding.sink.line reason)
      results

  (** Route triage signals to per-class analysis agents, validate candidate
      findings, and return only confirmed findings as review findings.

      Signals are grouped by vulnerability class so that each class gets a
      single agent invocation with all relevant triage context.  Candidate
      findings are passed through the validator agent; only confirmed
      findings are converted to review findings. *)
  let run_analysis ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~language_hints signals =
    let actionable = List.filter (should_analyze ~security_config) signals in
    match actionable with
    | [] ->
      log#info "triage: no actionable signals";
      Lwt.return ([], [])
    | _ :: _ ->
      log#info "triage: %d signals, %d actionable" (List.length signals) (List.length actionable);
      let groups = group_by_vuln_class actionable in
      let promises =
        List.map
          (fun (vuln_class, triage_signals) ->
            Lwt.catch
              (fun () ->
                run_single_analysis ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~language_hints ~vuln_class
                  ~triage_signals)
              (fun exn ->
                log#error "analysis agent %s raised: %s" (Security_types.vuln_class_to_string vuln_class) (Exn.str exn);
                Lwt.return ([], [])))
          groups
      in
      let%lwt results = Lwt.all promises in
      let candidates = List.concat_map fst results in
      let analysis_costs = List.concat_map snd results in
      log#info "analysis complete: %d total candidate findings" (List.length candidates);
      (match candidates with
      | [] -> Lwt.return ([], analysis_costs)
      | _ :: _ ->
        let%lwt validated, validator_costs =
          run_validator ~ctx ~repo_url ~security_config ~diff_text ~candidate_findings:candidates
        in
        log_rejected validated;
        let confirmed =
          List.filter_map
            (fun (vf : Security_types.validated_finding) ->
              match vf.verdict with
              | Confirmed -> Some vf
              | Rejected _ -> None)
            validated
        in
        log#info "validation complete: %d confirmed, %d rejected" (List.length confirmed)
          (List.length validated - List.length confirmed);
        Lwt.return (List.map validated_to_finding confirmed, analysis_costs @ validator_costs))

  let run ~ctx ~repo_url ~diff ~diff_text ~metadata:_ =
    let config = Context.get_config ctx ~repo_url in
    let security_config = config.review_plugins.security in
    let file_paths = List.map (fun (fd : Diff_parser.file_diff) -> fd.path) diff in
    let%lwt triage_result, triage_costs = run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths in
    match triage_result with
    | None -> Lwt.return ([], triage_costs)
    | Some triage_output ->
    match triage_output.skip_reason with
    | Some reason ->
      log#info "triage: skipped (%s)" reason;
      Lwt.return ([], triage_costs)
    | None ->
      let%lwt findings, analysis_costs =
        run_analysis ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~language_hints:triage_output.language_hints
          triage_output.signals
      in
      Lwt.return (findings, triage_costs @ analysis_costs)
end
