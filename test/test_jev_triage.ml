open Alcotest
open Reviewotron_lib

let response =
  {|{
    "model": "jev-1.13.0",
    "answers": {
      "xss": {"type": "noul", "noul": 0.91},
      "injection": {"type": "noul", "noul": 0.20}
    },
    "usage": {"input_tokens": 500, "output_tokens": 40}
  }|}

let graded_response =
  {|{
    "model": "jev-1.13.0",
    "answers": {
      "decision": {"type": "score", "score": 2.4, "confidence": 0.6}
    },
    "usage": {"input_tokens": 300, "output_tokens": 30}
  }|}

let test_response_routes_only_probable_classes () =
  let diff =
    Diff_parser.parse
      "diff --git a/app.ts b/app.ts\n\
       --- a/app.ts\n\
       +++ b/app.ts\n\
       @@ -10,1 +10,2 @@\n\
       -return text;\n\
       +const html = marked(text);\n\
       +return html;\n"
  in
  match diff with
  | [ file_diff ] ->
    (match
       Jev_triage.signals_of_response ~threshold:0.5 ~vuln_classes:[ Config_types.Xss; Injection ] ~file_diff response
     with
    | Error error -> fail error
    | Ok ([ signal ], cost) ->
      check string "class" "xss" (Security_types.vuln_class_to_string signal.vuln_class);
      check int "one region" 1 (List.length signal.regions);
      check int "input tokens" 500 cost.input_tokens;
      check (float 0.0000001) "cost" 0.000021 cost.estimated_cost_usd
    | Ok _ -> fail "expected exactly one XSS signal")
  | _ -> fail "expected exactly one parsed file"

let test_score_context_response_contract () =
  match Jev_triage.scores_of_response ~vuln_classes:[ Config_types.Xss; Injection ] response with
  | Error error -> fail error
  | Ok { scores = [ xss; injection ]; cost } ->
    check string "first class" "xss" (Security_types.vuln_class_to_string xss.vuln_class);
    check (float 0.0001) "xss probability" 0.91 xss.probability;
    check string "second class" "injection" (Security_types.vuln_class_to_string injection.vuln_class);
    check (float 0.0001) "injection probability" 0.20 injection.probability;
    check int "input tokens" 500 cost.input_tokens
  | Ok _ -> fail "expected two raw scores"

let test_graded_response_contract () =
  match Jev_triage.graded_output_of_response ~levels:4 graded_response with
  | Error error -> fail error
  | Ok output ->
    check (float 0.0001) "score" 2.4 output.score;
    check (float 0.0001) "confidence" 0.6 output.confidence;
    check int "input tokens" 300 output.cost.input_tokens

let () =
  run "jev_triage"
    [
      ( "response",
        [
          test_case "routes probable classes" `Quick test_response_routes_only_probable_classes;
          test_case "preserves raw probabilities" `Quick test_score_context_response_contract;
          test_case "parses graded output" `Quick test_graded_response_contract;
        ] );
    ]
