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

module Make (AI : Api.Agent_runner) = struct
  let name = "security"

  (** Run the triage agent and parse its structured output.
      Returns the parsed output (if successful) and any agent costs incurred. *)
  let run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths ?security_memory ?debug_dir () =
    let triage_config =
      Triage_agent.config ~model_tier:(agent_model_tier security_config.Config_types.triage_model_tier)
    in
    let triage_input = Triage_agent.build_input ~diff_text ~file_paths ?security_memory () in
    let%lwt result = AI.run ~ctx ~repo_url ?debug_dir ~config:triage_config ~input:triage_input () in
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

  (** Run a single analysis agent for one vulnerability class.

      Returns the list of candidate findings and the agent cost on success,
      or an empty list with no cost if the agent fails. *)
  let run_single_analysis ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~file_paths ~language_hints ~vuln_class
    ~triage_signals ?debug_dir () =
    let vc_name = Security_types.vuln_class_to_string vuln_class in
    let model_tier = agent_model_tier security_config.Config_types.analysis_model_tier in
    let agent_config = Analysis_agent.config ~vuln_class ~model_tier ~language_hints in
    let input = Analysis_agent.build_input ~diff_text ~triage_signals ~file_paths () in
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

  (** A candidate's sink is what the analysis agent picked as "the dangerous
      operation."  For some vulnerability classes — notably authz — the agent
      tends to point [sink] at the enforcement/decision point (e.g. a role
      check) rather than at the defect site where the PR actually introduces
      the flaw.  When that enforcement point lives in unchanged code, the
      finding can't be rendered as an inline comment even though the flow
      chain almost always traces through a line that was changed.

      [pick_inline_anchor] walks [\[sink\] @ flow @ \[source\]] in priority
      order and returns the first [(path, line)] whose [path] is present in
      the diff.  If none qualify, we fall back to the sink — the finding then
      routes to the "unchanged code" section in the main review body.

      The ordering means: prefer the sink when it's already in the diff,
      otherwise prefer a flow step, otherwise the source.  Flow is ordered
      source→sink by construction, so taking the first diff-resident step
      gives us the earliest point on the path that this PR touches. *)
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

  (** Convert a validated finding into a review finding.

      Only called for findings with a [Confirmed] verdict.  Severity is
      derived from the inner candidate's confidence level.  [evidence_notes]
      from the validator is not surfaced in the PR comment — it is available
      in logs for prompt tuning.

      Inline anchor is picked from the evidence chain via [pick_inline_anchor]
      so that findings whose sink lives in unchanged code still land on a
      changed line when the flow traces through one.  [end_line] is derived
      from flow steps relative to the chosen anchor. *)
  let validated_to_finding ~diff (vf : Security_types.validated_finding) : Review_types.finding =
    let f = vf.finding in
    let anchor_kind, anchor_path, anchor_line = pick_inline_anchor ~diff f in
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
      failure_scenario = f.description;
      suggested_fix = f.suggested_fix;
    }

  (** Run the validator agent on candidate findings and parse its output.

      Returns the list of validated findings and the agent cost on success.
      If the validator agent fails or its output cannot be parsed, returns
      an empty list — unvalidated findings are never reported. *)
  let run_validator ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~candidate_findings ?debug_dir () =
    let model_tier = agent_model_tier security_config.Config_types.validator_model_tier in
    let agent_config = Validator_agent.config ~model_tier in
    let input = Validator_agent.build_input ~diff_text ~candidate_findings () in
    let tools = Validator_agent.tools ~fetch_file:(fun path -> fetch_file ~path) in
    let%lwt result = AI.run ~ctx ~repo_url ~tools ?debug_dir ~config:agent_config ~input () in
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
  let run_analysis ~ctx ~repo_url ~fetch_file ~security_config ~diff ~diff_text ~file_paths ~language_hints ?debug_dir
    signals =
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
                run_single_analysis ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~file_paths ~language_hints
                  ~vuln_class ~triage_signals ?debug_dir ())
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
      | [] -> Lwt.return ([], analysis_costs)
      | _ :: _ ->
        let%lwt validated, validator_costs =
          run_validator ~ctx ~repo_url ~fetch_file ~security_config ~diff_text ~candidate_findings:candidates ?debug_dir
            ()
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
        Lwt.return (List.map (validated_to_finding ~diff) confirmed, analysis_costs @ validator_costs))

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
      (match Security_types.curator_output_of_json agent_result.output with
      | output ->
        let estimated = Memory_curator_agent.estimate_tokens output.updated_memory in
        if estimated > memory_max_tokens then
          log#warn "curator output exceeds token limit (%d > %d), saving anyway" estimated memory_max_tokens;
        Security_memory.save ~memory_dir ~repo_url ~content:output.updated_memory;
        log#info "memory brief updated";
        Lwt.return [ cost ]
      | exception exn ->
        log#error "failed to parse curator output: %s" (Exn.str exn);
        Lwt.return [ cost ])

  let run ~ctx ~repo_url ~(config : Config_types.config) ~diff ~diff_text ~(metadata : Review_plugin.review_metadata)
    ~debug_dir =
    let security_config = config.review_plugins.security in
    let memory_dir = "memory" in
    let security_memory = Security_memory.load ~memory_dir ~repo_url in
    let file_paths = List.map (fun (fd : Diff_parser.file_diff) -> fd.path) diff in
    let%lwt triage_result, triage_costs =
      run_triage ~ctx ~repo_url ~security_config ~diff_text ~file_paths ?security_memory ~debug_dir ()
    in
    match triage_result with
    | None -> Lwt.return ([], triage_costs)
    | Some triage_output ->
      (* Triage is sometimes asked to choose between [skip_reason = None] (proceed)
       and [skip_reason = Some "..."] (bail).  When it has nothing to say but
       still feels obliged to populate the field, it emits the empty string —
       and we used to treat that as a real skip, silencing the entire security
       pipeline for the PR (observed in production).  An empty or
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
        Lwt.return ([], triage_costs)
      | None ->
        let%lwt findings, analysis_costs =
          run_analysis ~ctx ~repo_url ~fetch_file:metadata.fetch_file ~security_config ~diff ~diff_text ~file_paths
            ~language_hints:triage_output.language_hints ~debug_dir triage_output.signals
        in
        let observations = build_observations ~triage_output ~file_paths in
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
        Lwt.return (findings, triage_costs @ analysis_costs))
end
