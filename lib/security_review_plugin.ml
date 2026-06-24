open Devkit

let log = Log.from "security_plugin"

(** Numeric rank for confidence levels — higher means more confident. *)
let confidence_rank = Config_types.confidence_rank

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

    A class is enabled if it appears in [vuln_classes] or in
    [always_analyze_vuln_classes]. Disabled classes never trigger analysis.
    For enabled classes, signals at or above the configured confidence
    threshold trigger analysis. Signals below the threshold only trigger if
    the class is listed in [always_analyze_vuln_classes]. *)
let should_analyze ~security_config (signal : Security_types.triage_signal) =
  let threshold = security_config.Config_types.confidence_threshold in
  let always_analyze = List.exists (vuln_class_equal signal.vuln_class) security_config.always_analyze_vuln_classes in
  let enabled = always_analyze || List.exists (vuln_class_equal signal.vuln_class) security_config.vuln_classes in
  let above_threshold = confidence_rank signal.confidence >= confidence_rank threshold in
  enabled && (above_threshold || always_analyze)

let non_empty s = String.length (String.trim s) > 0

let proof_trace_site_re = Re2.create_exn {|[A-Za-z0-9_./-]+:[1-9][0-9]*|}

let proof_trace_step_has_site step = Re2.matches proof_trace_site_re step

let proof_is_concrete (proof : Security_types.exploitation_proof) =
  non_empty proof.trigger
  && non_empty proof.missing_or_inadequate_control
  && non_empty proof.expected_impact
  && (match proof.source_to_sink_trace with
    | [] -> false
    | _ :: _ -> true)
  && List.for_all non_empty proof.source_to_sink_trace
  && List.for_all proof_trace_step_has_site proof.source_to_sink_trace
  && List.for_all non_empty proof.preconditions
  &&
  match proof.assumptions with
  | [] -> true
  | _ :: _ -> false

let trace_contains_site ~path ~line trace =
  let site = Printf.sprintf "%s:%d" path line in
  List.exists (fun step -> CCString.find ~sub:site step >= 0) trace

let proof_matches_finding (finding : Security_types.candidate_finding) (proof : Security_types.exploitation_proof) =
  trace_contains_site ~path:finding.source.path ~line:finding.source.line proof.source_to_sink_trace
  && trace_contains_site ~path:finding.sink.path ~line:finding.sink.line proof.source_to_sink_trace

let proof_violation_note =
  "Rejected by Reviewotron after validator parsing: confirmed validator result did not include a concrete \
   proof_by_construction."

let contains_sub ~sub s = CCString.find ~sub s >= 0

let lower_contains ~sub s = contains_sub ~sub (String.lowercase_ascii s)

let notes_mention_line ~line notes =
  let line = string_of_int line in
  [
    Printf.sprintf ":%s" line; Printf.sprintf "line %s" line; Printf.sprintf "lines %s" line; Printf.sprintf "`%s`" line;
  ]
  |> List.exists (fun sub -> lower_contains ~sub notes)

let notes_mention_site ~path ~line notes = contains_sub ~sub:path notes || notes_mention_line ~line notes

let notes_are_decisive notes =
  [ "assume"; "assumption"; "could not"; "difficult"; "non-trivial"; "probably"; "unclear"; "unknown" ]
  |> List.for_all (fun sub -> not (lower_contains ~sub notes))

let sanitization_supports_repair = function
  | Security_types.Missing | Inadequate -> true
  | Adequate | Unknown -> false

let evidence_supports_proof_repair (f : Security_types.candidate_finding) notes =
  non_empty notes
  && notes_are_decisive notes
  && non_empty f.source.path
  && non_empty f.sink.path
  && f.source.line > 0
  && f.sink.line > 0
  && notes_mention_site ~path:f.source.path ~line:f.source.line notes
  && notes_mention_site ~path:f.sink.path ~line:f.sink.line notes
  && sanitization_supports_repair f.sanitization

let proof_repair_control (f : Security_types.candidate_finding) =
  match f.sanitization with
  | Missing ->
    Printf.sprintf "missing %s control on the source-to-sink path" (Security_types.vuln_class_to_string f.vuln_class)
  | Inadequate ->
    Printf.sprintf "inadequate %s control on the source-to-sink path" (Security_types.vuln_class_to_string f.vuln_class)
  | Adequate | Unknown -> "unproven security control state"

let proof_repair_trigger (f : Security_types.candidate_finding) =
  match f.vuln_class with
  | Injection ->
    Printf.sprintf "Submit attacker-controlled input such as `' OR '1'='1` through %s so it reaches %s."
      f.source.description f.sink.description
  | Xss ->
    Printf.sprintf "Submit `<img src=x onerror=alert(1)>` through %s and render the value at %s." f.source.description
      f.sink.description
  | Command_injection ->
    Printf.sprintf "Submit shell metacharacters such as `; id` through %s so they reach %s." f.source.description
      f.sink.description
  | Authn ->
    Printf.sprintf "Send an authentication request with attacker-controlled token or credential data through %s."
      f.source.description
  | Authz ->
    Printf.sprintf "Call the reviewed handler through %s for a resource the caller should not be allowed to access."
      f.source.description
  | Ssrf ->
    Printf.sprintf "Submit `http://169.254.169.254/latest/meta-data/` through %s so the server fetches it at %s."
      f.source.description f.sink.description

let proof_repair_impact (f : Security_types.candidate_finding) =
  match f.vuln_class with
  | Injection -> "The attacker can alter the query executed by the application."
  | Xss -> "The attacker-controlled script executes in another user's browser."
  | Command_injection -> "The attacker-controlled command fragment executes on the server."
  | Authn -> "An invalid, expired, or otherwise unsafe authentication token can be accepted."
  | Authz -> "The attacker can access or mutate a resource without the required authorization check."
  | Ssrf -> "The server makes an attacker-controlled outbound request to an internal or sensitive URL."

let proof_trace_from_finding (f : Security_types.candidate_finding) =
  let source = Printf.sprintf "%s:%d source: %s" f.source.path f.source.line f.source.description in
  let flow =
    List.map
      (fun (step : Security_types.flow_step) -> Printf.sprintf "%s:%d flow: %s" step.path step.line step.description)
      f.flow
  in
  let sink = Printf.sprintf "%s:%d sink: %s" f.sink.path f.sink.line f.sink.description in
  (source :: flow) @ [ sink ]

let proof_from_validated_notes (vf : Security_types.validated_finding) =
  let finding = vf.finding in
  match evidence_supports_proof_repair finding vf.evidence_notes with
  | false -> None
  | true ->
    Some
      {
        Security_types.trigger = proof_repair_trigger finding;
        preconditions = [ "The reviewed source and sink sites are present in the validator evidence." ];
        source_to_sink_trace = proof_trace_from_finding finding;
        missing_or_inadequate_control = proof_repair_control finding;
        expected_impact = proof_repair_impact finding;
        assumptions = [];
      }

let repair_missing_validator_proof (vf : Security_types.validated_finding) =
  match vf.verdict, vf.proof_by_construction with
  | Confirmed, None ->
    (match proof_from_validated_notes vf with
    | Some proof -> { vf with proof_by_construction = Some proof }
    | None -> vf)
  | Confirmed, Some _ | Rejected, Some _ | Rejected, None -> vf

let reject_for_missing_proof (vf : Security_types.validated_finding) =
  let evidence_notes =
    match String.trim vf.evidence_notes with
    | "" -> proof_violation_note
    | notes -> Printf.sprintf "%s\n\n%s" notes proof_violation_note
  in
  { vf with verdict = Rejected; evidence_notes; proof_by_construction = None }

let enforce_validator_proofs results =
  List.map
    (fun (vf : Security_types.validated_finding) ->
      let vf = repair_missing_validator_proof vf in
      match vf.verdict, vf.proof_by_construction with
      | Confirmed, Some proof ->
        (match proof_is_concrete proof && proof_matches_finding vf.finding proof with
        | true -> vf
        | false -> reject_for_missing_proof vf)
      | Confirmed, None -> reject_for_missing_proof vf
      | Rejected, Some _ | Rejected, None -> vf)
    results

type analysis_metrics = {
  actionable_triage_signal_count : int;
  analysis_agents_run : int;
  raw_candidates_produced : int;
  candidates_kept_after_deduplication : int;
  duplicate_candidates_dropped : int;
  validator_confirmed : int;
  validator_rejected : int;
  final_findings_produced : int;
}

let empty_analysis_metrics ~actionable_triage_signal_count =
  {
    actionable_triage_signal_count;
    analysis_agents_run = 0;
    raw_candidates_produced = 0;
    candidates_kept_after_deduplication = 0;
    duplicate_candidates_dropped = 0;
    validator_confirmed = 0;
    validator_rejected = 0;
    final_findings_produced = 0;
  }

let count_confirmed results =
  List.fold_left
    (fun acc (vf : Security_types.validated_finding) ->
      match vf.verdict with
      | Confirmed -> acc + 1
      | Rejected -> acc)
    0 results

let total_files_fetched costs =
  List.fold_left (fun acc (cost : Cost_tracking.agent_cost) -> acc + cost.files_fetched) 0 costs

let total_estimated_cost costs =
  List.fold_left (fun acc (cost : Cost_tracking.agent_cost) -> acc +. cost.estimated_cost_usd) 0.0 costs

let metrics_json ~changed_file_count ~deterministic_signals ~triage_signal_count ~metrics ~costs =
  `Assoc
    [
      "changed_file_count", `Int changed_file_count;
      "deterministic_signals", Security_artifacts.signal_counts_json deterministic_signals;
      "triage_signal_count", `Int triage_signal_count;
      "actionable_triage_signal_count", `Int metrics.actionable_triage_signal_count;
      "analysis_agents_run", `Int metrics.analysis_agents_run;
      "raw_candidates_produced", `Int metrics.raw_candidates_produced;
      "candidates_kept_after_deduplication", `Int metrics.candidates_kept_after_deduplication;
      "duplicate_candidates_dropped", `Int metrics.duplicate_candidates_dropped;
      "validator_results_confirmed", `Int metrics.validator_confirmed;
      "validator_results_rejected", `Int metrics.validator_rejected;
      "final_findings_produced", `Int metrics.final_findings_produced;
      ( "finding_routing",
        `Assoc
          [
            "inline", `Null;
            "unchanged", `Null;
            "anchor_failed", `Null;
            "note", `String "not_recorded_before_review_engine_routing";
          ] );
      "security_files_fetched", `Int (total_files_fetched costs);
      "agent_costs", Security_artifacts.agent_costs_json costs;
    ]

let log_stage_metrics ~changed_file_count ~deterministic_signals ~triage_signal_count ~metrics ~costs =
  log#info
    "security metrics: files=%d deterministic_signals=%d triage_signals=%d actionable=%d analysis_agents=%d \
     raw_candidates=%d deduped=%d duplicates_dropped=%d validator_confirmed=%d validator_rejected=%d final_findings=%d \
     files_fetched=%d estimated_cost=$%.4f"
    changed_file_count (List.length deterministic_signals) triage_signal_count metrics.actionable_triage_signal_count
    metrics.analysis_agents_run metrics.raw_candidates_produced metrics.candidates_kept_after_deduplication
    metrics.duplicate_candidates_dropped metrics.validator_confirmed metrics.validator_rejected
    metrics.final_findings_produced (total_files_fetched costs) (total_estimated_cost costs)

module Make (AI : Api.Agent_runner) = struct
  let name = "security"

  (** Run the triage agent and parse its structured output.
      Returns the parsed output (if successful) and any agent costs incurred. *)
  let run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~deterministic_signals ~artifacts
    ?security_memory ?debug_dir () =
    let triage_config =
      Triage_agent.config ~model_tier:(agent_model_tier security_config.Config_types.triage_model_tier)
    in
    let triage_input = Triage_agent.build_input ~diff_text ~file_paths ?security_memory ~deterministic_signals () in
    Security_artifacts.write_debug_text artifacts ~filename:"triage_input.md" triage_input;
    let%lwt result = AI.run ~ctx ~repo_url ?debug_dir ~config:triage_config ~input:triage_input () in
    match result with
    | Error msg ->
      log#error "triage agent failed: %s" msg;
      Lwt.return (None, [])
    | Ok agent_result ->
      let cost = Cost_tracking.of_agent_result ~agent_name:"triage" ~files_fetched:0 agent_result in
      Security_artifacts.write_debug_json artifacts ~filename:"triage_output.json" agent_result.output;
      let triage_output = Security_types.triage_output_of_json agent_result.output in
      Lwt.return (Some triage_output, [ cost ])

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

  (** Run a single analysis agent for one vulnerability class.

      Returns the list of candidate findings and the agent cost on success,
      or an empty list with no cost if the agent fails. *)
  let run_single_analysis ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~file_paths ~language_hints ~vuln_class
    ~triage_signals ~artifacts ?debug_dir () =
    let vc_name = Security_types.vuln_class_to_string vuln_class in
    let model_tier = agent_model_tier security_config.Config_types.analysis_model_tier in
    let agent_config = Analysis_agent.config ~vuln_class ~model_tier ~language_hints in
    let input = Analysis_agent.build_input ~diff_text ~triage_signals ~file_paths () in
    Security_artifacts.write_debug_text artifacts ~filename:(Printf.sprintf "analysis_%s_input.md" vc_name) input;
    let tools = Analysis_agent.tools ~fetch_file:(fun path -> fetch_file ~path) in
    let%lwt result = AI.run ~ctx ~repo_url ~tools ?debug_dir ~config:agent_config ~input () in
    match result with
    | Error msg ->
      log#error "analysis agent %s failed: %s" vc_name msg;
      Lwt.return ([], [])
    | Ok agent_result ->
      let agent_name = Printf.sprintf "%s_analysis" vc_name in
      let files_fetched = agent_result.steps_count - 1 |> max 0 in
      let cost = Cost_tracking.of_agent_result ~agent_name ~files_fetched agent_result in
      Security_artifacts.write_debug_json artifacts
        ~filename:(Printf.sprintf "analysis_%s_output.json" vc_name)
        agent_result.output;
      let analysis = Security_types.analysis_output_of_json agent_result.output in
      log#info "analysis agent %s: %d findings, %d files examined" vc_name (List.length analysis.findings)
        (List.length analysis.files_examined);
      Lwt.return (analysis.findings, [ cost ])

  (** Map confidence from a candidate finding to review severity.

      Per PRD §4.3: High → Critical, Medium → Warning.  Low is not
      specified in the PRD; mapped to Warning as the conservative
      default — if a finding survives adversarial validation despite
      low confidence, it warrants a warning. *)
  let severity_of_confidence : Security_types.confidence -> Review_types.severity = function
    | High -> Critical
    | Medium | Low -> Warning

  (** A candidate's sink is what the analysis agent picked as "the dangerous
      operation."  For some vulnerability classes — notably authz — the agent
      tends to point [sink] at the enforcement/decision point (e.g. a role
      check) rather than at the defect site where the reviewed change actually
      introduces the flaw.  When that enforcement point lives in unchanged code, the
      finding can't be rendered as an inline comment even though the flow
      chain almost always traces through a line that was changed.

      [pick_inline_anchor] walks [\[sink\] @ flow @ \[source\]] in priority
      order and returns the first [(path, line)] whose [path] is present in
      the diff.  If none qualify, we fall back to the sink — the finding then
      routes to the "unchanged code" section in the main review body.

      The ordering means: prefer the sink when it's already in the diff,
      otherwise prefer a flow step, otherwise the source.  Flow is ordered
      source→sink by construction, so taking the first diff-resident step
      gives us the earliest point on the path that this change touches. *)
  let pick_inline_anchor ~diff (f : Security_types.candidate_finding) =
    let sink_site = `Sink, f.sink.path, f.sink.line in
    let flow_sites = List.map (fun (s : Security_types.flow_step) -> `Flow, s.path, s.line) f.flow in
    let source_site = `Source, f.source.path, f.source.line in
    let candidates = sink_site :: (flow_sites @ [ source_site ]) in
    let in_diff (_kind, path, _line) = Option.is_some (Diff_anchor.find_file_diff_by_path ~diff path) in
    match List.find_opt in_diff candidates with
    | Some chosen -> chosen
    | None -> sink_site

  (** Derive a multi-line [end_line] relative to the chosen inline anchor.

      We look for flow steps on the anchor's file whose line sits strictly
      below the anchor line, pick the greatest one, and keep it only if the
      whole [anchor_line..end_line] span fits inside one right-side hunk.
      Otherwise the finding renders as a single-line anchor. *)
  let derive_end_line_from_flow ~diff ~anchor_path ~anchor_line (f : Security_types.candidate_finding) =
    let file_diff = Diff_anchor.find_file_diff_by_path ~diff anchor_path in
    match file_diff with
    | None -> None
    | Some fd ->
      let same_file_flow_lines =
        f.flow
        |> List.filter_map (fun (step : Security_types.flow_step) ->
          match String.equal step.path anchor_path && step.line > anchor_line with
          | true -> Some step.line
          | false -> None)
      in
      (match same_file_flow_lines with
      | [] -> None
      | _ :: _ ->
        let candidate = List.fold_left max anchor_line same_file_flow_lines in
        (match
           candidate > anchor_line && Diff_anchor.single_hunk_contains fd ~start_line:anchor_line ~end_line:candidate
         with
        | true -> Some candidate
        | false -> None))

  (** If the inline anchor differs from the sink (we snapped onto a flow or
      source step), prepend a short "Related" line so the reader sees the
      enforcement/sink location too.  When the anchor IS the sink, return the
      description unchanged. *)
  let enrich_message_with_sink ~anchor_kind ~(f : Security_types.candidate_finding) =
    match anchor_kind with
    | `Sink -> f.description
    | `Flow | `Source ->
      Printf.sprintf "**Related sink:** `%s:%d` — %s\n\n%s" f.sink.path f.sink.line f.sink.description f.description

  let truncate_text ~max_len s =
    match String.length s <= max_len with
    | true -> s
    | false -> String.sub s 0 max_len ^ "..."

  let first_n n values =
    let rec aux remaining acc = function
      | [] -> List.rev acc
      | _ :: _ when remaining <= 0 -> List.rev acc
      | value :: rest -> aux (remaining - 1) (value :: acc) rest
    in
    aux n [] values

  let fallback_trace (f : Security_types.candidate_finding) =
    Printf.sprintf "%s:%d source -> %s:%d sink" f.source.path f.source.line f.sink.path f.sink.line

  let proof_summaries (vf : Security_types.validated_finding) =
    let f = vf.finding in
    match vf.proof_by_construction with
    | None -> "", "", ""
    | Some proof ->
      let failure_scenario =
        Printf.sprintf "Trigger: %s Impact: %s" proof.trigger proof.expected_impact |> truncate_text ~max_len:420
      in
      let trace =
        match proof.source_to_sink_trace with
        | [] -> fallback_trace f
        | _ :: _ -> proof.source_to_sink_trace |> first_n 4 |> String.concat " -> "
      in
      let evidence_snippet =
        Printf.sprintf "%s. Control: %s" trace proof.missing_or_inadequate_control |> truncate_text ~max_len:520
      in
      let why_now =
        Printf.sprintf "The reviewed change leaves this path reaching `%s:%d` without %s." f.sink.path f.sink.line
          proof.missing_or_inadequate_control
        |> truncate_text ~max_len:320
      in
      failure_scenario, evidence_snippet, why_now

  (** Convert a validated finding into a review finding.

      Only called for findings with a [Confirmed] verdict.  Severity is
      derived from the inner candidate's confidence level.  [evidence_notes]
      from the validator is not surfaced in the review comment — it is available
      in logs for prompt tuning.

      Inline anchor is picked from the evidence chain via [pick_inline_anchor]
      so that findings whose sink lives in unchanged code still land on a
      changed line when the flow traces through one.  [end_line] is derived
      from flow steps relative to the chosen anchor. *)
  let validated_to_finding ~diff (vf : Security_types.validated_finding) : Review_types.finding =
    let f = vf.finding in
    let anchor_kind, anchor_path, anchor_line = pick_inline_anchor ~diff f in
    let failure_scenario, evidence_snippet, why_now = proof_summaries vf in
    (match anchor_kind with
    | `Sink -> ()
    | `Flow | `Source ->
      log#info "anchor-snap: sink %s:%d not in diff, anchoring on %s %s:%d (vuln_class=%s)" f.sink.path f.sink.line
        (match anchor_kind with
        | `Flow -> "flow step"
        | `Source -> "source"
        | `Sink -> "sink")
        anchor_path anchor_line
        (Security_types.vuln_class_to_string f.vuln_class));
    {
      path = anchor_path;
      line = anchor_line;
      end_line = derive_end_line_from_flow ~diff ~anchor_path ~anchor_line f;
      severity = severity_of_confidence f.confidence;
      category = Security;
      message = enrich_message_with_sink ~anchor_kind ~f;
      failure_scenario;
      evidence_snippet;
      why_now;
      confidence = f.confidence;
      suggested_fix = f.suggested_fix;
    }

  (** Run the validator agent on candidate findings and parse its output.

      Returns the list of validated findings and the agent cost on success.
      If the validator agent fails or its output cannot be parsed, returns
      an empty list — unvalidated findings are never reported. *)
  let run_validator ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~candidate_findings ~artifacts ?debug_dir ()
      =
    let model_tier = agent_model_tier security_config.Config_types.validator_model_tier in
    let agent_config = Validator_agent.config ~model_tier in
    let input = Validator_agent.build_input ~diff_text ~candidate_findings () in
    Security_artifacts.write_debug_text artifacts ~filename:"validator_input.md" input;
    let tools = Validator_agent.tools ~fetch_file:(fun path -> fetch_file ~path) in
    let%lwt result = AI.run ~ctx ~repo_url ~tools ?debug_dir ~config:agent_config ~input () in
    match result with
    | Error msg ->
      log#error "validator agent failed: %s" msg;
      Lwt.return ([], [])
    | Ok agent_result ->
      let files_fetched = agent_result.steps_count - 1 |> max 0 in
      let cost = Cost_tracking.of_agent_result ~agent_name:"validator" ~files_fetched agent_result in
      Security_artifacts.write_debug_json artifacts ~filename:"validator_output.json" agent_result.output;
      (try
         let output = Security_types.validator_output_of_json agent_result.output in
         let results = enforce_validator_proofs output.results in
         let downgraded = count_confirmed output.results - count_confirmed results in
         (match downgraded > 0 with
         | true -> log#warn "validator: downgraded %d confirmed result(s) without concrete proof" downgraded
         | false -> ());
         log#info "validator: %d results" (List.length results);
         Lwt.return (results, [ cost ])
       with exn ->
         log#error "validator output parse failed: %s" (Exn.str exn);
         Lwt.return ([], [ cost ]))

  (** Collapse candidate findings that share the same [(sink.path, sink.line)].

      Per-class analysis agents run independently, so a single defect (e.g. a
      SQL injection in a [/search] route that also has missing authz on the
      enclosing handler) frequently surfaces as several near-identical
      candidates, one per vuln_class.  Forwarding all of them to the validator
      causes three problems: (1) the validator's prompt grows linearly with the
      duplication, eating its step budget on PRs with several defects (we have
      observed it exhaust [max_steps] on real PRs); (2) the validator
      sometimes accepts duplicates as separate findings, producing repetitive
      inline comments; (3) when it does try to dedupe, it does so
      inconsistently, so review counts swing run-to-run on the same diff.

      This pass runs {e before} the validator, picks one canonical candidate
      per [(sink.path, sink.line)], and discards the rest.  Selection is
      deterministic: highest [confidence] first, then longest [flow] (more
      evidence usually means the agent traced the chain harder), then
      first-seen.  The deterministic ordering is what gives us run-to-run
      consistency.

      We do {e not} merge candidates across different sink lines, even when
      they describe the same overall chain — the source-route line and the
      actual exec call are both legitimate inline-comment anchors and both
      worth surfacing.  Same [(path, line)] = same fix site = collapse. *)
  let dedup_candidates (candidates : Security_types.candidate_finding list) =
    let key (c : Security_types.candidate_finding) = c.sink.path, c.sink.line in
    (* Bucket candidates by sink, preserving first-seen order both for buckets
       and within each bucket. *)
    let buckets = Hashtbl.create 16 in
    let order = ref [] in
    List.iter
      (fun c ->
        let k = key c in
        match Hashtbl.find_opt buckets k with
        | None ->
          Hashtbl.replace buckets k [ c ];
          order := k :: !order
        | Some existing -> Hashtbl.replace buckets k (existing @ [ c ]))
      candidates;
    let pick_best bucket =
      match bucket with
      | [] -> None
      | first :: _ ->
        let better (a : Security_types.candidate_finding) (b : Security_types.candidate_finding) =
          let ca = confidence_rank a.confidence in
          let cb = confidence_rank b.confidence in
          match Int.compare ca cb with
          | x when x > 0 -> a
          | x when x < 0 -> b
          | _ ->
            let fa = List.length a.flow in
            let fb = List.length b.flow in
            (match Int.compare fa fb with
            | x when x > 0 -> a
            | x when x < 0 -> b
            | _ -> a)
          (* first-seen wins on full tie; List.fold_left feeds [a] = accumulator
             which started as the bucket's first element, so [a] is older *)
        in
        Some (List.fold_left better first bucket)
    in
    let log_discards (kept : Security_types.candidate_finding) bucket =
      List.iter
        (fun (c : Security_types.candidate_finding) ->
          match c == kept with
          | true -> ()
          | false ->
            log#info "dedup: dropped %s candidate at %s:%d (kept %s, %s confidence, %d flow steps)"
              (Security_types.vuln_class_to_string c.vuln_class)
              c.sink.path c.sink.line
              (Security_types.vuln_class_to_string kept.vuln_class)
              (Security_types.confidence_to_string kept.confidence)
              (List.length kept.flow))
        bucket
    in
    List.rev !order
    |> List.filter_map (fun k ->
      let bucket = Hashtbl.find buckets k in
      match pick_best bucket with
      | None -> None
      | Some kept ->
        log_discards kept bucket;
        Some kept)

  (** Log each rejected finding for offline prompt tuning. *)
  let log_rejected (results : Security_types.validated_finding list) =
    List.iter
      (fun (vf : Security_types.validated_finding) ->
        match vf.verdict with
        | Confirmed -> ()
        | Rejected ->
          let vc = Security_types.vuln_class_to_string vf.finding.vuln_class in
          log#info "validator rejected %s finding at %s:%d: %s" vc vf.finding.sink.path vf.finding.sink.line
            vf.evidence_notes)
      results

  (** Route triage signals to per-class analysis agents, validate candidate
      findings, and return only confirmed findings as review findings.

      Signals are grouped by vulnerability class so that each class gets a
      single agent invocation with all relevant triage context.  Candidate
      findings are passed through the validator agent; only confirmed
      findings are converted to review findings. *)
  let run_analysis ~ctx ~repo_url ~fetch_file ~security_config ~diff ~diff_text ~file_paths ~language_hints ~artifacts
    ?debug_dir signals =
    let actionable = List.filter (should_analyze ~security_config) signals in
    match actionable with
    | [] ->
      log#info "triage: no actionable signals";
      Lwt.return ([], [], empty_analysis_metrics ~actionable_triage_signal_count:0)
    | _ :: _ ->
      log#info "triage: %d signals, %d actionable" (List.length signals) (List.length actionable);
      let groups = group_by_vuln_class actionable in
      let promises =
        List.map
          (fun (vuln_class, triage_signals) ->
            Lwt.catch
              (fun () ->
                run_single_analysis ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~file_paths ~language_hints
                  ~vuln_class ~triage_signals ~artifacts ?debug_dir ())
              (fun exn ->
                log#error "analysis agent %s raised: %s" (Security_types.vuln_class_to_string vuln_class) (Exn.str exn);
                Lwt.return ([], [])))
          groups
      in
      let%lwt results = Lwt.all promises in
      let raw_candidates = List.concat_map fst results in
      let analysis_costs = List.concat_map snd results in
      log#info "analysis complete: %d total candidate findings" (List.length raw_candidates);
      let candidates = dedup_candidates raw_candidates in
      (match List.compare_lengths candidates raw_candidates < 0 with
      | true ->
        log#info "dedup: %d → %d candidates after collapsing duplicates by sink" (List.length raw_candidates)
          (List.length candidates)
      | false -> ());
      (match candidates with
      | [] ->
        let metrics =
          {
            actionable_triage_signal_count = List.length actionable;
            analysis_agents_run = List.length groups;
            raw_candidates_produced = List.length raw_candidates;
            candidates_kept_after_deduplication = List.length candidates;
            duplicate_candidates_dropped = List.length raw_candidates - List.length candidates;
            validator_confirmed = 0;
            validator_rejected = 0;
            final_findings_produced = 0;
          }
        in
        Lwt.return ([], analysis_costs, metrics)
      | _ :: _ ->
        let%lwt validated, validator_costs =
          run_validator ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~candidate_findings:candidates ~artifacts
            ?debug_dir ()
        in
        log_rejected validated;
        let confirmed =
          List.filter_map
            (fun (vf : Security_types.validated_finding) ->
              match vf.verdict with
              | Confirmed -> Some vf
              | Rejected -> None)
            validated
        in
        log#info "validation complete: %d confirmed, %d rejected" (List.length confirmed)
          (List.length validated - List.length confirmed);
        let findings = List.map (validated_to_finding ~diff) confirmed in
        Security_artifacts.write_debug_json artifacts ~filename:"final_findings.json"
          (Security_artifacts.final_findings_json findings);
        let metrics =
          {
            actionable_triage_signal_count = List.length actionable;
            analysis_agents_run = List.length groups;
            raw_candidates_produced = List.length raw_candidates;
            candidates_kept_after_deduplication = List.length candidates;
            duplicate_candidates_dropped = List.length raw_candidates - List.length candidates;
            validator_confirmed = List.length confirmed;
            validator_rejected = List.length validated - List.length confirmed;
            final_findings_produced = List.length findings;
          }
        in
        Lwt.return (findings, analysis_costs @ validator_costs, metrics))

  (** Build the architectural observations passed to the memory curator.

      Deliberately derived only from the shape of the review — language
      hints, a sample of files touched, and the distribution of triage
      vuln-class signals.  Findings are never included: the curator
      cannot record file:line claims because it is never told about them. *)
  let build_observations ~(triage_output : Security_types.triage_output) ~file_paths :
    Security_types.architectural_observations =
    let reviewed_files =
      match List.compare_length_with file_paths 12 > 0 with
      | true -> CCList.take 12 file_paths
      | false -> file_paths
    in
    let vuln_class_distribution =
      let bump acc vc =
        let matching, others = List.partition (fun (v, _) -> String.equal v vc) acc in
        let existing =
          match matching with
          | (_, n) :: _ -> n
          | [] -> 0
        in
        (vc, existing + 1) :: others
      in
      triage_output.signals
      |> List.map (fun (s : Security_types.triage_signal) -> Security_types.vuln_class_to_string s.vuln_class)
      |> List.fold_left bump []
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    in
    { language_hints = triage_output.language_hints; reviewed_files; vuln_class_distribution }

  (** Run the memory curator to refresh the repo's architectural brief.

      The curator rewrites the brief from the provided observations plus
      the current brief (if any).  Runs a single-shot call — no tools,
      no queue — and writes directly to the memory file.  Last write wins
      if two reviews curate concurrently; since the brief is a pure
      architectural description the output converges rather than
      accumulates. *)
  let curate_memory ~ctx ~repo_url ~memory_dir ~security_config ~observations ?debug_dir () =
    let current_memory = Security_memory.load ~memory_dir ~repo_url in
    let memory_max_tokens = security_config.Config_types.memory_max_tokens in
    let repo_name = Security_memory.repo_slug repo_url in
    let curator_config = Memory_curator_agent.config ~model_tier:(agent_model_tier security_config.triage_model_tier) in
    let input = Memory_curator_agent.build_input ~repo_name ~memory_max_tokens ~observations ?current_memory () in
    let%lwt result = AI.run ~ctx ~repo_url ?debug_dir ~config:curator_config ~input () in
    match result with
    | Error msg ->
      log#error "memory curator agent failed: %s" msg;
      Lwt.return []
    | Ok agent_result ->
      let cost = Cost_tracking.of_agent_result ~agent_name:"memory_curator" ~files_fetched:0 agent_result in
      let output = Security_types.curator_output_of_json agent_result.output in
      let estimated = Memory_curator_agent.estimate_tokens output.updated_memory in
      if estimated > memory_max_tokens then
        log#warn "curator output exceeds token limit (%d > %d), saving anyway" estimated memory_max_tokens;
      Security_memory.save ~memory_dir ~repo_url ~content:output.updated_memory;
      log#info "memory brief updated";
      Lwt.return [ cost ]

  let run ~ctx ~repo_url ~(config : Config_types.config) ~diff ~diff_text ~(metadata : Review_plugin.review_metadata)
    ~debug_dir =
    let security_config = config.review_plugins.security in
    let memory_dir = "memory" in
    let security_memory = Security_memory.load ~memory_dir ~repo_url in
    let file_paths = List.map (fun (fd : Diff_parser.file_diff) -> fd.path) diff in
    let artifacts =
      Security_artifacts.create ~debug_dir ~metrics_artifacts:security_config.metrics_artifacts
        ~debug_artifacts:security_config.debug_artifacts
    in
    Security_artifacts.write_manifest artifacts ~repo_url;
    let deterministic_signals = Security_diff_signal.scan diff in
    log#info "deterministic signals: %d signal(s)" (List.length deterministic_signals);
    Security_artifacts.write_debug_json artifacts ~filename:"deterministic_signals.json"
      (`List (List.map Security_types.candidate_signal_to_json deterministic_signals));
    let%lwt triage_result, triage_costs =
      run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths ~deterministic_signals ~artifacts
        ?security_memory ~debug_dir ()
    in
    match triage_result with
    | None ->
      let metrics = empty_analysis_metrics ~actionable_triage_signal_count:0 in
      log_stage_metrics ~changed_file_count:(List.length file_paths) ~deterministic_signals ~triage_signal_count:0
        ~metrics ~costs:triage_costs;
      Security_artifacts.write_metrics artifacts
        (metrics_json ~changed_file_count:(List.length file_paths) ~deterministic_signals ~triage_signal_count:0
           ~metrics ~costs:triage_costs);
      Security_artifacts.write_fetch_stats artifacts triage_costs;
      Security_artifacts.write_debug_json artifacts ~filename:"final_findings.json" (`List []);
      Lwt.return ([], triage_costs)
    | Some triage_output ->
      (* Triage is sometimes asked to choose between [skip_reason = None] (proceed)
       and [skip_reason = Some "..."] (bail).  When it has nothing to say but
       still feels obliged to populate the field, it emits the empty string —
       and we used to treat that as a real skip, silencing the entire security
       pipeline for the reviewed change (observed in production).  An empty or
       whitespace-only reason carries no information, so
       fall through to analysis and let the signal list drive the decision. *)
      let effective_skip_reason =
        match triage_output.skip_reason with
        | Some reason when String.length (String.trim reason) > 0 -> Some reason
        | Some _ | None -> None
      in
      (match effective_skip_reason with
      | Some reason ->
        log#info "triage: skipped (%s)" reason;
        let metrics = empty_analysis_metrics ~actionable_triage_signal_count:0 in
        log_stage_metrics ~changed_file_count:(List.length file_paths) ~deterministic_signals
          ~triage_signal_count:(List.length triage_output.signals) ~metrics ~costs:triage_costs;
        Security_artifacts.write_metrics artifacts
          (metrics_json ~changed_file_count:(List.length file_paths) ~deterministic_signals
             ~triage_signal_count:(List.length triage_output.signals) ~metrics ~costs:triage_costs);
        Security_artifacts.write_fetch_stats artifacts triage_costs;
        Security_artifacts.write_debug_json artifacts ~filename:"final_findings.json" (`List []);
        Lwt.return ([], triage_costs)
      | None ->
        let%lwt findings, analysis_costs, analysis_metrics =
          run_analysis ~ctx ~repo_url ~fetch_file:metadata.fetch_file ~security_config ~diff ~diff_text ~file_paths
            ~language_hints:triage_output.language_hints ~artifacts ~debug_dir triage_output.signals
        in
        let costs = triage_costs @ analysis_costs in
        log_stage_metrics ~changed_file_count:(List.length file_paths) ~deterministic_signals
          ~triage_signal_count:(List.length triage_output.signals) ~metrics:analysis_metrics ~costs;
        Security_artifacts.write_metrics artifacts
          (metrics_json ~changed_file_count:(List.length file_paths) ~deterministic_signals
             ~triage_signal_count:(List.length triage_output.signals) ~metrics:analysis_metrics ~costs);
        Security_artifacts.write_fetch_stats artifacts costs;
        Security_artifacts.write_debug_json artifacts ~filename:"final_findings.json"
          (Security_artifacts.final_findings_json findings);
        let observations = build_observations ~triage_output ~file_paths in
        Security_artifacts.write_debug_json artifacts ~filename:"memory_observations.json"
          (Security_types.architectural_observations_to_json observations);
        (* Fire the curator asynchronously — not in the critical review path.
         Last-write-wins is acceptable: the brief is a pure architectural
         description over the same repo, so concurrent writes converge. *)
        Lwt.async (fun () ->
          try%lwt
            let%lwt costs = curate_memory ~ctx ~repo_url ~memory_dir ~security_config ~observations ~debug_dir () in
            ignore (costs : Cost_tracking.agent_cost list);
            Lwt.return_unit
          with exn ->
            log#error "memory curator async task raised: %s" (Exn.str exn);
            Lwt.return_unit);
        Lwt.return (findings, costs))
end
