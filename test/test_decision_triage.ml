open Alcotest
open Reviewotron_lib

let response =
  {|{
    "id": "gen-dec-1",
    "model": "typesafe/jev-1.13-20260917",
    "provider": "TypeSafe",
    "answers": {
      "xss": {"type": "noul", "noul": 0.91},
      "injection": {"type": "noul", "noul": 0.20}
    },
    "usage": {"input_tokens": 500, "output_tokens": 40}
  }|}

let candidate_validation_response =
  {|{
    "model": "openai/gpt-6-luna-decisions-20261006",
    "provider": "OpenAI",
    "answers": {
      "supported": {"type": "noul", "noul": 0.66},
      "fatal_defect": {"type": "noul", "noul": 0.24}
    },
    "usage": {"input_tokens": 900, "output_tokens": 0, "cost": 0.00009}
  }|}

let single_file_diff () =
  match
    Diff_parser.parse
      "diff --git a/app.ts b/app.ts\n\
       --- a/app.ts\n\
       +++ b/app.ts\n\
       @@ -10,1 +10,2 @@\n\
       -return text;\n\
       +const html = marked(text);\n\
       +return html;\n"
  with
  | [ file_diff ] -> file_diff
  | _ -> fail "expected exactly one parsed file"

let test_response_routes_only_probable_classes () =
  let file_diff = single_file_diff () in
  match
    Decision_triage.signals_of_body ~model:Jev ~threshold:0.5 ~vuln_classes:[ Config_types.Xss; Injection ] ~file_diff
      response
  with
  | Error error -> fail error
  | Ok ([ signal ], cost) ->
    check string "class" "xss" (Security_types.vuln_class_to_string signal.vuln_class);
    check int "one region" 1 (List.length signal.regions);
    check bool "high confidence above the model's triage threshold" true
      (match signal.confidence with
      | High -> true
      | Medium | Low -> false);
    check int "input tokens" 500 cost.input_tokens;
    check (float 0.0000001) "price fallback when usage.cost is absent" 0.000021 cost.estimated_cost_usd
  | Ok _ -> fail "expected exactly one XSS signal"

let test_score_context_response_contract () =
  match Decision_triage.scores_of_body ~model:Jev ~vuln_classes:[ Config_types.Xss; Injection ] response with
  | Error error -> fail error
  | Ok { scores = [ xss; injection ]; cost } ->
    check string "first class" "xss" (Security_types.vuln_class_to_string xss.vuln_class);
    check (float 0.0001) "xss probability" 0.91 xss.probability;
    check string "second class" "injection" (Security_types.vuln_class_to_string injection.vuln_class);
    check (float 0.0001) "injection probability" 0.20 injection.probability;
    check string "reported model" "typesafe/jev-1.13-20260917" cost.model;
    check string "reported under the triage label" "decision_triage" cost.agent_name
  | Ok _ -> fail "expected two raw scores"

let test_candidate_validation_response_contract () =
  match
    Decision_triage.candidate_validation_of_body ~agent_name:"decision_validator_cascade" ~model:Gpt_6_luna
      candidate_validation_response
  with
  | Error error -> fail error
  | Ok output ->
    check (float 0.0001) "supported" 0.66 output.supported;
    check (float 0.0001) "fatal defect" 0.24 output.fatal_defect;
    check (float 0.0000001) "cost" 0.00009 output.cost.estimated_cost_usd;
    check string "caller's label" "decision_validator_cascade" output.cost.agent_name

let test_unexpected_answer_type_is_an_error () =
  let body =
    {|{"model": "openai/gpt-6-luna-decisions-20261006",
       "answers": {"xss": {"type": "refusal"}, "injection": {"type": "noul", "noul": 0.1}},
       "usage": {"input_tokens": 10, "output_tokens": 0}}|}
  in
  check bool "refused answer fails the request" true
    (Result.is_error
       (Decision_triage.scores_of_body ~model:Gpt_6_luna ~vuln_classes:[ Config_types.Xss; Injection ] body))

let test_request_body_wire_format () =
  let body =
    Decision_client.request_body ~model:Gpt_6_luna
      ~state:(`Assoc [ "diff", `String "+x" ])
      ~questions:
        [
          "triage", { instructions = "Is it risky?"; true_criteria = "Risky."; false_criteria = "Safe." };
          "secret", { instructions = "Is a secret exposed?"; true_criteria = "Exposed."; false_criteria = "Hidden." };
        ]
  in
  check string "OpenRouter decisions body"
    {|{"model":"openai/gpt-6-luna-decisions-20261006","state":{"diff":"+x"},"questions":{"triage":{"type":"noul","instructions":"Is it risky?","criteria":{"true":"Risky.","false":"Safe."}},"secret":{"type":"noul","instructions":"Is a secret exposed?","criteria":{"true":"Exposed.","false":"Hidden."}}}}|}
    body

let test_endpoint_follows_base_url () =
  check string "default" "https://openrouter.ai/api/alpha/decisions" (Decision_client.endpoint_of_base_url None);
  check string "proxy with /v1" "http://127.0.0.1:18080/api/alpha/decisions"
    (Decision_client.endpoint_of_base_url (Some "http://127.0.0.1:18080/api/v1"));
  check string "proxy without /v1" "http://proxy/api/alpha/decisions"
    (Decision_client.endpoint_of_base_url (Some "http://proxy/api"))

let test_decisions_key_falls_back_to_openrouter_key () =
  let secrets ~decisions ~openrouter : Config_types.secrets =
    {
      repos = [];
      anthropic_api_key = Some "sk-ant";
      openrouter_api_key = openrouter;
      openrouter_decisions_api_key = decisions;
      slack_access_token = None;
    }
  in
  check bool "decisions-only key" true
    (Stdlib.Option.is_some
       (Decision_client.of_secrets ~model:Jev (secrets ~decisions:(Some "sk-or-d") ~openrouter:None)));
  check bool "general OpenRouter key" true
    (Stdlib.Option.is_some
       (Decision_client.of_secrets ~model:Jev (secrets ~decisions:(Some " ") ~openrouter:(Some "sk-or"))));
  check bool "Anthropic key alone is not enough" true
    (Stdlib.Option.is_none (Decision_client.of_secrets ~model:Jev (secrets ~decisions:None ~openrouter:None)))

(* Decision features run by default on OpenRouter reviews and are opt-in for
   other providers; an explicit setting always wins. *)
let test_features_follow_the_review_provider () =
  let client ~openrouter ~decisions =
    Decision_client.of_secrets ~model:Gpt_6_luna
      {
        repos = [];
        anthropic_api_key = Some "sk-ant";
        openrouter_api_key = openrouter;
        openrouter_decisions_api_key = decisions;
        slack_access_token = None;
      }
  in
  let openrouter = client ~openrouter:(Some "sk-or") ~decisions:None in
  let anthropic = client ~openrouter:None ~decisions:(Some "sk-or-d") in
  let mode client setting = Config_types.decision_triage_mode_to_string (Decision_client.triage_mode client setting) in
  check bool "OpenRouter review: on by default" true (Decision_client.enabled openrouter None);
  check string "OpenRouter review: gate by default" "gate" (mode openrouter None);
  check bool "OpenRouter review: opt out" false (Decision_client.enabled openrouter (Some false));
  check string "OpenRouter review: triage opt out" "off" (mode openrouter (Some Off));
  check bool "Anthropic review: off by default" false (Decision_client.enabled anthropic None);
  check string "Anthropic review: triage off by default" "off" (mode anthropic None);
  check bool "Anthropic review: opt in" true (Decision_client.enabled anthropic (Some true));
  check string "Anthropic review: triage opt in" "route" (mode anthropic (Some Route));
  check bool "no key: off" false (Decision_client.enabled None None)

let test_refusal_is_not_retried () =
  check bool "refusal" true
    (Decision_client.refusal
       (Http_util.Status (502, {|{"error":{"message":"OpenAI refused to answer question \"xss\"","code":502}}|})));
  check bool "other 502 stays retryable" false
    (Decision_client.refusal (Http_util.Status (502, {|{"error":{"message":"Bad gateway"}}|})));
  check bool "refusal text on another status" false
    (Decision_client.refusal (Http_util.Status (400, "refused to answer")))

let test_client_thresholds_follow_model () =
  let client = Decision_client.create ~model:Gpt_6_luna ~api_key:"sk-or" () in
  check (float 0.0001) "Luna grouping" 0.30 (Decision_client.thresholds client).grouping

let test_validator_cascade_boundary () =
  let thresholds = Decision_model.thresholds Jev in
  check bool "confirmed" true
    (match Decision_model.cascade_decision thresholds ~supported:0.62 ~fatal_defect:0.30 with
    | Confirm_candidate -> true
    | Reject_candidate | Run_validator -> false);
  check bool "rejected" true
    (match Decision_model.cascade_decision thresholds ~supported:0.30 ~fatal_defect:0.70 with
    | Reject_candidate -> true
    | Confirm_candidate | Run_validator -> false);
  check bool "uncertain" true
    (match Decision_model.cascade_decision thresholds ~supported:0.61 ~fatal_defect:0.31 with
    | Run_validator -> true
    | Confirm_candidate | Reject_candidate -> false)

let test_luna_cascade_never_rejects () =
  let thresholds = Decision_model.thresholds Gpt_6_luna in
  let decide ~supported ~fatal_defect = Decision_model.cascade_decision thresholds ~supported ~fatal_defect in
  check bool "confirms at its measured boundary" true
    (match decide ~supported:0.50 ~fatal_defect:0.30 with
    | Confirm_candidate -> true
    | Reject_candidate | Run_validator -> false);
  check bool "demonstrated fatal defect still goes to the validator" true
    (match decide ~supported:0.0 ~fatal_defect:1.0 with
    | Run_validator -> true
    | Confirm_candidate | Reject_candidate -> false)

let test_source_constraint_boundary () =
  let thresholds = Decision_model.thresholds Jev in
  let rejects = Decision_model.source_constraint_rejects thresholds in
  check bool "rejects demonstrated constraint" true (rejects ~source_constrained:0.60 ~supported:0.30);
  check bool "keeps higher support" false (rejects ~source_constrained:0.60 ~supported:0.31);
  check bool "keeps weaker constraint" false (rejects ~source_constrained:0.59 ~supported:0.30)

let test_relationship_proposal_requires_both_orientations () =
  check bool "both pass" true (Decision_triage.relationship_proposed ~threshold:0.7 ~forward:0.72 ~reverse:0.75);
  check bool "one fails" false (Decision_triage.relationship_proposed ~threshold:0.7 ~forward:0.91 ~reverse:0.69)

let () =
  run "decision_triage"
    [
      ( "response",
        [
          test_case "routes probable classes" `Quick test_response_routes_only_probable_classes;
          test_case "preserves raw probabilities" `Quick test_score_context_response_contract;
          test_case "parses candidate validation" `Quick test_candidate_validation_response_contract;
          test_case "rejects unexpected answer types" `Quick test_unexpected_answer_type_is_an_error;
        ] );
      ( "client",
        [
          test_case "request wire format" `Quick test_request_body_wire_format;
          test_case "endpoint follows base URL" `Quick test_endpoint_follows_base_url;
          test_case "decisions key fallback" `Quick test_decisions_key_falls_back_to_openrouter_key;
          test_case "features follow the review provider" `Quick test_features_follow_the_review_provider;
          test_case "refusal is not retried" `Quick test_refusal_is_not_retried;
          test_case "thresholds follow the model" `Quick test_client_thresholds_follow_model;
        ] );
      ( "rules",
        [
          test_case "candidate cascade boundary" `Quick test_validator_cascade_boundary;
          test_case "Luna cascade never rejects" `Quick test_luna_cascade_never_rejects;
          test_case "source constraint boundary" `Quick test_source_constraint_boundary;
          test_case "relationship proposal requires both orientations" `Quick
            test_relationship_proposal_requires_both_orientations;
        ] );
    ]
