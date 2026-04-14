open Devkit
open Reviewotron_lib
open Alcotest

let read_file path = Std.input_file ~bin:true path

let test_parse_pr_opened () =
  let body = read_file "mock_payloads/pr_opened.json" in
  match Github.parse_event ~event_type:"pull_request" ~body with
  | Ok (Github.Pull_request n) ->
    (check string) "action" "opened" n.action;
    (check int) "pr number" 42 n.pull_request.number;
    (check string) "title" "Add feature X to the dashboard" n.pull_request.title;
    (check string) "repo" "org/monorepo" n.repository.full_name;
    (check string) "sender" "developer1" n.sender.login
  | Ok _ -> fail "expected Pull_request event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let test_parse_push_develop () =
  let body = read_file "mock_payloads/push_develop.json" in
  match Github.parse_event ~event_type:"push" ~body with
  | Ok (Github.Push n) ->
    (check string) "ref" "refs/heads/develop" n.ref_;
    (check int) "commit count" 2 (List.length n.commits);
    (check string) "repo" "org/monorepo" n.repository.full_name;
    (check string) "pusher" "developer2" n.pusher.name
  | Ok _ -> fail "expected Push event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let test_parse_unknown_event () =
  let body = "{}" in
  match Github.parse_event ~event_type:"deployment" ~body with
  | Ok (Github.Unknown "deployment") -> ()
  | Ok _ -> fail "expected Unknown event"
  | Error msg -> fail (Printf.sprintf "unexpected error: %s" msg)

let test_hmac_signature_valid () =
  let secret = "test-secret" in
  let body = "test-body" in
  let expected = Digestif.SHA256.(hmac_string ~key:secret body |> to_hex) in
  let signature = "sha256=" ^ expected in
  match Github.validate_signature ~secret ~signature ~body with
  | Ok () -> ()
  | Error msg -> fail (Printf.sprintf "expected valid signature: %s" msg)

let test_hmac_signature_invalid () =
  let secret = "test-secret" in
  let body = "test-body" in
  let signature = "sha256=0000000000000000000000000000000000000000000000000000000000000000" in
  match Github.validate_signature ~secret ~signature ~body with
  | Ok () -> fail "expected signature mismatch"
  | Error _ -> ()

let test_config_defaults () =
  let json =
    {|{
    "repos": [{"url": "https://github.com/org/repo", "gh_token": "tok"}],
    "anthropic_api_key": "sk-test"
  }|}
  in
  let secrets = Config_types.secrets_of_json (Melange_json.of_string json) in
  (check string) "api key" "sk-test" secrets.anthropic_api_key;
  (check string) "version default" "2023-06-01" secrets.anthropic_version;
  (check int) "repo count" 1 (List.length secrets.repos)

(** {2 Review prompt tests} *)

let test_system_prompt_default () =
  let prompt = Review_prompt.system_prompt () in
  (check bool) "non-empty" true (String.length prompt > 0);
  (check bool) "contains focus" true (CCString.find ~sub:"Focus on:" prompt >= 0)

let test_system_prompt_override () =
  let custom = "You are a custom reviewer" in
  let prompt = Review_prompt.system_prompt ~override:custom () in
  (check string) "override used" custom prompt

let test_build_user_message () =
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let msg = Review_prompt.build_user_message ~diff ~pr_title:"Test PR" ~pr_description:"A test" () in
  (check bool) "has title" true (CCString.find ~sub:"## Pull Request: Test PR" msg >= 0);
  (check bool) "has diff" true (CCString.find ~sub:"## Diff" msg >= 0);
  (check bool) "has diff content" true (CCString.find ~sub:"let x = 1" msg >= 0)

let test_build_user_message_no_description () =
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let msg = Review_prompt.build_user_message ~diff ~pr_title:"Test PR" () in
  (check bool) "has title" true (CCString.find ~sub:"## Pull Request: Test PR" msg >= 0);
  (check bool) "has diff" true (CCString.find ~sub:"## Diff" msg >= 0)

let test_review_schema_valid () =
  let schema = Review_prompt.review_schema in
  let json_str = Yojson.Safe.to_string schema in
  (check bool) "has type" true (CCString.find ~sub:{|"type":"object"|} json_str >= 0);
  (check bool) "has properties" true (CCString.find ~sub:{|"properties"|} json_str >= 0);
  (check bool) "has required" true (CCString.find ~sub:{|"required"|} json_str >= 0);
  (check bool) "has summary" true (CCString.find ~sub:{|"summary"|} json_str >= 0);
  (check bool) "has findings" true (CCString.find ~sub:{|"findings"|} json_str >= 0)

let test_prompt_token_estimation () =
  let system = Review_prompt.system_prompt () in
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let user = Review_prompt.build_user_message ~diff ~pr_title:"Test" () in
  let estimate = Review_prompt.estimate_prompt_tokens ~system ~user in
  let char_count = String.length system + String.length user in
  (* Estimate should be roughly chars/4, within 2x *)
  (check bool) "estimate > 0" true (estimate > 0);
  (check bool) "estimate within 2x of chars/4" true (estimate <= char_count / 2);
  (check bool) "estimate at least chars/8" true (estimate >= char_count / 8)

(** {2 Review types tests} *)

let test_review_output_roundtrip () =
  let review : Review_types.review_output =
    {
      summary = "Looks good";
      findings =
        [
          {
            path = "src/main.ml";
            line = Some 42;
            end_line = None;
            severity = Warning;
            category = Error_handling;
            message = "Missing error handling";
            suggested_fix = Some "add try/with";
          };
        ];
      overall_assessment = "Solid code";
    }
  in
  let json_str = Melange_json.to_string (Review_types.review_output_to_json review) in
  let parsed = Review_types.review_output_of_json (Melange_json.of_string json_str) in
  (check string) "summary" review.summary parsed.summary;
  (check int) "findings count" 1 (List.length parsed.findings);
  let f = List.hd parsed.findings in
  (check string) "finding path" "src/main.ml" f.path;
  (check (option int)) "finding line" (Some 42) f.line

let test_mock_claude_response () =
  let json_str = read_file "mock_api_responses/claude/review_response.json" in
  let review = Review_types.review_output_of_json (Melange_json.of_string json_str) in
  (check int) "findings count" 3 (List.length review.findings);
  (check bool) "has summary" true (String.length review.summary > 0);
  (check bool) "has assessment" true (String.length review.overall_assessment > 0)

(** {2 End-to-end reviewer tests} *)

module R_test = Reviewer.Make (Api_local.Github) (Api_local.Claude) (Api_local.Slack)

let test_pr_review_e2e () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "correct repo" true (CCString.find ~sub:"repo=https://github.com/org/monorepo" write_log >= 0);
  (check bool) "correct PR number" true (CCString.find ~sub:"number=42" write_log >= 0);
  (check bool) "has summary" true (CCString.find ~sub:"The changes look generally good" write_log >= 0);
  (check bool) "has comments" true (CCString.find ~sub:"error-handling" write_log >= 0)

let test_pr_skipped_when_draft () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.make_pr_payload ~draft:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no review posted" "" write_log

let test_pr_skipped_when_closed () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.make_pr_payload ~action:"closed" () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no review posted" "" write_log

(** {2 PR edge case tests} *)

let test_pr_synchronize_review () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let payload = Stre.replace_all ~str:payload ~sub:{|"action": "opened"|} ~by:{|"action": "synchronize"|} in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted on synchronize" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0)

let test_pr_all_ignored_paths_skipped () =
  Test_helpers.reset_test_state ();
  let config = Config_types.config_of_json (Melange_json.of_string {|{"ignored_paths": ["*.lock", "*.json"]}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  (* Use PR 99 which only has .lock and .json files *)
  let payload = Test_helpers.make_pr_payload ~number:99 ~title:"Update lock files" () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "all ignored paths skipped" "" write_log

let test_pr_empty_findings_review () =
  Test_helpers.reset_test_state ();
  Api_local.set_claude_response_path "mock_api_responses/claude/empty_findings_response.json";
  let ctx = Test_helpers.make_test_context () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* Review should still be posted with summary only *)
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has summary" true (CCString.find ~sub:"The code looks clean" write_log >= 0);
  (* No inline comments since findings list is empty — ATD omits empty default *)
  (check bool) "no inline comments" true (CCString.find ~sub:{|"comments":|} write_log < 0)

let test_pr_large_diff_skipped () =
  Test_helpers.reset_test_state ();
  (* Set max_diff_lines very low so the normal PR 42 diff exceeds it *)
  let config = Config_types.config_of_json (Melange_json.of_string {|{"max_diff_lines": 1}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "large PR skipped" "" write_log

(** {2 Push review tests} *)

let test_push_review_e2e () =
  Test_helpers.reset_test_state ();
  Api_local.set_claude_response_path "mock_api_responses/claude/push_review_response.json";
  let config = Config_types.config_of_json (Melange_json.of_string {|{"slack_channel": "dev-reviews"}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "commit comment posted" true (CCString.find ~sub:"[create_commit_comment]" write_log >= 0);
  (check bool) "comment on correct sha" true
    (CCString.find ~sub:"sha=e2173f38ae43865433a182c1fc1b5442d9763b54" write_log >= 0);
  (check bool) "security finding posted" true (CCString.find ~sub:"security" write_log >= 0);
  (check bool) "slack message sent" true (CCString.find ~sub:"[slack]" write_log >= 0);
  (check bool) "slack mentions develop" true (CCString.find ~sub:"develop" write_log >= 0);
  let slack_msgs = Api_local.get_slack_messages () in
  (check int) "one slack message" 1 (List.length slack_msgs)

let test_push_skipped_non_develop () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.make_push_payload ~ref_:"refs/heads/main" () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no actions" "" write_log

(** {2 Push edge case tests} *)

let test_push_created_skipped () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.make_push_payload ~created:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "new branch push skipped" "" write_log

let test_push_deleted_skipped () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.make_push_payload ~deleted:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "branch deletion push skipped" "" write_log

(** {2 Duplicate prevention tests} *)

let test_duplicate_pr_prevention () =
  Test_helpers.reset_test_state ();
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  (* First review should go through *)
  Lwt_main.run (R_test.process_event ctx ~event);
  let first_log = Api_local.get_write_log () in
  (check bool) "first review posted" true (CCString.find ~sub:"[create_pr_review]" first_log >= 0);
  (* Second review with same SHA should be skipped *)
  Api_local.clear_write_log ();
  Lwt_main.run (R_test.process_event ctx ~event);
  let second_log = Api_local.get_write_log () in
  (check string) "second review skipped" "" second_log

let test_duplicate_push_prevention () =
  Test_helpers.reset_test_state ();
  Api_local.set_claude_response_path "mock_api_responses/claude/push_review_response.json";
  let state = State.create () in
  let config = Config_types.config_of_json (Melange_json.of_string {|{"slack_channel": "dev-reviews"}|}) in
  let ctx = Test_helpers.make_test_context ~state ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  (* First push review should go through *)
  Lwt_main.run (R_test.process_event ctx ~event);
  let first_log = Api_local.get_write_log () in
  (check bool) "first push reviewed" true (CCString.find ~sub:"[create_commit_comment]" first_log >= 0);
  (* Second push with same SHA should be skipped *)
  Api_local.clear_write_log ();
  Api_local.clear_slack_messages ();
  Lwt_main.run (R_test.process_event ctx ~event);
  let second_log = Api_local.get_write_log () in
  (check string) "second push skipped" "" second_log

(** {2 Ignored author tests} *)

let test_ignored_author_pr_skipped () =
  Test_helpers.reset_test_state ();
  let config = Config_types.config_of_json (Melange_json.of_string {|{"ignored_authors": ["developer1"]}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "ignored author skipped" "" write_log

let test_ignored_author_push_skipped () =
  Test_helpers.reset_test_state ();
  let config = Config_types.config_of_json (Melange_json.of_string {|{"ignored_authors": ["developer2"]}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "ignored author push skipped" "" write_log

(** {2 State persistence tests} *)

let test_state_save_load_roundtrip () =
  let tmp_path = Filename.temp_file "reviewotron_state_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      let state = State.create ~filepath:tmp_path () in
      let repo = "https://github.com/test/repo" in
      State.record_pr_review state ~repo_url:repo ~pr_number:1 ~head_sha:"abc123";
      State.record_push_review state ~repo_url:repo ~after_sha:"def456";
      State.save state;
      let loaded = State.load ~filepath:tmp_path in
      (check bool) "pr review found" true (State.is_pr_reviewed loaded ~repo_url:repo ~pr_number:1 ~head_sha:"abc123");
      (check bool) "pr review different sha not found" false
        (State.is_pr_reviewed loaded ~repo_url:repo ~pr_number:1 ~head_sha:"xyz789");
      (check bool) "push review found" true (State.is_push_reviewed loaded ~repo_url:repo ~after_sha:"def456");
      (check bool) "push review different sha not found" false
        (State.is_push_reviewed loaded ~repo_url:repo ~after_sha:"zzz999"))

let test_state_empty_load () =
  let tmp_path = Filename.temp_file "reviewotron_state_" ".json" in
  Sys.remove tmp_path;
  let loaded = State.load ~filepath:tmp_path in
  (check bool) "no pr reviewed" false (State.is_pr_reviewed loaded ~repo_url:"x" ~pr_number:1 ~head_sha:"abc")

let () =
  run "reviewotron"
    [
      ( "github_parsing",
        [
          test_case "parse pr_opened" `Quick test_parse_pr_opened;
          test_case "parse push_develop" `Quick test_parse_push_develop;
          test_case "parse unknown event" `Quick test_parse_unknown_event;
        ] );
      ( "hmac_signature",
        [
          test_case "valid signature" `Quick test_hmac_signature_valid;
          test_case "invalid signature" `Quick test_hmac_signature_invalid;
        ] );
      "config", [ test_case "config defaults" `Quick test_config_defaults ];
      ( "review_prompt",
        [
          test_case "default system prompt" `Quick test_system_prompt_default;
          test_case "system prompt override" `Quick test_system_prompt_override;
          test_case "build user message" `Quick test_build_user_message;
          test_case "build user message no description" `Quick test_build_user_message_no_description;
          test_case "review schema valid" `Quick test_review_schema_valid;
          test_case "prompt token estimation" `Quick test_prompt_token_estimation;
        ] );
      ( "review_types",
        [
          test_case "review output roundtrip" `Quick test_review_output_roundtrip;
          test_case "mock claude response" `Quick test_mock_claude_response;
        ] );
      ( "reviewer_e2e",
        [
          test_case "PR review end-to-end" `Quick test_pr_review_e2e;
          test_case "draft PR skipped" `Quick test_pr_skipped_when_draft;
          test_case "closed PR skipped" `Quick test_pr_skipped_when_closed;
        ] );
      ( "pr_edge_cases",
        [
          test_case "PR synchronize triggers review" `Quick test_pr_synchronize_review;
          test_case "PR with all ignored paths skipped" `Quick test_pr_all_ignored_paths_skipped;
          test_case "PR with empty findings posts summary" `Quick test_pr_empty_findings_review;
          test_case "large PR over max_diff_lines skipped" `Quick test_pr_large_diff_skipped;
        ] );
      ( "push_review",
        [
          test_case "push review end-to-end" `Quick test_push_review_e2e;
          test_case "push to non-develop skipped" `Quick test_push_skipped_non_develop;
        ] );
      ( "push_edge_cases",
        [
          test_case "push with created=true skipped" `Quick test_push_created_skipped;
          test_case "push with deleted=true skipped" `Quick test_push_deleted_skipped;
        ] );
      ( "duplicate_prevention",
        [
          test_case "duplicate PR prevention" `Quick test_duplicate_pr_prevention;
          test_case "duplicate push prevention" `Quick test_duplicate_push_prevention;
        ] );
      ( "ignored_authors",
        [
          test_case "ignored author PR skipped" `Quick test_ignored_author_pr_skipped;
          test_case "ignored author push skipped" `Quick test_ignored_author_push_skipped;
        ] );
      ( "state_persistence",
        [
          test_case "save/load roundtrip" `Quick test_state_save_load_roundtrip;
          test_case "load from non-existent file" `Quick test_state_empty_load;
        ] );
    ]
