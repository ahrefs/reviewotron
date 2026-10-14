open Reviewotron_lib

type case = {
  name : string;
  expected_supported : bool;
  candidate : Security_types.candidate_finding;
  evidence : string;
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

let case_of_json json =
  {
    name = string "name" json;
    expected_supported = bool "expected_supported" json;
    candidate = Security_types.candidate_finding_of_json (assoc "candidate" json);
    evidence = string "evidence" json;
  }

let read_corpus path =
  match assoc "cases" (Yojson.Basic.from_file path) with
  | `List cases -> List.map case_of_json cases
  | _ -> failwith "Corpus cases must be a JSON array"

let emit ~case ~repetition ~elapsed result =
  let common =
    [
      "case", `String case.name;
      "expected_supported", `Bool case.expected_supported;
      "repetition", `Int repetition;
      "elapsed_ms", `Float (elapsed *. 1000.0);
    ]
  in
  let json =
    match result with
    | Error error -> `Assoc (("error", `String error) :: common)
    | Ok ({ supported; fatal_defect; cost } : Jev_triage.candidate_validation_output) ->
      `Assoc
        (("supported", `Float supported)
        :: ("fatal_defect", `Float fatal_defect)
        :: ("input_tokens", `Int cost.input_tokens)
        :: ("cost_usd", `Float cost.estimated_cost_usd)
        :: common)
  in
  print_endline (Yojson.Basic.to_string json);
  flush stdout

let run_case ~api_key ~repeats case =
  let rec repeat repetition =
    if repetition > repeats then Lwt.return_unit
    else (
      let started = Unix.gettimeofday () in
      let%lwt result =
        Jev_triage.score_candidate_validation ~api_key ~candidate:case.candidate ~evidence:case.evidence
      in
      emit ~case ~repetition ~elapsed:(Unix.gettimeofday () -. started) result;
      repeat (repetition + 1))
  in
  repeat 1

let () =
  let corpus = ref "" in
  let repeats = ref 3 in
  Arg.parse
    [
      "--corpus", Arg.Set_string corpus, "FILE candidate-validation corpus";
      "--repeats", Arg.Set_int repeats, "N repetitions per case";
    ]
    (fun argument -> raise (Arg.Bad (Printf.sprintf "Unexpected argument: %s" argument)))
    "jev_candidate_validation_benchmark --corpus FILE [options]";
  if String.equal !corpus "" then raise (Arg.Bad "--corpus is required");
  if !repeats < 1 then raise (Arg.Bad "--repeats must be positive");
  let api_key =
    match Sys.getenv_opt "TYPESAFE_API_KEY" with
    | Some api_key when not (String.equal (String.trim api_key) "") -> api_key
    | Some _ | None -> failwith "TYPESAFE_API_KEY is required"
  in
  Lwt_main.run (Lwt_list.iter_s (run_case ~api_key ~repeats:!repeats) (read_corpus !corpus))
