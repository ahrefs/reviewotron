open Devkit
open Reviewotron_lib
open Alcotest

let read_file path = Std.input_file ~bin:true path

let security_enabled_config =
  Config_types.config_of_json (Melange_json.of_string {|{"review_plugins": {"security": {"enabled": true}}}|})

let security_enabled_slack_config =
  Config_types.config_of_json
    (Melange_json.of_string {|{"slack_channel": "dev-reviews", "review_plugins": {"security": {"enabled": true}}}|})

let test_parse_pr_opened () =
  let body = read_file "mock_payloads/pr_opened.json" in
  match Github.parse_event ~event_type:"pull_request" ~body with
  | Ok (Github.Pull_request n) ->
    (check string) "action" "opened" n.action;
    (check int) "pr number" 42 n.pull_request.number;
    (check string) "title" "Add feature X to the dashboard" n.pull_request.title;
    (check string) "repo" "ahrefs/monorepo" n.repository.full_name;
    (check string) "sender" "developer1" n.sender.login
  | Ok _ -> fail "expected Pull_request event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let test_parse_push_develop () =
  let body = read_file "mock_payloads/push_develop.json" in
  match Github.parse_event ~event_type:"push" ~body with
  | Ok (Github.Push n) ->
    (check string) "ref" "refs/heads/develop" n.ref_;
    (check int) "commit count" 2 (List.length n.commits);
    (check string) "repo" "ahrefs/monorepo" n.repository.full_name;
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
  (check bool) "security disabled by default" false config.review_plugins.security.enabled;
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
  (check bool) "has findings" true (CCString.find ~sub:{|"findings"|} json_str >= 0);
  (check bool) "has field descriptions" true (CCString.find ~sub:{|"description"|} json_str >= 0)

let rec collect_anthropic_schema_issues ~path (json : Yojson.Basic.t) =
  match json with
  | `Assoc fields ->
    let key_issues =
      List.concat_map
        (fun (key, value) ->
          let current_path = Printf.sprintf "%s/%s" path key in
          let current_issues =
            match key with
            | "maxItems" | "prefixItems" | "unevaluatedItems" | "contains" | "minContains" | "maxContains"
            | "uniqueItems" ->
              [ Printf.sprintf "%s uses unsupported keyword '%s'" current_path key ]
            | "minimum" | "maximum" | "multipleOf" | "exclusiveMinimum" | "exclusiveMaximum" | "minLength" | "maxLength"
              ->
              [ Printf.sprintf "%s uses unsupported keyword '%s'" current_path key ]
            | "minItems" ->
              (match value with
              | `Int n when n > 1 -> [ Printf.sprintf "%s has unsupported minItems=%d" current_path n ]
              | _ -> [])
            | "$ref" ->
              (match value with
              | `String ref_ when CCString.prefix ~pre:"#/" ref_ -> []
              | `String ref_ -> [ Printf.sprintf "%s has unsupported external ref '%s'" current_path ref_ ]
              | _ -> [ Printf.sprintf "%s has invalid $ref value" current_path ])
            | _ -> []
          in
          current_issues @ collect_anthropic_schema_issues ~path:current_path value)
        fields
    in
    let object_issues =
      match List.assoc_opt "type" fields with
      | Some (`String "object") ->
        (match List.assoc_opt "additionalProperties" fields with
        | Some (`Bool false) -> []
        | Some _ -> [ Printf.sprintf "%s object must set additionalProperties=false" path ]
        | None -> [ Printf.sprintf "%s object is missing additionalProperties=false" path ])
      | _ -> []
    in
    object_issues @ key_issues
  | `List values ->
    values
    |> List.mapi (fun i value -> collect_anthropic_schema_issues ~path:(Printf.sprintf "%s[%d]" path i) value)
    |> List.concat
  | `Bool _ | `Float _ | `Int _ | `Null | `String _ -> []

let test_anthropic_structured_output_schemas_compatible () =
  let schemas : (string * Yojson.Basic.t) list =
    [
      "general_review", Review_types.review_output_jsonschema;
      "security_triage", Security_types.triage_output_jsonschema;
      "security_analysis", Security_types.analysis_output_jsonschema;
      "security_validator", Security_types.validator_output_jsonschema;
      "memory_curator", Security_types.curator_output_jsonschema;
    ]
  in
  let issues = schemas |> List.concat_map (fun (name, schema) -> collect_anthropic_schema_issues ~path:name schema) in
  match issues with
  | [] -> ()
  | _ ->
    let issue_preview = issues |> CCList.take 20 |> String.concat "\n" in
    fail (Printf.sprintf "generated structured output schemas violate Anthropic constraints:\n%s" issue_preview)

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
      Adequate, {|"adequate"|};
      Inadequate, {|"inadequate"|};
      Missing, {|"missing"|};
      Unknown, {|"unknown"|};
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
  let cases = [ Confirmed, {|"confirmed"|}; Rejected, {|"rejected"|} ] in
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
                sanitization = Inadequate;
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

(** {2 Security corpus triage tests} *)

let parse_single_diff ~fixture ~expected_path =
  let diff_text = read_file fixture in
  let diffs = Diff_parser.parse diff_text in
  match diffs with
  | [ fd ] ->
    (check string) "correct file path" expected_path fd.path;
    (check bool) "has hunks" true (fd.hunks <> []);
    diff_text
  | _ -> fail (Printf.sprintf "expected 1 file diff, got %d" (List.length diffs))

let parse_triage_file path = read_file path |> Melange_json.of_string |> Security_types.triage_output_of_json

let test_triage_corpus_injection_diff_valid () =
  ignore
    (parse_single_diff ~fixture:"security_corpus/injection/sql_concat_vulnerable.diff"
       ~expected_path:"src/handlers/user.py"
      : string)

let test_triage_corpus_safe_diff_valid () =
  ignore
    (parse_single_diff ~fixture:"security_corpus/injection/sql_parameterized_safe.diff"
       ~expected_path:"src/handlers/user.py"
      : string)

let test_triage_corpus_injection_build_input () =
  let diff_text = read_file "security_corpus/injection/sql_concat_vulnerable.diff" in
  let diffs = Diff_parser.parse diff_text in
  let file_paths = List.map (fun (fd : Diff_parser.file_diff) -> fd.path) diffs in
  let input = Triage_agent.build_input ~diff_text ~file_paths () in
  (check bool) "contains file path" true (CCString.find ~sub:"src/handlers/user.py" input >= 0);
  (check bool) "contains language hint" true (CCString.find ~sub:"Python" input >= 0);
  (check bool) "contains diff" true (CCString.find ~sub:"SELECT * FROM users" input >= 0)

let test_triage_corpus_injection_response () =
  let triage = parse_triage_file "mock_api_responses/triage/injection_vulnerable.json" in
  (match triage.signals with
  | [ signal ] ->
    (check bool) "vuln class is injection" true (Security_review_plugin.vuln_class_equal signal.vuln_class Injection);
    (check bool) "confidence is high" true
      (match signal.confidence with
      | High -> true
      | Medium | Low -> false)
  | signals -> fail (Printf.sprintf "expected 1 signal, got %d" (List.length signals)));
  (check bool) "has python hint" true (List.exists (String.equal "python") triage.language_hints);
  (check bool) "no skip reason" true (Option.is_none triage.skip_reason)

let test_triage_corpus_safe_response () =
  let triage = parse_triage_file "mock_api_responses/triage/safe_no_signals.json" in
  (check int) "no signals" 0 (List.length triage.signals);
  (check bool) "has skip reason" true (Option.is_some triage.skip_reason);
  (check bool) "skip reason mentions parameterized" true
    (match triage.skip_reason with
    | Some reason -> CCString.find ~sub:"parameterized" reason >= 0
    | None -> false)

let test_triage_corpus_injection_routing () =
  let triage = parse_triage_file "mock_api_responses/triage/injection_vulnerable.json" in
  let security_config = Config_types.default_security_plugin_config in
  let actionable = List.filter (Security_review_plugin.should_analyze ~security_config) triage.signals in
  match actionable with
  | [ signal ] ->
    (check bool) "injection routed" true (Security_review_plugin.vuln_class_equal signal.vuln_class Injection)
  | signals -> fail (Printf.sprintf "expected 1 actionable signal, got %d" (List.length signals))

let test_triage_corpus_safe_skip () =
  let triage = parse_triage_file "mock_api_responses/triage/safe_no_signals.json" in
  let security_config = Config_types.default_security_plugin_config in
  let actionable = List.filter (Security_review_plugin.should_analyze ~security_config) triage.signals in
  (check int) "no actionable signals" 0 (List.length actionable)

(** {2 Analysis agent tests} *)

let test_analysis_agent_config () =
  let cfg = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[ "Python" ] in
  (check string) "name" "security_analysis_injection" cfg.name;
  (check int) "max_steps" 10 cfg.max_steps;
  (check bool) "has system prompt" true (String.length cfg.system_prompt > 0);
  (check bool) "has output schema" true
    (match cfg.output_schema with
    | `Assoc _ -> true
    | _ -> false)

let test_analysis_agent_config_per_class () =
  let injection = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  let xss = Analysis_agent.config ~vuln_class:Xss ~model_tier:Standard ~language_hints:[] in
  let cmd = Analysis_agent.config ~vuln_class:Command_injection ~model_tier:Standard ~language_hints:[] in
  let authn = Analysis_agent.config ~vuln_class:Authn ~model_tier:Standard ~language_hints:[] in
  let authz = Analysis_agent.config ~vuln_class:Authz ~model_tier:Standard ~language_hints:[] in
  let ssrf = Analysis_agent.config ~vuln_class:Ssrf ~model_tier:Standard ~language_hints:[] in
  (check string) "injection name" "security_analysis_injection" injection.name;
  (check string) "xss name" "security_analysis_xss" xss.name;
  (check string) "cmd name" "security_analysis_command_injection" cmd.name;
  (check string) "authn name" "security_analysis_authn" authn.name;
  (check string) "authz name" "security_analysis_authz" authz.name;
  (check string) "ssrf name" "security_analysis_ssrf" ssrf.name;
  (* Each agent has a distinct system prompt *)
  (check bool) "injection prompt differs from xss" true (not (String.equal injection.system_prompt xss.system_prompt))

let test_analysis_agent_config_model_tier () =
  let fast = Analysis_agent.config ~vuln_class:Injection ~model_tier:Fast ~language_hints:[] in
  let standard = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  let strong = Analysis_agent.config ~vuln_class:Injection ~model_tier:Strong ~language_hints:[] in
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

let test_analysis_agent_prompt_contains_methodology () =
  let cfg = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  (check bool) "source identification" true (Devkit.Stre.exists cfg.system_prompt "Source Identification");
  (check bool) "sink identification" true (Devkit.Stre.exists cfg.system_prompt "Sink Identification");
  (check bool) "data flow tracing" true (Devkit.Stre.exists cfg.system_prompt "Data Flow Tracing");
  (check bool) "sanitization evaluation" true (Devkit.Stre.exists cfg.system_prompt "Sanitization Evaluation");
  (check bool) "get_file_content tool" true (Devkit.Stre.exists cfg.system_prompt "get_file_content")

let test_analysis_agent_prompt_contains_class_section () =
  let injection = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  let xss = Analysis_agent.config ~vuln_class:Xss ~model_tier:Standard ~language_hints:[] in
  let cmd = Analysis_agent.config ~vuln_class:Command_injection ~model_tier:Standard ~language_hints:[] in
  let authn = Analysis_agent.config ~vuln_class:Authn ~model_tier:Standard ~language_hints:[] in
  let authz = Analysis_agent.config ~vuln_class:Authz ~model_tier:Standard ~language_hints:[] in
  let ssrf = Analysis_agent.config ~vuln_class:Ssrf ~model_tier:Standard ~language_hints:[] in
  (check bool) "injection section" true (Devkit.Stre.exists injection.system_prompt "SQL/Query Injection");
  (check bool) "xss section" true (Devkit.Stre.exists xss.system_prompt "Cross-Site Scripting");
  (check bool) "cmd section" true (Devkit.Stre.exists cmd.system_prompt "Command Injection");
  (check bool) "authn section" true (Devkit.Stre.exists authn.system_prompt "Authentication");
  (check bool) "authz section" true (Devkit.Stre.exists authz.system_prompt "Authorization");
  (check bool) "ssrf section" true (Devkit.Stre.exists ssrf.system_prompt "Server-Side Request Forgery")

let test_analysis_agent_language_hints () =
  let with_hints =
    Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[ "Python"; "JavaScript" ]
  in
  let without_hints = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  (check bool) "prompt contains Python" true (Devkit.Stre.exists with_hints.system_prompt "Python");
  (check bool) "prompt contains JavaScript" true (Devkit.Stre.exists with_hints.system_prompt "JavaScript");
  (check bool) "no language note without hints" false
    (Devkit.Stre.exists without_hints.system_prompt "Languages detected in this diff")

let test_analysis_agent_build_input_minimal () =
  let signal : Security_types.triage_signal =
    {
      vuln_class = Injection;
      confidence = High;
      regions = [ { path = "app.py"; start_line = 10; end_line = 20 } ];
      rationale = "SQL string concatenation";
    }
  in
  let input =
    Analysis_agent.build_input ~diff_text:"diff content" ~triage_signals:[ signal ] ~file_paths:[ "app.py" ] ()
  in
  (check bool) "contains diff" true (Devkit.Stre.exists input "diff content");
  (check bool) "contains file path" true (Devkit.Stre.exists input "app.py");
  (check bool) "contains rationale" true (Devkit.Stre.exists input "SQL string concatenation");
  (check bool) "contains confidence" true (Devkit.Stre.exists input "high");
  (check bool) "contains regions" true (Devkit.Stre.exists input "lines 10");
  (check bool) "no security memory section" false (Devkit.Stre.exists input "Repository Security Context")

let test_analysis_agent_build_input_with_memory () =
  let signal : Security_types.triage_signal =
    {
      vuln_class = Xss;
      confidence = Medium;
      regions = [ { path = "template.html"; start_line = 5; end_line = 15 } ];
      rationale = "Unescaped template variable";
    }
  in
  let input =
    Analysis_agent.build_input ~diff_text:"diff content" ~triage_signals:[ signal ] ~file_paths:[ "template.html" ]
      ~security_memory:"Known safe: Html.escape_text used consistently" ()
  in
  (check bool) "contains memory" true (Devkit.Stre.exists input "Known safe: Html.escape_text used consistently");
  (check bool) "has security memory section" true (Devkit.Stre.exists input "Repository Security Context")

let test_analysis_agent_build_input_empty_memory () =
  let signal : Security_types.triage_signal =
    {
      vuln_class = Injection;
      confidence = High;
      regions = [ { path = "app.py"; start_line = 1; end_line = 5 } ];
      rationale = "test";
    }
  in
  let input =
    Analysis_agent.build_input ~diff_text:"diff" ~triage_signals:[ signal ] ~file_paths:[ "app.py" ] ~security_memory:""
      ()
  in
  (check bool) "no security memory section for empty" false (Devkit.Stre.exists input "Repository Security Context")

let test_analysis_agent_tools () =
  let fetch_file _path = Lwt.return_ok (Some "file content") in
  let tool_list = Analysis_agent.tools ~fetch_file in
  (check int) "one tool" 1 (List.length tool_list);
  match tool_list with
  | [ (name, _tool) ] -> (check string) "tool name" "get_file_content" name
  | _ -> fail "expected exactly one tool"

let test_analysis_agent_output_schema () =
  let cfg = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  let schema = cfg.output_schema in
  (check bool) "schema has type" true
    (match schema with
    | `Assoc fields -> List.exists (fun (k, _) -> String.equal k "type") fields
    | _ -> false);
  (check bool) "schema has properties" true
    (match schema with
    | `Assoc fields -> List.exists (fun (k, _) -> String.equal k "properties") fields
    | _ -> false)

let test_analysis_agent_shared_methodology () =
  let methodology = Analysis_agent.shared_methodology in
  (check bool) "step 1" true (Devkit.Stre.exists methodology "Step 1");
  (check bool) "step 2" true (Devkit.Stre.exists methodology "Step 2");
  (check bool) "step 3" true (Devkit.Stre.exists methodology "Step 3");
  (check bool) "step 4" true (Devkit.Stre.exists methodology "Step 4")

let test_analysis_agent_vuln_class_section_all_classes () =
  let classes : Security_types.vuln_class list = [ Injection; Xss; Command_injection; Authn; Authz; Ssrf ] in
  List.iter
    (fun vc ->
      let section = Analysis_agent.vuln_class_section vc ~language_hints:[] in
      (check bool)
        (Printf.sprintf "%s non-empty" (Security_types.vuln_class_to_string vc))
        true
        (String.length section > 0);
      (check bool)
        (Printf.sprintf "%s has sources or sinks" (Security_types.vuln_class_to_string vc))
        true
        (Devkit.Stre.exists section "Source" || Devkit.Stre.exists section "What to look for"))
    classes

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
  (check bool) "correct repo" true (CCString.find ~sub:"repo=https://github.com/ahrefs/monorepo" write_log >= 0);
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
      State.record_pr_review state ~repo_url:repo ~pr_number:1 ~head_sha:"abc123" ~review_costs:[];
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

(** {2 Cost tracking tests} *)

(** Shared test fixtures for cost tracking tests. *)

let triage_agent_cost : Cost_tracking.agent_cost =
  {
    agent_name = "triage";
    model = "claude-haiku-4-5-20251001";
    input_tokens = 1000;
    output_tokens = 200;
    cache_read_input_tokens = 0;
    cache_creation_input_tokens = 0;
    turns = 1;
    files_fetched = 0;
    (* 1000 * 1.0/1M + 200 * 5.0/1M = 0.001 + 0.001 = 0.002 *)
    estimated_cost_usd = 0.002;
  }

let analysis_agent_cost : Cost_tracking.agent_cost =
  {
    agent_name = "injection_analysis";
    model = "claude-sonnet-4-6-20260414";
    input_tokens = 5000;
    output_tokens = 1000;
    cache_read_input_tokens = 0;
    cache_creation_input_tokens = 0;
    turns = 4;
    files_fetched = 3;
    (* 5000 * 3/1M + 1000 * 15/1M = 0.015 + 0.015 = 0.030 *)
    estimated_cost_usd = 0.030;
  }

let general_agent_cost : Cost_tracking.agent_cost =
  {
    agent_name = "general_review";
    model = "claude-sonnet-4-6-20260414";
    input_tokens = 3000;
    output_tokens = 800;
    cache_read_input_tokens = 0;
    cache_creation_input_tokens = 0;
    turns = 1;
    files_fetched = 0;
    (* 3000 * 3/1M + 800 * 15/1M = 0.009 + 0.012 = 0.021 *)
    estimated_cost_usd = 0.021;
  }

let test_estimate_cost_sonnet () =
  (* Sonnet: $3/M input, $15/M output *)
  let cost =
    Cost_tracking.estimate_cost ~model_id:"claude-sonnet-4-6-20260414" ~input_tokens:1_000_000 ~output_tokens:1_000_000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (check (float 1e-6)) "sonnet 1M in + 1M out" 18.0 cost

let test_estimate_cost_haiku () =
  (* Haiku: $1/M input, $5/M output *)
  let cost =
    Cost_tracking.estimate_cost ~model_id:"claude-haiku-4-5-20251001" ~input_tokens:500_000 ~output_tokens:100_000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (* 500k * 1.0/1M + 100k * 5.0/1M = 0.50 + 0.50 = 1.00 *)
  (check (float 1e-6)) "haiku 500k in + 100k out" 1.00 cost

let test_estimate_cost_opus () =
  (* Opus: $5/M input, $25/M output *)
  let cost =
    Cost_tracking.estimate_cost ~model_id:"claude-opus-4-6-20260414" ~input_tokens:100_000 ~output_tokens:10_000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (* 100k * 5/1M + 10k * 25/1M = 0.50 + 0.25 = 0.75 *)
  (check (float 1e-6)) "opus 100k in + 10k out" 0.75 cost

let test_estimate_cost_unknown_model () =
  let cost =
    Cost_tracking.estimate_cost ~model_id:"gpt-4o-unknown" ~input_tokens:1000 ~output_tokens:1000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (check (float 1e-6)) "unknown model zero cost" 0.0 cost

let test_estimate_cost_with_cache () =
  (* Sonnet: $3/M input, $15/M output, $3.75/M cache write, $0.30/M cache read *)
  let cost =
    Cost_tracking.estimate_cost ~model_id:"claude-sonnet-4-6-20260414" ~input_tokens:10_000 ~output_tokens:5_000
      ~cache_read_input_tokens:100_000 ~cache_creation_input_tokens:50_000
  in
  (* 10k * 3/1M + 5k * 15/1M + 50k * 3.75/1M + 100k * 0.30/1M
     = 0.03 + 0.075 + 0.1875 + 0.03 = 0.3225 *)
  (check (float 1e-6)) "sonnet with cache" 0.3225 cost

let test_of_agent_result () =
  let usage : Ai_provider.Usage.t = { input_tokens = 2000; output_tokens = 500; total_tokens = Some 2500 } in
  let result : Agent_runner.agent_result =
    {
      output = `Null;
      usage;
      cache_read_input_tokens = 0;
      cache_creation_input_tokens = 0;
      steps_count = 3;
      model_id = "claude-sonnet-4-6-20260414";
    }
  in
  let cost = Cost_tracking.of_agent_result ~agent_name:"test_agent" ~files_fetched:2 result in
  (check string) "agent_name" "test_agent" cost.agent_name;
  (check string) "model" "claude-sonnet-4-6-20260414" cost.model;
  (check int) "input_tokens" 2000 cost.input_tokens;
  (check int) "output_tokens" 500 cost.output_tokens;
  (check int) "cache_read" 0 cost.cache_read_input_tokens;
  (check int) "cache_write" 0 cost.cache_creation_input_tokens;
  (check int) "turns" 3 cost.turns;
  (check int) "files_fetched" 2 cost.files_fetched;
  (* 2000 * 3/1M + 500 * 15/1M = 0.006 + 0.0075 = 0.0135 *)
  (check (float 1e-6)) "estimated_cost_usd" 0.0135 cost.estimated_cost_usd

let test_aggregate () =
  let rc = Cost_tracking.aggregate ~plugin:"security" [ triage_agent_cost; analysis_agent_cost ] in
  (check string) "plugin" "security" rc.plugin;
  (check int) "total_input" 6000 rc.total_input_tokens;
  (check int) "total_output" 1200 rc.total_output_tokens;
  (* triage: 0.002 + analysis: 0.030 = 0.032 *)
  (check (float 1e-6)) "total_cost" 0.032 rc.total_estimated_cost_usd;
  (check int) "agent_count" 2 (List.length rc.agents)

let test_format_footer () =
  let rc1 = Cost_tracking.aggregate ~plugin:"general" [ general_agent_cost ] in
  let rc2 = Cost_tracking.aggregate ~plugin:"security" [ triage_agent_cost; analysis_agent_cost ] in
  let footer = Cost_tracking.format_footer [ rc1; rc2 ] in
  (check bool) "contains agent count" true (CCString.find ~sub:"3 agents" footer >= 0);
  (check bool) "contains general" true (CCString.find ~sub:"general: 1 agent" footer >= 0);
  (check bool) "contains security" true (CCString.find ~sub:"security: 2 agents" footer >= 0);
  (check bool) "contains cost" true (CCString.find ~sub:"$0.05" footer >= 0)

let test_format_footer_empty_plugin () =
  let rc : Cost_tracking.review_cost =
    {
      plugin = "security";
      agents = [];
      total_input_tokens = 0;
      total_output_tokens = 0;
      total_estimated_cost_usd = 0.0;
    }
  in
  let footer = Cost_tracking.format_footer [ rc ] in
  (check bool) "contains 0 agents" true (CCString.find ~sub:"0 agents" footer >= 0);
  (check bool) "does not list empty plugin" true (CCString.find ~sub:"security:" footer < 0)

let test_agent_cost_json_roundtrip () =
  let cost : Cost_tracking.agent_cost =
    {
      agent_name = "triage";
      model = "claude-haiku-4-5-20251001";
      input_tokens = 1234;
      output_tokens = 567;
      cache_read_input_tokens = 8000;
      cache_creation_input_tokens = 2000;
      turns = 2;
      files_fetched = 1;
      estimated_cost_usd = 0.00327;
    }
  in
  let json = Cost_tracking.agent_cost_to_json cost in
  let decoded = Cost_tracking.agent_cost_of_json json in
  (check string) "agent_name" cost.agent_name decoded.agent_name;
  (check string) "model" cost.model decoded.model;
  (check int) "input_tokens" cost.input_tokens decoded.input_tokens;
  (check int) "output_tokens" cost.output_tokens decoded.output_tokens;
  (check int) "cache_read" cost.cache_read_input_tokens decoded.cache_read_input_tokens;
  (check int) "cache_write" cost.cache_creation_input_tokens decoded.cache_creation_input_tokens;
  (check int) "turns" cost.turns decoded.turns;
  (check int) "files_fetched" cost.files_fetched decoded.files_fetched;
  (check (float 1e-10)) "estimated_cost_usd" cost.estimated_cost_usd decoded.estimated_cost_usd

let test_review_cost_json_roundtrip () =
  let cost = Cost_tracking.aggregate ~plugin:"security" [ triage_agent_cost ] in
  let json = Cost_tracking.review_cost_to_json cost in
  let decoded = Cost_tracking.review_cost_of_json json in
  (check string) "plugin" cost.plugin decoded.plugin;
  (check int) "total_input" cost.total_input_tokens decoded.total_input_tokens;
  (check int) "total_output" cost.total_output_tokens decoded.total_output_tokens;
  (check (float 1e-10)) "total_cost" cost.total_estimated_cost_usd decoded.total_estimated_cost_usd;
  (check int) "agents count" (List.length cost.agents) (List.length decoded.agents)

let test_state_roundtrip_with_costs () =
  let tmp_path = Filename.temp_file "reviewotron_cost_state_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      let state = State.create ~filepath:tmp_path () in
      let repo = "https://github.com/test/repo" in
      let review_costs = [ Cost_tracking.aggregate ~plugin:"general" [ general_agent_cost ] ] in
      State.record_pr_review state ~repo_url:repo ~pr_number:1 ~head_sha:"abc123" ~review_costs;
      State.save state;
      let loaded = State.load ~filepath:tmp_path in
      let data = State.data loaded in
      let repo_state =
        match List.assoc_opt repo data.repos with
        | Some rs -> rs
        | None -> Alcotest.fail "repo not found in loaded state"
      in
      match repo_state.pr_reviews with
      | [] -> Alcotest.fail "no pr reviews found"
      | review :: _ ->
      match review.State_types.review_costs with
      | rc :: _ ->
        (check string) "plugin" "general" rc.plugin;
        (check int) "total_input" 3000 rc.total_input_tokens;
        (check (float 1e-6)) "total_cost" 0.021 rc.total_estimated_cost_usd
      | [] -> Alcotest.fail "expected at least one review cost")

(** {2 Security memory tests} *)

let test_repo_slug_basic () =
  (check string) "github url" "ahrefs-monorepo" (Security_memory.repo_slug "https://github.com/ahrefs/monorepo")

let test_repo_slug_with_git_suffix () =
  (check string) "git suffix" "ahrefs-monorepo" (Security_memory.repo_slug "https://github.com/ahrefs/monorepo.git")

let test_repo_slug_trailing_slash () =
  (check string) "trailing slash" "ahrefs-monorepo" (Security_memory.repo_slug "https://github.com/ahrefs/monorepo/")

let test_repo_slug_http () =
  (check string) "http url" "ahrefs-monorepo" (Security_memory.repo_slug "http://github.com/ahrefs/monorepo")

let test_repo_slug_bare () = (check string) "bare path" "ahrefs-monorepo" (Security_memory.repo_slug "ahrefs/monorepo")

let test_memory_path () =
  let path = Security_memory.memory_path ~memory_dir:"memory" ~repo_url:"https://github.com/ahrefs/monorepo" in
  (check string) "memory path" "memory/ahrefs-monorepo.md" path

let test_memory_load_missing () =
  let result = Security_memory.load ~memory_dir:"nonexistent_dir_for_test" ~repo_url:"https://github.com/test/repo" in
  (check bool) "missing file returns None" true (Option.is_none result)

let test_memory_save_load_roundtrip () =
  let tmp_dir = Filename.temp_dir "reviewotron_memory_" "_test" in
  Fun.protect
    ~finally:(fun () ->
      let path = Security_memory.memory_path ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" in
      (try Sys.remove path with Sys_error _ -> ());
      try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ())
    (fun () ->
      let content = "# Security Memory: test/repo\n\n## Architecture\n- Backend: OCaml\n" in
      Security_memory.save ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" ~content;
      let loaded = Security_memory.load ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" in
      match loaded with
      | Some s -> (check string) "roundtrip content" content s
      | None -> Alcotest.fail "expected Some content after save")

let test_memory_load_empty_file () =
  let tmp_dir = Filename.temp_dir "reviewotron_memory_" "_test" in
  Fun.protect
    ~finally:(fun () ->
      let path = Security_memory.memory_path ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" in
      (try Sys.remove path with Sys_error _ -> ());
      try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ())
    (fun () ->
      Security_memory.save ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" ~content:"";
      let loaded = Security_memory.load ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" in
      (check bool) "empty file returns None" true (Option.is_none loaded))

(** {2 Memory queue tests} *)

let test_memory_update_roundtrip () =
  let open Security_types in
  let update =
    {
      timestamp = "2026-04-15T10:00:00Z";
      review_id = "PR-42";
      learnings = [ "OCaml backend uses Dream" ];
      stale_entries = [];
    }
  in
  let parsed = roundtrip memory_update_to_json memory_update_of_json update in
  (check string) "timestamp" update.timestamp parsed.timestamp;
  (check string) "review_id" update.review_id parsed.review_id;
  (check (list string)) "learnings" update.learnings parsed.learnings;
  (check (list string)) "stale_entries" update.stale_entries parsed.stale_entries

let test_memory_update_roundtrip_with_stale () =
  let open Security_types in
  let update =
    {
      timestamp = "2026-04-15T10:00:00Z";
      review_id = "PR-43";
      learnings = [ "Found new auth pattern" ];
      stale_entries = [ "Old JWT middleware info" ];
    }
  in
  let parsed = roundtrip memory_update_to_json memory_update_of_json update in
  (check (list string)) "stale_entries" update.stale_entries parsed.stale_entries

let test_queue_path () =
  let path = Security_memory.queue_path ~memory_dir:"memory" ~repo_url:"https://github.com/ahrefs/monorepo" in
  (check string) "queue path" "memory/ahrefs-monorepo.queue" path

let make_test_update ~review_id ~learnings =
  Security_types.{ timestamp = "2026-04-15T10:00:00Z"; review_id; learnings; stale_entries = [] }

(** Create a temp dir and clean up memory + queue files after the test. *)
let with_queue_dir f =
  let tmp_dir = Filename.temp_dir "reviewotron_queue_" "_test" in
  let repo_url = "https://github.com/test/repo" in
  Fun.protect
    ~finally:(fun () ->
      let mem_path = Security_memory.memory_path ~memory_dir:tmp_dir ~repo_url in
      let q_path = Security_memory.queue_path ~memory_dir:tmp_dir ~repo_url in
      (try Sys.remove mem_path with Sys_error _ -> ());
      (try Sys.remove q_path with Sys_error _ -> ());
      try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ())
    (fun () -> f tmp_dir repo_url)

let test_queue_append_read_roundtrip () =
  with_queue_dir (fun tmp_dir repo_url ->
    let u1 = make_test_update ~review_id:"PR-1" ~learnings:[ "Backend uses Dream" ] in
    let u2 = make_test_update ~review_id:"PR-2" ~learnings:[ "SQL via Caqti"; "Auth via JWT" ] in
    Security_memory.append_update ~memory_dir:tmp_dir ~repo_url ~update:u1;
    Security_memory.append_update ~memory_dir:tmp_dir ~repo_url ~update:u2;
    let updates = Security_memory.read_updates ~memory_dir:tmp_dir ~repo_url in
    (check int) "two updates read back" 2 (List.length updates);
    match updates with
    | [ first; second ] ->
      (check string) "first review_id" "PR-1" first.review_id;
      (check string) "second review_id" "PR-2" second.review_id;
      (check (list string)) "second learnings" [ "SQL via Caqti"; "Auth via JWT" ] second.learnings
    | _ -> Alcotest.fail "expected exactly two updates")

let test_queue_read_missing_file () =
  let updates =
    Security_memory.read_updates ~memory_dir:"nonexistent_dir_for_test" ~repo_url:"https://github.com/test/repo"
  in
  (check (list string)) "empty list" [] (List.map (fun (u : Security_types.memory_update) -> u.review_id) updates)

let test_queue_read_malformed_entries () =
  with_queue_dir (fun tmp_dir repo_url ->
    let u1 = make_test_update ~review_id:"PR-1" ~learnings:[ "Valid entry" ] in
    Security_memory.append_update ~memory_dir:tmp_dir ~repo_url ~update:u1;
    (* Manually append a malformed line *)
    let path = Security_memory.queue_path ~memory_dir:tmp_dir ~repo_url in
    let oc = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc "not valid json\n");
    let u2 = make_test_update ~review_id:"PR-3" ~learnings:[ "Also valid" ] in
    Security_memory.append_update ~memory_dir:tmp_dir ~repo_url ~update:u2;
    let updates = Security_memory.read_updates ~memory_dir:tmp_dir ~repo_url in
    (check int) "skips malformed, keeps valid" 2 (List.length updates);
    match updates with
    | [ first; second ] ->
      (check string) "first review_id" "PR-1" first.review_id;
      (check string) "second review_id" "PR-3" second.review_id
    | _ -> Alcotest.fail "expected exactly two valid updates")

let test_queue_truncate () =
  with_queue_dir (fun tmp_dir repo_url ->
    let u1 = make_test_update ~review_id:"PR-1" ~learnings:[ "Some learning" ] in
    Security_memory.append_update ~memory_dir:tmp_dir ~repo_url ~update:u1;
    let before = Security_memory.read_updates ~memory_dir:tmp_dir ~repo_url in
    (check int) "one update before truncate" 1 (List.length before);
    Security_memory.truncate_queue ~memory_dir:tmp_dir ~repo_url;
    let after = Security_memory.read_updates ~memory_dir:tmp_dir ~repo_url in
    (check int) "empty after truncate" 0 (List.length after))

let test_queue_truncate_missing_file () =
  (* Should not raise — truncating a nonexistent file is a no-op *)
  Security_memory.truncate_queue ~memory_dir:"nonexistent_dir_for_test" ~repo_url:"https://github.com/test/repo"

(** {2 Memory curator agent tests} *)

let test_curator_output_roundtrip () =
  let open Security_types in
  let output = { updated_memory = "# Security Memory: test/repo\n\n## Architecture\n- OCaml backend\n" } in
  let parsed = roundtrip curator_output_to_json curator_output_of_json output in
  (check string) "updated_memory" output.updated_memory parsed.updated_memory

let test_curator_agent_config () =
  let cfg = Memory_curator_agent.config ~model_tier:Fast in
  (check string) "name" "memory_curator" cfg.name;
  (check int) "max_steps" 1 cfg.max_steps;
  (check bool) "has system prompt" true (String.length cfg.system_prompt > 0);
  (check bool) "has output schema" true
    (match cfg.output_schema with
    | `Assoc _ -> true
    | _ -> false)

let test_curator_agent_config_model_tier () =
  let fast = Memory_curator_agent.config ~model_tier:Fast in
  let standard = Memory_curator_agent.config ~model_tier:Standard in
  (check bool) "fast tier" true
    (match fast.model_tier with
    | Fast -> true
    | Standard | Strong -> false);
  (check bool) "standard tier" true
    (match standard.model_tier with
    | Standard -> true
    | Fast | Strong -> false)

let test_curator_agent_output_schema_valid () =
  let cfg = Memory_curator_agent.config ~model_tier:Fast in
  match cfg.output_schema with
  | `Assoc fields ->
    (check bool) "has type" true (List.mem_assoc "type" fields);
    (check bool) "has properties" true (List.mem_assoc "properties" fields)
  | _ -> fail "expected JSON object schema"

let test_curator_build_input_no_memory () =
  let input =
    Memory_curator_agent.build_input ~repo_name:"ahrefs/monorepo" ~memory_max_tokens:5000
      ~learnings:[ "Backend uses Dream framework"; "SQL goes through Caqti" ]
      ()
  in
  (check bool) "contains repo name" true (Devkit.Stre.exists input "ahrefs/monorepo");
  (check bool) "contains no existing memory" true (Devkit.Stre.exists input "No existing memory");
  (check bool) "contains current token count" true (Devkit.Stre.exists input "Current: 0 tokens");
  (check bool) "contains max token budget" true (Devkit.Stre.exists input "Maximum: 5000 tokens");
  (check bool) "contains learning 1" true (Devkit.Stre.exists input "Backend uses Dream framework");
  (check bool) "contains learning 2" true (Devkit.Stre.exists input "SQL goes through Caqti")

let test_curator_build_input_with_memory () =
  let existing = "# Security Memory: test/repo\n\n## Architecture\n- OCaml backend\n" in
  let input =
    Memory_curator_agent.build_input ~repo_name:"test/repo" ~memory_max_tokens:3000
      ~learnings:[ "New endpoint added in lib/api.ml" ] ~current_memory:existing ()
  in
  (check bool) "contains existing memory" true (Devkit.Stre.exists input "OCaml backend");
  (check bool) "contains Current Memory section" true (Devkit.Stre.exists input "## Current Memory");
  (check bool) "no 'No existing memory' text" false (Devkit.Stre.exists input "No existing memory");
  (check bool) "contains current token estimate" true (Devkit.Stre.exists input "Current: ~");
  (check bool) "contains max token budget" true (Devkit.Stre.exists input "Maximum: 3000 tokens");
  (check bool) "contains learning" true (Devkit.Stre.exists input "New endpoint added in lib/api.ml")

let test_curator_build_input_empty_memory () =
  let input =
    Memory_curator_agent.build_input ~repo_name:"test/repo" ~memory_max_tokens:5000 ~learnings:[ "test learning" ]
      ~current_memory:"" ()
  in
  (check bool) "empty memory treated as no memory" true (Devkit.Stre.exists input "No existing memory")

let test_curator_build_input_empty_learnings () =
  let input =
    Memory_curator_agent.build_input ~repo_name:"test/repo" ~memory_max_tokens:5000 ~learnings:[]
      ~current_memory:"# Security Memory\n" ()
  in
  (check bool) "contains New Learnings section" true (Devkit.Stre.exists input "## New Learnings");
  (check bool) "contains existing memory" true (Devkit.Stre.exists input "# Security Memory")

(** {2 Memory round-trip tests} *)

let test_memory_rt_queue_to_curator_input () =
  (* Queue I/O round-trip is covered by test_queue_append_read_roundtrip.
     This test focuses on build_input surfacing learnings in the prompt. *)
  let learnings = [ "Language hints: ocaml"; "Triage flagged: injection"; "Reviewed files: lib/db.ml" ] in
  let input = Memory_curator_agent.build_input ~repo_name:"test/repo" ~memory_max_tokens:5000 ~learnings () in
  (check bool) "curator input contains language hint" true (Devkit.Stre.exists input "Language hints: ocaml");
  (check bool) "curator input contains triage flag" true (Devkit.Stre.exists input "Triage flagged: injection");
  (check bool) "curator input contains file list" true (Devkit.Stre.exists input "Reviewed files: lib/db.ml");
  (check bool) "curator input has New Learnings section" true (Devkit.Stre.exists input "## New Learnings")

let test_memory_rt_curator_save_load () =
  with_queue_dir (fun tmp_dir repo_url ->
    let updated_memory =
      "# Security Memory: test/repo\n\n\
       ## Architecture\n\
       - OCaml with Dream\n\n\
       ## Known Safe Patterns\n\
       - Db.query parameterized\n"
    in
    Security_memory.save ~memory_dir:tmp_dir ~repo_url ~content:updated_memory;
    let loaded = Security_memory.load ~memory_dir:tmp_dir ~repo_url in
    match loaded with
    | None -> Alcotest.fail "expected memory to be present after save"
    | Some content -> (check bool) "loaded content matches saved" true (String.equal content updated_memory))

let test_memory_rt_injected_into_triage () =
  let security_memory =
    Some
      "# Security Memory: test/repo\n\n\
       ## Architecture\n\
       - OCaml backend\n\n\
       ## Known Risk Areas\n\
       - lib/export/csv.ml uses shell commands\n"
  in
  let input =
    Triage_agent.build_input
      ~diff_text:"diff --git a/lib/db.ml b/lib/db.ml\n+let q = \"SELECT * FROM users WHERE id = \" ^ id"
      ~file_paths:[ "lib/db.ml" ] ?security_memory ()
  in
  (check bool) "triage input has repository security context" true
    (Devkit.Stre.exists input "## Repository Security Context");
  (check bool) "triage input contains memory architecture" true (Devkit.Stre.exists input "OCaml backend");
  (check bool) "triage input contains risk areas" true (Devkit.Stre.exists input "lib/export/csv.ml")

let test_memory_rt_injected_into_analysis () =
  let security_memory =
    Some "# Security Memory: test/repo\n\n## Known Safe Patterns\n- Db.query uses parameterized statements\n"
  in
  let signal = make_triage_signal ~vuln_class:Security_types.Injection ~confidence:Security_types.High in
  let input =
    Analysis_agent.build_input
      ~diff_text:"diff --git a/lib/query.ml b/lib/query.ml\n+let q = \"SELECT * FROM t WHERE id = \" ^ id"
      ~triage_signals:[ signal ] ~file_paths:[ "lib/query.ml" ] ?security_memory ()
  in
  (check bool) "analysis input has repository security context" true
    (Devkit.Stre.exists input "## Repository Security Context");
  (check bool) "analysis input contains safe patterns from memory" true
    (Devkit.Stre.exists input "Db.query uses parameterized statements")

let test_memory_rt_token_budget () =
  (* Verify that when memory exceeds the configured limit, the curator's input
     correctly communicates the budget so the model knows to compress. The actual
     compression instruction lives in the curator's system prompt constant (not in
     build_input), so we only assert that the budget numbers are surfaced here. *)
  let large_memory = String.make 4001 'x' in
  (* 4001 chars → estimate_tokens ≈ 1001, which is > max_tokens = 800 *)
  let max_tokens = 800 in
  let input =
    Memory_curator_agent.build_input ~repo_name:"test/repo" ~memory_max_tokens:max_tokens ~learnings:[ "New learning" ]
      ~current_memory:large_memory ()
  in
  let estimated = Memory_curator_agent.estimate_tokens large_memory in
  (check bool) "estimated tokens exceeds limit" true (estimated > max_tokens);
  (check bool) "curator input contains token budget section" true (Devkit.Stre.exists input "## Token Budget");
  (check bool) "curator input contains maximum tokens" true
    (Devkit.Stre.exists input (Printf.sprintf "Maximum: %d tokens" max_tokens));
  (check bool) "curator input contains current estimate" true (Devkit.Stre.exists input "Current: ~")

let test_memory_full_round_trip () =
  with_queue_dir (fun tmp_dir repo_url ->
    let repo_name = Security_memory.repo_slug repo_url in
    (* 1. Review produces learnings → queue *)
    let learnings =
      [
        "Language hints: ocaml";
        "Triage flagged: injection";
        "Reviewed files: lib/db.ml, lib/auth.ml";
        "Confirmed security finding at lib/db.ml:42";
      ]
    in
    let update = make_test_update ~review_id:"PR-10" ~learnings in
    Security_memory.append_update ~memory_dir:tmp_dir ~repo_url ~update;
    (* 2. Queue persists learnings *)
    let updates = Security_memory.read_updates ~memory_dir:tmp_dir ~repo_url in
    (check int) "queue has one entry" 1 (List.length updates);
    let queued_learnings = List.concat_map (fun (u : Security_types.memory_update) -> u.learnings) updates in
    (check bool) "queued learnings include finding" true
      (List.exists (String.equal "Confirmed security finding at lib/db.ml:42") queued_learnings);
    (* 3. Curator input is built from queue learnings *)
    let curator_input =
      Memory_curator_agent.build_input ~repo_name ~memory_max_tokens:5000 ~learnings:queued_learnings ()
    in
    (check bool) "curator input contains finding learning" true
      (Devkit.Stre.exists curator_input "Confirmed security finding at lib/db.ml:42");
    (* 4. Curator saves updated memory and queue is truncated *)
    let updated_memory =
      "# Security Memory: test/repo\n\n\
       ## Architecture\n\
       - OCaml with Dream\n\n\
       ## Known Risk Areas\n\
       - lib/db.ml:42 SQL injection confirmed\n"
    in
    Security_memory.save ~memory_dir:tmp_dir ~repo_url ~content:updated_memory;
    Security_memory.truncate_queue ~memory_dir:tmp_dir ~repo_url;
    (check int) "queue empty after truncation" 0
      (List.length (Security_memory.read_updates ~memory_dir:tmp_dir ~repo_url));
    (* 5. Next review loads memory → injected into triage prompt *)
    let loaded_memory = Security_memory.load ~memory_dir:tmp_dir ~repo_url in
    let triage_input =
      Triage_agent.build_input ~diff_text:"+ let x = Dream.query req \"id\"" ~file_paths:[ "lib/db.ml" ]
        ?security_memory:loaded_memory ()
    in
    (check bool) "next review triage sees updated memory" true
      (Devkit.Stre.exists triage_input "## Repository Security Context");
    (check bool) "next review triage sees risk area from memory" true
      (Devkit.Stre.exists triage_input "lib/db.ml:42 SQL injection confirmed"))

(** {2 Security pipeline end-to-end tests} *)

let test_security_e2e_vulnerable () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/security/triage_injection.json";
      "security_analysis_injection", "mock_api_responses/security/analysis_injection.json";
      "security_validator", "mock_api_responses/security/validator_confirmed.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has general review summary" true (CCString.find ~sub:"The changes look generally good" write_log >= 0);
  (check bool) "has security finding" true (CCString.find ~sub:"**[critical]** security" write_log >= 0);
  (check bool) "has injection description" true
    (CCString.find ~sub:"SQL query string without parameterization" write_log >= 0);
  (check bool) "finding on correct path" true (CCString.find ~sub:"src/main.ml" write_log >= 0);
  (check bool) "has suggested fix" true (CCString.find ~sub:"Caqti prepared statements" write_log >= 0)

let test_security_e2e_safe () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/security/triage_safe.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has general review" true (CCString.find ~sub:"The changes look generally good" write_log >= 0);
  (check bool) "no security category" true (CCString.find ~sub:{|"security"|} write_log < 0)

let test_security_e2e_rejected () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/security/triage_injection.json";
      "security_analysis_injection", "mock_api_responses/security/analysis_injection.json";
      "security_validator", "mock_api_responses/security/validator_rejected.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has general review" true (CCString.find ~sub:"The changes look generally good" write_log >= 0);
  (check bool) "no security findings after rejection" true (CCString.find ~sub:{|"security"|} write_log < 0)

let test_security_e2e_disabled () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json (Melange_json.of_string {|{"review_plugins": {"security": {"enabled": false}}}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has general review" true (CCString.find ~sub:"The changes look generally good" write_log >= 0);
  (check bool) "no security category" true (CCString.find ~sub:{|"security"|} write_log < 0)

(** {2 General review failure robustness tests} *)

let test_pr_general_failure_no_findings () =
  Test_helpers.reset_test_state ();
  (* Map general_review agent to a nonexistent file so it fails.
     Security triage returns safe (no signals), so no security findings either. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/nonexistent_file.json";
      "security_triage", "mock_api_responses/security/triage_safe.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted despite failure" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has failure notice" true (CCString.find ~sub:"Review failed" write_log >= 0);
  (check bool) "has re-trigger message" true (CCString.find ~sub:"re-trigger the review" write_log >= 0);
  (check bool) "has service logs hint" true (CCString.find ~sub:"check the service logs" write_log >= 0)

let test_pr_general_failure_with_security_findings () =
  Test_helpers.reset_test_state ();
  (* General review agent fails, but security pipeline finds a confirmed vulnerability. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/nonexistent_file.json";
      "security_triage", "mock_api_responses/security/triage_injection.json";
      "security_analysis_injection", "mock_api_responses/security/analysis_injection.json";
      "security_validator", "mock_api_responses/security/validator_confirmed.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted despite general failure" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has partial failure notice" true (CCString.find ~sub:"Review partially failed" write_log >= 0);
  (check bool) "has re-trigger suggestion" true (CCString.find ~sub:"re-trigger the review" write_log >= 0);
  (check bool) "has security finding" true (CCString.find ~sub:"**[critical]** security" write_log >= 0);
  (check bool) "finding on correct path" true (CCString.find ~sub:"src/main.ml" write_log >= 0)

let test_push_general_failure () =
  Test_helpers.reset_test_state ();
  (* General review agent fails for push review. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/nonexistent_file.json";
      "security_triage", "mock_api_responses/security/triage_safe.json";
    ];
  let config = security_enabled_slack_config in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* Slack message should be sent with failure notice *)
  (check bool) "slack message sent" true (CCString.find ~sub:"[slack]" write_log >= 0);
  (check bool) "slack mentions failure" true (CCString.find ~sub:"Code Review Failed" write_log >= 0);
  let slack_msgs = Api_local.get_slack_messages () in
  (check int) "one slack message" 1 (List.length slack_msgs)

let test_push_general_failure_with_findings () =
  Test_helpers.reset_test_state ();
  (* General review agent fails but security pipeline finds a vulnerability.
     Push reviews post commit comments for critical/warning findings. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/nonexistent_file.json";
      "security_triage", "mock_api_responses/security/triage_injection.json";
      "security_analysis_injection", "mock_api_responses/security/analysis_injection.json";
      "security_validator", "mock_api_responses/security/validator_confirmed.json";
    ];
  let config = security_enabled_slack_config in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* Commit comments should be posted for security findings *)
  (check bool) "commit comment posted" true (CCString.find ~sub:"[create_commit_comment]" write_log >= 0);
  (* Slack message should indicate partial failure *)
  (check bool) "slack message sent" true (CCString.find ~sub:"[slack]" write_log >= 0);
  (check bool) "slack mentions failure" true (CCString.find ~sub:"Code Review Failed" write_log >= 0)

(** {2 Security plugin failure notice tests} *)

let test_pr_security_failure_notice () =
  Test_helpers.reset_test_state ();
  (* Map security_triage agent to a nonexistent file so it fails entirely.
     General review succeeds normally. When triage produces no costs,
     run_plugins detects the error. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/nonexistent_security_triage.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has general review summary" true (CCString.find ~sub:"The changes look generally good" write_log >= 0);
  (check bool) "has security failure notice" true
    (CCString.find ~sub:"security review plugin encountered an error" write_log >= 0);
  (check bool) "has incompleteness warning" true
    (CCString.find ~sub:"Security analysis may be incomplete" write_log >= 0)

let test_push_security_failure_notice () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/push_review_response.json";
      "security_triage", "mock_api_responses/nonexistent_security_triage.json";
    ];
  let config = security_enabled_slack_config in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "slack message sent" true (CCString.find ~sub:"[slack]" write_log >= 0);
  (* The Slack attachment should include the security failure note *)
  let slack_msgs = Api_local.get_slack_messages () in
  (check int) "one slack message" 1 (List.length slack_msgs);
  match slack_msgs with
  | [] -> fail "expected at least one Slack message"
  | (_channel, _text, attachments) :: _ ->
  match attachments with
  | None -> fail "expected Slack attachments"
  | Some [] -> fail "expected at least one attachment"
  | Some (att :: _) ->
    (check bool) "attachment has security failure notice" true
      (CCString.find ~sub:"security review plugin encountered an error" att.Slack_types.text >= 0)

let test_pr_no_security_notice_when_disabled () =
  Test_helpers.reset_test_state ();
  (* Disable the security plugin. No security failure notice should appear. *)
  let config =
    Config_types.config_of_json (Melange_json.of_string {|{"review_plugins": {"security": {"enabled": false}}}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "no security failure notice" true
    (CCString.find ~sub:"security review plugin encountered an error" write_log < 0)

(** {2 GitHub API retry tests} *)

let test_pr_review_retry_on_failure () =
  Test_helpers.reset_test_state ();
  (* Make the first create_pr_review call fail, then succeed on retry. *)
  Api_local.set_fail_next_pr_review ();
  let ctx = Test_helpers.make_test_context () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* The review should still be posted after the retry *)
  (check bool) "review posted after retry" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has summary" true (CCString.find ~sub:"The changes look generally good" write_log >= 0)

let test_commit_comment_retry_on_failure () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/push_review_response.json";
  (* Make the first create_commit_comment call fail, then succeed on retry. *)
  Api_local.set_fail_next_commit_comment ();
  let config = Config_types.config_of_json (Melange_json.of_string {|{"slack_channel": "dev-reviews"}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* The commit comment should still be posted after the retry *)
  (check bool) "commit comment posted after retry" true (CCString.find ~sub:"[create_commit_comment]" write_log >= 0)

(** {2 Debug dump tests} *)

let test_write_debug_dump () =
  let tmp_dir = Filename.temp_dir "reviewotron_debug_test" "" in
  let dir = Printf.sprintf "%s/nested/subdir" tmp_dir in
  let config : Agent_runner.agent_config =
    { name = "test_agent"; system_prompt = "unused"; model_tier = Fast; output_schema = `Assoc []; max_steps = 3 }
  in
  let step0 : Ai_core.Generate_text_result.step =
    {
      text = "step zero text here";
      reasoning = "";
      tool_calls = [];
      tool_results = [];
      finish_reason = Ai_provider.Finish_reason.Tool_calls;
      usage = { input_tokens = 0; output_tokens = 0; total_tokens = None };
    }
  in
  let step1 : Ai_core.Generate_text_result.step =
    {
      text = "step one output with some JSON-like content";
      reasoning = "";
      tool_calls = [ { tool_call_id = "tc1"; tool_name = "read_file"; args = `Null } ];
      tool_results = [];
      finish_reason = Ai_provider.Finish_reason.Stop;
      usage = { input_tokens = 0; output_tokens = 0; total_tokens = None };
    }
  in
  let steps = [ step0; step1 ] in
  let usage : Ai_provider.Usage.t = { input_tokens = 500; output_tokens = 200; total_tokens = Some 700 } in
  let result =
    Agent_runner.write_debug_dump ~dir ~config ~finish_reason:Ai_provider.Finish_reason.Length ~steps ~usage
  in
  (* Verify file was created *)
  (match result with
  | None -> Alcotest.fail "write_debug_dump returned None"
  | Some filepath ->
    (check string) "filepath" (Printf.sprintf "%s/test_agent.txt" dir) filepath;
    let content = Std.input_file ~bin:true filepath in
    (check bool) "contains agent name" true (CCString.find ~sub:"Agent: test_agent" content >= 0);
    (check bool) "contains finish reason" true (CCString.find ~sub:"Finish reason: length" content >= 0);
    (check bool) "contains input tokens" true (CCString.find ~sub:"500 input" content >= 0);
    (check bool) "contains output tokens" true (CCString.find ~sub:"200 output" content >= 0);
    (check bool) "contains step count" true (CCString.find ~sub:"Steps: 2" content >= 0);
    (check bool) "contains step 0 header" true (CCString.find ~sub:"Step 0 (text=19 chars, tool_calls=0)" content >= 0);
    (check bool) "contains step 0 text" true (CCString.find ~sub:"step zero text here" content >= 0);
    (check bool) "contains step 1 header" true (CCString.find ~sub:"Step 1 (text=43 chars, tool_calls=1)" content >= 0);
    (check bool) "contains step 1 text" true
      (CCString.find ~sub:"step one output with some JSON-like content" content >= 0));
  (* Cleanup *)
  (try Sys.remove (Printf.sprintf "%s/test_agent.txt" dir) with Sys_error _ -> ());
  (try Unix.rmdir dir with Unix.Unix_error _ -> ());
  (try Unix.rmdir (Printf.sprintf "%s/nested" tmp_dir) with Unix.Unix_error _ -> ());
  try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ()

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
      ( "anthropic_schema_compat",
        [ test_case "structured output schemas compatible" `Quick test_anthropic_structured_output_schemas_compatible ]
      );
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
      ( "triage_corpus",
        [
          test_case "injection diff valid" `Quick test_triage_corpus_injection_diff_valid;
          test_case "safe diff valid" `Quick test_triage_corpus_safe_diff_valid;
          test_case "injection build input" `Quick test_triage_corpus_injection_build_input;
          test_case "injection response parseable" `Quick test_triage_corpus_injection_response;
          test_case "safe response parseable" `Quick test_triage_corpus_safe_response;
          test_case "injection routing" `Quick test_triage_corpus_injection_routing;
          test_case "safe skip" `Quick test_triage_corpus_safe_skip;
        ] );
      ( "analysis_agent",
        [
          test_case "config defaults" `Quick test_analysis_agent_config;
          test_case "config per class" `Quick test_analysis_agent_config_per_class;
          test_case "config model tier" `Quick test_analysis_agent_config_model_tier;
          test_case "prompt methodology" `Quick test_analysis_agent_prompt_contains_methodology;
          test_case "prompt class section" `Quick test_analysis_agent_prompt_contains_class_section;
          test_case "language hints" `Quick test_analysis_agent_language_hints;
          test_case "build input minimal" `Quick test_analysis_agent_build_input_minimal;
          test_case "build input with memory" `Quick test_analysis_agent_build_input_with_memory;
          test_case "build input empty memory" `Quick test_analysis_agent_build_input_empty_memory;
          test_case "tools" `Quick test_analysis_agent_tools;
          test_case "output schema" `Quick test_analysis_agent_output_schema;
          test_case "shared methodology" `Quick test_analysis_agent_shared_methodology;
          test_case "vuln class sections" `Quick test_analysis_agent_vuln_class_section_all_classes;
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
      ( "cost_tracking",
        [
          test_case "estimate cost sonnet" `Quick test_estimate_cost_sonnet;
          test_case "estimate cost haiku" `Quick test_estimate_cost_haiku;
          test_case "estimate cost opus" `Quick test_estimate_cost_opus;
          test_case "estimate cost unknown model" `Quick test_estimate_cost_unknown_model;
          test_case "estimate cost with cache" `Quick test_estimate_cost_with_cache;
          test_case "of_agent_result" `Quick test_of_agent_result;
          test_case "aggregate" `Quick test_aggregate;
          test_case "format footer" `Quick test_format_footer;
          test_case "format footer empty plugin" `Quick test_format_footer_empty_plugin;
          test_case "agent_cost JSON roundtrip" `Quick test_agent_cost_json_roundtrip;
          test_case "review_cost JSON roundtrip" `Quick test_review_cost_json_roundtrip;
          test_case "state roundtrip with costs" `Quick test_state_roundtrip_with_costs;
        ] );
      ( "security_memory",
        [
          test_case "repo slug basic" `Quick test_repo_slug_basic;
          test_case "repo slug git suffix" `Quick test_repo_slug_with_git_suffix;
          test_case "repo slug trailing slash" `Quick test_repo_slug_trailing_slash;
          test_case "repo slug http" `Quick test_repo_slug_http;
          test_case "repo slug bare path" `Quick test_repo_slug_bare;
          test_case "memory path" `Quick test_memory_path;
          test_case "load missing" `Quick test_memory_load_missing;
          test_case "save load roundtrip" `Quick test_memory_save_load_roundtrip;
          test_case "load empty file" `Quick test_memory_load_empty_file;
        ] );
      ( "memory_queue",
        [
          test_case "memory_update roundtrip" `Quick test_memory_update_roundtrip;
          test_case "memory_update with stale entries" `Quick test_memory_update_roundtrip_with_stale;
          test_case "queue path" `Quick test_queue_path;
          test_case "append and read roundtrip" `Quick test_queue_append_read_roundtrip;
          test_case "read missing file" `Quick test_queue_read_missing_file;
          test_case "read with malformed entries" `Quick test_queue_read_malformed_entries;
          test_case "truncate" `Quick test_queue_truncate;
          test_case "truncate missing file" `Quick test_queue_truncate_missing_file;
        ] );
      ( "memory_curator",
        [
          test_case "curator_output roundtrip" `Quick test_curator_output_roundtrip;
          test_case "config" `Quick test_curator_agent_config;
          test_case "config model tier" `Quick test_curator_agent_config_model_tier;
          test_case "output schema valid" `Quick test_curator_agent_output_schema_valid;
          test_case "build input no memory" `Quick test_curator_build_input_no_memory;
          test_case "build input with memory" `Quick test_curator_build_input_with_memory;
          test_case "build input empty memory" `Quick test_curator_build_input_empty_memory;
          test_case "build input empty learnings" `Quick test_curator_build_input_empty_learnings;
        ] );
      ( "memory_round_trip",
        [
          test_case "queue to curator input" `Quick test_memory_rt_queue_to_curator_input;
          test_case "curator save load" `Quick test_memory_rt_curator_save_load;
          test_case "injected into triage" `Quick test_memory_rt_injected_into_triage;
          test_case "injected into analysis" `Quick test_memory_rt_injected_into_analysis;
          test_case "token budget shown in curator input" `Quick test_memory_rt_token_budget;
          test_case "full round trip" `Quick test_memory_full_round_trip;
        ] );
      ( "security_e2e",
        [
          test_case "vulnerable diff produces security finding" `Quick test_security_e2e_vulnerable;
          test_case "safe diff produces no security findings" `Quick test_security_e2e_safe;
          test_case "rejected finding produces no security output" `Quick test_security_e2e_rejected;
          test_case "disabled plugin produces no security findings" `Quick test_security_e2e_disabled;
        ] );
      ( "general_failure_robustness",
        [
          test_case "PR review posted on general failure (no findings)" `Quick test_pr_general_failure_no_findings;
          test_case "PR review posted on general failure (with security findings)" `Quick
            test_pr_general_failure_with_security_findings;
          test_case "push review posts Slack on general failure" `Quick test_push_general_failure;
          test_case "push review posts comments on general failure with findings" `Quick
            test_push_general_failure_with_findings;
        ] );
      ( "security_failure_notice",
        [
          test_case "PR review includes security failure notice on triage error" `Quick test_pr_security_failure_notice;
          test_case "push review Slack includes security failure notice on triage error" `Quick
            test_push_security_failure_notice;
          test_case "no security failure notice when plugin disabled" `Quick test_pr_no_security_notice_when_disabled;
        ] );
      ( "github_api_retry",
        [
          test_case "PR review retries on first failure" `Quick test_pr_review_retry_on_failure;
          test_case "commit comment retries on first failure" `Quick test_commit_comment_retry_on_failure;
        ] );
      "debug_dump", [ test_case "write debug dump creates file with expected content" `Quick test_write_debug_dump ];
    ]
