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
      branch.  Phase 5 will thread the PR head SHA for branch-accurate
      context expansion. *)
  let fetch_file ~ctx ~repo_url path = GH.get_file_content ~ctx ~repo_url ~path ~ref_:"HEAD"

  (** Run a single analysis agent for one vulnerability class.

      Returns the list of candidate findings on success, or an empty list
      if the agent fails or its output cannot be parsed. *)
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
      Lwt.return []
    | Ok agent_result ->
    match Security_types.analysis_output_of_json agent_result.output with
    | analysis ->
      log#info "analysis agent %s: %d findings, %d files examined" vc_name (List.length analysis.findings)
        (List.length analysis.files_examined);
      Lwt.return analysis.findings
    | exception exn ->
      log#error "failed to parse analysis output for %s: %s" vc_name (Exn.str exn);
      Lwt.return []

  (** Map confidence from a candidate finding to review severity.

      Per PRD §4.3: High → Critical, Medium/Low → Warning. *)
  let severity_of_confidence : Security_types.confidence -> Review_types.severity = function
    | High -> Critical
    | Medium -> Warning
    | Low -> Warning

  (** Convert a candidate finding into a review finding.

      Phase 5 will insert the validator agent between analysis and this
      conversion — only confirmed findings will be converted. *)
  let candidate_to_finding (f : Security_types.candidate_finding) : Review_types.finding =
    {
      path = f.sink.path;
      line = Some f.sink.line;
      end_line = None;
      severity = severity_of_confidence f.confidence;
      category = Security;
      message = f.description;
      suggested_fix = f.suggested_fix;
    }

  (** Route triage signals to per-class analysis agents, run them in
      parallel, and collect candidate findings converted to review findings.

      Signals are grouped by vulnerability class so that each class gets a
      single agent invocation with all relevant triage context. *)
  let run_analysis ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~language_hints signals =
    let actionable = List.filter (should_analyze ~security_config) signals in
    match actionable with
    | [] ->
      log#info "triage: no actionable signals";
      Lwt.return []
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
                Lwt.return []))
          groups
      in
      let%lwt results = Lwt.all promises in
      let candidates = List.concat results in
      log#info "analysis complete: %d total candidate findings" (List.length candidates);
      Lwt.return (List.map candidate_to_finding candidates)

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
    | None ->
      run_analysis ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~language_hints:triage_output.language_hints
        triage_output.signals
end
