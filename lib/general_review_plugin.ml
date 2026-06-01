open Devkit

let log = Log.from "general_review_plugin"

(* Sized for a single-shot multi-finding review; tune here without touching
   call sites. *)
let general_review_thinking_budget = 4096

let build_agent_config ~system_prompt : Agent_runner.agent_config =
  {
    name = "general_review";
    system_prompt;
    model_tier = Standard;
    output_schema = Review_types.review_output_jsonschema;
    max_steps = 1;
    thinking_budget = Some general_review_thinking_budget;
  }

let low_value_inline (f : Review_types.finding) =
  match f.severity, f.category with
  | Praise, _ | Nitpick, _ | _, Style | _, Naming | _, Documentation -> true
  | (Critical | Warning | Suggestion | Other _), (Bug | Security | Performance | Logic | Error_handling | Other _) ->
    false

let has_required_grounding (f : Review_types.finding) =
  let non_empty s = String.length (String.trim s) > 0 in
  non_empty f.message && non_empty f.failure_scenario && non_empty f.evidence_snippet && non_empty f.why_now

let security_category (f : Review_types.finding) =
  match f.category with
  | Security -> true
  | Bug | Performance | Style | Logic | Error_handling | Naming | Documentation | Other _ -> false

let should_validate_candidate ~security_covered_elsewhere (f : Review_types.finding) =
  (not (security_covered_elsewhere && security_category f))
  && (not (low_value_inline f))
  && Config_types.confidence_rank f.confidence >= Config_types.confidence_rank Medium
  && has_required_grounding f

let filter_candidates ~security_covered_elsewhere findings =
  List.filter
    (fun (f : Review_types.finding) ->
      let keep = should_validate_candidate ~security_covered_elsewhere f in
      if not keep then
        log#info "general review: dropped candidate before validation at %s:%d (%s/%s confidence=%s)" f.path f.line
          (Review_types.severity_to_string f.severity)
          (Review_types.finding_category_to_string f.category)
          (Review_types.confidence_to_string f.confidence);
      keep)
    findings

module Make (AI : Api.Agent_runner) = struct
  let name = "general"

  let confirmed_findings_by_candidate_id candidate_findings (output : Review_types.validator_output) =
    let n_candidates = List.length candidate_findings in
    let n_results = List.length output.results in
    match Int.equal n_candidates n_results with
    | false -> Error (Printf.sprintf "general validator returned %d results for %d candidates" n_results n_candidates)
    | true ->
      let by_id = Hashtbl.create n_results in
      let index_result (vf : Review_types.validated_finding) =
        match Hashtbl.find_opt by_id vf.candidate_id with
        | Some _ ->
          Error (Printf.sprintf "general validator returned duplicate result for candidate_id %d" vf.candidate_id)
        | None ->
          Hashtbl.replace by_id vf.candidate_id vf;
          Ok ()
      in
      let rec index_results = function
        | [] -> Ok ()
        | (vf : Review_types.validated_finding) :: rest ->
        match index_result vf with
        | Error _ as e -> e
        | Ok () -> index_results rest
      in
      (match index_results output.results with
      | Error _ as e -> e
      | Ok () ->
        let validator_decision index =
          match Hashtbl.find_opt by_id index with
          | None -> Error (Printf.sprintf "general validator omitted result for candidate_id %d" index)
          | Some vf -> Ok vf
        in
        let rec collect index acc = function
          | [] -> Ok (List.rev acc)
          | candidate :: rest ->
          match validator_decision index with
          | Error _ as e -> e
          | Ok vf ->
          match vf.verdict with
          | Confirmed -> collect (index + 1) (candidate :: acc) rest
          | Rejected ->
            log#info "general validator rejected candidate %d at %s:%d: %s" index vf.finding.path vf.finding.line
              vf.evidence_notes;
            collect (index + 1) acc rest
        in
        collect 0 [] candidate_findings)

  let run_validator ~ctx ~repo_url ~diff_text ~candidate_findings ?debug_dir () =
    match candidate_findings with
    | [] -> Lwt.return (Ok [], [])
    | _ :: _ ->
      let input = General_validator_agent.build_input ~diff_text ~candidate_findings () in
      let%lwt result = AI.run ~ctx ~repo_url ?debug_dir ~config:General_validator_agent.config ~input () in
      (match result with
      | Error msg ->
        log#error "general validator failed: %s" msg;
        Lwt.return (Error (Printf.sprintf "general validator failed: %s" msg), [])
      | Ok agent_result ->
        let cost = Cost_tracking.of_agent_result ~agent_name:"general_validator" ~files_fetched:0 agent_result in
        (match Review_types.validator_output_of_json agent_result.output with
        | exception exn ->
          let msg = Printf.sprintf "failed to parse general validator output: %s" (Exn.str exn) in
          log#error "%s" msg;
          Lwt.return (Error msg, [ cost ])
        | output ->
        match confirmed_findings_by_candidate_id candidate_findings output with
        | Ok confirmed -> Lwt.return (Ok confirmed, [ cost ])
        | Error msg ->
          log#error "%s" msg;
          Lwt.return (Error msg, [ cost ])))

  let run_review ~ctx ~repo_url ~(config : Config_types.config) ~diff_text ~metadata ?debug_dir () =
    let security_covered_elsewhere = config.review_plugins.security.enabled in
    let system = Review_prompt.system_prompt ?override:config.system_prompt_override ~security_covered_elsewhere () in
    let Review_plugin.{ pr_title; pr_description; file_contents; _ } = metadata in
    let input = Review_prompt.build_user_message ~diff:diff_text ~pr_title ~pr_description ~file_contents () in
    let agent_config = build_agent_config ~system_prompt:system in
    let%lwt result = AI.run ~ctx ~repo_url ~model_id:config.model ?debug_dir ~config:agent_config ~input () in
    match result with
    | Error _ as e -> Lwt.return (e, [])
    | Ok agent_result ->
      let cost = Cost_tracking.of_agent_result ~agent_name:"general_review" ~files_fetched:0 agent_result in
      (match Review_types.review_output_of_json agent_result.output with
      | exception exn ->
        Lwt.return (Error (Printf.sprintf "failed to parse general review output: %s" (Exn.str exn)), [ cost ])
      | review ->
        let counts = Hashtbl.create 8 in
        List.iter
          (fun (f : Review_types.finding) ->
            let key = Review_types.finding_category_to_string f.category in
            let n = try Hashtbl.find counts key with Not_found -> 0 in
            Hashtbl.replace counts key (n + 1))
          review.findings;
        let dist =
          Hashtbl.fold (fun k v acc -> (k, v) :: acc) counts []
          |> List.sort (fun (a, _) (b, _) -> String.compare a b)
          |> List.map (fun (k, v) -> Printf.sprintf "%s=%d" k v)
          |> String.concat " "
        in
        log#info "review agent: %d findings (%s), summary length %d" (List.length review.findings) dist
          (String.length review.summary);
        let candidates = filter_candidates ~security_covered_elsewhere review.findings in
        let%lwt confirmed, validator_costs =
          run_validator ~ctx ~repo_url ~diff_text ~candidate_findings:candidates ?debug_dir ()
        in
        (match confirmed with
        | Error msg -> Lwt.return (Error msg, cost :: validator_costs)
        | Ok confirmed ->
          log#info "general validator: %d/%d candidates confirmed" (List.length confirmed) (List.length candidates);
          Lwt.return (Ok { review with findings = confirmed }, cost :: validator_costs)))

  let run ~ctx ~repo_url ~config ~diff:_ ~diff_text ~metadata =
    let%lwt result, costs = run_review ~ctx ~repo_url ~config ~diff_text ~metadata () in
    match result with
    | Ok review -> Lwt.return (review.findings, costs)
    | Error msg ->
      log#error "general review plugin failed: %s" msg;
      Lwt.return ([], costs)
end
