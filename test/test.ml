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
  (check int) "repo count" 1 (List.length secrets.repos)

let test_config_ignores_removed_fields () =
  let json =
    {|{
    "repos": [{"url": "https://github.com/org/repo", "gh_token": "tok"}],
    "anthropic_api_key": "sk-test",
    "anthropic_version": "2023-06-01"
  }|}
  in
  let secrets = Config_types.secrets_of_json (Melange_json.of_string json) in
  (check string) "api key" "sk-test" secrets.anthropic_api_key;
  (check int) "repo count" 1 (List.length secrets.repos)

let test_config_review_plugins_defaults () =
  let config = Config_types.config_of_json (Melange_json.of_string {|{}|}) in
  (check bool) "general enabled" true config.review_plugins.general.enabled;
  (check bool) "general prompt override" true (Option.is_none config.review_plugins.general.system_prompt_override);
  (check bool) "security enabled" true config.review_plugins.security.enabled;
  (check int) "vuln_classes count" 6 (List.length config.review_plugins.security.vuln_classes);
  (check int) "memory_max_tokens" 5000 config.review_plugins.security.memory_max_tokens;
  (check bool) "show_review_cost" false config.show_review_cost

let test_config_review_plugins_explicit () =
  let json =
    {|{
    "show_review_cost": true,
    "review_plugins": {
      "general": { "enabled": false },
      "security": {
        "enabled": true,
        "vuln_classes": ["injection", "xss"],
        "triage_model_tier": "standard",
        "confidence_threshold": "high",
        "memory_max_tokens": 10000
      }
    }
  }|}
  in
  let config = Config_types.config_of_json (Melange_json.of_string json) in
  (check bool) "show_review_cost" true config.show_review_cost;
  (check bool) "general disabled" false config.review_plugins.general.enabled;
  (check bool) "security enabled" true config.review_plugins.security.enabled;
  (check int) "vuln_classes count" 2 (List.length config.review_plugins.security.vuln_classes);
  (check int) "memory_max_tokens" 10000 config.review_plugins.security.memory_max_tokens

let test_vuln_class_roundtrip () =
  List.iter
    (fun vc ->
      let json = Config_types.vuln_class_to_json vc in
      let parsed = Config_types.vuln_class_of_json json in
      (check string) "roundtrip" (Config_types.vuln_class_to_string vc) (Config_types.vuln_class_to_string parsed))
    Config_types.all_vuln_classes

let test_security_plugin_config_roundtrip () =
  let cfg : Config_types.security_plugin_config =
    {
      enabled = true;
      vuln_classes = [ Injection; Xss ];
      triage_model_tier = Fast;
      analysis_model_tier = Standard;
      validator_model_tier = Strong;
      confidence_threshold = High;
      memory_max_tokens = 3000;
    }
  in
  let json = Config_types.security_plugin_config_to_json cfg in
  let parsed = Config_types.security_plugin_config_of_json json in
  (check bool) "enabled" true parsed.enabled;
  (check int) "vuln_classes" 2 (List.length parsed.vuln_classes);
  (check int) "memory_max_tokens" 3000 parsed.memory_max_tokens;
  (check string) "confidence" "high" (Config_types.confidence_to_string parsed.confidence_threshold);
  (check string) "validator tier" "strong" (Config_types.model_tier_to_string parsed.validator_model_tier)

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

(** {2 Security types tests} *)

let roundtrip to_json of_json v =
  let json_str = Melange_json.to_string (to_json v) in
  of_json (Melange_json.of_string json_str)

let test_security_triage_output_roundtrip () =
  let open Security_types in
  let triage : triage_output =
    {
      signals =
        [
          {
            vuln_class = Injection;
            confidence = High;
            regions = [ { path = "lib/db.ml"; start_line = 10; end_line = 20 } ];
            rationale = "SQL string concatenation detected";
          };
          {
            vuln_class = Xss;
            confidence = Medium;
            regions = [ { path = "lib/view.ml"; start_line = 5; end_line = 8 } ];
            rationale = "Unescaped output in template";
          };
        ];
      language_hints = [ "ocaml"; "javascript" ];
      skip_reason = None;
    }
  in
  let parsed = roundtrip triage_output_to_json triage_output_of_json triage in
  (check int) "signals count" 2 (List.length parsed.signals);
  (match parsed.signals with
  | s :: _ ->
    (check string) "vuln_class" "injection" (vuln_class_to_string s.vuln_class);
    (check string) "confidence" "high" (confidence_to_string s.confidence);
    (check int) "regions count" 1 (List.length s.regions)
  | [] -> fail "expected at least one signal");
  (check (option string)) "skip_reason" None parsed.skip_reason;
  (check int) "language_hints" 2 (List.length parsed.language_hints)

let test_security_triage_output_with_skip () =
  let open Security_types in
  let triage : triage_output = { signals = []; language_hints = []; skip_reason = Some "no code changes" } in
  let parsed = roundtrip triage_output_to_json triage_output_of_json triage in
  (check (option string)) "skip_reason" (Some "no code changes") parsed.skip_reason;
  (check int) "signals empty" 0 (List.length parsed.signals)

let test_security_candidate_finding_roundtrip () =
  let open Security_types in
  let finding : candidate_finding =
    {
      vuln_class = Command_injection;
      source = { path = "lib/handler.ml"; line = 15; description = "HTTP query parameter cmd" };
      sink = { path = "lib/exec.ml"; line = 42; description = "Unix.system call" };
      flow =
        [
          { path = "lib/handler.ml"; line = 16; description = "Passed to process_command" };
          { path = "lib/exec.ml"; line = 40; description = "Received as cmd argument" };
        ];
      sanitization = Missing;
      confidence = High;
      description = "User input flows to shell execution without sanitization";
      suggested_fix = Some "Use Filename.quote or switch to execvp";
    }
  in
  let parsed = roundtrip candidate_finding_to_json candidate_finding_of_json finding in
  (check string) "vuln_class" "command_injection" (vuln_class_to_string parsed.vuln_class);
  (check string) "source path" "lib/handler.ml" parsed.source.path;
  (check int) "source line" 15 parsed.source.line;
  (check string) "sink path" "lib/exec.ml" parsed.sink.path;
  (check int) "flow steps" 2 (List.length parsed.flow);
  (check (option string)) "suggested_fix" (Some "Use Filename.quote or switch to execvp") parsed.suggested_fix

let test_security_sanitization_status_roundtrip () =
  let open Security_types in
  let cases =
    [
      Adequate, {|["Adequate"]|};
      Inadequate "encoding not context-aware", {|["Inadequate","encoding not context-aware"]|};
      Missing, {|["Missing"]|};
      Unknown, {|["Unknown"]|};
    ]
  in
  List.iter
    (fun (status, expected_json) ->
      let json_str = Melange_json.to_string (sanitization_status_to_json status) in
      (check string) ("sanitization_status json " ^ expected_json) expected_json json_str;
      let parsed = sanitization_status_of_json (Melange_json.of_string json_str) in
      let re_json = Melange_json.to_string (sanitization_status_to_json parsed) in
      (check string) ("sanitization_status roundtrip " ^ expected_json) json_str re_json)
    cases

let test_security_validation_verdict_roundtrip () =
  let open Security_types in
  let cases =
    [
      Confirmed, {|["Confirmed"]|};
      Rejected "source is not user-controllable", {|["Rejected","source is not user-controllable"]|};
    ]
  in
  List.iter
    (fun (verdict, expected_json) ->
      let json_str = Melange_json.to_string (validation_verdict_to_json verdict) in
      (check string) ("verdict json " ^ expected_json) expected_json json_str;
      let parsed = validation_verdict_of_json (Melange_json.of_string json_str) in
      let re_json = Melange_json.to_string (validation_verdict_to_json parsed) in
      (check string) ("verdict roundtrip " ^ expected_json) json_str re_json)
    cases

let test_security_validator_output_roundtrip () =
  let open Security_types in
  let output : validator_output =
    {
      results =
        [
          {
            finding =
              {
                vuln_class = Ssrf;
                source = { path = "lib/api.ml"; line = 10; description = "URL from user input" };
                sink = { path = "lib/http.ml"; line = 30; description = "HTTP GET request" };
                flow = [ { path = "lib/api.ml"; line = 12; description = "Passed to fetch_url" } ];
                sanitization = Inadequate "URL validation missing scheme check";
                confidence = Medium;
                description = "User-controlled URL used in server-side request";
                suggested_fix = None;
              };
            verdict = Confirmed;
            evidence_notes = "Verified: URL constructed from query param without scheme validation";
          };
        ];
    }
  in
  let parsed = roundtrip validator_output_to_json validator_output_of_json output in
  (check int) "results count" 1 (List.length parsed.results);
  match parsed.results with
  | r :: _ ->
    (check string) "finding vuln_class" "ssrf" (vuln_class_to_string r.finding.vuln_class);
    (check (option string)) "suggested_fix" None r.finding.suggested_fix
  | [] -> fail "expected at least one result"

let test_security_triage_output_extra_fields () =
  let json_str = {|{"signals":[],"language_hints":[],"skip_reason":null,"extra_field":"ignored","another":123}|} in
  let parsed = Security_types.triage_output_of_json (Melange_json.of_string json_str) in
  (check int) "signals empty" 0 (List.length parsed.signals)

(** {2 Security tools tests} *)

let test_security_tools_params_roundtrip () =
  let open Security_tools in
  let params : get_file_content_params = { path = "lib/auth.ml" } in
  let parsed = roundtrip get_file_content_params_to_json get_file_content_params_of_json params in
  (check string) "path" "lib/auth.ml" parsed.path

let test_security_tools_result_with_content () =
  let open Security_tools in
  let result : get_file_content_result = { content = Some "let x = 42"; error = None } in
  let parsed = roundtrip get_file_content_result_to_json get_file_content_result_of_json result in
  (check (option string)) "content" (Some "let x = 42") parsed.content;
  (check (option string)) "error" None parsed.error

let test_security_tools_result_with_error () =
  let open Security_tools in
  let result : get_file_content_result = { content = None; error = Some "File not found: foo.ml" } in
  let parsed = roundtrip get_file_content_result_to_json get_file_content_result_of_json result in
  (check (option string)) "content" None parsed.content;
  (check (option string)) "error" (Some "File not found: foo.ml") parsed.error

let test_security_tools_result_empty () =
  let open Security_tools in
  let result : get_file_content_result = { content = None; error = None } in
  let parsed = roundtrip get_file_content_result_to_json get_file_content_result_of_json result in
  (check (option string)) "content" None parsed.content;
  (check (option string)) "error" None parsed.error

let test_security_tools_result_missing_fields () =
  let json_str = "{}" in
  let parsed = Security_tools.get_file_content_result_of_json (Melange_json.of_string json_str) in
  (check (option string)) "content" None parsed.content;
  (check (option string)) "error" None parsed.error

let test_security_tools_execute_success () =
  let fetch_file _path = Lwt.return (Ok (Some "file content here")) in
  let _name, tool = Security_tools.make_get_file_content ~fetch_file in
  let args = `Assoc [ "path", `String "lib/auth.ml" ] in
  let execute = CCOption.get_exn_or __LOC__ tool.execute in
  let result_json = Lwt_main.run (execute args) in
  let result = Security_tools.get_file_content_result_of_json result_json in
  (check (option string)) "content" (Some "file content here") result.content;
  (check (option string)) "error" None result.error

let test_security_tools_execute_not_found () =
  let fetch_file _path = Lwt.return (Ok None) in
  let _name, tool = Security_tools.make_get_file_content ~fetch_file in
  let args = `Assoc [ "path", `String "nonexistent.ml" ] in
  let execute = CCOption.get_exn_or __LOC__ tool.execute in
  let result_json = Lwt_main.run (execute args) in
  let result = Security_tools.get_file_content_result_of_json result_json in
  (check (option string)) "content" None result.content;
  (check bool) "has error" true (Option.is_some result.error)

let test_security_tools_execute_api_error () =
  let fetch_file _path = Lwt.return (Error "rate limited") in
  let _name, tool = Security_tools.make_get_file_content ~fetch_file in
  let args = `Assoc [ "path", `String "lib/db.ml" ] in
  let execute = CCOption.get_exn_or __LOC__ tool.execute in
  let result_json = Lwt_main.run (execute args) in
  let result = Security_tools.get_file_content_result_of_json result_json in
  (check (option string)) "content" None result.content;
  (check (option string)) "error" (Some "rate limited") result.error

let test_security_tools_execute_invalid_params () =
  let fetch_file _path = Lwt.return (Ok (Some "should not reach")) in
  let _name, tool = Security_tools.make_get_file_content ~fetch_file in
  let args = `Assoc [ "wrong_key", `Int 42 ] in
  let execute = CCOption.get_exn_or __LOC__ tool.execute in
  let result_json = Lwt_main.run (execute args) in
  let result = Security_tools.get_file_content_result_of_json result_json in
  (check (option string)) "content" None result.content;
  (check bool) "has error" true (Option.is_some result.error)

let test_security_tools_tool_name () =
  let fetch_file _path = Lwt.return (Ok None) in
  let name, _tool = Security_tools.make_get_file_content ~fetch_file in
  (check string) "tool name" "get_file_content" name

(** {2 Triage agent tests} *)

let test_triage_agent_config () =
  let cfg = Triage_agent.config ~model_tier:Fast in
  (check string) "name" "security_triage" cfg.name;
  (check int) "max_steps" 1 cfg.max_steps;
  (check bool) "has system prompt" true (String.length cfg.system_prompt > 0);
  (check bool) "has output schema" true
    (match cfg.output_schema with
    | `Assoc _ -> true
    | _ -> false)

let test_triage_agent_config_model_tier () =
  let fast = Triage_agent.config ~model_tier:Fast in
  let standard = Triage_agent.config ~model_tier:Standard in
  let strong = Triage_agent.config ~model_tier:Strong in
  (check bool) "fast tier" true
    (match fast.model_tier with
    | Fast -> true
    | Standard | Strong -> false);
  (check bool) "standard tier" true
    (match standard.model_tier with
    | Standard -> true
    | Fast | Strong -> false);
  (check bool) "strong tier" true
    (match strong.model_tier with
    | Strong -> true
    | Fast | Standard -> false)

let test_triage_agent_detect_languages () =
  let langs =
    Triage_agent.detect_languages
      [ "lib/auth.ml"; "lib/auth.mli"; "src/app.tsx"; "src/utils.ts"; "scripts/deploy.sh"; "README.md" ]
  in
  (check (list string)) "detected" [ "OCaml"; "Shell"; "TSX"; "TypeScript" ] langs

let test_triage_agent_detect_languages_empty () =
  let langs = Triage_agent.detect_languages [] in
  (check (list string)) "empty" [] langs

let test_triage_agent_detect_languages_unknown () =
  let langs = Triage_agent.detect_languages [ "Makefile"; "README"; ".gitignore"; "data.parquet" ] in
  (check (list string)) "unknown only" [] langs

let test_triage_agent_build_input_minimal () =
  let input = Triage_agent.build_input ~diff_text:"diff content" ~file_paths:[ "lib/foo.ml" ] () in
  (check bool) "contains diff" true (Devkit.Stre.exists input "diff content");
  (check bool) "contains file path" true (Devkit.Stre.exists input "lib/foo.ml");
  (check bool) "contains OCaml hint" true (Devkit.Stre.exists input "OCaml");
  (check bool) "no security memory section" false (Devkit.Stre.exists input "Repository Security Context")

let test_triage_agent_build_input_with_memory () =
  let input =
    Triage_agent.build_input ~diff_text:"diff content" ~file_paths:[ "lib/foo.ml" ]
      ~security_memory:"Known safe: Db.query uses parameterized queries" ()
  in
  (check bool) "contains memory" true (Devkit.Stre.exists input "Known safe: Db.query uses parameterized queries");
  (check bool) "has security memory section" true (Devkit.Stre.exists input "Repository Security Context")

let test_triage_agent_build_input_empty_memory () =
  let input = Triage_agent.build_input ~diff_text:"diff content" ~file_paths:[ "lib/foo.ml" ] ~security_memory:"" () in
  (check bool) "no security memory section for empty" false (Devkit.Stre.exists input "Repository Security Context")

let test_triage_agent_output_schema_valid () =
  let cfg = Triage_agent.config ~model_tier:Fast in
  let schema = cfg.output_schema in
  (check bool) "schema has type" true
    (match schema with
    | `Assoc fields -> List.exists (fun (k, _) -> String.equal k "type") fields
    | _ -> false);
  (check bool) "schema has properties" true
    (match schema with
    | `Assoc fields -> List.exists (fun (k, _) -> String.equal k "properties") fields
    | _ -> false)

(** {2 Security review plugin tests} *)

let make_triage_signal ~vuln_class ~confidence =
  Security_types.
    {
      vuln_class;
      confidence;
      regions = [ { path = "test.ml"; start_line = 1; end_line = 10 } ];
      rationale = "test signal";
    }

let test_security_confidence_rank () =
  let open Security_review_plugin in
  (check bool) "High > Medium" true (confidence_rank Config_types.High > confidence_rank Medium);
  (check bool) "Medium > Low" true (confidence_rank Medium > confidence_rank Low);
  (check bool) "High > Low" true (confidence_rank High > confidence_rank Low)

let test_security_vuln_class_equal () =
  let open Security_review_plugin in
  (check bool) "same class" true (vuln_class_equal Config_types.Injection Injection);
  (check bool) "different class" false (vuln_class_equal Injection Xss);
  (check bool) "all classes equal themselves" true
    (List.for_all
       (fun vc -> vuln_class_equal vc vc)
       Config_types.[ Injection; Xss; Command_injection; Authn; Authz; Ssrf ])

let test_security_should_analyze_above_threshold () =
  let security_config = Config_types.default_security_plugin_config in
  (* Default threshold is Medium. High and Medium should always trigger. *)
  let high_signal = make_triage_signal ~vuln_class:Injection ~confidence:High in
  let medium_signal = make_triage_signal ~vuln_class:Xss ~confidence:Medium in
  (check bool) "High >= Medium threshold" true (Security_review_plugin.should_analyze ~security_config high_signal);
  (check bool) "Medium >= Medium threshold" true (Security_review_plugin.should_analyze ~security_config medium_signal)

let test_security_should_analyze_below_threshold_in_config () =
  let security_config = Config_types.default_security_plugin_config in
  (* Default config has all vuln_classes. Low signal for a configured class should trigger. *)
  let low_signal = make_triage_signal ~vuln_class:Injection ~confidence:Low in
  (check bool) "Low in vuln_classes" true (Security_review_plugin.should_analyze ~security_config low_signal)

let test_security_should_analyze_below_threshold_not_in_config () =
  let security_config = { Config_types.default_security_plugin_config with vuln_classes = [ Xss; Ssrf ] } in
  (* Low confidence for a class NOT in the restricted list should not trigger. *)
  let low_injection = make_triage_signal ~vuln_class:Injection ~confidence:Low in
  (check bool) "Low not in vuln_classes" false (Security_review_plugin.should_analyze ~security_config low_injection);
  (* But Low for a class that IS in the list should still trigger. *)
  let low_xss = make_triage_signal ~vuln_class:Xss ~confidence:Low in
  (check bool) "Low in vuln_classes" true (Security_review_plugin.should_analyze ~security_config low_xss)

let test_security_should_analyze_high_threshold () =
  let security_config = { Config_types.default_security_plugin_config with confidence_threshold = High } in
  (* With High threshold, only High triggers unconditionally. *)
  let high_signal = make_triage_signal ~vuln_class:Injection ~confidence:High in
  let medium_signal = make_triage_signal ~vuln_class:Injection ~confidence:Medium in
  (check bool) "High >= High threshold" true (Security_review_plugin.should_analyze ~security_config high_signal);
  (* Medium is below High threshold but Injection is in default vuln_classes. *)
  (check bool) "Medium < High, but in vuln_classes" true
    (Security_review_plugin.should_analyze ~security_config medium_signal)

let test_security_should_analyze_high_threshold_restricted () =
  let security_config =
    { Config_types.default_security_plugin_config with confidence_threshold = High; vuln_classes = [ Xss ] }
  in
  (* Medium confidence for Injection (not in vuln_classes) should not trigger. *)
  let medium_injection = make_triage_signal ~vuln_class:Injection ~confidence:Medium in
  (check bool) "Medium < High, not in vuln_classes" false
    (Security_review_plugin.should_analyze ~security_config medium_injection);
  (* High confidence always triggers regardless of vuln_classes. *)
  let high_injection = make_triage_signal ~vuln_class:Injection ~confidence:High in
  (check bool) "High >= High threshold, even if not in vuln_classes" true
    (Security_review_plugin.should_analyze ~security_config high_injection)

let test_security_should_analyze_low_threshold () =
  let security_config = { Config_types.default_security_plugin_config with confidence_threshold = Low } in
  (* With Low threshold, everything triggers unconditionally. *)
  let low_signal = make_triage_signal ~vuln_class:Injection ~confidence:Low in
  (check bool) "Low >= Low threshold" true (Security_review_plugin.should_analyze ~security_config low_signal)

let test_security_agent_model_tier () =
  let open Security_review_plugin in
  (check bool) "Fast maps correctly" true
    (match agent_model_tier Config_types.Fast with
    | Agent_runner.Fast -> true
    | Standard | Strong -> false);
  (check bool) "Standard maps correctly" true
    (match agent_model_tier Standard with
    | Standard -> true
    | Fast | Strong -> false);
  (check bool) "Strong maps correctly" true
    (match agent_model_tier Strong with
    | Strong -> true
    | Fast | Standard -> false)

(** {2 End-to-end reviewer tests} *)

module R_test = Reviewer.Make (Api_local.Github) (Api_local.Agent_runner) (Api_local.Slack)

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
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
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
  Api_local.set_agent_response_path "mock_api_responses/claude/push_review_response.json";
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
  Api_local.set_agent_response_path "mock_api_responses/claude/push_review_response.json";
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
      ( "config",
        [
          test_case "config defaults" `Quick test_config_defaults;
          test_case "config ignores removed fields" `Quick test_config_ignores_removed_fields;
          test_case "review_plugins defaults" `Quick test_config_review_plugins_defaults;
          test_case "review_plugins explicit" `Quick test_config_review_plugins_explicit;
          test_case "vuln_class roundtrip" `Quick test_vuln_class_roundtrip;
          test_case "security_plugin_config roundtrip" `Quick test_security_plugin_config_roundtrip;
        ] );
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
      ( "security_types",
        [
          test_case "triage output roundtrip" `Quick test_security_triage_output_roundtrip;
          test_case "triage output with skip" `Quick test_security_triage_output_with_skip;
          test_case "candidate finding roundtrip" `Quick test_security_candidate_finding_roundtrip;
          test_case "sanitization status roundtrip" `Quick test_security_sanitization_status_roundtrip;
          test_case "validation verdict roundtrip" `Quick test_security_validation_verdict_roundtrip;
          test_case "validator output roundtrip" `Quick test_security_validator_output_roundtrip;
          test_case "triage output extra fields" `Quick test_security_triage_output_extra_fields;
        ] );
      ( "security_tools",
        [
          test_case "params roundtrip" `Quick test_security_tools_params_roundtrip;
          test_case "result with content" `Quick test_security_tools_result_with_content;
          test_case "result with error" `Quick test_security_tools_result_with_error;
          test_case "result empty" `Quick test_security_tools_result_empty;
          test_case "result missing fields" `Quick test_security_tools_result_missing_fields;
          test_case "execute success" `Quick test_security_tools_execute_success;
          test_case "execute not found" `Quick test_security_tools_execute_not_found;
          test_case "execute API error" `Quick test_security_tools_execute_api_error;
          test_case "execute invalid params" `Quick test_security_tools_execute_invalid_params;
          test_case "tool name" `Quick test_security_tools_tool_name;
        ] );
      ( "triage_agent",
        [
          test_case "config defaults" `Quick test_triage_agent_config;
          test_case "config model tier" `Quick test_triage_agent_config_model_tier;
          test_case "detect languages" `Quick test_triage_agent_detect_languages;
          test_case "detect languages empty" `Quick test_triage_agent_detect_languages_empty;
          test_case "detect languages unknown" `Quick test_triage_agent_detect_languages_unknown;
          test_case "build input minimal" `Quick test_triage_agent_build_input_minimal;
          test_case "build input with memory" `Quick test_triage_agent_build_input_with_memory;
          test_case "build input empty memory" `Quick test_triage_agent_build_input_empty_memory;
          test_case "output schema valid" `Quick test_triage_agent_output_schema_valid;
        ] );
      ( "security_plugin",
        [
          test_case "confidence rank ordering" `Quick test_security_confidence_rank;
          test_case "vuln class equality" `Quick test_security_vuln_class_equal;
          test_case "should analyze above threshold" `Quick test_security_should_analyze_above_threshold;
          test_case "should analyze below threshold in config" `Quick
            test_security_should_analyze_below_threshold_in_config;
          test_case "should analyze below threshold not in config" `Quick
            test_security_should_analyze_below_threshold_not_in_config;
          test_case "should analyze high threshold" `Quick test_security_should_analyze_high_threshold;
          test_case "should analyze high threshold restricted" `Quick
            test_security_should_analyze_high_threshold_restricted;
          test_case "should analyze low threshold" `Quick test_security_should_analyze_low_threshold;
          test_case "agent model tier conversion" `Quick test_security_agent_model_tier;
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
