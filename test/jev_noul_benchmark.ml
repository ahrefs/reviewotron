open Reviewotron_lib

type case = {
  name : string;
  expected : bool;
  state : Yojson.Basic.t;
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

let question_of_json json : Jev_triage.noul_question =
  {
    instructions = string "instructions" json;
    true_criteria = string "true_criteria" json;
    false_criteria = string "false_criteria" json;
  }

let case_of_json json = { name = string "name" json; expected = bool "expected" json; state = assoc "state" json }

let read_corpus path =
  let json = Yojson.Basic.from_file path in
  let question = question_of_json (assoc "question" json) in
  let cases =
    match assoc "cases" json with
    | `List cases -> List.map case_of_json cases
    | _ -> failwith "Corpus cases must be a JSON array"
  in
  question, cases

let emit ~case ~repetition ~elapsed result =
  let common =
    [
      "case", `String case.name;
      "expected", `Bool case.expected;
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

let run_case ~api_key ~question ~repeats case =
  let rec repeat repetition =
    if repetition > repeats then Lwt.return_unit
    else (
      let started = Unix.gettimeofday () in
      let%lwt result = Jev_triage.score_noul ~api_key ~state:case.state ~question in
      emit ~case ~repetition ~elapsed:(Unix.gettimeofday () -. started) result;
      repeat (repetition + 1))
  in
  repeat 1

let self_test cases =
  let positive, negative = List.partition (fun case -> case.expected) cases in
  if List.is_empty cases then failwith "Corpus must not be empty";
  if List.length positive <> List.length negative then failwith "Corpus must be balanced";
  Printf.printf "ok: %d cases (%d positive, %d negative)\n" (List.length cases) (List.length positive)
    (List.length negative)

let () =
  let corpus = ref "" in
  let repeats = ref 5 in
  let self_test_only = ref false in
  Arg.parse
    [
      "--corpus", Arg.Set_string corpus, "FILE Noul benchmark corpus";
      "--repeats", Arg.Set_int repeats, "N Repetitions per case";
      "--self-test", Arg.Set self_test_only, "Validate benchmark inputs without API calls";
    ]
    (fun argument -> raise (Arg.Bad (Printf.sprintf "Unexpected argument: %s" argument)))
    "jev_noul_benchmark --corpus FILE [options]";
  if String.equal !corpus "" then raise (Arg.Bad "--corpus is required");
  let question, cases = read_corpus !corpus in
  match !self_test_only with
  | true -> self_test cases
  | false ->
    if !repeats < 1 then raise (Arg.Bad "--repeats must be positive");
    let api_key =
      match Sys.getenv_opt "TYPESAFE_API_KEY" with
      | Some api_key when not (String.equal (String.trim api_key) "") -> api_key
      | Some _ | None -> failwith "TYPESAFE_API_KEY is required"
    in
    Lwt_main.run (Lwt_list.iter_s (run_case ~api_key ~question ~repeats:!repeats) cases)
