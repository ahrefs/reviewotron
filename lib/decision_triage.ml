open Devkit

let log = Log.from "decision_triage"
let ( let* ) = Result.bind

let log_context_prefix = function
  | Some context -> context ^ " "
  | None -> ""

type output = {
  signals : Security_types.triage_signal list;
  costs : Cost_tracking.agent_cost list;
  complete : bool;
}

type score = {
  vuln_class : Config_types.vuln_class;
  probability : float;
}

type score_output = {
  scores : score list;
  cost : Cost_tracking.agent_cost;
}

type candidate_validation_output = {
  supported : float;
  fatal_defect : float;
  cost : Cost_tracking.agent_cost;
}

let status_string = function
  | Diff_parser.Added -> "added"
  | Deleted -> "deleted"
  | Modified -> "modified"
  | Renamed -> "renamed"

let regions (file_diff : Diff_parser.file_diff) =
  List.filter_map
    (fun (hunk : Diff_parser.hunk) ->
      match hunk.new_count with
      | 0 -> None
      | count ->
        Some
          { Security_types.path = file_diff.path; start_line = hunk.new_start; end_line = hunk.new_start + count - 1 })
    file_diff.hunks

let relationship_proposed ~threshold ~forward ~reverse = forward >= threshold && reverse >= threshold

let confidence ~model probability =
  match probability >= (Decision_model.thresholds model).triage with
  | true -> Security_types.High
  | false -> Medium

let signal ~model ~threshold ~regions ~scope { vuln_class; probability } =
  match probability < threshold with
  | true -> None
  | false ->
    let id = Security_types.vuln_class_to_string vuln_class in
    Some
      {
        Security_types.vuln_class;
        confidence = confidence ~model probability;
        regions;
        rationale =
          Printf.sprintf "%s routed %s to %s analysis (Noul %.3f)." (Decision_model.openrouter_id model) scope id
            probability;
      }

let scores_of_response ~vuln_classes response =
  let* scores =
    List.fold_left
      (fun result vuln_class ->
        let* scores = result in
        let* probability = Decision_client.noul_answer response (Security_types.vuln_class_to_string vuln_class) in
        Ok ({ vuln_class; probability } :: scores))
      (Ok []) vuln_classes
  in
  Ok { scores = List.rev scores; cost = Decision_client.cost response }

let triage_agent_name = "decision_triage"

let scores_of_body ~model ~vuln_classes body =
  Result.bind
    (Decision_client.response_of_body ~agent_name:triage_agent_name ~model body)
    (scores_of_response ~vuln_classes)

let candidate_validation_of_response response =
  let* supported = Decision_client.noul_answer response "supported" in
  let* fatal_defect = Decision_client.noul_answer response "fatal_defect" in
  Ok { supported; fatal_defect; cost = Decision_client.cost response }

let candidate_validation_of_body ~agent_name ~model body =
  Result.bind (Decision_client.response_of_body ~agent_name ~model body) candidate_validation_of_response

let signals_of_scores ~model ~threshold ~file_diff scores =
  List.filter_map (signal ~model ~threshold ~regions:(regions file_diff) ~scope:"this file") scores

let add_whole_diff_signals ~file_signals whole_diff_signals =
  let uncovered (signal : Security_types.triage_signal) =
    not
      (List.exists
         (fun (file_signal : Security_types.triage_signal) ->
           Config_types.vuln_class_equal file_signal.vuln_class signal.vuln_class)
         file_signals)
  in
  file_signals @ List.filter uncovered whole_diff_signals

let signals_of_body ~model ~threshold ~vuln_classes ~file_diff body =
  let* { scores; cost } = scores_of_body ~model ~vuln_classes body in
  Ok (signals_of_scores ~model ~threshold ~file_diff scores, cost)

let score_context client ~vuln_classes ~path ~status ~annotated_diff =
  let state = `Assoc [ "path", `String path; "status", `String status; "annotated_diff", `String annotated_diff ] in
  let%lwt response =
    Decision_client.decide client ~agent_name:triage_agent_name ~state
      ~questions:(Decision_questions.triage_questions vuln_classes)
  in
  Lwt.return (Result.bind response (scores_of_response ~vuln_classes))

let score_candidate_validation client ~agent_name ~candidate ~evidence =
  let state =
    `Assoc [ "candidate", Security_types.candidate_finding_to_json candidate; "evidence", `String evidence ]
  in
  let%lwt response =
    Decision_client.decide client ~agent_name ~state ~questions:Decision_questions.candidate_validation
  in
  Lwt.return (Result.bind response candidate_validation_of_response)

let evaluate_file client ~threshold ~vuln_classes file_diff =
  let%lwt result =
    score_context client ~vuln_classes ~path:file_diff.Diff_parser.path ~status:(status_string file_diff.status)
      ~annotated_diff:(Diff_parser.to_string_annotated [ file_diff ])
  in
  Lwt.return
    (Result.map
       (fun { scores; cost } ->
         signals_of_scores ~model:(Decision_client.model client) ~threshold ~file_diff scores, cost)
       result)

let evaluate_and_log ?log_context client ~threshold ~vuln_classes file_diff =
  let%lwt result = evaluate_file client ~threshold ~vuln_classes file_diff in
  Result.iter_error
    (fun error ->
      log#warn "%sdecision triage failed for %s: %s" (log_context_prefix log_context) file_diff.Diff_parser.path error)
    result;
  Lwt.return result

let evaluate_whole_diff ?log_context client ~threshold ~vuln_classes diff =
  let%lwt result =
    score_context client ~vuln_classes ~path:"(whole diff)" ~status:"modified"
      ~annotated_diff:(Diff_parser.to_string_annotated diff)
  in
  Result.iter_error
    (fun error -> log#warn "%swhole-diff decision triage failed: %s" (log_context_prefix log_context) error)
    result;
  let regions = List.concat_map regions diff in
  Lwt.return
    (Result.map
       (fun { scores; cost } ->
         ( List.filter_map
             (signal ~model:(Decision_client.model client) ~threshold ~regions ~scope:"the whole diff")
             scores,
           cost ))
       result)

let run ?log_context client ~threshold ~vuln_classes ~diff () =
  match Decision_model.is_probability threshold, vuln_classes, diff with
  | false, _, _ ->
    Lwt.return (Error (Printf.sprintf "decision triage threshold must be between 0 and 1 (got %.4f)" threshold))
  | true, [], _ | true, _, [] -> Lwt.return (Ok { signals = []; costs = []; complete = true })
  | true, _ :: _, (_ :: rest as files) ->
    (* The client bounds how many files are scored at once. *)
    let%lwt results = Lwt_list.map_p (evaluate_and_log ?log_context client ~threshold ~vuln_classes) files
    and whole_diff =
      match rest with
      | [] -> Lwt.return (Ok ([], []))
      | _ :: _ ->
        Lwt.map
          (Result.map (fun (signals, cost) -> signals, [ cost ]))
          (evaluate_whole_diff ?log_context client ~threshold ~vuln_classes files)
    in
    let evaluated, errors =
      List.partition_map
        (function
          | Ok evaluated -> Either.Left evaluated
          | Error error -> Either.Right error)
        results
    in
    (match evaluated, errors with
    | [], error :: _ -> Lwt.return (Error error)
    | _ :: _, _ | [], [] ->
      let file_signals = List.concat_map fst evaluated in
      let costs = List.map snd evaluated in
      let signals, costs, whole_diff_complete =
        match whole_diff with
        | Ok (whole_diff_signals, whole_diff_costs) ->
          add_whole_diff_signals ~file_signals whole_diff_signals, costs @ whole_diff_costs, true
        | Error _ -> file_signals, costs, false
      in
      Lwt.return (Ok { signals; costs; complete = CCList.is_empty errors && whole_diff_complete }))
