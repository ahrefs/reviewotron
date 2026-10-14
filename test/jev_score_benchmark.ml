open Reviewotron_lib

type case = {
  name : string;
  confirmed : bool;
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

let question_of_json json : Jev_triage.graded_question =
  let criteria =
    match assoc "criteria" json with
    | `List values ->
      List.map
        (function
          | `String value -> value
          | _ -> failwith "Score criteria must be strings")
        values
    | _ -> failwith "Score criteria must be an array"
  in
  { instructions = string "instructions" json; criteria }

let case_of_json json = { name = string "name" json; confirmed = bool "confirmed" json; state = assoc "state" json }

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
      "confirmed", `Bool case.confirmed;
      "repetition", `Int repetition;
      "elapsed_ms", `Float (elapsed *. 1000.0);
    ]
  in
  let json =
    match result with
    | Error error -> `Assoc (("error", `String error) :: common)
    | Ok ({ score; confidence; cost } : Jev_triage.graded_output) ->
      `Assoc
        (("score", `Float score)
        :: ("confidence", `Float confidence)
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
      let%lwt result = Jev_triage.score_dimension ~api_key ~state:case.state ~question in
      emit ~case ~repetition ~elapsed:(Unix.gettimeofday () -. started) result;
      repeat (repetition + 1))
  in
  repeat 1

let self_test question cases =
  let confirmed, rejected = List.partition (fun case -> case.confirmed) cases in
  if List.length confirmed <> List.length rejected then failwith "Ranking corpus must be balanced";
  if List.length question.Jev_triage.criteria < 2 then failwith "Ranking question needs at least two levels";
  Printf.printf "ok: %d cases (%d confirmed, %d rejected, %d levels)\n" (List.length cases) (List.length confirmed)
    (List.length rejected) (List.length question.criteria)

let () =
  let corpus = ref "test/jev_ranking_cases.json" in
  let repeats = ref 5 in
  let self_test_only = ref false in
  Arg.parse
    [
      "--corpus", Arg.Set_string corpus, "FILE Candidate ranking corpus";
      "--repeats", Arg.Set_int repeats, "N Repetitions per candidate";
      "--self-test", Arg.Set self_test_only, "Validate benchmark inputs without API calls";
    ]
    (fun argument -> raise (Arg.Bad (Printf.sprintf "Unexpected argument: %s" argument)))
    "jev_score_benchmark [options]";
  let question, cases = read_corpus !corpus in
  match !self_test_only with
  | true -> self_test question cases
  | false ->
    if !repeats < 1 then raise (Arg.Bad "--repeats must be positive");
    let api_key =
      match Sys.getenv_opt "TYPESAFE_API_KEY" with
      | Some api_key when not (String.equal (String.trim api_key) "") -> api_key
      | Some _ | None -> failwith "TYPESAFE_API_KEY is required"
    in
    Lwt_main.run (Lwt_list.iter_s (run_case ~api_key ~question ~repeats:!repeats) cases)
