(* Calibrate decision-model thresholds against labeled corpora.

   Each feature sends the production questions from {!Decision_questions},
   grouped into requests exactly as the runtime groups them and with the same
   question names, so a measured threshold applies to the shipped prompt. The
   corpus supplies only states and labels:

     {"cases": [{"name": "...", "expected": <any JSON>, "state": {...}}]}

   Output is one JSON line per case and repetition. *)

open Reviewotron_lib

type request = {
  label : string;
  questions : (string * Decision_client.noul_question) list;
}

let single label question = { label; questions = [ "decision", question ] }

let candidate_validation =
  {
    label = "candidate_validation";
    questions =
      [ "supported", Decision_questions.candidate_supported; "fatal_defect", Decision_questions.candidate_fatal_defect ];
  }

let triage =
  {
    label = "triage";
    questions =
      List.map
        (fun vuln_class -> Security_types.vuln_class_to_string vuln_class, Decision_questions.triage vuln_class)
        Config_types.all_vuln_classes;
  }

let features =
  [
    "triage", [ triage ];
    "build_claim", [ single "build_claim" Decision_questions.build_claim ];
    ( "suggestion",
      [
        single "suggestion_defect" Decision_questions.suggestion_defect;
        single "suggestion_plausibility" Decision_questions.suggestion_plausibility;
      ] );
    "grouping_proposal", [ single "grouping_proposal" Decision_questions.grouping_proposal ];
    "notification_grouping", [ single "notification_grouping" Decision_questions.notification_grouping ];
    "candidate_validation", [ candidate_validation ];
    "source_constraint", [ single "source_constraint" Decision_questions.source_constraint; candidate_validation ];
  ]

let question_json (question : Decision_client.noul_question) =
  `Assoc
    [
      "instructions", `String question.instructions;
      "true_criteria", `String question.true_criteria;
      "false_criteria", `String question.false_criteria;
    ]

let dump_questions () =
  let triage =
    List.map
      (fun vuln_class ->
        "triage." ^ Security_types.vuln_class_to_string vuln_class, question_json (Decision_questions.triage vuln_class))
      Config_types.all_vuln_classes
  in
  let feature_questions =
    List.concat_map
      (fun (_, requests) ->
        List.concat_map
          (fun request ->
            List.map
              (fun (name, question) -> Printf.sprintf "%s.%s" request.label name, question_json question)
              request.questions)
          requests)
      features
    |> List.sort_uniq (fun (left, _) (right, _) -> String.compare left right)
  in
  print_endline (Yojson.Basic.pretty_to_string (`Assoc (triage @ feature_questions)))

(* Replace production questions by "label.name" key, for trying variants
   before they reach {!Decision_questions}. *)
let apply_overrides path requests =
  let json = Yojson.Basic.from_file path in
  let text name = function
    | `Assoc fields ->
      (match List.assoc_opt name fields with
      | Some (`String value) -> value
      | Some _ | None -> failwith (Printf.sprintf "override is missing string %S" name))
    | _ -> failwith "override must be an object"
  in
  let overrides =
    match json with
    | `Assoc fields -> fields
    | _ -> failwith "override file must map label.name to a question"
  in
  let used = ref [] in
  let requests =
    List.map
      (fun request ->
        {
          request with
          questions =
            List.map
              (fun (name, question) ->
                let key = Printf.sprintf "%s.%s" request.label name in
                match List.assoc_opt key overrides with
                | None -> name, question
                | Some override ->
                  used := key :: !used;
                  ( name,
                    {
                      Decision_client.instructions = text "instructions" override;
                      true_criteria = text "true_criteria" override;
                      false_criteria = text "false_criteria" override;
                    } ))
              request.questions;
        })
      requests
  in
  List.iter
    (fun (key, _) ->
      match List.mem key !used with
      | true -> ()
      | false -> failwith (Printf.sprintf "override %S matches no question of this feature" key))
    overrides;
  requests

(* Decision models read the state as text, so object key order is an
   irrelevant input change that still moves probabilities. Scoring every case
   under several orders shows how much of a margin survives it. *)
type order =
  | Original
  | Sorted
  | Reversed

let order_name = function
  | Original -> "original"
  | Sorted -> "sorted"
  | Reversed -> "reversed"

let order_of_string = function
  | "original" -> Original
  | "sorted" -> Sorted
  | "reversed" -> Reversed
  | other -> raise (Arg.Bad (Printf.sprintf "unknown order %S (expected original, sorted, reversed)" other))

let rec reorder order (json : Yojson.Basic.t) : Yojson.Basic.t =
  match json with
  | `Assoc fields ->
    let fields = List.map (fun (key, value) -> key, reorder order value) fields in
    let compare_keys (left, _) (right, _) = String.compare left right in
    (match order with
    | Original -> `Assoc fields
    | Sorted -> `Assoc (List.stable_sort compare_keys fields)
    | Reversed -> `Assoc (List.stable_sort (fun left right -> compare_keys right left) fields))
  | `List items -> `List (List.map (reorder order) items)
  | (`Null | `Bool _ | `Int _ | `Float _ | `String _) as scalar -> scalar

type case = {
  name : string;
  expected : Yojson.Basic.t;
  state : Yojson.Basic.t;
}

let read_corpus path =
  let field name json =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt name fields with
      | Some value -> value
      | None -> failwith (Printf.sprintf "corpus case is missing %S" name))
    | _ -> failwith "corpus case must be an object"
  in
  match field "cases" (Yojson.Basic.from_file path) with
  | `List cases ->
    List.map
      (fun json ->
        let name =
          match field "name" json with
          | `String name -> name
          | _ -> failwith "case name must be a string"
        in
        { name; expected = field "expected" json; state = field "state" json })
      cases
  | _ -> failwith "corpus cases must be a list"

let run_request client ~state request =
  let questions = List.map (fun (name, question) -> name, Decision_client.Noul question) request.questions in
  let%lwt response = Decision_client.decide client ~state ~questions in
  Lwt.return
    (match response with
    | Error error -> [], [ `String (Printf.sprintf "%s: %s" request.label error) ], 0.0, 0, None
    | Ok response ->
      let cost = Decision_client.cost response in
      let answers, errors =
        List.partition_map
          (fun (name, _) ->
            let key = Printf.sprintf "%s.%s" request.label name in
            match Decision_client.noul_answer response name with
            | Ok probability -> Left (key, `Float probability)
            | Error error -> Right (`String (Printf.sprintf "%s: %s" key error)))
          request.questions
      in
      answers, errors, cost.estimated_cost_usd, cost.input_tokens, Some cost.model)

let run_case client ~requests ~repetition ~order case =
  let started = Unix.gettimeofday () in
  let%lwt results = Lwt_list.map_s (run_request client ~state:(reorder order case.state)) requests in
  let answers = List.concat_map (fun (answers, _, _, _, _) -> answers) results in
  let errors = List.concat_map (fun (_, errors, _, _, _) -> errors) results in
  let cost = List.fold_left (fun total (_, _, cost, _, _) -> total +. cost) 0.0 results in
  let tokens = List.fold_left (fun total (_, _, _, tokens, _) -> total + tokens) 0 results in
  let response_models =
    List.filter_map (fun (_, _, _, _, model) -> Stdlib.Option.map (fun model -> `String model) model) results
  in
  `Assoc
    [
      "case", `String case.name;
      "expected", case.expected;
      "repetition", `Int repetition;
      "order", `String (order_name order);
      "model", `String (Decision_model.to_string (Decision_client.model client));
      "response_models", `List response_models;
      "answers", `Assoc answers;
      "errors", `List errors;
      "cost_usd", `Float cost;
      "input_tokens", `Int tokens;
      "elapsed_ms", `Float ((Unix.gettimeofday () -. started) *. 1000.0);
    ]
  |> Yojson.Basic.to_string
  |> print_endline;
  flush stdout;
  Lwt.return_unit

let run client ~requests ~repeats ~orders ~concurrency cases =
  let jobs =
    List.concat_map
      (fun repetition -> List.concat_map (fun order -> List.map (fun case -> repetition, order, case) cases) orders)
      (List.init repeats succ)
  in
  Lwt_list.iter_s
    (fun chunk ->
      Lwt_list.iter_p (fun (repetition, order, case) -> run_case client ~requests ~repetition ~order case) chunk)
    (CCList.chunks concurrency jobs)

let () =
  let feature = ref "" in
  let corpus = ref "" in
  let repeats = ref 3 in
  let concurrency = ref 4 in
  let dump = ref false in
  let override = ref "" in
  let orders = ref [ Original ] in
  Arg.parse
    [
      Decision_benchmark_env.model_spec;
      "--feature", Arg.Set_string feature, Printf.sprintf "NAME One of: %s" (String.concat ", " (List.map fst features));
      "--corpus", Arg.Set_string corpus, "FILE Calibration corpus";
      "--repeats", Arg.Set_int repeats, "N Repetitions per case (default 3)";
      "--concurrency", Arg.Set_int concurrency, "N Cases scored in parallel (default 4)";
      "--dump-questions", Arg.Set dump, "Print the production questions as JSON and exit";
      "--override", Arg.Set_string override, "FILE Replace questions by label.name (experiments only)";
      ( "--orders",
        Arg.String (fun names -> orders := List.map order_of_string (String.split_on_char ',' names)),
        "LIST State key orders to score: original,sorted,reversed (default original)" );
    ]
    (fun argument -> raise (Arg.Bad (Printf.sprintf "Unexpected argument: %s" argument)))
    "decision_calibration_benchmark --feature NAME --corpus FILE [options]";
  match !dump with
  | true -> dump_questions ()
  | false ->
    let requests =
      match List.assoc_opt !feature features with
      | Some requests -> requests
      | None ->
        raise (Arg.Bad (Printf.sprintf "--feature must be one of: %s" (String.concat ", " (List.map fst features))))
    in
    let requests =
      match !override with
      | "" -> requests
      | path -> apply_overrides path requests
    in
    if String.equal !corpus "" then raise (Arg.Bad "--corpus is required");
    if !repeats < 1 || !concurrency < 1 then raise (Arg.Bad "--repeats and --concurrency must be positive");
    let cases = read_corpus !corpus in
    let client = Decision_benchmark_env.client () in
    Lwt_main.run (run client ~requests ~repeats:!repeats ~orders:!orders ~concurrency:!concurrency cases)
