open Reviewotron_lib

type pair_case = {
  name : string;
  duplicate : bool;
  finding_a : Yojson.Basic.t;
  finding_b : Yojson.Basic.t;
}

let assoc name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
    | Some value -> value
    | None -> failwith (Printf.sprintf "Missing %S" name))
  | _ -> failwith "Expected a JSON object"

let string name json =
  match assoc name json with
  | `String value -> value
  | _ -> failwith (Printf.sprintf "%S must be a string" name)

let bool name json =
  match assoc name json with
  | `Bool value -> value
  | _ -> failwith (Printf.sprintf "%S must be a boolean" name)

let int name json =
  match assoc name json with
  | `Int value -> value
  | _ -> failwith (Printf.sprintf "%S must be an integer" name)

let pair_case_of_json json =
  {
    name = string "name" json;
    duplicate = bool "duplicate" json;
    finding_a = assoc "finding_a" json;
    finding_b = assoc "finding_b" json;
  }

let read_cases path =
  match Yojson.Basic.from_file path with
  | `List cases -> List.map pair_case_of_json cases
  | _ -> failwith "Dedup corpus must be a JSON array"

let sink finding =
  let sink = assoc "sink" finding in
  string "path" sink, int "line" sink

let finding_class finding = string "class" finding

let exact_sink_duplicate case =
  let path_a, line_a = sink case.finding_a in
  let path_b, line_b = sink case.finding_b in
  String.equal path_a path_b && Int.equal line_a line_b

let nearby_same_class_duplicate case =
  let path_a, line_a = sink case.finding_a in
  let path_b, line_b = sink case.finding_b in
  String.equal (finding_class case.finding_a) (finding_class case.finding_b)
  && String.equal path_a path_b
  && Int.abs (line_a - line_b) <= 3

let dedup_question : Jev_triage.noul_question =
  {
    instructions =
      "Should `finding_a` and `finding_b` be merged because they describe the same underlying security defect and one \
       concrete code or policy repair would resolve both reports? Judge the causal defect and repair, not wording, \
       vulnerability label, or anchor-line equality.";
    true_criteria =
      "Both findings trace to the same unsafe operation or missing control, and one concrete repair at that operation \
       or control would resolve both reports. Different evidence anchors or descriptions may still be duplicates.";
    false_criteria =
      "The findings require separate repairs, concern different unsafe operations or missing controls, or one is a \
       prerequisite or companion issue whose repair would not resolve the other. Proximity, shared data, or the same \
       handler alone is insufficient.";
  }

let consolidation_question : Jev_triage.noul_question =
  {
    instructions =
      "Can `finding_a` and `finding_b` be safely published as one security finding because they are independently \
       confirmed evidence of the same causal defect and one specific repair at their shared source of truth or control \
       resolves both?";
    true_criteria =
      "The findings establish the same causal defect, and one specific repair at a shared source of truth or control \
       resolves every affected location while preserving the evidence and impact from both findings.";
    false_criteria =
      "The findings require separate edits or repairs, repeat a vulnerability pattern at independent sites, describe \
       prerequisite or companion defects, or cannot be combined without hiding an affected location, proof, impact, or \
       remediation step. A broad patch that could happen to address both is insufficient.";
  }

let grouping_proposal_question : Jev_triage.noul_question =
  {
    instructions =
      "Should `finding_a` and `finding_b` be sent together to a consolidation verifier because they plausibly arise \
       from the same causal defect or missing control and may share one repair? This judgment only retrieves possible \
       groups; it does not merge or suppress either confirmed finding.";
    true_criteria =
      "The findings plausibly share one causal source, source-of-truth policy, generated artifact, unsafe input, or \
       missing control such that one repair may resolve both. Include cases needing repository evidence to confirm the \
       relationship.";
    false_criteria =
      "The findings are independent defects or merely repeat a vulnerability pattern, principal, file, feature, or \
       review context without a plausible shared causal source or control.";
  }

let emit ~case ~order ~repetition ~elapsed result =
  let common =
    [
      "case", `String case.name;
      "duplicate", `Bool case.duplicate;
      "exact_sink_duplicate", `Bool (exact_sink_duplicate case);
      "nearby_same_class_duplicate", `Bool (nearby_same_class_duplicate case);
      "order", `String order;
      "repetition", `Int repetition;
      "elapsed_ms", `Float (elapsed *. 1000.0);
    ]
  in
  let json =
    match result with
    | Error error -> `Assoc (("error", `String error) :: common)
    | Ok ({ probability; cost } : Jev_triage.noul_output) ->
      `Assoc
        (("probability", `Float probability)
        :: ("input_tokens", `Int cost.input_tokens)
        :: ("cost_usd", `Float cost.estimated_cost_usd)
        :: common)
  in
  print_endline (Yojson.Basic.to_string json);
  flush stdout

let run_order ~api_key ~question ~case ~repetition (order, finding_a, finding_b) =
  let state = `Assoc [ "finding_a", finding_a; "finding_b", finding_b ] in
  let started = Unix.gettimeofday () in
  let%lwt result = Jev_triage.score_noul ~api_key ~state ~question in
  emit ~case ~order ~repetition ~elapsed:(Unix.gettimeofday () -. started) result;
  Lwt.return_unit

let run_case ~api_key ~question ~repeats case =
  let orders = [ "ab", case.finding_a, case.finding_b; "ba", case.finding_b, case.finding_a ] in
  let rec repeat repetition =
    if repetition > repeats then Lwt.return_unit
    else (
      let%lwt () = Lwt_list.iter_s (run_order ~api_key ~question ~case ~repetition) orders in
      repeat (repetition + 1))
  in
  repeat 1

let self_test cases =
  let duplicates, distinct = List.partition (fun case -> case.duplicate) cases in
  if List.length duplicates <> List.length distinct then failwith "Dedup corpus must be balanced";
  let baseline_errors = List.filter (fun case -> exact_sink_duplicate case <> case.duplicate) cases in
  if List.is_empty baseline_errors then failwith "Dedup corpus must challenge exact-sink matching";
  Printf.printf "ok: %d pairs (%d duplicates, %d distinct, %d exact-sink errors)\n" (List.length cases)
    (List.length duplicates) (List.length distinct) (List.length baseline_errors)

let () =
  let corpus = ref "test/jev_dedup_cases.json" in
  let repeats = ref 5 in
  let self_test_only = ref false in
  let consolidation = ref false in
  let grouping_proposal = ref false in
  Arg.parse
    [
      "--corpus", Arg.Set_string corpus, "FILE Dedup pair corpus";
      "--repeats", Arg.Set_int repeats, "N Repetitions per pair";
      "--self-test", Arg.Set self_test_only, "Validate benchmark inputs without API calls";
      "--consolidation", Arg.Set consolidation, "Ask whether confirmed findings are safe to consolidate";
      "--grouping-proposal", Arg.Set grouping_proposal, "Ask whether confirmed findings warrant shared verification";
    ]
    (fun argument -> raise (Arg.Bad (Printf.sprintf "Unexpected argument: %s" argument)))
    "jev_dedup_benchmark [options]";
  let cases = read_cases !corpus in
  match !self_test_only with
  | true -> self_test cases
  | false ->
    if !repeats < 1 then raise (Arg.Bad "--repeats must be positive");
    let api_key =
      match Sys.getenv_opt "TYPESAFE_API_KEY" with
      | Some api_key when not (String.equal (String.trim api_key) "") -> api_key
      | Some _ | None -> failwith "TYPESAFE_API_KEY is required"
    in
    let question =
      match !consolidation, !grouping_proposal with
      | true, false -> consolidation_question
      | false, true -> grouping_proposal_question
      | false, false -> dedup_question
      | true, true -> raise (Arg.Bad "choose only one benchmark question")
    in
    Lwt_main.run (Lwt_list.iter_s (run_case ~api_key ~question ~repeats:!repeats) cases)
