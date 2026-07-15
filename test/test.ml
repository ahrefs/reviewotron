open Devkit
open Reviewotron_lib
open Alcotest

let read_file path = Std.input_file ~bin:true path
let read_json path = Melange_json.of_string (read_file path)

let contains_sub ~sub s = CCString.find ~sub s >= 0

let require_some label = function
  | Some value -> value
  | None -> fail label

let count_sub ~sub s =
  let sub_len = String.length sub in
  let s_len = String.length s in
  match Int.equal sub_len 0 with
  | true -> 0
  | false ->
    let rec loop i acc =
      match i + sub_len > s_len with
      | true -> acc
      | false ->
      match String.equal (String.sub s i sub_len) sub with
      | true -> loop (i + sub_len) (acc + 1)
      | false -> loop (i + 1) acc
    in
    loop 0 0

let reviewed_commit_sub sha = Printf.sprintf "**Reviewed commit:** `%s`" (Review_job.short_display_id sha)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc contents)

let telemetry_lookup bindings name =
  match List.find_opt (fun (key, _) -> String.equal key name) bindings with
  | Some (_, value) -> Some value
  | None -> None

let otel_base_endpoint_var = "OTEL_EXPORTER_OTLP_ENDPOINT"
let otel_traces_endpoint_var = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"

let test_telemetry_env_absent_disables () =
  (check bool) "disabled" false (Telemetry.enabled_of_env (telemetry_lookup []))

let test_telemetry_env_reviewotron_flag_enables () =
  (check bool) "enabled" true (Telemetry.enabled_of_env (telemetry_lookup [ "REVIEWOTRON_OTEL", "1" ]))

let test_telemetry_env_standard_endpoint_enables () =
  (check bool) "enabled" true
    (Telemetry.enabled_of_env (telemetry_lookup [ "OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318" ]))

let test_telemetry_env_sdk_disabled_wins () =
  (check bool) "disabled" false
    (Telemetry.enabled_of_env
       (telemetry_lookup
          [
            "OTEL_SDK_DISABLED", "true"; "REVIEWOTRON_OTEL", "1"; "OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318";
          ]))

let test_telemetry_env_explicit_false_disables () =
  (check bool) "disabled" false
    (Telemetry.enabled_of_env
       (telemetry_lookup [ "REVIEWOTRON_OTEL", "0"; "OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318" ]))

let test_telemetry_blank_traces_endpoint_strips_base_slash () =
  (check (list (pair string string)))
    "overrides"
    [ otel_traces_endpoint_var, "http://collector:4318/v1/traces" ]
    (Telemetry.endpoint_overrides_of_env
       (telemetry_lookup [ otel_base_endpoint_var, "http://collector:4318/"; otel_traces_endpoint_var, "" ]))

let test_telemetry_cli_traces_endpoint_overrides_traces_env () =
  (check (list (pair string string)))
    "overrides"
    [ otel_traces_endpoint_var, "http://cli-collector:4318/v1/traces" ]
    (Telemetry.endpoint_overrides_of_env ~traces_endpoint:"http://cli-collector:4318/v1/traces"
       (telemetry_lookup [ otel_traces_endpoint_var, "http://env-collector:4318/v1/traces" ]))

let with_env_vars bindings f =
  let names = List.map fst bindings in
  let old_values = List.map (fun name -> name, Sys.getenv_opt name) names in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, value) ->
          match value with
          | Some value -> Unix.putenv name value
          | None -> ExtUnix.All.unsetenv name)
        old_values)
    (fun () ->
      List.iter (fun (name, value) -> Unix.putenv name value) bindings;
      f ())

let test_telemetry_disabled_setup_smoke () =
  with_env_vars
    [ "OTEL_SDK_DISABLED", "true"; "REVIEWOTRON_OTEL", "1" ]
    (fun () ->
      let ran = ref false in
      Lwt_main.run
        (Telemetry.with_setup ~command:"test" (fun () ->
           Telemetry.span "reviewotron.test.span" (fun () ->
             ran := true;
             Lwt.return_unit)));
      (check bool) "span body ran" true !ran)

let test_with_env_vars_restores_unset_vars_to_unset () =
  let var = "REVIEWOTRON_TEST_WAS_UNSET" in
  ExtUnix.All.unsetenv var;
  (check bool) "var unset before test" true (Option.is_none (Sys.getenv_opt var));
  with_env_vars [ var, "x" ] (fun () -> (check (option string)) "var set inside scope" (Some "x") (Sys.getenv_opt var));
  (check bool) "var restored to unset, not empty string" true (Option.is_none (Sys.getenv_opt var))

(* Default-off auto-review flags mean every test that wants the review pipeline
   to actually run must opt in explicitly. The shared security config fixtures
   below opt into PR-open and PR-sync because the security e2e suite always
   exercises the PR flow. The Slack-enabled variant adds [review_pushes_to_develop]
   for tests that exercise the push-to-develop path. *)

let security_enabled_config =
  Config_types.config_of_json
    (Melange_json.of_string
       {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "review_plugins": {"security": {"enabled": true}}}|})

let security_enabled_slack_config =
  Config_types.config_of_json
    (Melange_json.of_string
       {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "review_pushes_to_develop": true, "slack_channel": "dev-reviews", "review_plugins": {"security": {"enabled": true}}}|})

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

let test_parse_issue_comment_review () =
  let body = read_file "mock_payloads/issue_comment_review.json" in
  match Github.parse_event ~event_type:"issue_comment" ~body with
  | Ok (Github.Issue_comment n) ->
    (check string) "action" "created" n.action;
    (check int) "issue number" 42 n.issue.number;
    (check string) "issue state" "open" n.issue.state;
    (check bool) "issue is a PR" true (Option.is_some n.issue.pull_request);
    (check string) "comment body" "REVIEW" n.comment.body;
    (check string) "sender" "reviewer1" n.sender.login;
    (check string) "repo" "org/monorepo" n.repository.full_name
  | Ok _ -> fail "expected Issue_comment event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let test_parse_issue_comment_on_regular_issue () =
  let body = read_file "mock_payloads/issue_comment_on_issue.json" in
  match Github.parse_event ~event_type:"issue_comment" ~body with
  | Ok (Github.Issue_comment n) ->
    (* The parser must accept comments on regular issues; the dispatch layer
       is the one that rejects them when they're not on a PR. *)
    (check bool) "pull_request marker is null" true (Option.is_none n.issue.pull_request);
    (check int) "issue number" 7 n.issue.number
  | Ok _ -> fail "expected Issue_comment event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let test_parse_issue_comment_null_user () =
  let body = read_file "mock_payloads/issue_comment_null_user.json" in
  match Github.parse_event ~event_type:"issue_comment" ~body with
  | Ok (Github.Issue_comment n) ->
    (check bool) "issue.user is None" true (Option.is_none n.issue.user);
    (check bool) "comment.user is None" true (Option.is_none n.comment.user);
    (check string) "comment body still parsed" "REVIEW" n.comment.body
  | Ok _ -> fail "expected Issue_comment event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let review_event_payload_without_pr_change_counts ~event_type =
  let pull_request_json =
    {|{
      "url": "https://api.github.com/repos/org/monorepo/pulls/42",
      "id": 123456,
      "node_id": "PR_kwDO",
      "html_url": "https://github.com/org/monorepo/pull/42",
      "diff_url": "https://github.com/org/monorepo/pull/42.diff",
      "patch_url": "https://github.com/org/monorepo/pull/42.patch",
      "issue_url": "https://api.github.com/repos/org/monorepo/issues/42",
      "number": 42,
      "state": "open",
      "title": "Add feature X to the dashboard"
    }|}
  in
  match event_type with
  | "pull_request_review" ->
    Printf.sprintf
      {|{
  "action": "submitted",
  "review": {"id": 7001, "body": "review body", "state": "commented", "user": %s},
  "pull_request": %s,
  "repository": %s,
  "sender": %s
}|}
      (Test_helpers.user_json ~login:"reviewer1" ())
      pull_request_json (Test_helpers.repo_json ())
      (Test_helpers.user_json ~login:"reviewer1" ())
  | "pull_request_review_comment" ->
    Printf.sprintf
      {|{
  "action": "created",
  "comment": {"id": 8001, "body": "reply", "path": "src/main.ml", "line": 14, "user": %s},
  "pull_request": %s,
  "repository": %s,
  "sender": %s
}|}
      (Test_helpers.user_json ~login:"reviewer1" ())
      pull_request_json (Test_helpers.repo_json ())
      (Test_helpers.user_json ~login:"reviewer1" ())
  | event_type -> invalid_arg (Printf.sprintf "unsupported review event fixture: %s" event_type)

let test_parse_pull_request_review_without_change_counts () =
  let body = review_event_payload_without_pr_change_counts ~event_type:"pull_request_review" in
  match Github.parse_event ~event_type:"pull_request_review" ~body with
  | Ok (Github.Pull_request_review n) ->
    (check string) "action" "submitted" n.action;
    (check int) "pr number" 42 n.pull_request.number;
    (check string) "title" "Add feature X to the dashboard" n.pull_request.title;
    (check string) "sender" "reviewer1" n.sender.login
  | Ok _ -> fail "expected Pull_request_review event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

let test_parse_pull_request_review_comment_without_change_counts () =
  let body = review_event_payload_without_pr_change_counts ~event_type:"pull_request_review_comment" in
  match Github.parse_event ~event_type:"pull_request_review_comment" ~body with
  | Ok (Github.Pull_request_review_comment n) ->
    (check string) "action" "created" n.action;
    (check int) "pr number" 42 n.pull_request.number;
    (check string) "title" "Add feature X to the dashboard" n.pull_request.title;
    (check string) "sender" "reviewer1" n.sender.login
  | Ok _ -> fail "expected Pull_request_review_comment event"
  | Error msg -> fail (Printf.sprintf "parse error: %s" msg)

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
  (check (option string)) "api key" (Some "sk-test") secrets.anthropic_api_key;
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
  (check (option string)) "api key" (Some "sk-test") secrets.anthropic_api_key;
  (check int) "repo count" 1 (List.length secrets.repos)

let test_parse_secrets_openrouter_only () =
  let json = {|{"repos": [], "openrouter_api_key": "sk-or-test"}|} in
  let secrets = Config_types.secrets_of_json (Melange_json.of_string json) in
  (check (option string)) "anthropic key absent" None secrets.anthropic_api_key;
  (check (option string)) "openrouter key present" (Some "sk-or-test") secrets.openrouter_api_key

let test_llm_provider_resolve () =
  let mk ?anthropic ?openrouter () : Config_types.secrets =
    { repos = []; anthropic_api_key = anthropic; openrouter_api_key = openrouter; slack_access_token = None }
  in
  (match Llm_provider.resolve (mk ~openrouter:"k" ~anthropic:"a" ()) with
  | Ok Llm_provider.Openrouter -> ()
  | Ok Llm_provider.Anthropic | Error _ -> fail "openrouter preferred when both present");
  (match Llm_provider.resolve (mk ~openrouter:"  " ~anthropic:"a" ()) with
  | Ok Llm_provider.Anthropic -> ()
  | Ok Llm_provider.Openrouter | Error _ -> fail "blank openrouter key should fall back to anthropic");
  (match Llm_provider.resolve (mk ~anthropic:"a" ()) with
  | Ok Llm_provider.Anthropic -> ()
  | Ok Llm_provider.Openrouter | Error _ -> fail "anthropic when only it present");
  match Llm_provider.resolve (mk ()) with
  | Error _ -> ()
  | Ok (Llm_provider.Anthropic | Llm_provider.Openrouter) -> fail "no key should error"

let test_llm_provider_normalize () =
  (check string) "anthropic unchanged" "claude-sonnet-4-6"
    (Llm_provider.normalize_model_id Llm_provider.Anthropic "claude-sonnet-4-6");
  (check string) "openrouter canonical sonnet" "anthropic/claude-sonnet-4.6"
    (Llm_provider.normalize_model_id Llm_provider.Openrouter "claude-sonnet-4-6");
  (check string) "openrouter canonical haiku" "anthropic/claude-haiku-4.5"
    (Llm_provider.normalize_model_id Llm_provider.Openrouter "claude-haiku-4-5-20251001");
  (check string) "openrouter idempotent" "anthropic/claude-opus-4.6"
    (Llm_provider.normalize_model_id Llm_provider.Openrouter "anthropic/claude-opus-4.6");
  (check string) "openrouter canonicalizes old prefixed id" "anthropic/claude-opus-4.6"
    (Llm_provider.normalize_model_id Llm_provider.Openrouter "anthropic/claude-opus-4-6")

let test_model_ids_no_regression () =
  let expect tier ~anthropic_id ~openrouter_id =
    (check string) "anthropic tier id" anthropic_id (Agent_runner.default_model_id tier);
    (check string) "openrouter tier id" openrouter_id
      (Llm_provider.normalize_model_id Llm_provider.Openrouter (Agent_runner.default_model_id tier))
  in
  expect Agent_runner.Fast ~anthropic_id:"claude-haiku-4-5-20251001" ~openrouter_id:"anthropic/claude-haiku-4.5";
  expect Agent_runner.Standard ~anthropic_id:"claude-sonnet-5" ~openrouter_id:"anthropic/claude-sonnet-5";
  expect Agent_runner.Strong ~anthropic_id:"claude-opus-4-8" ~openrouter_id:"anthropic/claude-opus-4.8";
  (* config.model default flows through the same normalization *)
  (check string) "config.model default on OR" "anthropic/claude-sonnet-4.6"
    (Llm_provider.normalize_model_id Llm_provider.Openrouter "claude-sonnet-4-6")

let test_llm_provider_usage_metadata_combines_openrouter_costs () =
  let metadata =
    Ai_provider.Provider_options.set Ai_provider_openrouter.Convert_usage.Openrouter_usage
      {
        Ai_provider_openrouter.Convert_usage.cache_read_tokens = 7;
        cache_write_tokens = 11;
        reasoning_tokens = 13;
        cost = Some 0.02;
        upstream_inference_cost = Some 0.5;
      }
      Ai_provider.Provider_options.empty
  in
  let usage = Llm_provider.usage_metadata Llm_provider.Openrouter (Some metadata) in
  (check int) "cache read" 7 usage.cache_read;
  (check int) "cache write" 11 usage.cache_write;
  (check (option (float 1e-9))) "total reported cost" (Some 0.52) usage.cost

let test_openrouter_requires_supported_parameters () =
  (check (option bool)) "require_parameters" (Some true) Llm_provider.anthropic_upstream_prefs.require_parameters

let test_openrouter_maps_error_finish_reason () =
  let is_error =
    match Ai_provider_openrouter.Convert_response.map_finish_reason (Some "error") with
    | Ai_provider.Finish_reason.Error -> true
    | Ai_provider.Finish_reason.Stop | Ai_provider.Finish_reason.Length | Ai_provider.Finish_reason.Tool_calls
    | Ai_provider.Finish_reason.Content_filter | Ai_provider.Finish_reason.Other _ | Ai_provider.Finish_reason.Unknown
      ->
      false
  in
  (check bool) "error finish reason" true is_error

let test_openrouter_embedded_error_is_provider_error () =
  let response =
    `Assoc
      [
        ( "choices",
          `List
            [
              `Assoc
                [
                  "index", `Int 0;
                  "message", `Assoc [ "role", `String "assistant"; "content", `String "" ];
                  "finish_reason", `String "error";
                  ( "error",
                    `Assoc
                      [
                        "code", `Int 502;
                        "message", `String "Provider disconnected";
                        ( "metadata",
                          `Assoc [ "provider_name", `String "Anthropic"; "error_type", `String "provider_unavailable" ]
                        );
                      ] );
                ];
            ] );
      ]
  in
  try
    ignore (Ai_provider_openrouter.Convert_response.parse_response response : Ai_provider.Generate_result.t);
    fail "expected an embedded OpenRouter error to raise"
  with Ai_provider.Provider_error.Provider_error error ->
    let message = Ai_provider.Provider_error.to_string error in
    (check bool) "provider error preserves upstream message" true (contains_sub ~sub:"Provider disconnected" message);
    (check bool) "provider error preserves retry status" true (contains_sub ~sub:"HTTP 502" message)

let test_config_review_plugins_defaults () =
  let config = Config_types.config_of_json (Melange_json.of_string {|{}|}) in
  (check bool) "general enabled" true config.review_plugins.general.enabled;
  (check bool) "general prompt override" true (Option.is_none config.review_plugins.general.system_prompt_override);
  (check bool) "security disabled by default" false config.review_plugins.security.enabled;
  (check int) "vuln_classes count" 7 (List.length config.review_plugins.security.vuln_classes);
  (check bool) "policy_regression enabled by default" true
    (List.exists
       (Security_review_plugin.vuln_class_equal Config_types.Policy_regression)
       config.review_plugins.security.vuln_classes);
  (check int) "always_analyze_vuln_classes default empty" 0
    (List.length config.review_plugins.security.always_analyze_vuln_classes);
  (match config.review_plugins.security.analysis_effort with
  | Some Config_types.Effort.Medium -> ()
  | Some Config_types.Effort.Low | Some High | Some Xhigh | None -> fail "expected medium analysis effort by default");
  (check int) "memory_max_tokens" 5000 config.review_plugins.security.memory_max_tokens;
  (check bool) "metrics_artifacts default off" false config.review_plugins.security.metrics_artifacts;
  (check bool) "debug_artifacts default off" false config.review_plugins.security.debug_artifacts;
  (check bool) "show_review_cost" false config.show_review_cost;
  (check bool) "agent debug_artifacts default off" false config.debug_artifacts;
  (check int) "ignored_file_regexes default empty" 0 (List.length config.ignored_file_regexes);
  (check bool) "ignore_generated_files default on" true config.ignore_generated_files

let test_config_review_plugins_explicit () =
  let json =
    {|{
    "show_review_cost": true,
    "debug_artifacts": true,
    "ignored_file_regexes": ["^snapshots/.*\\.golden$"],
    "ignore_generated_files": false,
    "review_plugins": {
      "general": { "enabled": false },
      "security": {
        "enabled": true,
        "vuln_classes": ["injection", "xss"],
        "always_analyze_vuln_classes": ["xss"],
        "triage_model_tier": "standard",
        "analysis_effort": "medium",
        "confidence_threshold": "high",
        "memory_max_tokens": 10000,
        "metrics_artifacts": true,
        "debug_artifacts": true
      }
    }
  }|}
  in
  let config = Config_types.config_of_json (Melange_json.of_string json) in
  (check bool) "show_review_cost" true config.show_review_cost;
  (check bool) "agent debug_artifacts" true config.debug_artifacts;
  (check (list string)) "ignored_file_regexes explicit" [ "^snapshots/.*\\.golden$" ] config.ignored_file_regexes;
  (check bool) "ignore_generated_files explicit off" false config.ignore_generated_files;
  (check bool) "general disabled" false config.review_plugins.general.enabled;
  (check bool) "security enabled" true config.review_plugins.security.enabled;
  (check int) "vuln_classes count" 2 (List.length config.review_plugins.security.vuln_classes);
  (check bool) "explicit old class list stays explicit" false
    (List.exists
       (Security_review_plugin.vuln_class_equal Config_types.Policy_regression)
       config.review_plugins.security.vuln_classes);
  (check int) "always_analyze count" 1 (List.length config.review_plugins.security.always_analyze_vuln_classes);
  (match config.review_plugins.security.analysis_effort with
  | Some Config_types.Effort.Medium -> ()
  | Some Config_types.Effort.Low | Some High | Some Xhigh | None -> fail "expected medium analysis effort");
  (check int) "memory_max_tokens" 10000 config.review_plugins.security.memory_max_tokens;
  (check bool) "metrics_artifacts" true config.review_plugins.security.metrics_artifacts;
  (check bool) "debug_artifacts" true config.review_plugins.security.debug_artifacts

let test_config_rejects_invalid_ignored_file_regex () =
  match Config_types.config_of_json (Melange_json.of_string {|{"ignored_file_regexes":["["]}|}) with
  | (_ : Config_types.config) -> fail "expected invalid ignored_file_regexes to be rejected"
  | exception Melange_json.Of_json_error (Melange_json.Json_error msg) ->
    (check bool) "error names ignored_file_regexes" true (contains_sub ~sub:"ignored_file_regexes" msg)

let test_config_rejects_broad_ignored_file_regex () =
  List.iter
    (fun pattern ->
      match
        Config_types.config_of_json (Melange_json.of_string (Printf.sprintf {|{"ignored_file_regexes":[%S]}|} pattern))
      with
      | (_ : Config_types.config) -> fail (Printf.sprintf "expected broad ignored_file_regex %S to be rejected" pattern)
      | exception Melange_json.Of_json_error (Melange_json.Json_error msg) ->
        (check bool) "error names ignored_file_regexes" true (contains_sub ~sub:"ignored_file_regexes" msg))
    [ ".*"; ".+"; "^.*$"; "^.+$"; "^" ]

let test_config_general_scout_defaults () =
  let config = Config_types.config_of_json (Melange_json.of_string {|{}|}) in
  (check bool) "scout_enabled default on" true config.review_plugins.general.scout_enabled;
  (check string) "scout_model_tier default standard" "standard"
    (Config_types.model_tier_to_string config.review_plugins.general.scout_model_tier);
  (check string) "deep_reviewer_model_tier default strong" "strong"
    (Config_types.model_tier_to_string config.review_plugins.general.deep_reviewer_model_tier);
  (check int) "max_leads default" 10 config.review_plugins.general.max_leads;
  (check (option string)) "model absent by default" None config.model

let test_config_general_scout_explicit () =
  let json =
    {|{
    "model": "explicit-model",
    "review_plugins": {
      "general": {
        "scout_enabled": false,
        "scout_model_tier": "fast",
        "deep_reviewer_model_tier": "standard",
        "max_leads": 5
      }
    }
  }|}
  in
  let config = Config_types.config_of_json (Melange_json.of_string json) in
  (check bool) "scout_enabled explicit off" false config.review_plugins.general.scout_enabled;
  (check string) "scout_model_tier explicit fast" "fast"
    (Config_types.model_tier_to_string config.review_plugins.general.scout_model_tier);
  (check string) "deep_reviewer_model_tier explicit standard" "standard"
    (Config_types.model_tier_to_string config.review_plugins.general.deep_reviewer_model_tier);
  (check int) "max_leads explicit" 5 config.review_plugins.general.max_leads;
  (check (option string)) "model explicit override" (Some "explicit-model") config.model

(* All three tests below drive the TOP-LEVEL [Config_types.config_of_json]
   entrypoint (the real config-load path), not [general_plugin_config_of_json]
   in isolation. [config_of_json] → [review_plugins_config_of_json] →
   [general_plugin_config_of_json], so a green result here proves validation
   fires on the nested path the pipeline actually uses. *)

(* Assert that parsing [json] through the top-level config decoder raises
   [Melange_json.Of_json_error] with a message naming [max_leads]. Matches the
   exact exception the derived decoders raise via [Melange_json.of_json_error];
   no broad catch-all. *)
let expect_max_leads_rejected ~label json =
  match Config_types.config_of_json (Melange_json.of_string json) with
  | (_ : Config_types.config) -> Alcotest.failf "%s: expected max_leads to be rejected" label
  | exception Melange_json.Of_json_error (Json_error msg) ->
    (check bool) (label ^ ": message names max_leads") true (CCString.find ~sub:"max_leads" msg >= 0)

let test_config_max_leads_zero_rejected () =
  expect_max_leads_rejected ~label:"max_leads = 0" {|{ "review_plugins": { "general": { "max_leads": 0 } } }|}

let test_config_max_leads_negative_rejected () =
  expect_max_leads_rejected ~label:"max_leads = -3" {|{ "review_plugins": { "general": { "max_leads": -3 } } }|}

let test_config_max_leads_valid_and_default_ok () =
  let one =
    Config_types.config_of_json (Melange_json.of_string {|{ "review_plugins": { "general": { "max_leads": 1 } } }|})
  in
  (check int) "max_leads = 1 accepted" 1 one.review_plugins.general.max_leads;
  let omitted = Config_types.config_of_json (Melange_json.of_string {|{ "review_plugins": { "general": {} } }|}) in
  (check int) "omitted max_leads defaults to 10" 10 omitted.review_plugins.general.max_leads

let test_context_create_requires_repos_by_default () =
  let tmp_path = Filename.temp_file "reviewotron_secrets_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      write_file tmp_path {|{"repos": [], "anthropic_api_key": "sk-test"}|};
      match Context.create ~secrets_filepath:tmp_path () with
      | Ok _ -> fail "expected empty repos to be rejected by default"
      | Error msg -> (check bool) "mentions repos" true (CCString.find ~sub:"at least one repo" msg >= 0))

let test_context_create_allows_repo_less_when_explicit () =
  let tmp_path = Filename.temp_file "reviewotron_secrets_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      write_file tmp_path {|{"repos": [], "anthropic_api_key": "sk-test"}|};
      match Context.create ~secrets_filepath:tmp_path ~require_repos:false () with
      | Error msg -> fail msg
      | Ok ctx ->
        let secrets = Context.secrets ctx in
        (check int) "no repos" 0 (List.length secrets.repos);
        (check (option string)) "api key" (Some "sk-test") secrets.anthropic_api_key)

let test_context_create_reports_feedback_store_error () =
  let secrets_path = Filename.temp_file "reviewotron_secrets_" ".json" in
  let state_path = Filename.temp_file "reviewotron_state_" ".json" in
  let feedback_dir = Filename.temp_file "reviewotron_feedback_dir_" "" in
  let remove path =
    match Sys.file_exists path with
    | true -> Sys.remove path
    | false -> ()
  in
  Fun.protect
    ~finally:(fun () -> List.iter remove [ secrets_path; state_path; feedback_dir ])
    (fun () ->
      write_file secrets_path
        {|{"repos": [{"url": "https://github.com/org/repo", "gh_token": "tok"}], "anthropic_api_key": "sk-test"}|};
      write_file state_path {|{"repos": {}}|};
      match Context.create ~secrets_filepath:secrets_path ~state_filepath:state_path ~feedback_dir () with
      | Ok _ -> fail "expected invalid feedback dir to be reported"
      | Error msg ->
        (check bool) "mentions feedback store" true (contains_sub ~sub:"failed to initialize feedback store" msg);
        (check bool) "includes setup failure" true (contains_sub ~sub:"expected directory" msg))

let test_context_load_config_file () =
  let tmp_path = Filename.temp_file "reviewotron_config_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      write_file tmp_path {|{"max_diff_lines": 5000, "show_review_cost": true}|};
      match Context.load_config_file ~filepath:tmp_path with
      | Error msg -> fail msg
      | Ok config ->
        (check int) "max diff lines" 5000 config.max_diff_lines;
        (check bool) "show review cost" true config.show_review_cost)

let test_context_load_local_config_uses_defaults_when_missing () =
  let tmp_dir = Filename.temp_dir "reviewotron_config_" "_test" in
  Fun.protect
    ~finally:(fun () -> Sys.rmdir tmp_dir)
    (fun () ->
      match Context.load_local_config ~root:tmp_dir ~config_filename:Context.default_config_filename with
      | Error msg -> fail msg
      | Ok config -> (check int) "default max diff lines" 2000 config.max_diff_lines)

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
      always_analyze_vuln_classes = [ Xss ];
      triage_model_tier = Fast;
      analysis_model_tier = Standard;
      analysis_effort = Some Config_types.Effort.Medium;
      validator_model_tier = Strong;
      confidence_threshold = High;
      memory_max_tokens = 3000;
      metrics_artifacts = true;
      debug_artifacts = false;
    }
  in
  let json = Config_types.security_plugin_config_to_json cfg in
  let parsed = Config_types.security_plugin_config_of_json json in
  (check bool) "enabled" true parsed.enabled;
  (check int) "vuln_classes" 2 (List.length parsed.vuln_classes);
  (check int) "always_analyze_vuln_classes" 1 (List.length parsed.always_analyze_vuln_classes);
  (check int) "memory_max_tokens" 3000 parsed.memory_max_tokens;
  (check bool) "metrics_artifacts" true parsed.metrics_artifacts;
  (check bool) "debug_artifacts" false parsed.debug_artifacts;
  (check string) "confidence" "high" (Config_types.confidence_to_string parsed.confidence_threshold);
  (match parsed.analysis_effort with
  | Some Config_types.Effort.Medium -> ()
  | Some Config_types.Effort.Low | Some High | Some Xhigh | None -> fail "expected medium analysis effort");
  (check string) "validator tier" "strong" (Config_types.model_tier_to_string parsed.validator_model_tier)

(** {2 Review prompt tests} *)

let test_system_prompt_security_disabled () =
  let prompt = Review_prompt.system_prompt ~security_covered_elsewhere:false () in
  (check bool) "non-empty" true (String.length prompt > 0);
  (check bool) "contains focus" true (CCString.find ~sub:"Focus on:" prompt >= 0);
  (check bool) "mentions security in scope" true (CCString.find ~sub:"Security vulnerabilities" prompt >= 0);
  (check bool) "does not tell agent to skip security" true
    (CCString.find ~sub:"Do NOT emit findings on any of those topics" prompt < 0)

let test_system_prompt_security_enabled () =
  let prompt = Review_prompt.system_prompt ~security_covered_elsewhere:true () in
  (check bool) "non-empty" true (String.length prompt > 0);
  (check bool) "states scope" true (CCString.find ~sub:"Your scope is" prompt >= 0);
  (check bool) "does not include security in the focus list" true
    (CCString.find ~sub:"Security vulnerabilities (injection" prompt < 0);
  (check bool) "tells agent to skip security topics in any category" true
    (CCString.find ~sub:"Do NOT emit findings on any of those topics" prompt >= 0);
  (check bool) "names the specific topics that are out of scope" true
    (CCString.find ~sub:"command injection" prompt >= 0)

let test_system_prompt_dedup_guidelines () =
  let prompt = Review_prompt.system_prompt ~security_covered_elsewhere:true () in
  (check bool) "mentions same root cause" true (CCString.find ~sub:"same root cause" prompt >= 0);
  (check bool) "mentions summary for refactor suggestions" true
    (CCString.find ~sub:"recommended alternative implementation" prompt >= 0);
  (check bool) "mentions documentation nits" true (CCString.find ~sub:"documentation nits" prompt >= 0)

let test_system_prompt_override () =
  let custom = "You are a custom reviewer" in
  let prompt = Review_prompt.system_prompt ~override:custom ~security_covered_elsewhere:true () in
  (check string) "override used" custom prompt;
  let prompt2 = Review_prompt.system_prompt ~override:custom ~security_covered_elsewhere:false () in
  (check string) "override bypasses the security clause switch" custom prompt2

let test_build_user_message () =
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let msg = Review_prompt.build_user_message ~diff ~change_title:"Test change" ~change_description:"A test" () in
  (check bool) "has title" true (CCString.find ~sub:"## Change: Test change" msg >= 0);
  (check bool) "has diff" true (CCString.find ~sub:"## Diff" msg >= 0);
  (check bool) "has diff content" true (CCString.find ~sub:"let x = 1" msg >= 0)

let test_build_user_message_no_description () =
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let msg = Review_prompt.build_user_message ~diff ~change_title:"Test change" () in
  (check bool) "has title" true (CCString.find ~sub:"## Change: Test change" msg >= 0);
  (check bool) "has diff" true (CCString.find ~sub:"## Diff" msg >= 0)

let test_review_schema_valid () =
  let schema = Review_prompt.review_schema in
  let json_str = Yojson.Safe.to_string schema in
  (check bool) "has type" true (CCString.find ~sub:{|"type":"object"|} json_str >= 0);
  (check bool) "has properties" true (CCString.find ~sub:{|"properties"|} json_str >= 0);
  (check bool) "has required" true (CCString.find ~sub:{|"required"|} json_str >= 0);
  (check bool) "has summary" true (CCString.find ~sub:{|"summary"|} json_str >= 0);
  (check bool) "has findings" true (CCString.find ~sub:{|"findings"|} json_str >= 0);
  (check bool) "has failure scenario" true (CCString.find ~sub:{|"failure_scenario"|} json_str >= 0);
  (check bool) "has field descriptions" true (CCString.find ~sub:{|"description"|} json_str >= 0)

(** The system prompt must explicitly establish the workflow that separates
    reasoning from the human-facing comment.  Reasoning happens first, the
    verdict is decided, and only then is the comment articulated. *)
let test_system_prompt_workflow_section () =
  let prompt = Review_prompt.system_prompt ~security_covered_elsewhere:false () in
  (check bool) "prompt names the workflow" true (CCString.find ~sub:"Per-Finding Workflow" prompt >= 0);
  (check bool) "prompt instructs to reason first" true (CCString.find ~sub:"REASON" prompt >= 0);
  (check bool) "prompt instructs to decide a verdict" true (CCString.find ~sub:"VERDICT" prompt >= 0);
  (check bool) "prompt instructs to articulate the comment last" true (CCString.find ~sub:"ARTICULATE" prompt >= 0);
  (check bool) "prompt includes a signal/noise check" true (CCString.find ~sub:"SIGNAL CHECK" prompt >= 0);
  (check bool) "prompt asks for failure scenarios" true (CCString.find ~sub:"failure_scenario" prompt >= 0)

(** Specific hedging phrases that indicate the model resolved its own concern
    mid-message must be called out as banned in the message field. *)
let test_system_prompt_banned_patterns () =
  let prompt = Review_prompt.system_prompt ~security_covered_elsewhere:false () in
  (* Spot-check a few representative banned phrases. The exhaustive list lives in the prompt itself. *)
  (check bool) {|prompt bans "actually"|} true (CCString.find ~sub:{|"actually"|} prompt >= 0);
  (check bool) {|prompt bans "no bug here"|} true (CCString.find ~sub:{|"no bug here"|} prompt >= 0);
  (check bool) {|prompt bans "ignore this"|} true (CCString.find ~sub:{|"ignore this|} prompt >= 0)

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

let field_is_required_in_schema ~field required =
  List.exists
    (function
      | `String value -> String.equal value field
      | `Assoc _ | `Bool _ | `Float _ | `Int _ | `List _ | `Null -> false)
    required

let rec schema_requires_property ~property = function
  | `Assoc fields ->
    let current_object_requires_property =
      match List.assoc_opt "properties" fields, List.assoc_opt "required" fields with
      | Some (`Assoc properties), Some (`List required) ->
        List.mem_assoc property properties && field_is_required_in_schema ~field:property required
      | Some (`Assoc _), Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Null | `String _) | Some (`Assoc _), None ->
        false
      | Some (`Bool _ | `Float _ | `Int _ | `List _ | `Null | `String _), _ | None, _ -> false
    in
    current_object_requires_property || List.exists (fun (_, value) -> schema_requires_property ~property value) fields
  | `List values -> List.exists (schema_requires_property ~property) values
  | `Bool _ | `Float _ | `Int _ | `Null | `String _ -> false

let test_anthropic_structured_output_schemas_compatible () =
  let security_validator_schema = (Validator_agent.config ~model_tier:Standard).output_schema in
  let schemas : (string * Yojson.Basic.t) list =
    [
      "general_review", Review_types.review_output_jsonschema;
      "general_validator", Review_types.validator_output_jsonschema;
      "security_triage", Security_types.triage_output_jsonschema;
      "security_analysis", Security_types.analysis_output_jsonschema;
      "security_validator", security_validator_schema;
      "memory_curator", Security_types.curator_output_jsonschema;
    ]
  in
  let issues = schemas |> List.concat_map (fun (name, schema) -> collect_anthropic_schema_issues ~path:name schema) in
  match issues with
  | [] -> ()
  | _ ->
    let issue_preview = issues |> CCList.take 20 |> String.concat "\n" in
    fail (Printf.sprintf "generated structured output schemas violate Anthropic constraints:\n%s" issue_preview)

let test_security_validator_schema_requires_proof_key () =
  let cfg = Validator_agent.config ~model_tier:Standard in
  (check bool) "validator schema requires proof key" true
    (schema_requires_property ~property:"proof_by_construction" cfg.output_schema)

let test_prompt_token_estimation () =
  let system = Review_prompt.system_prompt ~security_covered_elsewhere:false () in
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let user = Review_prompt.build_user_message ~diff ~change_title:"Test" () in
  let estimate = Review_prompt.estimate_prompt_tokens ~system ~user in
  let char_count = String.length system + String.length user in
  (* Estimate should be roughly chars/4, within 2x *)
  (check bool) "estimate > 0" true (estimate > 0);
  (check bool) "estimate within 2x of chars/4" true (estimate <= char_count / 2);
  (check bool) "estimate at least chars/8" true (estimate >= char_count / 8)

(** {2 Dedup tests} *)

let mk_finding ~path ~line ?(end_line = None) ?(severity = Review_types.Warning) ?(category = Review_types.Security)
  ?(message = "msg") ?(failure_scenario = "scenario") ?(evidence_snippet = "snippet") ?(why_now = "changed in this PR")
  ?(confidence = Review_types.Medium) ?(suggested_fix = None) () : Review_types.finding =
  {
    path;
    line;
    end_line;
    severity;
    category;
    message;
    failure_scenario;
    evidence_snippet;
    why_now;
    confidence;
    suggested_fix;
  }

let finding_by_message msg (f : Review_types.finding) = String.equal f.message msg

let test_dedup_same_line_prefers_security () =
  let general = mk_finding ~path:"a.ml" ~line:10 ~message:"general" () in
  let security = mk_finding ~path:"a.ml" ~line:10 ~message:"security" () in
  let out = Reviewer.deduplicate_findings [ Reviewer.From_general, general; Reviewer.From_security, security ] in
  (check int) "single finding" 1 (List.length out);
  (check bool) "security wins" true (List.exists (finding_by_message "security") out)

let test_dedup_preserves_plugin_provenance () =
  let general = mk_finding ~path:"a.ml" ~line:10 ~message:"general" () in
  let security = mk_finding ~path:"a.ml" ~line:10 ~message:"security" () in
  let out =
    Review_engine.deduplicate_sourced_findings
      [
        Review_engine.{ source = From_general; plugin_name = "general"; finding = general };
        Review_engine.{ source = From_security; plugin_name = "security"; finding = security };
      ]
  in
  match out with
  | [ sourced ] ->
    (check string) "source" "security" (Review_engine.finding_source_to_string sourced.source);
    (check string) "plugin" "security" sourced.plugin_name;
    (check string) "finding" "security" sourced.finding.message
  | _ -> fail "expected one sourced finding"

let test_dedup_same_line_same_source_higher_severity_wins () =
  let low = mk_finding ~path:"a.ml" ~line:10 ~severity:Suggestion ~message:"low" () in
  let high = mk_finding ~path:"a.ml" ~line:10 ~severity:Critical ~message:"high" () in
  let out = Reviewer.deduplicate_findings [ Reviewer.From_general, low; Reviewer.From_general, high ] in
  (check int) "single finding" 1 (List.length out);
  (check bool) "higher severity wins" true (List.exists (finding_by_message "high") out)

let test_dedup_near_line_collapse_same_category () =
  let a = mk_finding ~path:"a.ml" ~line:8 ~severity:Warning ~message:"a" () in
  let b = mk_finding ~path:"a.ml" ~line:10 ~severity:Critical ~message:"b" () in
  let c = mk_finding ~path:"a.ml" ~line:30 ~severity:Warning ~message:"c" () in
  let out =
    Reviewer.deduplicate_findings [ Reviewer.From_general, a; Reviewer.From_general, b; Reviewer.From_general, c ]
  in
  (check int) "two findings (a+b collapsed, c kept)" 2 (List.length out);
  (check bool) "critical survives collapse" true (List.exists (finding_by_message "b") out);
  (check bool) "far-apart finding kept" true (List.exists (finding_by_message "c") out);
  (check bool) "weaker near-line dropped" false (List.exists (finding_by_message "a") out)

let test_dedup_near_line_rechecks_promoted_best () =
  let a = mk_finding ~path:"a.ml" ~line:8 ~severity:Warning ~message:"a" () in
  let b = mk_finding ~path:"a.ml" ~line:10 ~severity:Critical ~message:"b" () in
  let c = mk_finding ~path:"a.ml" ~line:13 ~severity:Warning ~message:"c" () in
  let out =
    Reviewer.deduplicate_findings [ Reviewer.From_general, a; Reviewer.From_general, b; Reviewer.From_general, c ]
  in
  (check int) "single finding after promoted best collapse" 1 (List.length out);
  (check bool) "promoted critical survives" true (List.exists (finding_by_message "b") out)

let test_dedup_near_line_different_category_both_kept () =
  let a = mk_finding ~path:"a.ml" ~line:8 ~category:Review_types.Security ~message:"a" () in
  let b = mk_finding ~path:"a.ml" ~line:10 ~category:Review_types.Performance ~message:"b" () in
  let out = Reviewer.deduplicate_findings [ Reviewer.From_general, a; Reviewer.From_general, b ] in
  (check int) "both kept" 2 (List.length out)

let test_dedup_security_not_near_line_collapsed () =
  (* Security-plugin findings are exempted from near-line collapse because the
     validator already filters for uniqueness. *)
  let a = mk_finding ~path:"a.ml" ~line:8 ~message:"a" () in
  let b = mk_finding ~path:"a.ml" ~line:10 ~message:"b" () in
  let out = Reviewer.deduplicate_findings [ Reviewer.From_security, a; Reviewer.From_security, b ] in
  (check int) "both kept" 2 (List.length out)

let test_dedup_sorts_by_path_then_line () =
  let a = mk_finding ~path:"b.ml" ~line:5 ~message:"b5" () in
  let b = mk_finding ~path:"a.ml" ~line:20 ~message:"a20" () in
  let c = mk_finding ~path:"a.ml" ~line:10 ~message:"a10" () in
  let out =
    Reviewer.deduplicate_findings [ Reviewer.From_general, a; Reviewer.From_general, b; Reviewer.From_general, c ]
  in
  let messages = List.map (fun (f : Review_types.finding) -> f.message) out in
  (check (list string)) "sorted by path then line" [ "a10"; "a20"; "b5" ] messages

(** {2 Multi-line inline comment tests}

    These tests cover the end_line plumbing from [Review_types.finding] through
    [Reviewer.finding_to_comment], and the hunk-range helpers in {!Diff_anchor}
    that guard multi-line emission. *)

(** A two-hunk diff on one file: hunk A at new_start=10 covers lines 10..14,
    hunk B at new_start=40 covers lines 40..43.  All additions so the right-side
    line ranges match [new_start, new_start + new_count - 1]. *)
let two_hunk_diff_text =
  "diff --git a/src/main.ml b/src/main.ml\n\
   --- a/src/main.ml\n\
   +++ b/src/main.ml\n\
   @@ -10,5 +10,5 @@\n\
   a\n\
   b\n\
   +c\n\
   +d\n\
   e\n\
   @@ -40,4 +40,4 @@\n\
   f\n\
   +g\n\
   +h\n\
   i\n"

let parsed_two_hunk_diff = Diff_parser.parse two_hunk_diff_text

let find_fd_exn diff path =
  match Diff_anchor.find_file_diff_by_path ~diff path with
  | Some fd -> fd
  | None -> Alcotest.fail (Printf.sprintf "expected to find file diff for %s" path)

let test_single_hunk_contains_valid_range () =
  let fd = find_fd_exn parsed_two_hunk_diff "src/main.ml" in
  (check bool) "range fully inside hunk A" true (Diff_anchor.single_hunk_contains fd ~start_line:10 ~end_line:14);
  (check bool) "range fully inside hunk B" true (Diff_anchor.single_hunk_contains fd ~start_line:40 ~end_line:43)

let test_single_hunk_contains_straddles_hunks () =
  let fd = find_fd_exn parsed_two_hunk_diff "src/main.ml" in
  (check bool) "range crossing hunks is rejected" false
    (Diff_anchor.single_hunk_contains fd ~start_line:12 ~end_line:41);
  (check bool) "range spanning gap is rejected" false (Diff_anchor.single_hunk_contains fd ~start_line:14 ~end_line:40)

(** Instantiate the reviewer against the in-memory api harness so we can call
    [finding_to_comment] without standing up a real GitHub client. *)
module R_anchor_test =
  Reviewer.Make (Api_local.Github) (Api_local.Github) (Api_local.Github) (Api_local.Agent_runner) (Api_local.Slack)

let test_finding_to_comment_multiline_valid () =
  let finding = mk_finding ~path:"src/main.ml" ~line:10 ~end_line:(Some 14) () in
  match R_anchor_test.finding_to_comment ~diff:parsed_two_hunk_diff finding with
  | None -> Alcotest.fail "expected a review comment"
  | Some c ->
    (check (option int)) "start_line = 10" (Some 10) c.start_line;
    (check (option int)) "line = 14" (Some 14) c.line;
    let side_is_right = function
      | Some Github_types.Right -> true
      | _ -> false
    in
    (check bool) "start_side = Some Right" true (side_is_right c.start_side);
    (check bool) "side = Some Right" true (side_is_right c.side)

let test_finding_to_comment_end_line_equals_line_is_single () =
  let finding = mk_finding ~path:"src/main.ml" ~line:10 ~end_line:(Some 10) () in
  match R_anchor_test.finding_to_comment ~diff:parsed_two_hunk_diff finding with
  | None -> Alcotest.fail "expected a review comment"
  | Some c ->
    (check (option int)) "no start_line" None c.start_line;
    (check (option int)) "line = 10" (Some 10) c.line

let test_finding_to_comment_end_line_lt_line_is_single () =
  let finding = mk_finding ~path:"src/main.ml" ~line:12 ~end_line:(Some 10) () in
  match R_anchor_test.finding_to_comment ~diff:parsed_two_hunk_diff finding with
  | None -> Alcotest.fail "expected a review comment"
  | Some c ->
    (check (option int)) "no start_line" None c.start_line;
    (check (option int)) "line = 12" (Some 12) c.line

let test_finding_to_comment_range_crosses_hunks_degrades () =
  let finding = mk_finding ~path:"src/main.ml" ~line:12 ~end_line:(Some 41) () in
  match R_anchor_test.finding_to_comment ~diff:parsed_two_hunk_diff finding with
  | None -> Alcotest.fail "expected a review comment"
  | Some c ->
    (check (option int)) "no start_line" None c.start_line;
    (* Anchor line 12 is in range, so it stays at 12; the range falls back. *)
    (check (option int)) "line = 12" (Some 12) c.line

let test_finding_to_comment_end_line_out_of_file_degrades () =
  let finding = mk_finding ~path:"src/main.ml" ~line:10 ~end_line:(Some 999) () in
  match R_anchor_test.finding_to_comment ~diff:parsed_two_hunk_diff finding with
  | None -> Alcotest.fail "expected a review comment"
  | Some c ->
    (check (option int)) "no start_line" None c.start_line;
    (check (option int)) "line = 10" (Some 10) c.line

let test_finding_to_comment_single_line_unchanged () =
  let finding = mk_finding ~path:"src/main.ml" ~line:10 ~end_line:None () in
  match R_anchor_test.finding_to_comment ~diff:parsed_two_hunk_diff finding with
  | None -> Alcotest.fail "expected a review comment"
  | Some c ->
    (check (option int)) "no start_line" None c.start_line;
    (check (option int)) "no start_side" None (Option.map (fun _ -> 0) c.start_side);
    (check (option int)) "line = 10" (Some 10) c.line

(** {2 Finding routing tests}

    These exercise the [route_finding] classifier that decides whether a
    finding becomes an inline comment, a "Findings on unchanged code" entry,
    or an "Anchor failed" entry. *)

let routing_is_positioned = function
  | R_anchor_test.Positioned _ -> true
  | _ -> false

let routing_is_file_not_in_diff = function
  | R_anchor_test.File_not_in_diff -> true
  | _ -> false

let routing_is_anchor_failed = function
  | R_anchor_test.Anchor_failed -> true
  | _ -> false

let test_route_finding_positioned () =
  let finding = mk_finding ~path:"src/main.ml" ~line:10 () in
  (check bool) "positioned" true
    (routing_is_positioned (R_anchor_test.route_finding ~diff:parsed_two_hunk_diff finding))

let test_route_finding_file_not_in_diff () =
  let finding = mk_finding ~path:"src/other.ml" ~line:5 () in
  (check bool) "file_not_in_diff" true
    (routing_is_file_not_in_diff (R_anchor_test.route_finding ~diff:parsed_two_hunk_diff finding))

let test_route_finding_non_positive_line_is_anchor_failed () =
  let finding = mk_finding ~path:"src/main.ml" ~line:0 () in
  (check bool) "anchor_failed" true
    (routing_is_anchor_failed (R_anchor_test.route_finding ~diff:parsed_two_hunk_diff finding))

(** A diff whose only hunk is deletion-only: the file is in the diff, but
    there is no right-side line to anchor a finding on.  [resolve_right_line]
    returns [None] and [route_finding] must classify this as Anchor_failed. *)
let deletion_only_diff_text =
  "diff --git a/src/gone.ml b/src/gone.ml\n\
   --- a/src/gone.ml\n\
   +++ b/src/gone.ml\n\
   @@ -1,2 +1,0 @@\n\
   -deleted a\n\
   -deleted b\n"

let parsed_deletion_only_diff = Diff_parser.parse deletion_only_diff_text

let test_route_finding_deletion_only_file_is_anchor_failed () =
  let finding = mk_finding ~path:"src/gone.ml" ~line:1 () in
  (check bool) "anchor_failed on deletion-only file" true
    (routing_is_anchor_failed (R_anchor_test.route_finding ~diff:parsed_deletion_only_diff finding))

(** {2 Fetched-file annotation tests} *)

let test_annotate_file_content_header_and_gutter () =
  let content = "line one\nline two\nline three" in
  let annotated = Diff_parser.annotate_file_content ~path:"src/foo.ml" content in
  let expected = "# File: src/foo.ml\n   1 |  line one\n   2 |  line two\n   3 |  line three" in
  (check string) "annotated output" expected annotated

let test_annotate_file_content_empty () =
  let annotated = Diff_parser.annotate_file_content ~path:"x" "" in
  (* String.split_on_char always yields at least one element. *)
  (check string) "empty body still gets header + one numbered empty line" "# File: x\n   1 |  " annotated

(** {2 Security finding anchor-snapping tests}

    These exercise [Security_review_plugin.Make().validated_to_finding] —
    specifically the case where the analysis agent's chosen sink lives in
    unchanged code but the flow chain traces through a changed line.  The
    anchor must snap onto the earliest in-diff evidence step, and the sink
    must be surfaced in the comment body. *)

module Sec_test = Security_review_plugin.Make (Api_local.Agent_runner)

(** Same two-hunk diff we use for the multi-line tests: file [src/main.ml]
    with hunks at [10..14] and [40..43]. *)
let parsed_anchor_diff = parsed_two_hunk_diff

let mk_validated ~source ~sink ~flow ?(vuln_class = Security_types.Authz) ?(sanitization = Security_types.Missing)
  ?(verdict = Security_types.Confirmed) ?(evidence_notes = "ok") ?proof_by_construction () :
  Security_types.validated_finding =
  {
    finding =
      {
        vuln_class;
        source;
        sink;
        flow;
        sanitization;
        confidence = High;
        description = "described vulnerability";
        suggested_fix = None;
      };
    verdict;
    evidence_notes;
    proof_by_construction;
  }

let src_site ~path ~line ~description : Security_types.source_evidence = { path; line; description }
let sink_site ~path ~line ~description : Security_types.sink_evidence = { path; line; description }
let flow_step ~path ~line ~description : Security_types.flow_step = { path; line; description }

let test_anchor_sink_in_diff_no_snap () =
  (* Sink is already in the diff (src/main.ml hunk A).  We must not snap; the
     finding's path/line should equal the sink and the message should NOT
     carry a "Related sink" prefix. *)
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/unrelated.ml" ~line:1 ~description:"src")
      ~sink:(sink_site ~path:"src/main.ml" ~line:11 ~description:"dangerous op")
      ~flow:[] ()
  in
  let f = Sec_test.validated_to_finding ~diff:parsed_anchor_diff vf in
  (check string) "path stays on sink" "src/main.ml" f.path;
  (check int) "line stays on sink" 11 f.line;
  (check bool) "no Related prefix in message" true (not (CCString.mem ~sub:"Related sink" f.message))

let test_anchor_sink_not_in_diff_flow_in_diff () =
  (* Sink is in an unchanged file; flow passes through src/main.ml:12.  The
     finding must snap to the flow step and the body must carry the sink
     location as "Related sink: ...". *)
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/entry.ml" ~line:1 ~description:"http param")
      ~sink:(sink_site ~path:"src/unchanged.ml" ~line:99 ~description:"unchecked authz")
      ~flow:
        [
          flow_step ~path:"src/entry.ml" ~line:2 ~description:"passed to handler";
          flow_step ~path:"src/main.ml" ~line:12 ~description:"defect introduced here";
          flow_step ~path:"src/unchanged.ml" ~line:50 ~description:"reaches guard";
        ]
      ()
  in
  let f = Sec_test.validated_to_finding ~diff:parsed_anchor_diff vf in
  (check string) "path snaps to flow step file" "src/main.ml" f.path;
  (check int) "line snaps to flow step line" 12 f.line;
  (check bool) "message has Related sink prefix" true (CCString.mem ~sub:"Related sink" f.message);
  (check bool) "message references sink path" true (CCString.mem ~sub:"src/unchanged.ml:99" f.message)

let test_anchor_nothing_in_diff_falls_through_to_sink () =
  (* All evidence is in unchanged files.  The anchor stays on the sink so the
     finding routes to the "Findings on unchanged code" section of the main
     review body. *)
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/a.ml" ~line:1 ~description:"src")
      ~sink:(sink_site ~path:"src/b.ml" ~line:10 ~description:"sink")
      ~flow:[ flow_step ~path:"src/c.ml" ~line:5 ~description:"via" ]
      ()
  in
  let f = Sec_test.validated_to_finding ~diff:parsed_anchor_diff vf in
  (check string) "path stays on sink" "src/b.ml" f.path;
  (check int) "line stays on sink" 10 f.line;
  (check bool) "no Related prefix (unsnapped)" true (not (CCString.mem ~sub:"Related sink" f.message))

let test_anchor_source_fallback_when_flow_empty () =
  (* Sink is not in diff and flow is empty; fall through to source.  Source
     lives in the diff, so the anchor lands there with the Related-sink
     enrichment. *)
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:40 ~description:"user input")
      ~sink:(sink_site ~path:"src/elsewhere.ml" ~line:500 ~description:"sink far away")
      ~flow:[] ()
  in
  let f = Sec_test.validated_to_finding ~diff:parsed_anchor_diff vf in
  (check string) "snaps to source path" "src/main.ml" f.path;
  (check int) "snaps to source line" 40 f.line;
  (check bool) "message carries Related sink" true (CCString.mem ~sub:"src/elsewhere.ml:500" f.message)

let test_anchor_end_line_derived_from_anchor_not_sink () =
  (* Sink is unchanged; flow traces through src/main.ml:10 AND src/main.ml:14
     (both inside hunk A).  After snapping to 10, end_line should extend to
     14 — derived relative to the chosen anchor, not the original sink. *)
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/entry.ml" ~line:1 ~description:"src")
      ~sink:(sink_site ~path:"src/unchanged.ml" ~line:99 ~description:"sink")
      ~flow:
        [
          flow_step ~path:"src/main.ml" ~line:10 ~description:"defect introduced";
          flow_step ~path:"src/main.ml" ~line:14 ~description:"still inside hunk A";
          flow_step ~path:"src/unchanged.ml" ~line:50 ~description:"continues";
        ]
      ()
  in
  let f = Sec_test.validated_to_finding ~diff:parsed_anchor_diff vf in
  (check string) "snapped path" "src/main.ml" f.path;
  (check int) "snapped line" 10 f.line;
  (check (option int)) "end_line extends to 14" (Some 14) f.end_line

(** {2 Candidate finding deduplication tests}

    Per-class analysis agents independently flag the same defect under different
    vuln_class labels (e.g. SQL injection in a [/search] endpoint also smells
    like authn or authz to neighbouring agents).  [dedup_candidates] collapses
    candidates that share the same [(sink.path, sink.line)] so the validator
    sees the strongest framing of each defect, exactly once. *)

let mk_candidate ~vuln_class ~sink_path ~sink_line ?(confidence = Security_types.High) ?(flow = []) ?(tag = "") () :
  Security_types.candidate_finding =
  {
    vuln_class;
    source = { path = "src/entry.ts"; line = 1; description = "user input " ^ tag };
    sink = { path = sink_path; line = sink_line; description = "sink " ^ tag };
    flow;
    sanitization = Missing;
    confidence;
    description = "candidate finding " ^ tag;
    suggested_fix = None;
  }

let mk_flow_step ~path ~line description : Security_types.flow_step = { path; line; description }

let test_dedup_collapses_same_sink_across_vuln_classes () =
  let candidates =
    [
      mk_candidate ~vuln_class:Injection ~sink_path:"src/routes/notes.ts" ~sink_line:99 ~confidence:Medium
        ~tag:"injection" ();
      mk_candidate ~vuln_class:Authn ~sink_path:"src/routes/notes.ts" ~sink_line:99 ~confidence:Low ~tag:"authn" ();
      mk_candidate ~vuln_class:Authz ~sink_path:"src/routes/notes.ts" ~sink_line:99 ~confidence:Medium ~tag:"authz" ();
      mk_candidate ~vuln_class:Xss ~sink_path:"src/routes/notes.ts" ~sink_line:99 ~confidence:High ~tag:"xss" ();
    ]
  in
  let deduped = Sec_test.dedup_candidates candidates in
  (check int) "collapses 4 → 1" 1 (List.length deduped);
  match deduped with
  | [ kept ] ->
    (check string) "highest confidence wins (xss High > Medium > Low)" "xss"
      (Security_types.vuln_class_to_string kept.vuln_class)
  | _ -> Alcotest.fail "expected exactly one finding after dedup"

let test_dedup_preserves_distinct_sinks () =
  (* Two real, separate defects: command-injection sources at admin.ts:19 *and*
     the actual exec call at debug.ts:7.  Both should survive. *)
  let candidates =
    [
      mk_candidate ~vuln_class:Command_injection ~sink_path:"src/lib/debug.ts" ~sink_line:7 ~tag:"exec" ();
      mk_candidate ~vuln_class:Command_injection ~sink_path:"src/routes/admin.ts" ~sink_line:19 ~tag:"route" ();
    ]
  in
  let deduped = Sec_test.dedup_candidates candidates in
  (check int) "two distinct sinks preserved" 2 (List.length deduped)

let test_dedup_tiebreak_prefers_longer_flow () =
  let short_flow = [ mk_flow_step ~path:"src/a.ts" ~line:5 "step 1" ] in
  let long_flow =
    [
      mk_flow_step ~path:"src/a.ts" ~line:5 "step 1";
      mk_flow_step ~path:"src/a.ts" ~line:9 "step 2";
      mk_flow_step ~path:"src/a.ts" ~line:14 "step 3";
    ]
  in
  let candidates =
    [
      mk_candidate ~vuln_class:Injection ~sink_path:"src/a.ts" ~sink_line:42 ~confidence:Medium ~flow:short_flow
        ~tag:"short" ();
      mk_candidate ~vuln_class:Authz ~sink_path:"src/a.ts" ~sink_line:42 ~confidence:Medium ~flow:long_flow ~tag:"long"
        ();
    ]
  in
  let deduped = Sec_test.dedup_candidates candidates in
  (check int) "collapses to one" 1 (List.length deduped);
  match deduped with
  | [ kept ] ->
    (check int) "longer flow wins on confidence tie" 3 (List.length kept.flow);
    (check string) "kept the longer-flow candidate" "authz" (Security_types.vuln_class_to_string kept.vuln_class)
  | _ -> Alcotest.fail "expected exactly one finding after dedup"

let test_dedup_tiebreak_first_seen_when_fully_tied () =
  let flow = [ mk_flow_step ~path:"src/a.ts" ~line:5 "step 1" ] in
  let candidates =
    [
      mk_candidate ~vuln_class:Injection ~sink_path:"src/a.ts" ~sink_line:42 ~confidence:High ~flow ~tag:"first" ();
      mk_candidate ~vuln_class:Authz ~sink_path:"src/a.ts" ~sink_line:42 ~confidence:High ~flow ~tag:"second" ();
    ]
  in
  let deduped = Sec_test.dedup_candidates candidates in
  match deduped with
  | [ kept ] ->
    (check string) "first-seen wins when confidence and flow tied" "injection"
      (Security_types.vuln_class_to_string kept.vuln_class)
  | _ -> Alcotest.fail "expected exactly one finding after dedup"

let test_dedup_empty () =
  let deduped = Sec_test.dedup_candidates [] in
  (check int) "empty in, empty out" 0 (List.length deduped)

let test_dedup_single_candidate_passthrough () =
  let c = mk_candidate ~vuln_class:Injection ~sink_path:"src/a.ts" ~sink_line:1 ~tag:"only" () in
  let deduped = Sec_test.dedup_candidates [ c ] in
  (check int) "single candidate passes through" 1 (List.length deduped)

(** {2 Review types tests} *)

let test_review_output_roundtrip () =
  let review : Review_types.review_output =
    {
      summary = "Looks good";
      findings =
        [
          {
            path = "src/main.ml";
            line = 42;
            end_line = None;
            severity = Warning;
            category = Error_handling;
            message = "Missing error handling";
            failure_scenario = "Bad input raises and escapes the caller.";
            evidence_snippet = "process input";
            why_now = "The changed call site now invokes process directly.";
            confidence = Review_types.High;
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
  (check string) "failure scenario" "Bad input raises and escapes the caller." f.failure_scenario;
  (check int) "finding line" 42 f.line

let test_mock_claude_response () =
  let json_str = read_file "mock_api_responses/claude/review_response.json" in
  let review = Review_types.review_output_of_json (Melange_json.of_string json_str) in
  (check int) "findings count" 3 (List.length review.findings);
  (check bool) "has summary" true (String.length review.summary > 0);
  (check bool) "has assessment" true (String.length review.overall_assessment > 0)

let test_scout_output_parse_two_leads () =
  let scout = Review_types.scout_output_of_json (read_json "mock_api_responses/scout/leads_two.json") in
  (check int) "leads count" 2 (List.length scout.leads);
  (check string) "skip note" "test-only churn in test/fixtures skipped" scout.skip_note;
  match scout.leads with
  | [ first; second ] ->
    (check string) "first path" "lib/session.ml" first.path;
    (check int) "first line" 42 first.line;
    (check (option int)) "first end_line" None first.end_line;
    (check string) "first hypothesis"
      "The session token is no longer validated before use after this refactor; check whether callers can now pass an \
       expired token through."
      first.hypothesis;
    (check string) "first category" "bug" (Review_types.finding_category_to_string first.category);
    (check string) "first confidence" "high" (Review_types.confidence_to_string first.confidence);
    (check string) "second path" "lib/retry.ml" second.path;
    (check int) "second line" 88 second.line;
    (check (option int)) "second end_line" (Some 95) second.end_line;
    (check string) "second category" "performance" (Review_types.finding_category_to_string second.category);
    (check string) "second confidence" "medium" (Review_types.confidence_to_string second.confidence)
  | _ -> fail "expected exactly two leads"

let test_scout_output_parse_empty_leads () =
  let scout = Review_types.scout_output_of_json (read_json "mock_api_responses/scout/leads_empty.json") in
  (check int) "leads count" 0 (List.length scout.leads);
  (check string) "skip note empty" "" scout.skip_note

let test_scout_output_parse_overflow_leads () =
  let scout = Review_types.scout_output_of_json (read_json "mock_api_responses/scout/leads_overflow.json") in
  (check int) "leads count" 12 (List.length scout.leads)

let test_scout_output_roundtrip () =
  let scout : Review_types.scout_output =
    {
      leads =
        [
          {
            path = "lib/foo.ml";
            line = 10;
            end_line = Some 15;
            hypothesis = "Guard removed on the error branch.";
            category = Review_types.Bug;
            confidence = Review_types.High;
          };
        ];
      skip_note = "nothing skipped";
    }
  in
  let json_str = Melange_json.to_string (Review_types.scout_output_to_json scout) in
  let parsed = Review_types.scout_output_of_json (Melange_json.of_string json_str) in
  (check int) "roundtrip leads count" 1 (List.length parsed.leads);
  (check string) "roundtrip skip_note" "nothing skipped" parsed.skip_note;
  let lead = List.hd parsed.leads in
  (check string) "roundtrip path" "lib/foo.ml" lead.path;
  (check int) "roundtrip line" 10 lead.line;
  (check (option int)) "roundtrip end_line" (Some 15) lead.end_line;
  (check string) "roundtrip hypothesis" "Guard removed on the error branch." lead.hypothesis;
  (check string) "roundtrip category" "bug" (Review_types.finding_category_to_string lead.category);
  (check string) "roundtrip confidence" "high" (Review_types.confidence_to_string lead.confidence)

let test_scout_output_parse_missing_skip_note_defaults_empty () =
  let json : Yojson.Basic.t =
    `Assoc
      [
        ( "leads",
          `List
            [
              `Assoc
                [
                  "path", `String "lib/session.ml";
                  "line", `Int 42;
                  "end_line", `Null;
                  "hypothesis", `String "The session token is no longer validated before use after this refactor.";
                  "category", `String "bug";
                  "confidence", `String "high";
                ];
            ] );
      ]
  in
  let scout = Review_types.scout_output_of_json json in
  (check int) "leads count" 1 (List.length scout.leads);
  (check string) "skip_note defaults to empty when absent" "" scout.skip_note

let test_scout_output_jsonschema_has_properties () =
  (check bool) "schema has properties" true
    (match Review_types.scout_output_jsonschema with
    | `Assoc fields -> List.exists (fun (k, _) -> String.equal k "properties") fields
    | _ -> false)

(** {2 General scout agent tests} *)

let scout_lead ~path ~line ~confidence : Review_types.scout_lead =
  { path; line; end_line = None; hypothesis = "hypothesis"; category = Review_types.Bug; confidence }

let test_general_scout_cap_leads_truncates () =
  let leads =
    [
      scout_lead ~path:"a.ml" ~line:1 ~confidence:High;
      scout_lead ~path:"b.ml" ~line:2 ~confidence:Low;
      scout_lead ~path:"c.ml" ~line:3 ~confidence:High;
      scout_lead ~path:"d.ml" ~line:4 ~confidence:Medium;
      scout_lead ~path:"e.ml" ~line:5 ~confidence:Low;
      scout_lead ~path:"f.ml" ~line:6 ~confidence:Medium;
      scout_lead ~path:"g.ml" ~line:7 ~confidence:High;
      scout_lead ~path:"h.ml" ~line:8 ~confidence:Medium;
      scout_lead ~path:"i.ml" ~line:9 ~confidence:Low;
      scout_lead ~path:"j.ml" ~line:10 ~confidence:Medium;
      scout_lead ~path:"k.ml" ~line:11 ~confidence:Low;
      scout_lead ~path:"l.ml" ~line:12 ~confidence:Low;
    ]
  in
  let capped = General_scout_agent.cap_leads ~max_leads:10 leads in
  (check int) "capped to max_leads" 10 (List.length capped);
  (* Highest-confidence first, relative order preserved within each band.
     Highs (a, c, g), then Mediums (d, f, h, j), then Lows (b, e, i) — the two
     lowest-confidence lows (k, l) are dropped. *)
  let paths = List.map (fun (l : Review_types.scout_lead) -> l.path) capped in
  (check (list string))
    "kept highest-confidence, stable within band"
    [ "a.ml"; "c.ml"; "g.ml"; "d.ml"; "f.ml"; "h.ml"; "j.ml"; "b.ml"; "e.ml"; "i.ml" ]
    paths

let test_general_scout_cap_leads_identity () =
  let leads =
    [
      scout_lead ~path:"a.ml" ~line:1 ~confidence:Low;
      scout_lead ~path:"b.ml" ~line:2 ~confidence:High;
      scout_lead ~path:"c.ml" ~line:3 ~confidence:Medium;
    ]
  in
  let capped = General_scout_agent.cap_leads ~max_leads:10 leads in
  (check int) "identity length" 3 (List.length capped);
  (* Fewer than max_leads: still stable-sorted by confidence, none dropped. *)
  let paths = List.map (fun (l : Review_types.scout_lead) -> l.path) capped in
  (check (list string)) "all kept, confidence-sorted" [ "b.ml"; "c.ml"; "a.ml" ] paths

let test_general_scout_build_input_order () =
  let input =
    General_scout_agent.build_input ~diff_text:"THE_DIFF_BODY" ~change_title:"THE_TITLE"
      ~change_description:"THE_DESCRIPTION" ()
  in
  (* First index at which [needle] occurs in [input]; -1 if absent. *)
  let idx needle =
    let n = String.length needle
    and h = String.length input in
    let rec scan i =
      match i > h - n with
      | true -> -1
      | false ->
      match String.equal (String.sub input i n) needle with
      | true -> i
      | false -> scan (i + 1)
    in
    scan 0
  in
  let i_title = idx "THE_TITLE" in
  let i_desc = idx "THE_DESCRIPTION" in
  let i_explainer = idx "## Diff Format" in
  let i_diff = idx "THE_DIFF_BODY" in
  (check bool) "contains title" true (Devkit.Stre.exists input "THE_TITLE");
  (check bool) "contains description" true (Devkit.Stre.exists input "THE_DESCRIPTION");
  (check bool) "contains explainer" true (Devkit.Stre.exists input "## Diff Format");
  (check bool) "contains diff" true (Devkit.Stre.exists input "THE_DIFF_BODY");
  (check bool) "title before description" true (i_title < i_desc);
  (check bool) "description before explainer" true (i_desc < i_explainer);
  (check bool) "explainer before diff" true (i_explainer < i_diff);
  (check bool) "no file contents section" false (Devkit.Stre.exists input "File Contents")

let test_general_scout_config_security_covered () =
  let cfg = General_scout_agent.config ~model_tier:Standard ~security_covered_elsewhere:true in
  (check string) "name" "general_scout" cfg.name;
  (check int) "max_steps" 1 cfg.max_steps;
  (check bool) "suppresses security leads" true (Devkit.Stre.exists cfg.system_prompt "do not duplicate it")

let test_general_scout_config_security_not_covered () =
  let cfg = General_scout_agent.config ~model_tier:Standard ~security_covered_elsewhere:false in
  (check string) "name" "general_scout" cfg.name;
  (check bool) "allows security leads" true (Devkit.Stre.exists cfg.system_prompt "category \"security\"")

(** {2 General deep reviewer agent tests} *)

(* First index at which [needle] occurs in [haystack]; -1 if absent. *)
let substr_index haystack needle =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan i =
    match i > h - n with
    | true -> -1
    | false ->
    match String.equal (String.sub haystack i n) needle with
    | true -> i
    | false -> scan (i + 1)
  in
  scan 0

let deep_lead ~path ~line ~confidence : Review_types.scout_lead =
  { path; line; end_line = None; hypothesis = "hypothesis"; category = Review_types.Bug; confidence }

let test_general_deep_reviewer_build_input_filters_and_orders () =
  let leads = [ deep_lead ~path:"a.ml" ~line:1 ~confidence:High; deep_lead ~path:"b.ml" ~line:2 ~confidence:Medium ] in
  let file_contents = [ "a.ml", "CONTENTS_OF_A"; "b.ml", "CONTENTS_OF_B"; "c.ml", "CONTENTS_OF_C" ] in
  let input =
    General_deep_reviewer_agent.build_input ~leads ~diff_text:"THE_DIFF_BODY" ~change_title:"THE_TITLE"
      ~change_description:"THE_DESCRIPTION" ~file_contents ()
  in
  (check bool) "includes file A contents" true (Devkit.Stre.exists input "CONTENTS_OF_A");
  (check bool) "includes file B contents" true (Devkit.Stre.exists input "CONTENTS_OF_B");
  (check bool) "excludes file C contents" false (Devkit.Stre.exists input "CONTENTS_OF_C");
  (check bool) "leads section header" true (Devkit.Stre.exists input "## Investigation Leads");
  (check bool) "lead numbered L0" true (Devkit.Stre.exists input "L0");
  (check bool) "lead numbered L1" true (Devkit.Stre.exists input "L1");
  let i_leads = substr_index input "## Investigation Leads" in
  let i_change = substr_index input "## Change" in
  let i_files = substr_index input "## Relevant File Contents" in
  let i_a = substr_index input "CONTENTS_OF_A" in
  let i_diff = substr_index input "THE_DIFF_BODY" in
  (check bool) "leads before change" true (i_leads < i_change);
  (check bool) "change before file contents" true (i_change < i_files);
  (check bool) "file contents before diff" true (i_a < i_diff);
  (* Diff is the final section, after file contents and the explainer. *)
  let i_diff_header = substr_index input "## Diff\n" in
  (check bool) "file contents before diff header" true (i_files < i_diff_header);
  (check bool) "diff header after file A contents" true (i_a < i_diff_header)

let test_general_deep_reviewer_build_input_dedups_paths () =
  let leads = [ deep_lead ~path:"a.ml" ~line:1 ~confidence:High; deep_lead ~path:"a.ml" ~line:9 ~confidence:Medium ] in
  let file_contents = [ "a.ml", "UNIQUE_A_BODY" ] in
  let input =
    General_deep_reviewer_agent.build_input ~leads ~diff_text:"diff" ~change_title:"t" ~change_description:"d"
      ~file_contents ()
  in
  (* Duplicate-path leads must include the file's contents exactly once. *)
  let first = substr_index input "UNIQUE_A_BODY" in
  (check bool) "contents present" true (first >= 0);
  let rest_start = first + String.length "UNIQUE_A_BODY" in
  let rest = String.sub input rest_start (String.length input - rest_start) in
  (check bool) "contents included once" false (Devkit.Stre.exists rest "UNIQUE_A_BODY")

let test_general_deep_reviewer_build_input_prefixed_lead_paths () =
  (* Scout leads copy paths verbatim from git-style diff headers, so they may
     carry an [a/] or [b/] prefix, while file_contents keys are bare paths.
     The match must be prefix-tolerant; the emitted header must still show the
     actual bare file_contents key. *)
  let leads =
    [
      deep_lead ~path:"b/lib/foo.ml" ~line:1 ~confidence:High; deep_lead ~path:"a/lib/baz.ml" ~line:2 ~confidence:Medium;
    ]
  in
  let file_contents =
    [ "lib/foo.ml", "CONTENTS_OF_FOO"; "lib/baz.ml", "CONTENTS_OF_BAZ"; "lib/qux.ml", "CONTENTS_OF_QUX" ]
  in
  let input =
    General_deep_reviewer_agent.build_input ~leads ~diff_text:"THE_DIFF_BODY" ~change_title:"THE_TITLE"
      ~change_description:"THE_DESCRIPTION" ~file_contents ()
  in
  (* This is the assertion that fails on the old exact-match code: a lead path
     of "b/lib/foo.ml" never equals the bare key "lib/foo.ml", so the contents
     section is dropped and this substring is absent. *)
  (check bool) "b/-prefixed lead matches bare key" true (Devkit.Stre.exists input "CONTENTS_OF_FOO");
  (check bool) "a/-prefixed lead matches bare key" true (Devkit.Stre.exists input "CONTENTS_OF_BAZ");
  (check bool) "unreferenced file excluded" false (Devkit.Stre.exists input "CONTENTS_OF_QUX");
  (* Display shows the actual bare file_contents key, not the prefixed lead form. *)
  (check bool) "header shows bare path" true (Devkit.Stre.exists input "### File: lib/foo.ml");
  (check bool) "header does not show prefixed path" false (Devkit.Stre.exists input "### File: b/lib/foo.ml")

let test_general_deep_reviewer_build_input_bare_lead_paths () =
  (* No regression: a bare lead path still matches a bare file_contents key. *)
  let leads = [ deep_lead ~path:"lib/bar.ml" ~line:1 ~confidence:High ] in
  let file_contents = [ "lib/bar.ml", "CONTENTS_OF_BAR" ] in
  let input =
    General_deep_reviewer_agent.build_input ~leads ~diff_text:"diff" ~change_title:"t" ~change_description:"d"
      ~file_contents ()
  in
  (check bool) "bare lead matches bare key" true (Devkit.Stre.exists input "CONTENTS_OF_BAR");
  (check bool) "header shows bare path" true (Devkit.Stre.exists input "### File: lib/bar.ml")

let test_general_deep_reviewer_build_input_a_dir_key_not_overstripped () =
  (* Repo with a top-level "a" dir: lead "b/a/foo.ml" strips to "a/foo.ml",
     which must match the bare key "a/foo.ml".  Normalizing the key too would
     strip it to "foo.ml" and drop the file's contents. *)
  let leads = [ deep_lead ~path:"b/a/foo.ml" ~line:1 ~confidence:High ] in
  let file_contents = [ "a/foo.ml", "CONTENTS_OF_A_FOO" ] in
  let input =
    General_deep_reviewer_agent.build_input ~leads ~diff_text:"diff" ~change_title:"t" ~change_description:"d"
      ~file_contents ()
  in
  (check bool) "lead b/a/foo.ml matches key a/foo.ml" true (Devkit.Stre.exists input "CONTENTS_OF_A_FOO")

let test_general_deep_reviewer_config_default () =
  let cfg = General_deep_reviewer_agent.config ~model_tier:Strong ~system_prompt_override:None in
  (check string) "name" "general_deep_review" cfg.name;
  (check int) "max_steps" 1 cfg.max_steps;
  (check (option int)) "thinking budget" (Some 4096) cfg.thinking_budget;
  (check bool) "uses normative prompt" true (Devkit.Stre.exists cfg.system_prompt "deep code reviewer")

let test_general_deep_reviewer_config_override () =
  let cfg = General_deep_reviewer_agent.config ~model_tier:Strong ~system_prompt_override:(Some "X") in
  (check string) "name" "general_deep_review" cfg.name;
  (check string) "override replaces prompt wholesale" "X" cfg.system_prompt

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
    [ Adequate, {|"adequate"|}; Inadequate, {|"inadequate"|}; Missing, {|"missing"|}; Unknown, {|"unknown"|} ]
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
            proof_by_construction =
              Some
                {
                  trigger = "GET /fetch?url=http://169.254.169.254/latest/meta-data/";
                  preconditions = [ "The fetch endpoint is reachable by an attacker" ];
                  source_to_sink_trace =
                    [
                      "lib/api.ml:10 reads url from user input";
                      "lib/api.ml:12 passes url to fetch_url";
                      "lib/http.ml:30 performs the HTTP GET request";
                    ];
                  missing_or_inadequate_control = "scheme and private-network allowlist validation";
                  expected_impact = "The server can be induced to request internal metadata endpoints.";
                  assumptions = [];
                };
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

let concrete_exploitation_proof () : Security_types.exploitation_proof =
  {
    trigger = "GET /documents/123?admin=true";
    preconditions = [ "Attacker is authenticated as a non-admin user" ];
    source_to_sink_trace =
      [
        "src/main.ml:10 reads the document id from the request";
        "src/main.ml:12 passes the id into the update path";
        "src/main.ml:14 updates the document without owner scoping";
      ];
    missing_or_inadequate_control = "owner-scoped authorization check";
    expected_impact = "The attacker can modify another user's document.";
    assumptions = [];
  }

let test_security_exploitation_proof_roundtrip () =
  let proof = concrete_exploitation_proof () in
  let parsed = roundtrip Security_types.exploitation_proof_to_json Security_types.exploitation_proof_of_json proof in
  (check string) "trigger" proof.trigger parsed.trigger;
  (check int) "trace steps" 3 (List.length parsed.source_to_sink_trace);
  (check bool) "proof is concrete" true (Security_review_plugin.proof_is_concrete parsed)

let test_security_exploitation_proof_rejects_vague_trace () =
  let proof = { (concrete_exploitation_proof ()) with source_to_sink_trace = [ "user input reaches sink" ] } in
  (check bool) "vague trace is not concrete" false (Security_review_plugin.proof_is_concrete proof)

let test_security_exploitation_proof_rejects_assumptions () =
  let proof =
    { (concrete_exploitation_proof ()) with assumptions = [ "Imported middleware is configured this way" ] }
  in
  (check bool) "unresolved assumptions are not concrete" false (Security_review_plugin.proof_is_concrete proof)

let test_security_enforce_confirmed_requires_proof () =
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "downgraded verdict" "rejected" (Security_types.validation_verdict_to_string enforced.verdict);
    (check bool) "evidence note explains proof violation" true
      (contains_sub ~sub:"proof_by_construction" enforced.evidence_notes)
  | _ -> fail "expected one enforced result"

let test_security_enforce_repairs_missing_proof_from_concrete_notes () =
  let vf =
    mk_validated
      ~source:(src_site ~path:"lib/auth/jwt_middleware.ml" ~line:22 ~description:"Authorization header")
      ~sink:(sink_site ~path:"lib/auth/jwt_middleware.ml" ~line:18 ~description:"returns Ok user_id")
      ~flow:
        [
          flow_step ~path:"lib/auth/jwt_middleware.ml" ~line:11 ~description:"decodes the JWT payload";
          flow_step ~path:"lib/auth/jwt_middleware.ml" ~line:14 ~description:"extracts sub";
        ]
      ~vuln_class:Security_types.Authn
      ~evidence_notes:
        "The diff shows lib/auth/jwt_middleware.ml:22 reading the Authorization header, lines 11-14 decoding the \
         payload, and lib/auth/jwt_middleware.ml:18 returning Ok user_id without reading exp or comparing it to time."
      ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "concrete missing proof stays confirmed" "confirmed"
      (Security_types.validation_verdict_to_string enforced.verdict);
    (check bool) "proof synthesized" true (Option.is_some enforced.proof_by_construction)
  | _ -> fail "expected one enforced result"

let test_security_enforce_does_not_repair_path_only_same_file_notes () =
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ~evidence_notes:"src/main.ml has no sanitizer on the source-to-sink path." ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "path-only same-file notes downgraded" "rejected"
      (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_enforce_does_not_repair_hedged_missing_proof () =
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ~evidence_notes:"The source might reach line 14, but this probably depends on an unknown assumption."
      ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "hedged missing proof downgraded" "rejected"
      (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_enforce_confirmed_rejects_empty_proof () =
  let proof = { (concrete_exploitation_proof ()) with trigger = " " } in
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ~proof_by_construction:proof ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "empty proof downgraded" "rejected" (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_enforce_confirmed_requires_source_and_sink_trace () =
  let proof =
    {
      (concrete_exploitation_proof ()) with
      source_to_sink_trace = [ "src/main.ml:10 reads request id"; "src/main.ml:12 passes request id onward" ];
    }
  in
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ~proof_by_construction:proof ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "missing sink trace downgraded" "rejected"
      (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_enforce_policy_regression_accepts_concrete_proof () =
  let proof : Security_types.exploitation_proof =
    {
      trigger = "Apply the sudoers change, then deploy runs `sudo /usr/bin/systemctl restart sshd.service`.";
      preconditions = [ "The deploy user receives this sudoers policy." ];
      source_to_sink_trace =
        [
          "ops/sudoers/deploy:5 source: deploy gets NOPASSWD for /usr/bin/systemctl";
          "ops/sudoers/deploy:5 sink: deploy can run systemctl as root without password";
        ];
      missing_or_inadequate_control = "missing command/unit/action allowlist on the NOPASSWD systemctl grant";
      expected_impact = "The deploy user can restart or control root services through systemctl.";
      assumptions = [];
    }
  in
  let vf =
    mk_validated ~vuln_class:Security_types.Policy_regression
      ~source:(src_site ~path:"ops/sudoers/deploy" ~line:5 ~description:"deploy NOPASSWD systemctl sudo grant")
      ~sink:(sink_site ~path:"ops/sudoers/deploy" ~line:5 ~description:"deploy can run systemctl as root")
      ~flow:
        [ flow_step ~path:"ops/sudoers/deploy" ~line:5 ~description:"sudoers policy grants root systemctl capability" ]
      ~proof_by_construction:proof ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "concrete policy proof stays confirmed" "confirmed"
      (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_enforce_policy_regression_rejects_vague_proof () =
  let proof : Security_types.exploitation_proof =
    {
      trigger = "Apply the policy change.";
      preconditions = [ "The policy is deployed." ];
      source_to_sink_trace =
        [ "ops/policy.yml:3 source: security relevant policy change"; "ops/policy.yml:4 sink: security impact" ];
      missing_or_inadequate_control = "missing security control";
      expected_impact = "Security posture is worse.";
      assumptions = [];
    }
  in
  let vf =
    mk_validated ~vuln_class:Security_types.Policy_regression
      ~source:(src_site ~path:"ops/policy.yml" ~line:3 ~description:"security relevant policy change")
      ~sink:(sink_site ~path:"ops/policy.yml" ~line:4 ~description:"security impact")
      ~flow:[ flow_step ~path:"ops/policy.yml" ~line:4 ~description:"policy effect" ]
      ~proof_by_construction:proof ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "vague policy proof downgraded" "rejected"
      (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_partial_proof_json_downgrades () =
  let candidate =
    mk_candidate ~vuln_class:Authz ~sink_path:"src/main.ml" ~sink_line:14
      ~flow:[ { path = "src/main.ml"; line = 12; description = "passed to update" } ]
      ()
  in
  let json =
    `Assoc
      [
        ( "results",
          `List
            [
              `Assoc
                [
                  "finding", Security_types.candidate_finding_to_json candidate;
                  "verdict", `String "confirmed";
                  "evidence_notes", `String "partial proof fixture";
                  "proof_by_construction", `Assoc [ "source_to_sink_trace", `List [ `String "src/main.ml:10" ] ];
                ];
            ] );
      ]
  in
  let output = Security_types.validator_output_of_json json in
  match Security_review_plugin.enforce_validator_proofs output.results with
  | [ enforced ] ->
    (check string) "partial proof downgraded" "rejected" (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_validator_result_count_mismatch_is_error () =
  let candidate = mk_candidate ~vuln_class:Injection ~sink_path:"src/main.ml" ~sink_line:14 () in
  let output : Security_types.validator_output = { results = [] } in
  match Security_review_plugin.validator_results_for_candidates ~candidate_findings:[ candidate ] output with
  | Ok _ -> fail "expected validator result-count mismatch to fail"
  | Error msg ->
    (check bool) "message includes result count" true (contains_sub ~sub:"returned 0 results" msg);
    (check bool) "message includes candidate count" true (contains_sub ~sub:"for 1 candidates" msg)

let test_security_enforce_rejected_without_proof_ok () =
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ~verdict:Security_types.Rejected ()
  in
  match Security_review_plugin.enforce_validator_proofs [ vf ] with
  | [ enforced ] ->
    (check string) "rejected remains rejected" "rejected" (Security_types.validation_verdict_to_string enforced.verdict)
  | _ -> fail "expected one enforced result"

let test_security_validated_to_finding_uses_proof_summary () =
  let proof = concrete_exploitation_proof () in
  let vf =
    mk_validated
      ~source:(src_site ~path:"src/main.ml" ~line:10 ~description:"request id")
      ~sink:(sink_site ~path:"src/main.ml" ~line:14 ~description:"document update")
      ~flow:[ flow_step ~path:"src/main.ml" ~line:12 ~description:"passed to update" ]
      ~proof_by_construction:proof ()
  in
  let finding = Sec_test.validated_to_finding ~diff:parsed_anchor_diff vf in
  (check bool) "failure scenario has trigger" true (contains_sub ~sub:"GET /documents/123" finding.failure_scenario);
  (check bool) "evidence snippet has trace" true (contains_sub ~sub:"src/main.ml:10" finding.evidence_snippet);
  (check bool) "why_now has missing control" true (contains_sub ~sub:"owner-scoped authorization check" finding.why_now)

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
  (* The tool wraps raw content with a [# File: <path>] header and a
     per-line gutter so the agent can anchor findings without counting. *)
  (check (option string)) "content is annotated" (Some "# File: lib/auth.ml\n   1 |  file content here") result.content;
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

let test_triage_agent_prompt_includes_policy_regression () =
  let cfg = Triage_agent.config ~model_tier:Fast in
  (check bool) "mentions class" true (Devkit.Stre.exists cfg.system_prompt "policy_regression");
  (check bool) "mentions sudo policy" true (Devkit.Stre.exists cfg.system_prompt "NOPASSWD");
  (check bool) "mentions CI permission broadening" true (Devkit.Stre.exists cfg.system_prompt "contents: write")

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

(** {2 Security artifact tests} *)

let artifact_security_dir debug_dir = Filename.concat debug_dir "security"
let artifact_path debug_dir filename = Filename.concat (artifact_security_dir debug_dir) filename

let remove_if_exists path = try Sys.remove path with Sys_error _ -> ()

let rmdir_if_exists path = try Unix.rmdir path with Unix.Unix_error _ -> ()

let cleanup_artifacts debug_dir filenames =
  List.iter (fun filename -> remove_if_exists (artifact_path debug_dir filename)) filenames;
  rmdir_if_exists (artifact_security_dir debug_dir);
  rmdir_if_exists debug_dir

let test_security_artifacts_disabled_writes_nothing () =
  let debug_dir = Filename.temp_dir "reviewotron_artifacts_disabled_" "_test" in
  Fun.protect
    ~finally:(fun () -> cleanup_artifacts debug_dir [ "manifest.json"; "metrics.json"; "triage_input.md" ])
    (fun () ->
      let artifacts = Security_artifacts.create ~debug_dir ~metrics_artifacts:false ~debug_artifacts:false in
      Security_artifacts.write_manifest artifacts ~repo_url:"https://github.com/org/repo";
      Security_artifacts.write_metrics artifacts (`Assoc [ "changed_file_count", `Int 1 ]);
      Security_artifacts.write_debug_text artifacts ~filename:"triage_input.md" "diff content";
      (check bool) "security artifact dir absent" false (Sys.file_exists (artifact_security_dir debug_dir)))

let test_security_artifacts_metrics_files () =
  let debug_dir = Filename.temp_dir "reviewotron_artifacts_metrics_" "_test" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_artifacts debug_dir [ "manifest.json"; "metrics.json"; "fetch_stats.json"; "triage_input.md" ])
    (fun () ->
      let artifacts = Security_artifacts.create ~debug_dir ~metrics_artifacts:true ~debug_artifacts:false in
      Security_artifacts.write_manifest artifacts ~repo_url:"https://github.com/org/repo";
      Security_artifacts.write_metrics artifacts
        (`Assoc [ "changed_file_count", `Int 1; "triage_signal_count", `Int 0; "agent_costs", `List [] ]);
      Security_artifacts.write_fetch_stats artifacts [];
      Security_artifacts.write_debug_text artifacts ~filename:"triage_input.md" "prompt body with diff content";
      (check bool) "manifest exists" true (Sys.file_exists (artifact_path debug_dir "manifest.json"));
      (check bool) "metrics exists" true (Sys.file_exists (artifact_path debug_dir "metrics.json"));
      (check bool) "fetch stats exists" true (Sys.file_exists (artifact_path debug_dir "fetch_stats.json"));
      (check bool) "debug input not written" false (Sys.file_exists (artifact_path debug_dir "triage_input.md"));
      let metrics = read_file (artifact_path debug_dir "metrics.json") in
      (check bool) "metrics omit prompt body" false (contains_sub ~sub:"prompt body" metrics);
      (check bool) "metrics omit diff body" false (contains_sub ~sub:"diff content" metrics))

let test_security_artifacts_debug_redacts () =
  let debug_dir = Filename.temp_dir "reviewotron_artifacts_debug_" "_test" in
  Fun.protect
    ~finally:(fun () -> cleanup_artifacts debug_dir [ "triage_input.md" ])
    (fun () ->
      let artifacts = Security_artifacts.create ~debug_dir ~metrics_artifacts:false ~debug_artifacts:true in
      let secret_text =
        "Authorization: Bearer abcdef1234567890\n\
         OPENROUTER_API_KEY=sk-or-abcdefghi\n\
         {\"password\":\"hunter2\"}\n\
         {\"opaque\":\"0123456789abcdef0123456789abcdef\"}\n\
         \"backend/clickhouse/querybuilding/gen_schema/clickhouse_schema\""
      in
      Security_artifacts.write_debug_text artifacts ~filename:"triage_input.md" secret_text;
      let written = read_file (artifact_path debug_dir "triage_input.md") in
      (check bool) "bearer value redacted" false (contains_sub ~sub:"abcdef1234567890" written);
      (check bool) "api key redacted" false (contains_sub ~sub:"sk-or-abcdefghi" written);
      (check bool) "password value redacted" false (contains_sub ~sub:"hunter2" written);
      (check bool) "opaque value redacted" false (contains_sub ~sub:"0123456789abcdef0123456789abcdef" written);
      (check bool) "path value preserved" true
        (contains_sub ~sub:"backend/clickhouse/querybuilding/gen_schema/clickhouse_schema" written))

let test_security_artifacts_write_failure_best_effort () =
  let debug_file = Filename.temp_file "reviewotron_artifacts_file_" "_test" in
  Fun.protect
    ~finally:(fun () -> remove_if_exists debug_file)
    (fun () ->
      let artifacts = Security_artifacts.create ~debug_dir:debug_file ~metrics_artifacts:true ~debug_artifacts:true in
      Security_artifacts.write_manifest artifacts ~repo_url:"https://github.com/org/repo";
      Security_artifacts.write_metrics artifacts (`Assoc [ "changed_file_count", `Int 1 ]);
      Security_artifacts.write_debug_text artifacts ~filename:"triage_input.md" "content";
      (check bool) "write failure did not raise" true true)

(** {2 Deterministic security signal tests} *)

let signal_has ?hint ~category ~path ~line ~pattern_sub signals =
  let start_line = line in
  let end_line = line in
  List.exists
    (fun (signal : Security_types.candidate_signal) ->
      let category_matches =
        String.equal
          (Security_types.signal_category_to_string category)
          (Security_types.signal_category_to_string signal.category)
      in
      let hint_matches =
        match hint, signal.vuln_class_hint with
        | Some expected, Some actual -> Security_review_plugin.vuln_class_equal expected actual
        | None, None -> true
        | Some _, None | None, Some _ -> false
      in
      category_matches
      && hint_matches
      && String.equal path signal.path
      && Int.equal start_line signal.start_line
      && Int.equal end_line signal.end_line
      && contains_sub ~sub:pattern_sub signal.pattern)
    signals

let signal_has_range ?hint ~category ~path ~start_line ~end_line ~pattern_sub signals =
  List.exists
    (fun (signal : Security_types.candidate_signal) ->
      let category_matches =
        String.equal
          (Security_types.signal_category_to_string category)
          (Security_types.signal_category_to_string signal.category)
      in
      let hint_matches =
        match hint, signal.vuln_class_hint with
        | Some expected, Some actual -> Security_review_plugin.vuln_class_equal expected actual
        | None, None -> true
        | Some _, None | None, Some _ -> false
      in
      category_matches
      && hint_matches
      && String.equal path signal.path
      && Int.equal start_line signal.start_line
      && Int.equal end_line signal.end_line
      && contains_sub ~sub:pattern_sub signal.pattern)
    signals

let signal_diff =
  {|diff --git a/src/routes/admin.ts b/src/routes/admin.ts
--- a/src/routes/admin.ts
+++ b/src/routes/admin.ts
@@ -8,0 +10,5 @@
+const sql = "SELECT * FROM users WHERE id = " + req.query.id;
+profile.innerHTML = profile.bio;
+authorize(user);
+balance += credits;
+fetch(req.query.url);
|}

let test_security_diff_signal_dangerous_apis_and_lines () =
  let signals = Security_diff_signal.scan (Diff_parser.parse signal_diff) in
  (check bool) "raw SQL signal at line 10" true
    (signal_has ~hint:Security_types.Injection ~category:Security_types.Dangerous_api ~path:"src/routes/admin.ts"
       ~line:10 ~pattern_sub:"raw SQL" signals);
  (check bool) "HTML sink signal at line 11" true
    (signal_has ~hint:Security_types.Xss ~category:Security_types.Dangerous_api ~path:"src/routes/admin.ts" ~line:11
       ~pattern_sub:"HTML" signals);
  (check bool) "outbound fetch signal at line 14" true
    (signal_has ~hint:Security_types.Ssrf ~category:Security_types.Dangerous_api ~path:"src/routes/admin.ts" ~line:14
       ~pattern_sub:"outbound" signals)

let test_security_diff_signal_path_control_and_stateful () =
  let signals = Security_diff_signal.scan (Diff_parser.parse signal_diff) in
  (check bool) "risky admin path" true
    (signal_has ~hint:Security_types.Authz ~category:Security_types.Risky_path ~path:"src/routes/admin.ts" ~line:10
       ~pattern_sub:"admin" signals);
  (check bool) "sensitive route file" true
    (signal_has ~category:Security_types.Sensitive_file ~path:"src/routes/admin.ts" ~line:10 ~pattern_sub:"route"
       signals);
  (check bool) "changed security control" true
    (signal_has ~category:Security_types.Changed_security_control ~path:"src/routes/admin.ts" ~line:12
       ~pattern_sub:"security control" signals);
  (check bool) "stateful operation" true
    (signal_has ~category:Security_types.Stateful_operation ~path:"src/routes/admin.ts" ~line:13 ~pattern_sub:"stateful"
       signals)

let test_security_diff_signal_sensitive_files () =
  let diff_text =
    {|diff --git a/.github/workflows/deploy.yml b/.github/workflows/deploy.yml
--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -1,0 +1,1 @@
+name: deploy
diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -1,0 +1,1 @@
+{"scripts":{"start":"node server.js"}}
|}
  in
  let signals = Security_diff_signal.scan (Diff_parser.parse diff_text) in
  (check bool) "workflow sensitive file" true
    (signal_has ~category:Security_types.Sensitive_file ~path:".github/workflows/deploy.yml" ~line:1
       ~pattern_sub:"workflow" signals);
  (check bool) "package manifest sensitive file" true
    (signal_has ~category:Security_types.Sensitive_file ~path:"package.json" ~line:1 ~pattern_sub:"package" signals)

let test_security_diff_signal_policy_regression_patterns () =
  let diff_text =
    {|diff --git a/modules/sudo/manifests/deploy.pp b/modules/sudo/manifests/deploy.pp
--- a/modules/sudo/manifests/deploy.pp
+++ b/modules/sudo/manifests/deploy.pp
@@ -0,0 +1,1 @@
+deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl
diff --git a/infra/iam/admin.yml b/infra/iam/admin.yml
--- a/infra/iam/admin.yml
+++ b/infra/iam/admin.yml
@@ -0,0 +10,1 @@
+Action: *
diff --git a/k8s/workload.yml b/k8s/workload.yml
--- a/k8s/workload.yml
+++ b/k8s/workload.yml
@@ -0,0 +20,1 @@
+  privileged: true
diff --git a/.github/workflows/deploy.yml b/.github/workflows/deploy.yml
--- a/.github/workflows/deploy.yml
+++ b/.github/workflows/deploy.yml
@@ -0,0 +30,1 @@
+permissions: write-all
diff --git a/src/client.py b/src/client.py
--- a/src/client.py
+++ b/src/client.py
@@ -0,0 +40,1 @@
+requests.get(url, verify=False)
|}
  in
  let signals = Security_diff_signal.scan (Diff_parser.parse diff_text) in
  (check bool) "sudo policy signal" true
    (signal_has ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"modules/sudo/manifests/deploy.pp" ~line:1 ~pattern_sub:"sudo" signals);
  (check bool) "IAM wildcard signal" true
    (signal_has ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"infra/iam/admin.yml" ~line:10 ~pattern_sub:"IAM/RBAC" signals);
  (check bool) "Kubernetes privileged signal" true
    (signal_has ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"k8s/workload.yml" ~line:20 ~pattern_sub:"Kubernetes" signals);
  (check bool) "CI permission signal" true
    (signal_has ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:".github/workflows/deploy.yml" ~line:30 ~pattern_sub:"CI token" signals);
  (check bool) "control weakening signal" true
    (signal_has ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"src/client.py" ~line:40 ~pattern_sub:"security control weakening" signals)

let test_security_diff_signal_multiline_policy_wildcards () =
  let diff_text =
    {|diff --git a/k8s/rbac.yml b/k8s/rbac.yml
--- a/k8s/rbac.yml
+++ b/k8s/rbac.yml
@@ -0,0 +10,4 @@
+verbs:
+  - "*"
+resources:
+  - "*"
diff --git a/infra/iam/policy.tf b/infra/iam/policy.tf
--- a/infra/iam/policy.tf
+++ b/infra/iam/policy.tf
@@ -0,0 +20,3 @@
+actions = [
+  "*",
+]
diff --git a/infra/iam/existing.yml b/infra/iam/existing.yml
--- a/infra/iam/existing.yml
+++ b/infra/iam/existing.yml
@@ -30,3 +30,4 @@
 actions:
   - "s3:GetObject"
+  - "*"
|}
  in
  let signals = Security_diff_signal.scan (Diff_parser.parse diff_text) in
  (check bool) "kubernetes verbs wildcard range" true
    (signal_has_range ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"k8s/rbac.yml" ~start_line:10 ~end_line:11 ~pattern_sub:"multiline wildcard" signals);
  (check bool) "kubernetes resources wildcard range" true
    (signal_has_range ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"k8s/rbac.yml" ~start_line:12 ~end_line:13 ~pattern_sub:"multiline wildcard" signals);
  (check bool) "terraform actions wildcard range" true
    (signal_has_range ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"infra/iam/policy.tf" ~start_line:20 ~end_line:21 ~pattern_sub:"multiline wildcard" signals);
  (check bool) "existing key added wildcard anchors changed line" true
    (signal_has_range ~hint:Security_types.Policy_regression ~category:Security_types.Changed_security_control
       ~path:"infra/iam/existing.yml" ~start_line:32 ~end_line:32 ~pattern_sub:"multiline wildcard" signals)

let test_security_diff_signal_empty_for_safe_diff () =
  let diff_text =
    {|diff --git a/src/widgets/view.ts b/src/widgets/view.ts
--- a/src/widgets/view.ts
+++ b/src/widgets/view.ts
@@ -1,0 +1,2 @@
+const label = "hello";
+console.log(label);
|}
  in
  let signals = Security_diff_signal.scan (Diff_parser.parse diff_text) in
  (check int) "no deterministic signals" 0 (List.length signals)

let test_triage_agent_build_input_with_deterministic_signals () =
  let signals = Security_diff_signal.scan (Diff_parser.parse signal_diff) in
  let input =
    Triage_agent.build_input ~diff_text:"diff content" ~file_paths:[ "src/routes/admin.ts" ]
      ~deterministic_signals:signals ()
  in
  (check bool) "has deterministic section" true (contains_sub ~sub:"Deterministic Diff Signal Summary" input);
  (check bool) "has total count" true (contains_sub ~sub:"Total native scanner hints:" input);
  (check bool) "has category summary" true (contains_sub ~sub:"By category:" input);
  (check bool) "has class summary" true (contains_sub ~sub:"By vulnerability-class hint:" input);
  (check bool) "has capped exact hints" true (contains_sub ~sub:"Strongest exact hints" input);
  (check bool) "states hints not findings" true (contains_sub ~sub:"hints, not findings" input);
  (check bool) "contains signal path" true (contains_sub ~sub:"src/routes/admin.ts:10" input)

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
    (List.for_all (fun vc -> vuln_class_equal vc vc) Config_types.all_vuln_classes)

let test_security_should_analyze_above_threshold () =
  let security_config = Config_types.default_security_plugin_config in
  (* Default threshold is Medium. High and Medium should always trigger. *)
  let high_signal = make_triage_signal ~vuln_class:Injection ~confidence:High in
  let medium_signal = make_triage_signal ~vuln_class:Xss ~confidence:Medium in
  (check bool) "High >= Medium threshold" true (Security_review_plugin.should_analyze ~security_config high_signal);
  (check bool) "Medium >= Medium threshold" true (Security_review_plugin.should_analyze ~security_config medium_signal)

let test_security_should_analyze_below_threshold_in_config () =
  let security_config =
    { Config_types.default_security_plugin_config with always_analyze_vuln_classes = [ Injection ] }
  in
  (* Low signal for an explicitly always-analyzed enabled class should trigger. *)
  let low_signal = make_triage_signal ~vuln_class:Injection ~confidence:Low in
  (check bool) "Low in always_analyze_vuln_classes" true
    (Security_review_plugin.should_analyze ~security_config low_signal)

let test_security_should_analyze_below_threshold_not_in_config () =
  let security_config = { Config_types.default_security_plugin_config with vuln_classes = [ Xss; Ssrf ] } in
  (* Classes that appear in neither vuln_classes nor always_analyze_vuln_classes never trigger. *)
  let low_injection = make_triage_signal ~vuln_class:Injection ~confidence:Low in
  (check bool) "Low disabled class" false (Security_review_plugin.should_analyze ~security_config low_injection);
  let high_injection = make_triage_signal ~vuln_class:Injection ~confidence:High in
  (check bool) "High disabled class" false (Security_review_plugin.should_analyze ~security_config high_injection);
  (* Low for an enabled class still stays below the threshold unless it is explicitly always-analyzed. *)
  let low_xss = make_triage_signal ~vuln_class:Xss ~confidence:Low in
  (check bool) "Low enabled class below threshold" false
    (Security_review_plugin.should_analyze ~security_config low_xss)

let test_security_always_analyze_implies_enabled () =
  (* A class listed only in always_analyze_vuln_classes (absent from vuln_classes)
     must still trigger — otherwise the override is silently dead. *)
  let security_config =
    {
      Config_types.default_security_plugin_config with
      vuln_classes = [ Xss ];
      always_analyze_vuln_classes = [ Injection ];
    }
  in
  let low_injection = make_triage_signal ~vuln_class:Injection ~confidence:Low in
  (check bool) "Low always_analyze-only class triggers" true
    (Security_review_plugin.should_analyze ~security_config low_injection);
  let high_injection = make_triage_signal ~vuln_class:Injection ~confidence:High in
  (check bool) "High always_analyze-only class triggers" true
    (Security_review_plugin.should_analyze ~security_config high_injection)

let test_security_should_analyze_high_threshold () =
  let security_config = { Config_types.default_security_plugin_config with confidence_threshold = High } in
  (* With High threshold, only High triggers unconditionally. *)
  let high_signal = make_triage_signal ~vuln_class:Injection ~confidence:High in
  let medium_signal = make_triage_signal ~vuln_class:Injection ~confidence:Medium in
  (check bool) "High >= High threshold" true (Security_review_plugin.should_analyze ~security_config high_signal);
  (* Medium is below High threshold, even though Injection is enabled. *)
  (check bool) "Medium < High threshold" false (Security_review_plugin.should_analyze ~security_config medium_signal)

let test_security_should_analyze_high_threshold_restricted () =
  let security_config =
    { Config_types.default_security_plugin_config with confidence_threshold = High; vuln_classes = [ Xss ] }
  in
  (* Medium confidence for Injection (not enabled) should not trigger. *)
  let medium_injection = make_triage_signal ~vuln_class:Injection ~confidence:Medium in
  (check bool) "Medium disabled class" false (Security_review_plugin.should_analyze ~security_config medium_injection);
  (* High confidence does not bypass disabled classes. *)
  let high_injection = make_triage_signal ~vuln_class:Injection ~confidence:High in
  (check bool) "High disabled class" false (Security_review_plugin.should_analyze ~security_config high_injection)

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

let test_security_standard_tier_uses_sonnet_5 () =
  let tier = Security_review_plugin.agent_model_tier Config_types.default_security_plugin_config.analysis_model_tier in
  (check string) "security standard tier" "claude-sonnet-5" (Agent_runner.default_model_id tier)

let test_security_analysis_step_budget () =
  let high_authn = make_triage_signal ~vuln_class:Authn ~confidence:High in
  let medium_authn = make_triage_signal ~vuln_class:Authn ~confidence:Medium in
  let low_authn = make_triage_signal ~vuln_class:Authn ~confidence:Low in
  let high_injection = make_triage_signal ~vuln_class:Injection ~confidence:High in
  let medium_policy = make_triage_signal ~vuln_class:Policy_regression ~confidence:Medium in
  (check int) "high authn gets deep budget" 12
    (Security_review_plugin.analysis_step_budget ~vuln_class:Authn ~triage_signals:[ high_authn ]);
  (check int) "medium authn is bounded" 9
    (Security_review_plugin.analysis_step_budget ~vuln_class:Authn ~triage_signals:[ medium_authn ]);
  (check int) "low authn is short" 7
    (Security_review_plugin.analysis_step_budget ~vuln_class:Authn ~triage_signals:[ low_authn ]);
  (check int) "high injection is local" 10
    (Security_review_plugin.analysis_step_budget ~vuln_class:Injection ~triage_signals:[ high_injection ]);
  (check int) "medium policy is diff-local" 5
    (Security_review_plugin.analysis_step_budget ~vuln_class:Policy_regression ~triage_signals:[ medium_policy ]);
  (check int) "multiple signals add capped headroom" 12
    (Security_review_plugin.analysis_step_budget ~vuln_class:Authn
       ~triage_signals:[ high_authn; high_authn; high_authn; high_authn; high_authn ])

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
  (check int) "max_steps" 15 cfg.max_steps;
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
  let policy = Analysis_agent.config ~vuln_class:Policy_regression ~model_tier:Standard ~language_hints:[] in
  (check string) "injection name" "security_analysis_injection" injection.name;
  (check string) "xss name" "security_analysis_xss" xss.name;
  (check string) "cmd name" "security_analysis_command_injection" cmd.name;
  (check string) "authn name" "security_analysis_authn" authn.name;
  (check string) "authz name" "security_analysis_authz" authz.name;
  (check string) "ssrf name" "security_analysis_ssrf" ssrf.name;
  (check string) "policy name" "security_analysis_policy_regression" policy.name;
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
  (check bool) "get_file_content tool" true (Devkit.Stre.exists cfg.system_prompt "get_file_content");
  (check bool) "policy proof model" true (Devkit.Stre.exists cfg.system_prompt "policy/control state")

let test_analysis_agent_prompt_fetch_economy () =
  let cfg = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  (check bool) "requires concrete hypothesis" true (Devkit.Stre.exists cfg.system_prompt "concrete hypothesis");
  (check bool) "forbids speculative fetches" true (Devkit.Stre.exists cfg.system_prompt "speculatively.");
  (check bool) "prefers conclusion" true (Devkit.Stre.exists cfg.system_prompt "supported conclusion")

let test_analysis_agent_prompt_contains_class_section () =
  let injection = Analysis_agent.config ~vuln_class:Injection ~model_tier:Standard ~language_hints:[] in
  let xss = Analysis_agent.config ~vuln_class:Xss ~model_tier:Standard ~language_hints:[] in
  let cmd = Analysis_agent.config ~vuln_class:Command_injection ~model_tier:Standard ~language_hints:[] in
  let authn = Analysis_agent.config ~vuln_class:Authn ~model_tier:Standard ~language_hints:[] in
  let authz = Analysis_agent.config ~vuln_class:Authz ~model_tier:Standard ~language_hints:[] in
  let ssrf = Analysis_agent.config ~vuln_class:Ssrf ~model_tier:Standard ~language_hints:[] in
  let policy = Analysis_agent.config ~vuln_class:Policy_regression ~model_tier:Standard ~language_hints:[] in
  (check bool) "injection section" true (Devkit.Stre.exists injection.system_prompt "SQL/Query Injection");
  (check bool) "xss section" true (Devkit.Stre.exists xss.system_prompt "Cross-Site Scripting");
  (check bool) "cmd section" true (Devkit.Stre.exists cmd.system_prompt "Command Injection");
  (check bool) "authn section" true (Devkit.Stre.exists authn.system_prompt "Authentication");
  (check bool) "authz section" true (Devkit.Stre.exists authz.system_prompt "Authorization");
  (check bool) "ssrf section" true (Devkit.Stre.exists ssrf.system_prompt "Server-Side Request Forgery");
  (check bool) "policy section" true (Devkit.Stre.exists policy.system_prompt "Security Policy Regression");
  (check bool) "policy source model" true (Devkit.Stre.exists policy.system_prompt "changed principal")

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
  (check bool) "contains analysis scope" true (Devkit.Stre.exists input "Analysis Scope");
  (check bool) "contains analysis question" true
    (Devkit.Stre.exists input "Can any flagged externally controlled value");
  (check bool) "no repository security context section" false (Devkit.Stre.exists input "Repository Security Context")

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
  (check bool) "step 4" true (Devkit.Stre.exists methodology "Step 4");
  (check bool) "requires rendering sink input verbatim" true
    (Devkit.Stre.exists methodology "Render the sink's actual input")

let test_analysis_agent_vuln_class_section_all_classes () =
  let classes : Security_types.vuln_class list =
    [ Injection; Xss; Command_injection; Authn; Authz; Ssrf; Policy_regression ]
  in
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

module R_test =
  Reviewer.Make (Api_local.Github) (Api_local.Github) (Api_local.Github) (Api_local.Agent_runner) (Api_local.Slack)

let test_pr_review_e2e () =
  Test_helpers.reset_test_state ();
  (* Scout pipeline is on by default: route the scout to leads and the deep
     reviewer to the same review fixture the legacy single-pass agent used, so
     the downstream filter/validator behavior (and these assertions) are
     unchanged. *)
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  let eyes_pos = CCString.find ~sub:"[create_issue_reaction]" write_log in
  let delete_pos = CCString.find ~sub:"[delete_issue_reaction]" write_log in
  let review_pos = CCString.find ~sub:"[create_pr_review]" write_log in
  (check bool) "progress reaction added" true (eyes_pos >= 0);
  (check bool) "progress reaction removed before review" true (delete_pos > eyes_pos && review_pos > delete_pos);
  (check bool) "review posted" true (review_pos >= 0);
  (check bool) "correct repo" true (contains_sub ~sub:"repo=https://github.com/org/monorepo" write_log);
  (check bool) "correct PR number" true (contains_sub ~sub:"number=42" write_log);
  (check bool) "deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
  (* The internal summary trace must never leak into the consumer body. *)
  (check bool) "summary not published" false (contains_sub ~sub:"The changes look generally good" write_log);
  (check bool) "asks for feedback" true (contains_sub ~sub:Review_format.feedback_prompt write_log);
  (check bool) "asks for review and inline feedback" true (count_sub ~sub:Review_format.feedback_prompt write_log >= 2);
  (check bool) "has comments" true (contains_sub ~sub:"error-handling" write_log)

(* Regression: when findings exist alongside a non-empty summary trace, the
   body must be the plain header (findings render separately) — never the
   summary trace, and never under a "Minor:" heading. *)
let test_pr_review_findings_present_no_summary_leak () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/deep_review/finding_with_trace_summary.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review body present" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
  (check bool) "the finding still renders" true (contains_sub ~sub:"error-handling" write_log);
  (check bool) "no Minor heading" false (contains_sub ~sub:"Minor:" write_log);
  (check bool) "summary trace not leaked" false (contains_sub ~sub:"refuted" write_log);
  (check bool) "no LGTM when findings exist" false (contains_sub ~sub:"LGTM :+1:" write_log)

(* Regression: [format_slack_attachment] must not put the internal summary
   trace into the Slack attachment text. *)
let test_slack_attachment_omits_summary_trace () =
  let review : Review_types.review_output =
    {
      summary = "L0 lib/session.ml:42 — refuted: token expiry still checked by caller wrapper.";
      findings =
        [
          {
            path = "lib/session.ml";
            line = 42;
            end_line = None;
            severity = Review_types.Warning;
            category = Review_types.Bug;
            message = "example";
            failure_scenario = "";
            evidence_snippet = "";
            why_now = "";
            confidence = Review_types.High;
            suggested_fix = None;
          };
        ];
      overall_assessment = "";
    }
  in
  let att =
    Review_format.format_slack_attachment ~compare_url:"https://example.com/compare" ~pusher_name:"alice" ~num_commits:2
      ~review
  in
  (check bool) "attachment text omits summary trace" false (contains_sub ~sub:"refuted" att.Slack_types.text);
  (check bool) "attachment text omits full summary" false
    (contains_sub ~sub:"token expiry still checked" att.Slack_types.text)

let test_pr_skipped_when_draft () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload ~draft:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no review posted" "" write_log

let test_pr_reviewed_when_draft_and_flag_enabled () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "review_draft_prs": true}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_pr_payload ~draft:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0)

let test_pr_skipped_when_closed () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload ~action:"closed" () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no review posted" "" write_log

(** {2 REVIEW comment trigger tests}

    These exercise the [issue_comment] dispatch path end-to-end: each test
    constructs an [issue_comment.created] webhook, runs it through
    [process_event], and asserts on the resulting write log.  The PR fetched
    via [get_pull_request] is mocked to the same [pr_42.json] fixture used
    by other PR-flow tests, so the review pipeline runs identically to a
    PR-open trigger past dispatch.

    The skip-reason branches are covered as e2e tests rather than unit tests
    because the helper is internal to the [Make] functor and not exposed in
    the [.mli] — same pattern as [pr_skip_reason] / [push_skip_reason]. *)

let comment_trigger_config = Config_types.config_of_json (Melange_json.of_string {|{"auto_review_on_comment": true}|})

let test_comment_trigger_reviews_pr () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  let eyes_pos = CCString.find ~sub:"[create_issue_comment_reaction]" write_log in
  let delete_pos = CCString.find ~sub:"[delete_issue_comment_reaction]" write_log in
  let review_pos = CCString.find ~sub:"[create_pr_review]" write_log in
  (check bool) "progress reaction added to trigger comment" true (eyes_pos >= 0);
  (check bool) "progress reaction removed before review" true (delete_pos > eyes_pos && review_pos > delete_pos);
  (check bool) "review posted via REVIEW comment" true (review_pos >= 0);
  (check bool) "uses general review pipeline" true (contains_sub ~sub:":robot: **REVIEW**" write_log)

let test_comment_trigger_quiet_success_posts_lgtm_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
  (* Empty scout leads early-exit the general pipeline with zero findings,
     reproducing the legacy empty-findings quiet success. *)
  Api_local.set_agent_response_map [ "general_scout", "mock_api_responses/scout/leads_empty.json" ];
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "progress reaction added to trigger comment" true
    (contains_sub
       ~sub:"[create_issue_comment_reaction] repo=https://github.com/org/monorepo comment_id=9001 content=eyes"
       write_log);
  (check bool) "progress reaction removed" true
    (contains_sub ~sub:"[delete_issue_comment_reaction] repo=https://github.com/org/monorepo comment_id=9001" write_log);
  (check bool) "quiet success comment posted to PR" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "quiet success comment says LGTM" true (contains_sub ~sub:"LGTM :+1:" write_log);
  (check bool) "quiet success comment shows reviewed commit" true
    (contains_sub ~sub:(reviewed_commit_sub "abc123def456789012345678901234567890abcd") write_log);
  (check bool) "no quiet success reaction added" false
    (contains_sub
       ~sub:"[create_issue_comment_reaction] repo=https://github.com/org/monorepo comment_id=9001 content=+1"
       write_log);
  (check bool) "no PR review when there is nothing to add" false (contains_sub ~sub:"[create_pr_review]" write_log)

let test_comment_trigger_disabled () =
  Test_helpers.reset_test_state ();
  (* Default config has auto_review_on_comment = false *)
  let ctx = Test_helpers.make_test_context () in
  let payload = Test_helpers.make_issue_comment_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no review when auto_review_on_comment disabled" "" write_log

let test_comment_trigger_non_review_body_silent () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload ~body:"looks good!" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "non-trigger comment ignored" "" write_log

let test_comment_trigger_body_with_extra_text () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  (* Trigger phrase requires exact match — "REVIEW please" must not fire. *)
  let payload = Test_helpers.make_issue_comment_payload ~body:"REVIEW please" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "REVIEW with trailing text does not trigger" "" write_log

let test_comment_trigger_body_trims_whitespace () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  (* Leading/trailing whitespace is trimmed before the equality check. *)
  let payload = Test_helpers.make_issue_comment_payload ~body:"  REVIEW\n" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "trimmed REVIEW triggers" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0)

let test_comment_trigger_skips_on_regular_issue () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload ~is_pr:false () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "comment on regular issue does not trigger review" "" write_log

let test_comment_trigger_skips_on_closed_pr () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload ~state:"closed" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "REVIEW on closed PR does not trigger" "" write_log

let test_comment_trigger_skips_edited_action () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload ~action:"edited" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "edited comment does not retrigger review" "" write_log

let test_comment_trigger_skips_bot_sender () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload ~sender_login:"some-bot[bot]" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "bot sender does not trigger review" "" write_log

let test_comment_trigger_skips_ignored_author () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_on_comment": true, "ignored_authors": ["spammer"]}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_issue_comment_payload ~sender_login:"spammer" () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "ignored author does not trigger review" "" write_log

let test_comment_trigger_re_reviews_same_sha () =
  Test_helpers.reset_test_state ();
  (* PR open registers head_sha in state via is_pr_reviewed.  A subsequent
     REVIEW comment on the same SHA must still trigger — manual triggers
     bypass the dedup. *)
  let state = State.create () in
  let ctx =
    Test_helpers.make_test_context ~state
      ~config:
        (Config_types.config_of_json
           (Melange_json.of_string {|{"auto_review_pr_open": true, "auto_review_on_comment": true}|}))
      ()
  in
  (* First, trigger a normal PR-open review to populate state. *)
  let pr_payload = read_file "mock_payloads/pr_opened.json" in
  let pr_event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:pr_payload in
  Lwt_main.run (R_test.process_event ctx ~event:pr_event);
  let first_log = Api_local.get_write_log () in
  (check bool) "first review posted" true (CCString.find ~sub:"[create_pr_review]" first_log >= 0);
  (* Now send a REVIEW comment on the same PR. The PR-flow dedup would
     normally reject it, but the comment trigger bypasses that check. *)
  Api_local.clear_write_log ();
  let comment_payload = Test_helpers.make_issue_comment_payload () in
  let comment_event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:comment_payload in
  Lwt_main.run (R_test.process_event ctx ~event:comment_event);
  let second_log = Api_local.get_write_log () in
  (check bool) "REVIEW comment re-triggers despite same head SHA" true
    (CCString.find ~sub:"[create_pr_review]" second_log >= 0)

(** {2 PR edge case tests} *)

let test_pr_synchronize_review () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let payload = Stre.replace_all ~str:payload ~sub:{|"action": "opened"|} ~by:{|"action": "synchronize"|} in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted on synchronize" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0)

let test_pr_all_ignored_paths_posts_skip_comment () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "ignored_paths": ["*.lock", "*.json"]}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  (* Use PR 99 which only has .lock and .json files *)
  let payload = Test_helpers.make_pr_payload ~number:99 ~title:"Update lock files" () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* Nothing to review is a skip, not an approval. *)
  (check bool) "skip comment posted" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=99" write_log);
  (check bool) "skip comment explains no code was reviewed" true
    (contains_sub ~sub:"no code was analyzed or approved" write_log);
  (check bool) "skip comment does not say LGTM" false (contains_sub ~sub:"LGTM :+1:" write_log);
  (check bool) "skip comment shows reviewed commit" true
    (contains_sub ~sub:(reviewed_commit_sub "abc123def456789012345678901234567890abcd") write_log);
  (check bool) "no thumbs-up reaction added" false
    (contains_sub ~sub:"[create_issue_reaction] repo=https://github.com/org/monorepo number=99 content=+1" write_log);
  (check bool) "skip comment identifies the skip" true (contains_sub ~sub:"skipped this review" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log)

let test_pr_empty_findings_review () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
  (* Empty scout leads early-exit the general pipeline with zero findings,
     reproducing the legacy empty-findings quiet success. *)
  Api_local.set_agent_response_map [ "general_scout", "mock_api_responses/scout/leads_empty.json" ];
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "progress reaction added" true (contains_sub ~sub:"[create_issue_reaction]" write_log);
  (check bool) "progress reaction removed" true
    (contains_sub ~sub:"[delete_issue_reaction] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "quiet success comment posted" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "quiet success comment says LGTM" true (contains_sub ~sub:"LGTM :+1:" write_log);
  (check bool) "quiet success comment shows reviewed commit" true
    (contains_sub ~sub:(reviewed_commit_sub "abc123def456789012345678901234567890abcd") write_log);
  (check bool) "no quiet success reaction added" false
    (contains_sub ~sub:"[create_issue_reaction] repo=https://github.com/org/monorepo number=42 content=+1" write_log);
  (check bool) "no PR review when there is nothing to add" false (contains_sub ~sub:"[create_pr_review]" write_log);
  match event with
  | Github.Pull_request pr ->
    (check bool) "quiet review recorded in state" true
      (State.is_pr_reviewed (Context.state ctx) ~repo_url:pr.repository.url ~pr_number:pr.number
         ~head_sha:pr.pull_request.head.sha)
  | Github.Push _ | Github.Issue_comment _ | Github.Pull_request_review _ | Github.Pull_request_review_comment _
  | Github.Unknown _ ->
    fail "expected pull_request event"

let test_pr_large_diff_posts_comment () =
  Test_helpers.reset_test_state ();
  (* Set max_diff_lines very low so the normal PR 42 diff exceeds it *)
  let config =
    Config_types.config_of_json (Melange_json.of_string {|{"auto_review_pr_open": true, "max_diff_lines": 1}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (* Over the line limit: post a failure comment, do not attempt a review. *)
  (check bool) "failure comment posted" true (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log)

let generated_filter_diff_text =
  String.concat "\n"
    [
      "diff --git a/src/main.ml b/src/main.ml";
      "index 1234567..abcdefg 100644";
      "--- a/src/main.ml";
      "+++ b/src/main.ml";
      "@@ -10,7 +10,10 @@ let main () =";
      "   let config = load_config () in";
      "-  let old_value = 42 in";
      "-  process old_value";
      "+  let new_value = 100 in";
      "+  let result = process new_value in";
      "+  log_result result;";
      "+  print_endline \"done\";";
      "+  result";
      "diff --git a/src/__generated__/client.ml b/src/__generated__/client.ml";
      "new file mode 100644";
      "index 0000000..1111111";
      "--- /dev/null";
      "+++ b/src/__generated__/client.ml";
      "@@ -0,0 +1,2 @@";
      "+(* @generated *)";
      "+let endpoint = \"/v1/generated\"";
      "diff --git a/assets/app.min.js b/assets/app.min.js";
      "new file mode 100644";
      "index 0000000..2222222";
      "--- /dev/null";
      "+++ b/assets/app.min.js";
      "@@ -0,0 +1 @@";
      "+function min(){return 1}";
    ]

let test_pr_generated_files_filtered_before_file_limit () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff generated_filter_diff_text;
  let config = Config_types.config_of_json (Melange_json.of_string {|{"auto_review_pr_open": true, "max_files": 1}|}) in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "normal PR review attempted" true (contains_sub ~sub:"[create_pr_review]" write_log);
  (check bool) "file-limit failure not posted" false (contains_sub ~sub:"diff touches" write_log);
  (check bool) "generated path absent from review payload" false (contains_sub ~sub:"__generated__" write_log)

(** {2 Push review tests} *)

let test_push_review_e2e () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/push_review_response.json";
  (* Deep reviewer reuses the legacy push review fixture; the unmapped
     validator keeps selecting its push fixture from the fallback path. *)
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/push_review_response.json";
    ];
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"review_pushes_to_develop": true, "slack_channel": "dev-reviews"}|})
  in
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
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_push_payload ~ref_:"refs/heads/main" () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "no actions" "" write_log

(** {2 Push edge case tests} *)

let test_push_created_skipped () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_push_payload ~created:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "new branch push skipped" "" write_log

let test_push_deleted_skipped () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_push_payload ~deleted:true () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "branch deletion push skipped" "" write_log

(** {2 Duplicate prevention tests} *)

let test_duplicate_pr_prevention () =
  Test_helpers.reset_test_state ();
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state ~config:Test_helpers.auto_review_enabled_config () in
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
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/push_review_response.json";
    ];
  let state = State.create () in
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"review_pushes_to_develop": true, "slack_channel": "dev-reviews"}|})
  in
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
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "ignored_authors": ["developer1"]}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "ignored author skipped" "" write_log

let test_ignored_author_push_skipped () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"review_pushes_to_develop": true, "ignored_authors": ["developer2"]}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "ignored author push skipped" "" write_log

(** {2 Local diff review tests} *)

module Capturing_agent_runner = struct
  let model_ids : string option list ref = ref []

  let reset () = model_ids := []
  let get_model_ids () = List.rev !model_ids

  (* Confirm every surviving general-review candidate so the validator stage is
     a pass-through. The general plugin only validates findings that clear
     [filter_candidates], so we re-derive that set from the review fixture and
     emit one confirmation per candidate, keyed by zero-based candidate id. *)
  let validator_output_for_review_fixture () =
    let review =
      Review_types.review_output_of_json
        (Melange_json.of_string (read_file "mock_api_responses/claude/review_response.json"))
    in
    let security_covered_elsewhere = false in
    let candidates =
      List.filter
        (fun (f : Review_types.finding) ->
          (not
             (security_covered_elsewhere
             && Review_types.(
                  match f.category with
                  | Security -> true
                  | _ -> false)))
          && (match f.severity, f.category with
            | (Review_types.Praise | Nitpick), _ | _, (Review_types.Style | Naming | Documentation) -> false
            | _ -> true)
          && Config_types.confidence_rank f.confidence >= Config_types.confidence_rank Medium
          && String.length (String.trim f.failure_scenario) > 0
          && String.length (String.trim f.evidence_snippet) > 0
          && String.length (String.trim f.why_now) > 0)
        review.findings
    in
    let results =
      List.mapi
        (fun i (finding : Review_types.finding) ->
          Review_types.{ candidate_id = i; finding; verdict = Confirmed; evidence_notes = "confirmed by capture stub" })
        candidates
    in
    Review_types.validator_output_to_json { results }

  let run ~ctx:_ ~repo_url:_ ?model_id ?tools ?debug_dir ?log_context:_ ~config ~input:_ () =
    let tools_count =
      match tools with
      | None -> 0
      | Some tools -> List.length tools
    in
    ignore (tools_count : int);
    ignore (debug_dir : string option);
    model_ids := model_id :: !model_ids;
    let output =
      match config.Agent_runner.name with
      | "general_validator" -> validator_output_for_review_fixture ()
      | "general_scout" -> Melange_json.of_string (read_file "mock_api_responses/scout/leads_two.json")
      | _ -> Melange_json.of_string (read_file "mock_api_responses/claude/review_response.json")
    in
    let usage : Ai_provider.Usage.t = { input_tokens = 0; output_tokens = 0; total_tokens = None } in
    Lwt.return
      (Ok
         Agent_runner.
           {
             output;
             usage;
             cache_read_input_tokens = 0;
             cache_creation_input_tokens = 0;
             steps_count = 1;
             tool_calls_count = 0;
             tool_results_count = 0;
             model_id = config.name;
             reported_cost_usd = None;
           })
end

module Local_review_test = Local_review.Make (Api_local.Agent_runner)
module Local_review_capture = Local_review.Make (Capturing_agent_runner)

module Config_mutating_source = struct
  let replacement_config : Config_types.config option ref = ref None

  let set_replacement_config config = replacement_config := Some config
  let clear_replacement_config () = replacement_config := None

  let replace_config ctx repo_url =
    match !replacement_config with
    | None -> ()
    | Some config -> Context.set_config ctx ~repo_key:repo_url config

  let get_config = Api_local.Github.get_config
  let get_pr_files = Api_local.Github.get_pr_files

  let get_pr_diff ~ctx ~repo_url ~number ?log_context () =
    replace_config ctx repo_url;
    Api_local.Github.get_pr_diff ~ctx ~repo_url ~number ?log_context ()

  let get_pull_request = Api_local.Github.get_pull_request

  let get_compare_diff ~ctx ~repo_url ~base ~head ?log_context () =
    replace_config ctx repo_url;
    Api_local.Github.get_compare_diff ~ctx ~repo_url ~base ~head ?log_context ()

  let get_file_content = Api_local.Github.get_file_content
end

module Reviewer_config_capture =
  Reviewer.Make (Config_mutating_source) (Api_local.Github) (Api_local.Github) (Capturing_agent_runner)
    (Api_local.Slack)

let fake_git mapping ~cwd:_ args =
  let key = String.concat "\n" args in
  match List.find_opt (fun (candidate, _) -> String.equal candidate key) mapping with
  | Some (_, `Ok output) -> Ok output
  | Some (_, `Error msg) -> Error msg
  | None -> Error (Printf.sprintf "unexpected git args: %s" (String.concat " " args))

let git_key args = String.concat "\n" args

let test_local_git_default_repo_key () =
  (check string) "repo key" "local:/tmp/reviewotron" (Local_git.default_repo_key ~root:"/tmp/reviewotron")

let test_local_review_duplicate_message_detection () =
  let duplicate = "change local-change in local/repo was already reviewed" in
  let failure = "local review failed: boom" in
  (check bool) "duplicate skip detected" true (Local_review.is_already_reviewed_message duplicate);
  (check bool) "generic failure not duplicate skip" false (Local_review.is_already_reviewed_message failure)

let test_local_git_run_git_reports_spawn_errors () =
  let old_path = Sys.getenv_opt "PATH" in
  let empty_path = Filename.temp_dir "reviewotron_empty_path_" "_test" in
  Fun.protect
    ~finally:(fun () ->
      (match old_path with
      | Some path -> Unix.putenv "PATH" path
      | None -> Unix.putenv "PATH" "");
      try Unix.rmdir empty_path with Unix.Unix_error _ -> ())
    (fun () ->
      Unix.putenv "PATH" empty_path;
      match Local_git.run_git ~cwd:"/" [ "--version" ] with
      | Ok output -> fail (Printf.sprintf "expected git spawn failure, got: %s" output)
      | Error msg -> (check bool) "reports missing executable" true (contains_sub ~sub:"git -C / --version failed" msg))

let test_local_git_infer_base_uses_explicit_base () =
  let run_git =
    fake_git
      [
        git_key [ "rev-parse"; "--verify"; "--quiet"; "upstream/main^{commit}" ], `Ok "upstream/main";
        git_key [ "merge-base"; "HEAD"; "upstream/main" ], `Ok "abc123";
      ]
  in
  match Local_git.infer_base_with ~run_git ~root:"/repo" ~explicit:(Some "upstream/main") with
  | Ok base -> (check string) "base" "upstream/main" base
  | Error msg -> fail msg

let test_local_git_infer_base_uses_origin_head () =
  let run_git =
    fake_git
      [
        git_key [ "symbolic-ref"; "--quiet"; "--short"; "refs/remotes/origin/HEAD" ], `Ok "origin/trunk";
        git_key [ "rev-parse"; "--abbrev-ref"; "--symbolic-full-name"; "@{upstream}" ], `Error "no upstream";
        git_key [ "rev-parse"; "--verify"; "--quiet"; "origin/trunk^{commit}" ], `Ok "origin/trunk";
        git_key [ "merge-base"; "HEAD"; "origin/trunk" ], `Ok "abc123";
      ]
  in
  match Local_git.infer_base_with ~run_git ~root:"/repo" ~explicit:None with
  | Ok base -> (check string) "base" "origin/trunk" base
  | Error msg -> fail msg

let test_local_git_diff_against_base_uses_merge_base () =
  let diff_text = "diff --git a/a.ml b/a.ml\n" in
  let run_git =
    fake_git
      [ git_key [ "merge-base"; "HEAD"; "origin/main" ], `Ok "abc123"; git_key [ "diff"; "abc123" ], `Ok diff_text ]
  in
  match Local_git.diff_against_base_with ~run_git ~root:"/repo" ~base:"origin/main" with
  | Ok diff -> (check string) "diff" diff_text diff
  | Error msg -> fail msg

let with_local_root f =
  let tmp_dir = Filename.temp_dir "reviewotron_local_" "_test" in
  let src_dir = Filename.concat tmp_dir "src" in
  let main_path = Filename.concat src_dir "main.ml" in
  let rec remove_tree path =
    match Unix.lstat path with
    | exception Unix.Unix_error _ -> ()
    | st ->
    match st.Unix.st_kind with
    | Unix.S_DIR ->
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path
  in
  Fun.protect
    ~finally:(fun () -> remove_tree tmp_dir)
    (fun () ->
      Unix.mkdir src_dir 0o755;
      write_file main_path "let main () =\n  print_endline \"local\"\n";
      f tmp_dir)

let assert_local_trigger (trigger : Review_job.trigger) =
  match trigger with
  | Local -> ()
  | Pull_request | Push | Manual | Other _ -> fail "expected local trigger"

let assert_local_source_kind (source_kind : Review_job.source_kind) =
  match source_kind with
  | Local -> ()
  | Github | Other _ -> fail "expected local source kind"

let test_local_source_prepare_review_builds_job () =
  with_local_root (fun root ->
    let config = Context.default_config () in
    let result =
      Lwt_main.run
        (Local_source.prepare_review ~root ~repo_key:"local/repo" ~change_key:"change-1" ~title:"Local change"
           ~description:"Local description" ~diff_path:"mock_api_responses/github/pr_42.diff" ~config ())
    in
    match result with
    | Error error -> fail (Local_source.string_of_prepare_error error)
    | Ok job ->
      (check string) "repo key" "local/repo" job.repo_key;
      (check string) "change key" "change-1" job.change_key;
      (check string) "change label" "local change change-1" job.change_label;
      (check string) "title" "Local change" job.title;
      assert_local_trigger job.trigger;
      assert_local_source_kind job.source_kind;
      (check bool) "filtered diff populated" true (List.compare_length_with job.filtered_diff 0 > 0);
      let fetch_result = Lwt_main.run (job.fetch_file ~path:"src/main.ml") in
      (match fetch_result with
      | Ok (Some contents) -> (check bool) "local file content" true (CCString.find ~sub:"print_endline" contents >= 0)
      | Ok None -> fail "expected local file content"
      | Error msg -> fail msg))

let test_local_source_rejects_unsafe_fetch_path () =
  with_local_root (fun root ->
    let config = Context.default_config () in
    let result =
      Lwt_main.run
        (Local_source.prepare_review ~root ~repo_key:"local/repo" ~title:"Local change" ~description:""
           ~diff_path:"mock_api_responses/github/pr_42.diff" ~config ())
    in
    match result with
    | Error error -> fail (Local_source.string_of_prepare_error error)
    | Ok job ->
      let fetch_result = Lwt_main.run (job.fetch_file ~path:"../secret.txt") in
      (match fetch_result with
      | Error msg ->
        (check bool) "unsafe path rejected" true (CCString.find ~sub:"unsafe local path" msg >= 0);
        (check bool) "unsafe path reason" true (CCString.find ~sub:"parent-directory" msg >= 0)
      | Ok (Some _) -> fail "unsafe path should not return content"
      | Ok None -> fail "unsafe path should return an error"))

let test_local_source_rejects_symlink_escape () =
  with_local_root (fun root ->
    let outside_path = Filename.temp_file "reviewotron_secret_" ".txt" in
    let link_path = Filename.concat root "link.txt" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove link_path with Sys_error _ -> ());
        try Sys.remove outside_path with Sys_error _ -> ())
      (fun () ->
        write_file outside_path "secret\n";
        Unix.symlink outside_path link_path;
        let config = Context.default_config () in
        let result =
          Lwt_main.run
            (Local_source.prepare_review ~root ~repo_key:"local/repo" ~title:"Local change" ~description:""
               ~diff_path:"mock_api_responses/github/pr_42.diff" ~config ())
        in
        match result with
        | Error error -> fail (Local_source.string_of_prepare_error error)
        | Ok job ->
          let fetch_result = Lwt_main.run (job.fetch_file ~path:"link.txt") in
          (match fetch_result with
          | Error msg -> (check bool) "symlink escape rejected" true (CCString.find ~sub:"outside root" msg >= 0)
          | Ok (Some _) -> fail "symlink escape should not return content"
          | Ok None -> fail "symlink escape should return an error")))

let test_local_source_reports_fetch_read_errors () =
  with_local_root (fun root ->
    let config = Context.default_config () in
    let result =
      Lwt_main.run
        (Local_source.prepare_review ~root ~repo_key:"local/repo" ~title:"Local change" ~description:""
           ~diff_path:"mock_api_responses/github/pr_42.diff" ~config ())
    in
    match result with
    | Error error -> fail (Local_source.string_of_prepare_error error)
    | Ok job ->
      let fetch_result = Lwt_main.run (job.fetch_file ~path:"src") in
      (match fetch_result with
      | Error msg -> (check bool) "read error reported" true (CCString.find ~sub:"failed to read" msg >= 0)
      | Ok (Some _) -> fail "directory fetch should not return content"
      | Ok None -> fail "directory fetch should report a read error"))

let two_file_diff =
  {|
diff --git a/src/a.ml b/src/a.ml
index 1111111..2222222 100644
--- a/src/a.ml
+++ b/src/a.ml
@@ -1 +1 @@
-let a = 1
+let a = 2
diff --git a/src/b.ml b/src/b.ml
index 3333333..4444444 100644
--- a/src/b.ml
+++ b/src/b.ml
@@ -1 +1 @@
-let b = 1
+let b = 2
|}

let test_local_source_default_change_key_uses_filtered_diff () =
  let config_without_b = Config_types.config_of_json (Melange_json.of_string {|{"ignored_paths": ["src/b.ml"]}|}) in
  let config_without_a = Config_types.config_of_json (Melange_json.of_string {|{"ignored_paths": ["src/a.ml"]}|}) in
  let prepare config =
    Lwt_main.run
      (Local_source.prepare_review_from_text ~root:"." ~repo_key:"local/repo" ~title:"Local change" ~description:""
         ~diff_text:two_file_diff ~config ())
  in
  match prepare config_without_b, prepare config_without_a with
  | Ok without_b, Ok without_a ->
    (check bool) "default change key changes with filters" true
      (not (String.equal without_b.change_key without_a.change_key));
    (check bool) "head sha changes with filters" true (not (String.equal without_b.head_sha without_a.head_sha))
  | Error error, _ | _, Error error -> fail (Local_source.string_of_prepare_error error)

let test_local_review_path_filters_generated_before_limits () =
  with_local_root (fun root ->
    let src_generated_dir = Filename.concat (Filename.concat root "src") "__generated__" in
    let assets_dir = Filename.concat root "assets" in
    Unix.mkdir src_generated_dir 0o755;
    Unix.mkdir assets_dir 0o755;
    write_file (Filename.concat src_generated_dir "client.ml") "(* @generated *)\nlet endpoint = \"/v1\"\n";
    write_file (Filename.concat assets_dir "app.min.js") "function min(){return 1}\n";
    match Local_path.ingest root with
    | Error msg -> fail msg
    | Ok ingest ->
      (check int) "ingest sees source plus generated files" 3 ingest.Local_path.file_count;
      let config = Config_types.config_of_json (Melange_json.of_string {|{"max_files": 1}|}) in
      let result =
        Lwt_main.run
          (Local_source.prepare_review_from_text ~root ~repo_key:"local/repo" ~title:ingest.title ~description:""
             ~diff_text:ingest.diff_text ~config ())
      in
      (match result with
      | Error error -> fail (Local_source.string_of_prepare_error error)
      | Ok job ->
        (check int) "only source remains" 1 (List.length job.filtered_diff);
        (match job.filtered_diff with
        | [ fd ] -> (check string) "source path remains" "src/main.ml" fd.Diff_parser.path
        | [] | _ :: _ :: _ -> fail "expected exactly one filtered file");
        (check bool) "generated path absent from annotated diff" false (contains_sub ~sub:"__generated__" job.diff_text);
        (check bool) "minified artifact absent from annotated diff" false (contains_sub ~sub:"app.min.js" job.diff_text)))

let test_local_review_diff_returns_markdown () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state () in
  let config = Context.default_config () in
  let result =
    Lwt_main.run
      (Local_review_test.review_diff ~ctx ~root:"." ~repo_key:"local/repo" ~change_key:"local-change"
         ~title:"Local change" ~description:"Local description" ~diff_path:"mock_api_responses/github/pr_42.diff"
         ~config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok markdown ->
    (check bool) "summary not leaked" false (CCString.find ~sub:"The changes look generally good" markdown >= 0);
    (check bool) "has inline comments section" true (CCString.find ~sub:"### Inline comments" markdown >= 0);
    (check bool) "has local inline location" true (CCString.find ~sub:"src/main.ml:14" markdown >= 0);
    (check bool) "records generic change review" true
      (State.is_change_reviewed state ~repo_key:"local/repo" ~change_key:"local-change")

let test_local_review_diff_text_returns_markdown () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  let ctx = Test_helpers.make_test_context () in
  let config = Context.default_config () in
  let diff_text = read_file "mock_api_responses/github/pr_42.diff" in
  let result =
    Lwt_main.run
      (Local_review_test.review_diff_text ~ctx ~root:"." ~repo_key:"local/repo" ~title:"Generated local diff"
         ~description:"Local description" ~diff_text ~config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok markdown ->
    (check bool) "summary not leaked" false (CCString.find ~sub:"The changes look generally good" markdown >= 0);
    (check bool) "has inline comments section" true (CCString.find ~sub:"### Inline comments" markdown >= 0)

(* Regression: the deep reviewer's [summary] is an internal audit trace (one
   line per lead, e.g. "L0 ... refuted: ..."). When every lead is refuted the
   review is clean, so the consumer body must be the LGTM form — not a "Minor:"
   dump of the refutation trace. The local-review markdown surfaces
   [review_body] directly, so it exercises the zero-findings arm. *)
let test_local_review_all_refuted_shows_lgtm_not_summary () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/deep_review/all_refuted.json";
    ];
  let ctx = Test_helpers.make_test_context () in
  let config = Context.default_config () in
  let diff_text = read_file "mock_api_responses/github/pr_42.diff" in
  let result =
    Lwt_main.run
      (Local_review_test.review_diff_text ~ctx ~root:"." ~repo_key:"local/repo" ~change_key:"all-refuted"
         ~title:"All refuted" ~description:"Local description" ~diff_text ~config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok markdown ->
    (check bool) "clean review shows LGTM" true (CCString.find ~sub:"LGTM :+1:" markdown >= 0);
    (check bool) "no Minor heading" false (CCString.find ~sub:"Minor:" markdown >= 0);
    (check bool) "refutation trace not leaked" false (CCString.find ~sub:"refuted" markdown >= 0);
    (check bool) "lead marker not leaked" false (CCString.find ~sub:"L0 lib/session.ml" markdown >= 0)

let test_local_review_security_only_empty_is_success () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map [ "security_triage", "mock_api_responses/security/triage_safe.json" ];
  let ctx = Test_helpers.make_test_context () in
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"review_plugins": {"general": {"enabled": false}, "security": {"enabled": true}}}|})
  in
  let diff_text = read_file "mock_api_responses/github/pr_42.diff" in
  let result =
    Lwt_main.run
      (Local_review_test.review_diff_text ~ctx ~root:"." ~repo_key:"local/repo" ~change_key:"security-only-empty"
         ~title:"Generated local diff" ~description:"Local description" ~diff_text ~config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok markdown ->
    (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" markdown);
    (check bool) "does not report failure" false (contains_sub ~sub:"Review failed" markdown);
    (check bool) "does not ask for retrigger" false (contains_sub ~sub:"re-trigger the review" markdown)

let security_only_local_config () =
  Config_types.config_of_json
    (Melange_json.of_string {|{"review_plugins": {"general": {"enabled": false}, "security": {"enabled": true}}}|})

let test_local_review_policy_regression_sudo_vulnerable () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "security_triage", "mock_api_responses/security/triage_policy_regression_sudo.json";
      "security_analysis_policy_regression", "mock_api_responses/security/analysis_policy_regression_sudo.json";
      "security_validator", "mock_api_responses/security/validator_policy_regression_confirmed.json";
    ];
  let ctx = Test_helpers.make_test_context () in
  let config = security_only_local_config () in
  let diff_text = read_file "security_corpus/policy_regression/sudo_systemctl_nopasswd_vulnerable.diff" in
  let result =
    Lwt_main.run
      (Local_review_test.review_diff_text ~ctx ~root:"." ~repo_key:"local/repo" ~change_key:"policy-sudo-vuln"
         ~title:"Policy regression diff" ~description:"Local description" ~diff_text ~config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok markdown ->
    (check bool) "has security finding" true (contains_sub ~sub:"**[critical]** security" markdown);
    (check bool) "mentions NOPASSWD" true (contains_sub ~sub:"NOPASSWD" markdown);
    (check bool) "mentions systemctl" true (contains_sub ~sub:"systemctl" markdown)

let test_local_review_policy_regression_sudo_scoped_safe () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "security_triage", "mock_api_responses/security/triage_policy_regression_sudo.json";
      "security_analysis_policy_regression", "mock_api_responses/security/analysis_policy_regression_empty.json";
    ];
  let ctx = Test_helpers.make_test_context () in
  let config = security_only_local_config () in
  let diff_text = read_file "security_corpus/policy_regression/sudo_systemctl_reload_scoped_safe.diff" in
  let result =
    Lwt_main.run
      (Local_review_test.review_diff_text ~ctx ~root:"." ~repo_key:"local/repo" ~change_key:"policy-sudo-safe"
         ~title:"Scoped sudo diff" ~description:"Local description" ~diff_text ~config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok markdown ->
    (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" markdown);
    (check bool) "no security finding" false (contains_sub ~sub:"**[critical]** security" markdown);
    (check bool) "no review failure" false (contains_sub ~sub:"Review failed" markdown)

let test_local_review_uses_supplied_config_for_plugins () =
  Test_helpers.reset_test_state ();
  Capturing_agent_runner.reset ();
  let repo_key = "local/repo" in
  let ctx = Test_helpers.make_test_context () in
  let context_config = Config_types.config_of_json (Melange_json.of_string {|{"model": "context-model"}|}) in
  let supplied_config = Config_types.config_of_json (Melange_json.of_string {|{"model": "supplied-model"}|}) in
  Context.set_config ctx ~repo_key context_config;
  let diff_text = read_file "mock_api_responses/github/pr_42.diff" in
  let result =
    Lwt_main.run
      (Local_review_capture.review_diff_text ~ctx ~root:"." ~repo_key ~title:"Generated local diff"
         ~description:"Local description" ~diff_text ~config:supplied_config ())
  in
  match result with
  | Error msg -> fail msg
  | Ok _markdown ->
  (* The general plugin makes two agent calls: the review (with the supplied
     model id) and the validator (no model id). Only the review carries the
     model under test. *)
  match List.filter_map Fun.id (Capturing_agent_runner.get_model_ids ()) with
  | [ model_id ] -> check string "plugin model" "supplied-model" model_id
  | [] -> fail "expected one model-carrying plugin agent call"
  | _ :: _ -> fail "expected exactly one model-carrying plugin agent call"

let test_local_review_skips_duplicate_change () =
  Test_helpers.reset_test_state ();
  Capturing_agent_runner.reset ();
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state () in
  let config = Context.default_config () in
  let diff_text = read_file "mock_api_responses/github/pr_42.diff" in
  let review () =
    Lwt_main.run
      (Local_review_capture.review_diff_text ~ctx ~root:"." ~repo_key:"local/repo" ~change_key:"local-change"
         ~title:"Generated local diff" ~description:"Local description" ~diff_text ~config ())
  in
  (match review () with
  | Error msg -> fail msg
  | Ok _markdown -> ());
  let second = review () in
  (match second with
  | Error msg -> (check bool) "duplicate skipped" true (CCString.find ~sub:"already reviewed" msg >= 0)
  | Ok _markdown -> fail "duplicate local review should be skipped");
  (* Count all agent calls (general_scout + general_deep_review +
     general_validator): the duplicate second review must not run, so exactly
     three agent calls are expected from the single successful review. *)
  (check int) "agent calls" 3 (List.length (Capturing_agent_runner.get_model_ids ()))

let test_github_review_uses_captured_config_for_plugins () =
  Test_helpers.reset_test_state ();
  Capturing_agent_runner.reset ();
  Config_mutating_source.clear_replacement_config ();
  let captured_config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "model": "captured-model"}|})
  in
  let replacement_config =
    Config_types.config_of_json
      (Melange_json.of_string
         {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "model": "replacement-model"}|})
  in
  let ctx = Test_helpers.make_test_context ~config:captured_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Config_mutating_source.set_replacement_config replacement_config;
  Fun.protect ~finally:Config_mutating_source.clear_replacement_config (fun () ->
    Lwt_main.run (Reviewer_config_capture.process_event ctx ~event));
  match List.filter_map Fun.id (Capturing_agent_runner.get_model_ids ()) with
  | [ model_id ] -> check string "plugin model" "captured-model" model_id
  | [] -> fail "expected one model-carrying plugin agent call"
  | _ :: _ -> fail "expected exactly one model-carrying plugin agent call"

let json_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> value
  | Some _ -> fail (Printf.sprintf "expected string JSON field %s" key)
  | None -> fail (Printf.sprintf "missing JSON field %s" key)

let json_int_field fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> value
  | Some _ -> fail (Printf.sprintf "expected int JSON field %s" key)
  | None -> fail (Printf.sprintf "missing JSON field %s" key)

let json_list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List value) -> value
  | Some _ -> fail (Printf.sprintf "expected list JSON field %s" key)
  | None -> fail (Printf.sprintf "missing JSON field %s" key)

let test_local_sink_render_json () =
  let summary =
    "Legacy session-id file from old scc crashes startup because ensure_dir refuses to treat a regular file as a \
     directory"
  in
  let failure_scenario =
    "Any user who ran a previous scc has a regular file at <scc_metadata>/sessions/<wt_basename> holding their last \
     session UUID. After upgrading, scc calls ensure_dir on the legacy file path, sees S_REG, and aborts on startup."
  in
  let finding =
    mk_finding ~path:"backend/safer-claude-code/safer_claude_code.ml" ~line:492 ~message:summary ~failure_scenario ()
  in
  let report : Review_engine.report =
    {
      body = "";
      comments = [];
      inline_findings = [];
      findings = [ finding ];
      sourced_findings = [];
      routed_findings = [];
      unchanged_findings = [];
      anchor_failed_findings = [];
      review_costs = [];
      security_error = false;
      general_failed = false;
    }
  in
  match Yojson.Basic.from_string (Local_sink.render_json report) with
  | `Assoc fields ->
    (check string) "review summary" "" (json_string_field fields "summary");
    (match List.assoc_opt "findings" fields with
    | Some (`List [ `Assoc fields ]) ->
      (check string) "file" "backend/safer-claude-code/safer_claude_code.ml" (json_string_field fields "file");
      (check int) "line" 492 (json_int_field fields "line");
      (check string) "level" "warning" (json_string_field fields "level");
      (check string) "category" "security" (json_string_field fields "category");
      (check string) "summary" summary (json_string_field fields "summary");
      (check string) "failure_scenario" failure_scenario (json_string_field fields "failure_scenario")
    | Some _ -> fail "expected findings to contain one review finding"
    | None -> fail "missing JSON field findings")
  | _ -> fail "expected a JSON review object"

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

let test_state_change_review_roundtrip () =
  let tmp_path = Filename.temp_file "reviewotron_change_state_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      let state = State.create ~filepath:tmp_path () in
      State.record_change_review state ~repo_key:"local/repo" ~change_key:"diff/abc" ~review_costs:[];
      State.save state;
      let loaded = State.load ~filepath:tmp_path in
      (check bool) "change review found" true
        (State.is_change_reviewed loaded ~repo_key:"local/repo" ~change_key:"diff/abc");
      (check bool) "different change not found" false
        (State.is_change_reviewed loaded ~repo_key:"local/repo" ~change_key:"diff/def"))

let test_state_loads_legacy_repo_state_without_change_reviews () =
  let tmp_path = Filename.temp_file "reviewotron_legacy_state_" ".json" in
  Fun.protect
    ~finally:(fun () -> Sys.remove tmp_path)
    (fun () ->
      write_file tmp_path
        {|{
  "repos": {
    "https://github.com/test/repo": {
      "pr_reviews": [
        {
          "pr_number": 1,
          "head_sha": "abc123",
          "reviewed_at": "Mon, 01 Jan 2024 00:00:00 GMT",
          "review_costs": []
        }
      ],
      "push_reviews": []
    }
  }
}|};
      let loaded = State.load ~filepath:tmp_path in
      (check bool) "legacy PR review found" true
        (State.is_pr_reviewed loaded ~repo_url:"https://github.com/test/repo" ~pr_number:1 ~head_sha:"abc123");
      (check bool) "legacy state has no generic change review" false
        (State.is_change_reviewed loaded ~repo_key:"https://github.com/test/repo" ~change_key:"diff/abc"))

(** {2 Feedback store and collector tests} *)

let remove_if_exists path =
  match Sys.file_exists path with
  | true -> Sys.remove path
  | false -> ()

let rec remove_tree_if_exists path =
  match Sys.file_exists path with
  | false -> ()
  | true ->
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path |> Array.iter (fun child -> remove_tree_if_exists (Filename.concat path child));
    Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path

let with_temp_feedback_store f =
  let state_path = Filename.temp_file "reviewotron_feedback_state_" ".json" in
  let paths = Feedback_store.derive_paths ~state_filepath:state_path () in
  Fun.protect
    ~finally:(fun () ->
      remove_if_exists state_path;
      remove_if_exists paths.targets;
      remove_if_exists paths.events;
      remove_tree_if_exists paths.evidence_root)
    (fun () -> f state_path paths (Feedback_store.create ~state_filepath:state_path ()))

let with_temp_feedback_store_dir f =
  let dir_path = Filename.temp_file "reviewotron_feedback_dir_" "" in
  Sys.remove dir_path;
  Unix.mkdir dir_path 0o700;
  let state_path = Filename.concat dir_path "state.json" in
  let paths = Feedback_store.derive_paths ~state_filepath:state_path () in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.chmod dir_path 0o700 with _exn -> ());
      remove_if_exists state_path;
      remove_if_exists paths.targets;
      remove_if_exists paths.events;
      remove_tree_if_exists paths.evidence_root;
      try Unix.rmdir dir_path with _exn -> ())
    (fun () -> f state_path paths (Feedback_store.create ~state_filepath:state_path ()))

let ptime_exn value =
  match Feedback_store.parse_time value with
  | Ok time -> time
  | Error msg -> fail (Printf.sprintf "invalid test timestamp %s: %s" value msg)

module Engine_debug_test = Review_engine.Make (Api_local.Agent_runner)

let debug_dir_test_job ?(repo_key = Test_helpers.test_repo_url) ?(head_sha = "fb15a13a357f3e108dfc8257b480ef19ac5d0c00")
  () : Review_job.t =
  {
    repo_key;
    change_key = "change";
    change_label = "PR #1";
    title = "Test";
    description = "";
    head_sha;
    diff_text = "";
    filtered_diff = [];
    config = Config_types.config_of_json (Melange_json.of_string "{}");
    file_contents = [];
    fetch_file = (fun ~path:_ -> Lwt.return (Ok None));
    trigger = Pull_request;
    source_kind = Github;
  }

let test_local_runtime_dirs_use_xdg_state () =
  with_temp_feedback_store_dir (fun state_path _paths _store ->
    let state_home = Filename.dirname state_path in
    with_env_vars
      [ "XDG_STATE_HOME", state_home ]
      (fun () ->
        let ctx = Test_helpers.make_test_context () in
        let debug_dir = Engine_debug_test.debug_dir_for_job ~ctx (debug_dir_test_job ()) in
        let memory_dir = Engine_debug_test.memory_dir_for_context ~ctx in
        let runtime_root = Filename.concat state_home "reviewotron" in
        let expected_debug = Filename.concat (Filename.concat runtime_root "debug") "org-monorepo/fb15a13a" in
        let expected_memory = Filename.concat runtime_root "memory" in
        (check string) "external debug dir" expected_debug debug_dir;
        (check string) "external memory dir" expected_memory memory_dir;
        (check bool) "debug dir is absolute" false (Filename.is_relative debug_dir);
        (check bool) "memory dir is absolute" false (Filename.is_relative memory_dir)))

let test_debug_dir_with_feedback_store_uses_feedback_sibling () =
  with_temp_feedback_store_dir (fun _state_path paths store ->
    let ctx = Test_helpers.make_test_context ~feedback_store:store () in
    let dir = Engine_debug_test.debug_dir_for_job ~ctx (debug_dir_test_job ()) in
    let expected = Filename.concat (Filename.concat (Filename.dirname paths.evidence_root) "debug") "org-monorepo" in
    (check string) "feedback sibling debug dir" (Filename.concat expected "fb15a13a") dir)

let test_memory_dir_with_feedback_store_uses_feedback_sibling () =
  with_temp_feedback_store_dir (fun _state_path paths store ->
    let ctx = Test_helpers.make_test_context ~feedback_store:store () in
    let dir = Engine_debug_test.memory_dir_for_context ~ctx in
    (check string) "feedback sibling memory dir" (Filename.concat (Filename.dirname paths.evidence_root) "memory") dir)

let test_review_job_log_context () =
  let context = Review_job.log_context (debug_dir_test_job ()) in
  (check string) "PR log context" "[org-monorepo/#1/fb15a13a]" context;
  let context = Review_job.log_context (debug_dir_test_job ~head_sha:"abc123" ()) in
  (check string) "short sha log context" "[org-monorepo/#1/abc123]" context;
  let context =
    Review_job.log_context
      {
        (debug_dir_test_job ()) with
        change_label = "push fb15a13a";
        head_sha = "fb15a13a357f3e108dfc8257b480ef19ac5d0c00";
      }
  in
  (check string) "push log context" "[org-monorepo/push-fb15a13a/fb15a13a]" context

let feedback_created_at = ptime_exn "2026-06-24T10:00:00Z"

let feedback_comment ?(body = "feedback body") ?(path = "src/main.ml") ?(line = 14) ?start_line () : Review_comment.t =
  {
    path;
    line;
    side = Review_comment.Right;
    start_line;
    start_side = Option.map (fun (_ : int) -> Review_comment.Right) start_line;
    body;
  }

let feedback_input ?(feedback_id = "rvf_test") ?(line = 14) ?(body = "feedback body") () =
  let finding = mk_finding ~path:"src/main.ml" ~line ~severity:Warning ~category:Security ~confidence:High () in
  let comment = feedback_comment ~line ~body () in
  let comment_body = Feedback_store.append_marker ~feedback_id comment.body in
  let marked_comment = { comment with body = comment_body } in
  Feedback_store.
    {
      feedback_id;
      comment = marked_comment;
      finding;
      comment_body;
      evidence_dir = None;
      finding_id = None;
      finding_source = None;
      plugin_name = None;
    }

let record_one_feedback_target ?(feedback_id = "rvf_test") ?(review_id = 1000) ?(line = 14)
  ?(created_at = feedback_created_at) store =
  let input = feedback_input ~feedback_id ~line () in
  Lwt_main.run
    (Feedback_store.record_posted_pr_review_targets store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
       ~head_sha:"abc123def456789012345678901234567890abcd" ~review_id ~review_batch_id:"rvb_test" ~created_at [ input ]);
  input

let record_one_body_feedback_target ?(feedback_id = "rvf_body_test") ?(review_id = 1000)
  ?(review_node_id = "PRR_node_body") ?(created_at = feedback_created_at) store =
  let input : Feedback_store.review_body_target_input =
    { feedback_id; review_node_id; review_body = "review body"; evidence_dir = None }
  in
  Lwt_main.run
    (Feedback_store.record_posted_pr_review_targets store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
       ~head_sha:"abc123def456789012345678901234567890abcd" ~review_id ~review_batch_id:"rvb_body_test" ~created_at
       ~review_body_target:input []);
  input

let single_feedback_target store =
  match (Feedback_store.data store).Feedback_store.targets with
  | [ target ] -> target
  | targets -> fail (Printf.sprintf "expected one feedback target, got %d" (List.length targets))

let find_feedback_target ~kind targets =
  match
    List.find_opt
      (fun (target : Feedback_store.target) ->
        String.equal kind (Feedback_store.target_kind_to_string target.target_kind))
      targets
  with
  | Some target -> target
  | None -> fail (Printf.sprintf "expected feedback target kind %s" kind)

let feedback_event_lines path =
  match Sys.file_exists path with
  | false -> []
  | true ->
    read_file path |> String.split_on_char '\n' |> List.filter (fun line -> not (String.equal (String.trim line) ""))

let rec json_keys json =
  match json with
  | `Assoc fields -> List.concat_map (fun (key, value) -> key :: json_keys value) fields
  | `List values -> List.concat_map json_keys values
  | `Bool _ | `Float _ | `Int _ | `Null | `String _ -> []

let assert_no_forbidden_privacy_keys json =
  let forbidden = [ "sender"; "user"; "login"; "name"; "email"; "author"; "committer"; "pusher"; "avatar_url" ] in
  let keys = json_keys json in
  List.iter (fun key -> (check bool) (Printf.sprintf "forbidden key %s absent" key) false (List.mem key keys)) forbidden

let test_feedback_paths_from_state () =
  let paths = Feedback_store.derive_paths ~state_filepath:"/tmp/reviewotron/state.json" () in
  (check string) "targets sibling" "/tmp/reviewotron/reviewotron-feedback-targets.json" paths.targets;
  (check string) "events sibling" "/tmp/reviewotron/reviewotron-feedback-events.jsonl" paths.events;
  (check string) "evidence sibling" "/tmp/reviewotron/reviewotron-feedback-evidence" paths.evidence_root

let test_feedback_paths_are_absolute () =
  (* A relative --feedback-dir (e.g. "./var/") must be resolved to an absolute path so the
     evidence_dir recorded on each target stays valid regardless of the process working directory
     when the report is later run. *)
  let paths = Feedback_store.derive_paths ~state_filepath:"state.json" ~feedback_dir:"./var" () in
  let cwd = Sys.getcwd () in
  (check bool) "targets path is absolute" true (Filename.is_relative paths.targets |> not);
  (check string) "targets resolved under cwd"
    (Filename.concat (Filename.concat cwd "var") "reviewotron-feedback-targets.json")
    paths.targets;
  (check string) "evidence resolved under cwd"
    (Filename.concat (Filename.concat cwd "var") "reviewotron-feedback-evidence")
    paths.evidence_root

let test_feedback_paths_from_custom_dir () =
  let paths =
    Feedback_store.derive_paths ~state_filepath:"/tmp/reviewotron/state.json"
      ~feedback_dir:"/var/lib/reviewotron/feedback" ()
  in
  (check string) "targets custom dir" "/var/lib/reviewotron/feedback/reviewotron-feedback-targets.json" paths.targets;
  (check string) "events custom dir" "/var/lib/reviewotron/feedback/reviewotron-feedback-events.jsonl" paths.events;
  (check string) "evidence custom dir" "/var/lib/reviewotron/feedback/reviewotron-feedback-evidence" paths.evidence_root;
  let base = Filename.temp_dir "reviewotron_feedback_custom_" "_test" in
  let state_path = Filename.temp_file "reviewotron_feedback_custom_state_" ".json" in
  let feedback_dir = Filename.concat base "feedback" in
  Fun.protect
    ~finally:(fun () ->
      remove_if_exists state_path;
      remove_tree_if_exists base)
    (fun () ->
      let store = Feedback_store.create ~state_filepath:state_path ~feedback_dir () in
      (check bool) "custom dir created" true (Sys.file_exists feedback_dir);
      (check string) "store target path"
        (Filename.concat feedback_dir "reviewotron-feedback-targets.json")
        (Feedback_store.paths store).targets)

let test_feedback_marker_and_id_helpers () =
  let now = ptime_exn "2026-06-24T12:34:56Z" in
  let batch =
    Feedback_store.make_review_batch_id ~repo_url:Test_helpers.test_repo_url ~pr_number:42 ~head_sha:"abc" ~now
      ~nonce:"nonce"
  in
  let feedback_id =
    Feedback_store.make_feedback_id ~review_batch_id:batch ~index:0 ~path:"src/main.ml" ~line:14 ~comment_body:"body"
  in
  let marked = Feedback_store.append_marker ~feedback_id "body" in
  (check bool) "batch prefix" true (CCString.prefix ~pre:"rvb_" batch);
  (check bool) "feedback prefix" true (CCString.prefix ~pre:"rvf_" feedback_id);
  (check (option string)) "extract marker" (Some feedback_id) (Feedback_store.extract_marker marked);
  (check (option string)) "no marker" None (Feedback_store.extract_marker "plain body")

let test_feedback_target_roundtrip_and_privacy () =
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let target_file = Feedback_store.data store in
    let json = Feedback_store.file_to_json target_file in
    assert_no_forbidden_privacy_keys json;
    let decoded = Feedback_store.file_of_json json in
    (check int) "roundtrip target count" 1 (List.length decoded.targets);
    let now = Feedback_store.add_seconds feedback_created_at 60 in
    Lwt_main.run
      (Feedback_store.update_after_poll store ~now ~feedback_id:"rvf_test"
         ~counts:{ Feedback_store.plus_one = 1; minus_one = 0 });
    let event_json =
      match feedback_event_lines paths.events with
      | [ line ] -> Melange_json.of_string line
      | lines -> fail (Printf.sprintf "expected one event line, got %d" (List.length lines))
    in
    assert_no_forbidden_privacy_keys event_json)

let remove_json_fields keys fields = List.filter (fun (key, _value) -> not (List.exists (String.equal key) keys)) fields

let test_feedback_target_schema_compatibility_and_v3_fields () =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let target = single_feedback_target store in
    let inline_target_without_new_fields =
      match Feedback_store.target_to_json target with
      | `Assoc fields ->
        `Assoc
          (remove_json_fields
             [ "evidence_dir"; "finding_id"; "finding_source"; "plugin_name"; "review_node_id"; "review_body_sha256" ]
             fields)
      | _ -> fail "expected target JSON object"
    in
    let decoded =
      Feedback_store.file_of_json (`Assoc [ "schema", `Int 1; "targets", `List [ inline_target_without_new_fields ] ])
    in
    (check int) "v1 target count" 1 (List.length decoded.targets);
    match decoded.targets with
    | [ target ] ->
      (check string) "v1 target kind" "pr_review_comment" (Feedback_store.target_kind_to_string target.target_kind);
      (check (option string)) "v1 evidence_dir default" None target.evidence_dir;
      (check (option string)) "v1 finding_id default" None target.finding_id;
      (check (option string)) "v1 finding_source default" None target.finding_source;
      (check (option string)) "v1 plugin_name default" None target.plugin_name
    | [] | _ :: _ :: _ -> fail "expected one decoded v1 target");
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let target = single_feedback_target store in
    let v2_target =
      match Feedback_store.target_to_json target with
      | `Assoc fields -> `Assoc (remove_json_fields [ "review_node_id"; "review_body_sha256" ] fields)
      | _ -> fail "expected target JSON object"
    in
    let decoded = Feedback_store.file_of_json (`Assoc [ "schema", `Int 2; "targets", `List [ v2_target ] ]) in
    (check int) "v2 target count" 1 (List.length decoded.targets);
    match decoded.targets with
    | [ target ] ->
      (check string) "v2 target kind" "pr_review_comment" (Feedback_store.target_kind_to_string target.target_kind);
      (check (option string)) "v2 path" (Some "src/main.ml") target.path;
      (check (option int)) "v2 line" (Some 14) target.line
    | [] | _ :: _ :: _ -> fail "expected one decoded v2 target");
  with_temp_feedback_store (fun _state_path _paths store ->
    let input =
      {
        (feedback_input ()) with
        evidence_dir = Some "/tmp/reviewotron-feedback-evidence/rvb_schema";
        finding_id = Some "rvfind_schema";
        finding_source = Some "general";
        plugin_name = Some "general";
      }
    in
    let review_body_target : Feedback_store.review_body_target_input =
      {
        feedback_id = "rvf_body_schema";
        review_node_id = "PRR_node_schema";
        review_body = "review body";
        evidence_dir = Some "/tmp/reviewotron-feedback-evidence/rvb_schema";
      }
    in
    Lwt_main.run
      (Feedback_store.record_posted_pr_review_targets store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
         ~head_sha:"abc123def456789012345678901234567890abcd" ~review_id:1000 ~review_batch_id:"rvb_schema"
         ~created_at:feedback_created_at ~review_body_target [ input ]);
    let decoded = Feedback_store.file_of_json (Feedback_store.file_to_json (Feedback_store.data store)) in
    (check int) "v3 schema" 3 decoded.schema;
    (check int) "v3 target count" 2 (List.length decoded.targets);
    let inline_target = find_feedback_target ~kind:"pr_review_comment" decoded.targets in
    let body_target = find_feedback_target ~kind:"pr_review_body" decoded.targets in
    (check (option string)) "body review node id" (Some "PRR_node_schema") body_target.review_node_id;
    (check bool) "body hash stored" true (Option.is_some body_target.review_body_sha256);
    (check (option string))
      "body evidence dir" (Some "/tmp/reviewotron-feedback-evidence/rvb_schema") body_target.evidence_dir;
    match [ inline_target ] with
    | [ target ] ->
      (check (option string))
        "v3 evidence_dir" (Some "/tmp/reviewotron-feedback-evidence/rvb_schema") target.evidence_dir;
      (check (option string)) "v3 finding_id" (Some "rvfind_schema") target.finding_id;
      (check (option string)) "v3 finding_source" (Some "general") target.finding_source;
      (check (option string)) "v3 plugin_name" (Some "general") target.plugin_name
    | [] | _ :: _ :: _ -> fail "expected one decoded v3 inline target")

let test_feedback_deadline_semantics () =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let target = single_feedback_target store in
    let expected_hard_cap =
      Feedback_store.add_seconds feedback_created_at (5 * 24 * 60 * 60) |> Feedback_store.utc_string
    in
    (check string) "initial five day poll_until" expected_hard_cap target.poll_until;
    let first_interaction = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run
      (Feedback_store.apply_user_interaction store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
         ~received_at:first_interaction);
    let target = single_feedback_target store in
    let expected_short = Feedback_store.add_seconds first_interaction (24 * 60 * 60) |> Feedback_store.utc_string in
    (check string) "shortened to first interaction + 24h" expected_short target.poll_until;
    let later_interaction = Feedback_store.add_seconds feedback_created_at (4 * 60 * 60) in
    Lwt_main.run
      (Feedback_store.apply_user_interaction store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
         ~received_at:later_interaction);
    let target = single_feedback_target store in
    (check string) "later interaction does not extend" expected_short target.poll_until;
    Lwt_main.run (Feedback_store.mark_missing store ~now:later_interaction ~feedback_id:"rvf_test");
    Lwt_main.run
      (Feedback_store.apply_user_interaction store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
         ~received_at:(Feedback_store.add_seconds feedback_created_at (6 * 60 * 60)));
    let target = single_feedback_target store in
    (check string) "terminal target unchanged" expected_short target.poll_until)

let test_feedback_close_marks_final_due () =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let closed_at = Feedback_store.add_seconds feedback_created_at (3 * 60 * 60) in
    Lwt_main.run (Feedback_store.mark_pr_closed store ~repo_url:Test_helpers.test_repo_url ~pr_number:42 ~closed_at);
    let target = single_feedback_target store in
    (check string) "status final_due" "final_due" (Feedback_store.target_status_to_string target.status);
    (check (option string))
      "stop reason pr_closed" (Some "pr_closed")
      (Option.map Feedback_store.stop_reason_to_string target.stop_reason))

let test_feedback_pollable_selection () =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let first_due = Lwt_main.run (Feedback_store.pollable_targets store ~now:feedback_created_at) in
    (check int) "active never polled is due" 1 (List.length first_due);
    let first_poll = Feedback_store.add_seconds feedback_created_at 60 in
    Lwt_main.run
      (Feedback_store.update_after_poll store ~now:first_poll ~feedback_id:"rvf_test" ~counts:Feedback_store.zero_counts);
    let too_soon = Feedback_store.add_seconds first_poll (30 * 60) in
    let not_due = Lwt_main.run (Feedback_store.pollable_targets store ~now:too_soon) in
    (check int) "recently polled active target not due" 0 (List.length not_due);
    let due_with_custom_interval =
      Lwt_main.run (Feedback_store.pollable_targets ~poll_interval_seconds:(30 * 60) store ~now:too_soon)
    in
    (check int) "custom poll interval elapsed" 1 (List.length due_with_custom_interval);
    let due_again = Feedback_store.add_seconds first_poll (60 * 60) in
    let due = Lwt_main.run (Feedback_store.pollable_targets store ~now:due_again) in
    (check int) "poll interval elapsed" 1 (List.length due);
    let expired_at = Feedback_store.add_seconds feedback_created_at (5 * 24 * 60 * 60) in
    Lwt_main.run
      (Feedback_store.update_after_poll store ~now:expired_at ~feedback_id:"rvf_test" ~counts:Feedback_store.zero_counts);
    let terminal =
      Lwt_main.run (Feedback_store.pollable_targets store ~now:(Feedback_store.add_seconds expired_at 60))
    in
    (check int) "expired target not polled again" 0 (List.length terminal))

let test_feedback_status_selection_terminal_values () =
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let base = single_feedback_target store in
    let file =
      Feedback_store.
        {
          schema = 1;
          targets =
            [
              { base with feedback_id = "rvf_closed"; status = Closed; stop_reason = Some Pr_closed };
              { base with feedback_id = "rvf_missing"; status = Missing; stop_reason = Some Comment_missing };
              { base with feedback_id = "rvf_error"; status = Error; stop_reason = Some Api_error };
            ];
        }
    in
    write_file paths.targets (Yojson.Basic.to_string (Feedback_store.file_to_json file));
    let reloaded =
      Feedback_store.create ~state_filepath:(Filename.concat (Filename.dirname paths.targets) "state.json") ()
    in
    let due = Lwt_main.run (Feedback_store.pollable_targets reloaded ~now:feedback_created_at) in
    (check int) "closed missing and error targets are terminal" 0 (List.length due))

let reaction ?(id = 1) content : Github_types.reaction = { id; content }

let test_api_remote_collect_paginated_list_requests_all_pages () =
  let seen_pages = ref [] in
  let fetch_page page =
    seen_pages := page :: !seen_pages;
    Lwt.return (Ok (string_of_int page))
  in
  let parse = function
    | "1" -> Ok [ 1; 2 ]
    | "2" -> Ok [ 3; 4 ]
    | "3" -> Ok [ 5 ]
    | value -> Error (Printf.sprintf "unexpected page body %s" value)
  in
  match Lwt_main.run (Api_remote.collect_paginated_list ~page_size:2 ~fetch_page ~parse) with
  | Error msg -> fail (Printf.sprintf "unexpected pagination error: %s" msg)
  | Ok items ->
    (check (list int)) "items from all pages" [ 1; 2; 3; 4; 5 ] items;
    (check (list int)) "requested pages" [ 1; 2; 3 ] (List.rev !seen_pages)

let test_api_remote_parse_pr_review_reaction_counts () =
  let body =
    {|{
  "data": {
    "node": {
      "reactionGroups": [
        {"content": "THUMBS_UP", "reactors": {"totalCount": 4}},
        {"content": "THUMBS_DOWN", "reactors": {"totalCount": 2}},
        {"content": "HEART", "reactors": {"totalCount": 9}}
      ]
    }
  }
}|}
  in
  (match Api_remote.parse_pr_review_reaction_counts body with
  | Ok (Some counts) ->
    (check int) "graphql plus one" 4 counts.Github_types.plus_one;
    (check int) "graphql minus one" 2 counts.minus_one
  | Ok None -> fail "expected GraphQL counts"
  | Error msg -> fail (Printf.sprintf "unexpected GraphQL parse error: %s" msg));
  match Api_remote.parse_pr_review_reaction_counts {|{"data":{"node":null}}|} with
  | Ok None -> ()
  | Ok (Some _) -> fail "expected missing GraphQL node"
  | Error msg -> fail (Printf.sprintf "unexpected null-node parse error: %s" msg)

module Feedback_collector_test = Feedback_collector.Make (Api_local.Github)

let test_feedback_collector_resolves_counts_and_is_idempotent () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    let input = record_one_feedback_target store in
    Api_local.set_pr_review_comments ~review_id:1000 [ { Github_types.id = 90001; body = input.comment.body } ];
    Api_local.set_pr_review_comment_reactions ~comment_id:90001
      [ reaction ~id:1 "+1"; reaction ~id:2 "-1"; reaction ~id:3 "+1"; reaction ~id:4 "heart" ];
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check (option int)) "comment_id resolved" (Some 90001) target.comment_id;
    (check int) "plus one count" 2 target.last_counts.plus_one;
    (check int) "minus one count" 1 target.last_counts.minus_one;
    (check (option string))
      "reaction observed as interaction"
      (Some (Feedback_store.utc_string now))
      target.first_user_interaction_at;
    (check string) "reaction shortens poll window"
      (Feedback_store.add_seconds now (24 * 60 * 60) |> Feedback_store.utc_string)
      target.poll_until;
    let events_after_first = feedback_event_lines paths.events in
    (check int) "resolution and count events" 2 (List.length events_after_first);
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now:(Feedback_store.add_seconds now (10 * 60)) ());
    let events_after_second = feedback_event_lines paths.events in
    (check int) "no duplicate no-op events" 2 (List.length events_after_second))

let test_feedback_collector_final_due_closes_target () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    let input = record_one_feedback_target store in
    Api_local.set_pr_review_comments ~review_id:1000 [ { Github_types.id = 90002; body = input.comment.body } ];
    Api_local.set_pr_review_comment_reactions ~comment_id:90002 [ reaction "+1" ];
    let close_time = Feedback_store.add_seconds feedback_created_at (60 * 60) in
    Lwt_main.run
      (Feedback_store.mark_pr_closed store ~repo_url:Test_helpers.test_repo_url ~pr_number:42 ~closed_at:close_time);
    let ctx = Test_helpers.make_test_context () in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now:close_time ());
    let target = single_feedback_target store in
    (check string) "closed after final poll" "closed" (Feedback_store.target_status_to_string target.status);
    let events = String.concat "\n" (feedback_event_lines paths.events) in
    (check bool) "finalization event written" true (contains_sub ~sub:"target_finalized" events);
    let later = Lwt_main.run (Feedback_store.pollable_targets store ~now:(Feedback_store.add_seconds close_time 60)) in
    (check int) "closed target not polled again" 0 (List.length later))

let test_feedback_collector_marks_missing_on_review_comment_404 () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    Api_local.set_pr_review_comments_error ~review_id:1000 "http 404: not found";
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check string) "missing status" "missing" (Feedback_store.target_status_to_string target.status);
    (check (option string))
      "missing stop reason" (Some "comment_missing")
      (Option.map Feedback_store.stop_reason_to_string target.stop_reason);
    let events = String.concat "\n" (feedback_event_lines paths.events) in
    (check bool) "missing finalization event written" true (contains_sub ~sub:"target_finalized" events))

let test_feedback_collector_marks_missing_on_integration_403 () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    Lwt_main.run
      (Feedback_store.resolve_comment_id store ~now:feedback_created_at ~feedback_id:"rvf_test" ~comment_id:90004);
    (* A deleted PR review comment reached via a GitHub App installation token returns
       403 "Resource not accessible by integration", not 404. Treat it as missing. *)
    Api_local.set_pr_review_comment_reactions_error ~comment_id:90004
      "http 403: error while querying https://api.github.com/repos/o/r/pulls/comments/90004/reactions: \
       {\"message\":\"Resource not accessible by integration\",\"status\":\"403\"}";
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check string) "missing status" "missing" (Feedback_store.target_status_to_string target.status);
    (check (option string))
      "missing stop reason" (Some "comment_missing")
      (Option.map Feedback_store.stop_reason_to_string target.stop_reason);
    let events = String.concat "\n" (feedback_event_lines paths.events) in
    (check bool) "missing finalization event written" true (contains_sub ~sub:"target_finalized" events))

let test_feedback_collector_keeps_active_on_transient_reaction_error () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    Lwt_main.run
      (Feedback_store.resolve_comment_id store ~now:feedback_created_at ~feedback_id:"rvf_test" ~comment_id:90003);
    Api_local.set_pr_review_comment_reactions_error ~comment_id:90003 "http 502: bad gateway";
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check string) "status remains active" "active" (Feedback_store.target_status_to_string target.status);
    (check (option string)) "no stop reason" None (Option.map Feedback_store.stop_reason_to_string target.stop_reason);
    (check (option string)) "not marked polled" None target.last_polled_at;
    let events_after_error = feedback_event_lines paths.events in
    (check int) "only resolution event is written" 1 (List.length events_after_error))

let test_feedback_collector_collects_body_reaction_counts () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_body_feedback_target store : Feedback_store.review_body_target_input);
    Api_local.set_pr_review_body_reaction_counts ~review_node_id:"PRR_node_body"
      { Github_types.plus_one = 3; minus_one = 1 };
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check int) "body plus one count" 3 target.last_counts.plus_one;
    (check int) "body minus one count" 1 target.last_counts.minus_one;
    (check (option string))
      "body reaction observed as interaction"
      (Some (Feedback_store.utc_string now))
      target.first_user_interaction_at;
    let write_log = Api_local.get_write_log () in
    (check bool) "body collector uses GraphQL helper" true
      (contains_sub ~sub:"[get_pr_review_reaction_counts]" write_log);
    let events_after_collect = feedback_event_lines paths.events in
    (check int) "body count event" 1 (List.length events_after_collect))

let test_feedback_collector_marks_body_missing_on_null_graphql_node () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_body_feedback_target store : Feedback_store.review_body_target_input);
    Api_local.set_pr_review_body_reaction_counts_missing ~review_node_id:"PRR_node_body";
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check string) "body missing status" "missing" (Feedback_store.target_status_to_string target.status);
    (check (option string))
      "body missing stop reason" (Some "comment_missing")
      (Option.map Feedback_store.stop_reason_to_string target.stop_reason);
    let events = String.concat "\n" (feedback_event_lines paths.events) in
    (check bool) "body missing finalization event written" true (contains_sub ~sub:"target_finalized" events))

let test_feedback_collector_keeps_body_active_on_graphql_error () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun _state_path paths store ->
    ignore (record_one_body_feedback_target store : Feedback_store.review_body_target_input);
    Api_local.set_pr_review_body_reaction_counts_error ~review_node_id:"PRR_node_body" "http 502: bad gateway";
    let ctx = Test_helpers.make_test_context () in
    let now = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_collector_test.collect ~ctx ~store ~now ());
    let target = single_feedback_target store in
    (check string) "body status remains active" "active" (Feedback_store.target_status_to_string target.status);
    (check (option string))
      "body no stop reason" None
      (Option.map Feedback_store.stop_reason_to_string target.stop_reason);
    (check (option string)) "body not marked polled" None target.last_polled_at;
    let events_after_error = feedback_event_lines paths.events in
    (check int) "body error writes no events" 0 (List.length events_after_error))

let test_feedback_report_summarizes_targets_and_evidence () =
  with_temp_feedback_store (fun _state_path paths store ->
    let review_batch_id = "rvb_report" in
    let evidence_dir = Feedback_evidence.bundle_dir ~evidence_root:paths.evidence_root ~review_batch_id in
    Unix.mkdir paths.evidence_root 0o700;
    Unix.mkdir evidence_dir 0o700;
    let input_up =
      {
        (feedback_input ~feedback_id:"rvf_up" ~line:10 ()) with
        evidence_dir = Some evidence_dir;
        finding_id = Some "rvfind_up";
        finding_source = Some "security";
        plugin_name = Some "security";
      }
    in
    let input_down =
      {
        (feedback_input ~feedback_id:"rvf_down" ~line:20 ()) with
        evidence_dir = Some evidence_dir;
        finding_id = Some "rvfind_down";
        finding_source = Some "general";
        plugin_name = Some "general";
      }
    in
    Lwt_main.run
      (Feedback_store.record_posted_pr_review_targets store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
         ~head_sha:"abc123def456789012345678901234567890abcd" ~review_id:1000 ~review_batch_id
         ~created_at:feedback_created_at
         ~review_body_target:
           {
             Feedback_store.feedback_id = "rvf_body";
             review_node_id = "PRR_node_report";
             review_body = "review body";
             evidence_dir = Some evidence_dir;
           }
         [ input_up; input_down ]);
    Lwt_main.run
      (Feedback_store.resolve_comment_id store ~now:feedback_created_at ~feedback_id:"rvf_up" ~comment_id:91001);
    Lwt_main.run
      (Feedback_store.resolve_comment_id store ~now:feedback_created_at ~feedback_id:"rvf_down" ~comment_id:91002);
    let poll_time = Feedback_store.add_seconds feedback_created_at 60 in
    Lwt_main.run
      (Feedback_store.update_after_poll store ~now:poll_time ~feedback_id:"rvf_up"
         ~counts:{ Feedback_store.plus_one = 1; minus_one = 0 });
    Lwt_main.run
      (Feedback_store.update_after_poll store ~now:poll_time ~feedback_id:"rvf_down"
         ~counts:{ Feedback_store.plus_one = 0; minus_one = 1 });
    Lwt_main.run
      (Feedback_store.update_after_poll store ~now:poll_time ~feedback_id:"rvf_body"
         ~counts:{ Feedback_store.plus_one = 2; minus_one = 0 });
    write_file
      (Filename.concat evidence_dir "manifest.json")
      (Yojson.Basic.to_string
         (`Assoc
            [
              "review_batch_id", `String review_batch_id;
              "repo_url", `String Test_helpers.test_repo_url;
              "pr_number", `Int 42;
              "head_sha", `String "abc123def456789012345678901234567890abcd";
              "trigger", `String "manual";
              "config_sha256", `String "cfg";
              "diff_sha256", `String "diff";
              "comment_count", `Int 2;
              "github_review_id", `Int 1000;
            ]));
    write_file
      (Filename.concat evidence_dir "findings.json")
      (Yojson.Basic.to_string
         (`Assoc
            [
              ( "findings",
                `List
                  [
                    `Assoc
                      [
                        "finding_id", `String "rvfind_up";
                        "routing_outcome", `String "inline";
                        "finding", `Assoc [ "message", `String "security finding accepted" ];
                      ];
                    `Assoc
                      [
                        "finding_id", `String "rvfind_down";
                        "routing_outcome", `String "inline";
                        "finding", `Assoc [ "message", `String "general finding rejected" ];
                      ];
                  ] );
            ]));
    match Feedback_report.load paths with
    | Error msg -> fail msg
    | Ok report ->
      (check int) "report target count" 3 report.totals.target_count;
      (check int) "report reacted count" 3 report.totals.reacted_count;
      (check int) "report positive count" 2 report.totals.positive_count;
      (check int) "report negative count" 1 report.totals.negative_count;
      (check int) "report event count" 5 report.event_count;
      (match report.reviews with
      | [ review ] ->
        (check string) "review batch" review_batch_id review.review_batch_id;
        (check int) "review targets" 3 (List.length review.targets);
        let markdown = Feedback_report.render_markdown report in
        (check bool) "markdown includes positive target" true (contains_sub ~sub:"rvf_up" markdown);
        (check bool) "markdown includes negative target" true (contains_sub ~sub:"rvf_down" markdown);
        (check bool) "markdown includes body target" true (contains_sub ~sub:"rvf_body" markdown);
        (check bool) "markdown renders body target at review level" true (contains_sub ~sub:"review body" markdown);
        (check bool) "markdown includes github comment url" true
          (contains_sub ~sub:"https://github.com/org/monorepo/pull/42#discussion_r91002" markdown);
        (check bool) "markdown includes evidence message" true (contains_sub ~sub:"general finding rejected" markdown);
        let filtered =
          Feedback_report.apply_filter
            { Feedback_report.default_filter with sentiment = Feedback_report.Negative; limit = Some 1 }
            report
        in
        (check int) "filtered target count" 1 filtered.totals.target_count;
        (check int) "filtered negative count" 1 filtered.totals.negative_count;
        let brief = Feedback_report.render_markdown ~include_messages:false filtered in
        (check bool) "brief report omits message" false (contains_sub ~sub:"general finding rejected" brief);
        let json = Feedback_report.to_json report in
        let json_text = Yojson.Basic.to_string json in
        (check bool) "json includes sentiment" true (contains_sub ~sub:{|"sentiment":"negative"|} json_text);
        (check bool) "json includes comment url" true (contains_sub ~sub:{|"github_comment_url"|} json_text);
        (check bool) "json includes body target kind" true
          (contains_sub ~sub:{|"target_kind":"pr_review_body"|} json_text);
        let body_target_json =
          match json with
          | `Assoc fields ->
            (match json_list_field fields "reviews" with
            | [ `Assoc review_fields ] ->
              json_list_field review_fields "targets"
              |> List.find_opt (function
                | `Assoc target_fields ->
                  (match List.assoc_opt "target_kind" target_fields with
                  | Some (`String kind) -> String.equal kind "pr_review_body"
                  | Some (`Assoc _)
                  | Some (`Bool _)
                  | Some (`Float _)
                  | Some (`Int _)
                  | Some (`List _)
                  | Some `Null
                  | None ->
                    false)
                | `Bool _ | `Float _ | `Int _ | `List _ | `Null | `String _ -> false)
            | [ (`Bool _ | `Float _ | `Int _ | `List _ | `Null | `String _) ] -> fail "expected report review object"
            | [] | _ :: _ :: _ -> fail "expected one report review")
          | `Bool _ | `Float _ | `Int _ | `List _ | `Null | `String _ -> fail "expected report object"
        in
        (match body_target_json with
        | Some (`Assoc target_fields) ->
          let has_field name = List.exists (fun (key, _value) -> String.equal key name) target_fields in
          (check bool) "body target json omits path" false (has_field "path");
          (check bool) "body target json omits finding_id" false (has_field "finding_id");
          (check bool) "body target json has review hash" true (has_field "review_body_sha256")
        | Some (`Bool _) | Some (`Float _) | Some (`Int _) | Some (`List _) | Some `Null | Some (`String _) | None ->
          fail "expected body target JSON object")
      | [] | _ :: _ :: _ -> fail "expected one review summary"))

(* Regression: a target may carry a stale [evidence_dir] (e.g. a CWD-relative path written by a
   Reviewotron process whose working directory differs from where the report is later run). The
   report must still find the bundle under the current [evidence_root]/[review_batch_id] rather than
   reporting the manifest and findings as missing. *)
let test_feedback_report_resolves_evidence_when_stored_dir_is_stale () =
  with_temp_feedback_store (fun _state_path paths store ->
    let review_batch_id = "rvb_stale_dir" in
    let real_evidence_dir = Feedback_evidence.bundle_dir ~evidence_root:paths.evidence_root ~review_batch_id in
    Unix.mkdir paths.evidence_root 0o700;
    Unix.mkdir real_evidence_dir 0o700;
    let stale_evidence_dir = Filename.concat "./does-not-exist/reviewotron-feedback-evidence" review_batch_id in
    let input_up =
      {
        (feedback_input ~feedback_id:"rvf_stale" ~line:10 ()) with
        evidence_dir = Some stale_evidence_dir;
        finding_id = Some "rvfind_stale";
        finding_source = Some "security";
        plugin_name = Some "security";
      }
    in
    Lwt_main.run
      (Feedback_store.record_posted_pr_review_targets store ~repo_url:Test_helpers.test_repo_url ~pr_number:42
         ~head_sha:"abc123def456789012345678901234567890abcd" ~review_id:1000 ~review_batch_id
         ~created_at:feedback_created_at [ input_up ]);
    Lwt_main.run
      (Feedback_store.resolve_comment_id store ~now:feedback_created_at ~feedback_id:"rvf_stale" ~comment_id:91003);
    write_file
      (Filename.concat real_evidence_dir "manifest.json")
      (Yojson.Basic.to_string
         (`Assoc
            [
              "review_batch_id", `String review_batch_id;
              "repo_url", `String Test_helpers.test_repo_url;
              "pr_number", `Int 42;
              "head_sha", `String "abc123def456789012345678901234567890abcd";
              "github_review_id", `Int 1000;
            ]));
    write_file
      (Filename.concat real_evidence_dir "findings.json")
      (Yojson.Basic.to_string
         (`Assoc
            [
              ( "findings",
                `List
                  [
                    `Assoc
                      [
                        "finding_id", `String "rvfind_stale";
                        "routing_outcome", `String "inline";
                        "finding", `Assoc [ "message", `String "recovered from real bundle" ];
                      ];
                  ] );
            ]));
    match Feedback_report.load paths with
    | Error msg -> fail msg
    | Ok report ->
      (check (list string)) "no missing-evidence warnings" [] report.warnings;
      (match report.reviews with
      | [ review ] ->
        (check string) "evidence dir resolved to real bundle" real_evidence_dir review.evidence_dir;
        let markdown = Feedback_report.render_markdown report in
        (check bool) "evidence message recovered" true (contains_sub ~sub:"recovered from real bundle" markdown)
      | [] | _ :: _ :: _ -> fail "expected one review summary"))

let test_feedback_publish_records_targets_and_markers () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  with_temp_feedback_store (fun state_path paths feedback_store ->
    let config =
      Config_types.config_of_json
        (Melange_json.of_string
           {|{
              "auto_review_pr_open": true,
              "auto_review_pr_sync": true,
              "review_pushes_to_develop": true,
              "system_prompt_override": "secret top-level prompt",
              "review_plugins": {
                "general": { "system_prompt_override": "secret nested prompt" }
              }
            }|})
    in
    let state = State.create ~filepath:state_path () in
    let ctx = Test_helpers.make_test_context ~state ~feedback_store ~config () in
    let payload = Test_helpers.make_pr_payload () in
    let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
    Lwt_main.run (R_test.process_event ctx ~event);
    let write_log = Api_local.get_write_log () in
    (check bool) "posted marker" true (contains_sub ~sub:"reviewotron-feedback-id" write_log);
    let targets = (Feedback_store.data feedback_store).targets in
    (check int) "body plus inline target" 2 (List.length targets);
    let inline_target = find_feedback_target ~kind:"pr_review_comment" targets in
    let body_target = find_feedback_target ~kind:"pr_review_body" targets in
    (check int) "created review id stored" 1000 inline_target.review_id;
    (check int) "body review id stored" 1000 body_target.review_id;
    (check (option int)) "comment id unresolved initially" None inline_target.comment_id;
    (check (option string)) "body review node id" (Some "PRR_node_1000") body_target.review_node_id;
    (check bool) "body hash stored" true (Option.is_some body_target.review_body_sha256);
    (check string) "repo stored" Test_helpers.test_repo_url inline_target.repo_url;
    (check (option string)) "finding source stored" (Some "general") inline_target.finding_source;
    (check (option string)) "plugin stored" (Some "general") inline_target.plugin_name;
    (check bool) "finding id stored" true
      (match inline_target.finding_id with
      | Some id -> CCString.prefix ~pre:"rvfind_" id
      | None -> false);
    let evidence_dir =
      match inline_target.evidence_dir with
      | Some dir -> dir
      | None -> fail "target missing evidence_dir"
    in
    (check (option string)) "body evidence dir matches" (Some evidence_dir) body_target.evidence_dir;
    (check string) "evidence dir"
      (Feedback_evidence.bundle_dir ~evidence_root:paths.evidence_root ~review_batch_id:inline_target.review_batch_id)
      evidence_dir;
    let read_bundle_json filename =
      let path = Filename.concat evidence_dir filename in
      (check bool) (Printf.sprintf "%s exists" filename) true (Sys.file_exists path);
      match read_json path with
      | `Assoc fields -> fields
      | _ -> fail (Printf.sprintf "expected %s to contain a JSON object" filename)
    in
    let manifest = read_bundle_json "manifest.json" in
    (check string) "manifest batch" inline_target.review_batch_id (json_string_field manifest "review_batch_id");
    (check int) "manifest review id" 1000 (json_int_field manifest "github_review_id");
    (check int) "manifest comment count" 1 (json_int_field manifest "comment_count");
    (check string) "manifest source kind" "github" (json_string_field manifest "source_kind");
    let filtered_diff_path = Filename.concat evidence_dir "filtered_diff.patch" in
    (check bool) "filtered diff exists" true (Sys.file_exists filtered_diff_path);
    (check bool) "filtered diff content" true (contains_sub ~sub:"diff --git" (read_file filtered_diff_path));
    let posted = read_bundle_json "posted_review.json" in
    (check bool) "posted review body asks for feedback" true
      (contains_sub ~sub:Review_format.feedback_prompt (json_string_field posted "body"));
    let posted_comments = json_list_field posted "comments" in
    (match posted_comments with
    | [ `Assoc comment_fields ] ->
      (check string) "posted feedback id" inline_target.feedback_id (json_string_field comment_fields "feedback_id");
      (check (option string))
        "posted finding id" inline_target.finding_id
        (Some (json_string_field comment_fields "finding_id"));
      (check bool) "posted body has marker" true
        (contains_sub ~sub:"reviewotron-feedback-id" (json_string_field comment_fields "body"));
      (check bool) "posted body asks for feedback" true
        (contains_sub ~sub:Review_format.feedback_prompt (json_string_field comment_fields "body"));
      (check string) "posted body hash"
        (require_some "inline target missing comment_body_sha256" inline_target.comment_body_sha256)
        (json_string_field comment_fields "comment_body_sha256")
    | _ -> fail "expected one posted review comment");
    let findings = read_bundle_json "findings.json" in
    (match json_list_field findings "findings" with
    | [ `Assoc finding_fields ] ->
      (check string) "finding routing" "inline" (json_string_field finding_fields "routing_outcome");
      (check string) "finding source" "general" (json_string_field finding_fields "finding_source");
      (check string) "finding plugin" "general" (json_string_field finding_fields "plugin_name");
      (check (option string))
        "finding id linked" inline_target.finding_id
        (Some (json_string_field finding_fields "finding_id"))
    | _ -> fail "expected one routed finding");
    let costs = read_bundle_json "review_costs.json" in
    (check bool) "costs included" true
      (match json_list_field costs "review_costs" with
      | [] -> false
      | _ :: _ -> true);
    let config_path = Filename.concat evidence_dir "review_config.json" in
    let config_text = read_file config_path in
    (check bool) "top-level prompt redacted" false (contains_sub ~sub:"secret top-level prompt" config_text);
    (check bool) "nested prompt redacted" false (contains_sub ~sub:"secret nested prompt" config_text);
    let config = read_bundle_json "review_config.json" in
    (match List.assoc_opt "auto_review_pr_open" config with
    | Some (`Bool true) -> ()
    | Some _ | None -> fail "expected review config to include auto_review_pr_open=true");
    let fetched_files = read_bundle_json "fetched_files.json" in
    let fetched_file_keys = json_keys (`Assoc fetched_files) in
    (check bool) "fetched metadata has no content field" false (List.exists (String.equal "content") fetched_file_keys))

let test_feedback_publish_body_only_records_body_target_and_evidence () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/missing_for_body_only_test.json";
  with_temp_feedback_store (fun state_path paths feedback_store ->
    let state = State.create ~filepath:state_path () in
    let ctx =
      Test_helpers.make_test_context ~state ~feedback_store ~config:Test_helpers.auto_review_enabled_config ()
    in
    let payload = Test_helpers.make_pr_payload () in
    let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
    Lwt_main.run (R_test.process_event ctx ~event);
    let write_log = Api_local.get_write_log () in
    (check bool) "body-only review posted" true (contains_sub ~sub:"[create_pr_review]" write_log);
    (check bool) "body-only review asks for feedback" true (contains_sub ~sub:Review_format.feedback_prompt write_log);
    let targets = (Feedback_store.data feedback_store).targets in
    (check int) "one body target" 1 (List.length targets);
    let body_target = find_feedback_target ~kind:"pr_review_body" targets in
    (check (option string)) "body review node id" (Some "PRR_node_1000") body_target.review_node_id;
    (check (option int)) "body target has no comment id" None body_target.comment_id;
    (check (option string)) "body target has no finding id" None body_target.finding_id;
    let evidence_dir = require_some "body target missing evidence_dir" body_target.evidence_dir in
    (check string) "body evidence dir"
      (Feedback_evidence.bundle_dir ~evidence_root:paths.evidence_root ~review_batch_id:body_target.review_batch_id)
      evidence_dir;
    let posted =
      match read_json (Filename.concat evidence_dir "posted_review.json") with
      | `Assoc fields -> fields
      | _ -> fail "expected posted_review.json object"
    in
    (check bool) "posted review body persisted" true
      (contains_sub ~sub:Review_format.feedback_prompt (json_string_field posted "body"));
    match json_list_field posted "comments" with
    | [] -> ()
    | _ :: _ -> fail "expected no posted inline comments for body-only feedback")

let test_feedback_publish_failure_records_no_targets () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store (fun state_path paths feedback_store ->
    Api_local.set_next_pr_review_error "missing pull request review permission";
    let state = State.create ~filepath:state_path () in
    let ctx =
      Test_helpers.make_test_context ~state ~feedback_store ~config:Test_helpers.auto_review_enabled_config ()
    in
    let payload = Test_helpers.make_pr_payload () in
    let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
    Lwt_main.run (R_test.process_event ctx ~event);
    (check int) "no targets after failed post" 0 (List.length (Feedback_store.data feedback_store).targets);
    (check bool) "no evidence after failed post" false (Sys.file_exists paths.evidence_root))

let test_feedback_quiet_success_records_no_targets () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
  Api_local.set_agent_response_map [ "general_scout", "mock_api_responses/scout/leads_empty.json" ];
  with_temp_feedback_store (fun state_path paths feedback_store ->
    let state = State.create ~filepath:state_path () in
    let ctx =
      Test_helpers.make_test_context ~state ~feedback_store ~config:Test_helpers.auto_review_enabled_config ()
    in
    let payload = Test_helpers.make_pr_payload () in
    let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
    Lwt_main.run (R_test.process_event ctx ~event);
    let write_log = Api_local.get_write_log () in
    (check int) "no inline targets for quiet success" 0 (List.length (Feedback_store.data feedback_store).targets);
    (check bool) "quiet success omits feedback prompt" false (contains_sub ~sub:Review_format.feedback_prompt write_log);
    (check bool) "no evidence for quiet success" false (Sys.file_exists paths.evidence_root))

let test_feedback_disabled_writes_no_evidence () =
  Test_helpers.reset_test_state ();
  let state_path = Filename.temp_file "reviewotron_feedback_disabled_state_" ".json" in
  let paths = Feedback_store.derive_paths ~state_filepath:state_path () in
  Fun.protect
    ~finally:(fun () ->
      remove_if_exists state_path;
      remove_if_exists paths.targets;
      remove_if_exists paths.events;
      remove_tree_if_exists paths.evidence_root)
    (fun () ->
      let state = State.create ~filepath:state_path () in
      let ctx = Test_helpers.make_test_context ~state ~config:Test_helpers.auto_review_enabled_config () in
      let payload = Test_helpers.make_pr_payload () in
      let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
      Lwt_main.run (R_test.process_event ctx ~event);
      let write_log = Api_local.get_write_log () in
      (check bool) "review still posted" true (contains_sub ~sub:"[create_pr_review]" write_log);
      (check bool) "no targets when feedback disabled" false (Sys.file_exists paths.targets);
      (check bool) "no evidence when feedback disabled" false (Sys.file_exists paths.evidence_root))

let test_feedback_webhook_store_failure_does_not_block_review () =
  Test_helpers.reset_test_state ();
  with_temp_feedback_store_dir (fun feedback_state_path _paths feedback_store ->
    let old_created_at = ptime_exn "2020-01-01T00:00:00Z" in
    ignore (record_one_feedback_target ~created_at:old_created_at feedback_store : Feedback_store.target_input);
    Unix.chmod (Filename.dirname feedback_state_path) 0o500;
    let review_state_path = Filename.temp_file "reviewotron_review_state_" ".json" in
    Fun.protect
      ~finally:(fun () -> remove_if_exists review_state_path)
      (fun () ->
        let state = State.create ~filepath:review_state_path () in
        let ctx =
          Test_helpers.make_test_context ~state ~feedback_store ~config:Test_helpers.auto_review_enabled_config ()
        in
        let payload = Test_helpers.make_pr_payload ~action:"synchronize" () in
        let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
        Lwt_main.run (R_test.process_event ctx ~event);
        let write_log = Api_local.get_write_log () in
        (check bool) "review still posted" true (contains_sub ~sub:"[create_pr_review]" write_log)))

let test_feedback_webhook_issue_comment_shortens_deadline () =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let body = Test_helpers.make_issue_comment_payload ~body:"Looks good to me" () in
    let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body in
    let received_at = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_store.handle_webhook_event store ~event ~received_at);
    let target = single_feedback_target store in
    let expected = Feedback_store.add_seconds received_at (24 * 60 * 60) |> Feedback_store.utc_string in
    (check string) "issue_comment shortens deadline" expected target.poll_until)

let pull_request_json_from_payload () =
  match Melange_json.of_string (Test_helpers.make_pr_payload ()) with
  | `Assoc fields ->
    (match List.assoc_opt "pull_request" fields with
    | Some json -> Yojson.Basic.to_string json
    | None -> fail "missing pull_request fixture field")
  | _ -> fail "expected PR payload object"

let review_webhook_payload ~event_kind ~action =
  let pull_request_json = pull_request_json_from_payload () in
  match event_kind with
  | `Review ->
    Printf.sprintf
      {|{
  "action": %S,
  "review": {"id": 7001, "body": "review body", "state": "commented", "user": %s},
  "pull_request": %s,
  "repository": %s,
  "sender": %s
}|}
      action
      (Test_helpers.user_json ~login:"reviewer1" ())
      pull_request_json (Test_helpers.repo_json ())
      (Test_helpers.user_json ~login:"reviewer1" ())
  | `Review_comment ->
    Printf.sprintf
      {|{
  "action": %S,
  "comment": {"id": 8001, "body": "reply", "path": "src/main.ml", "line": 14, "user": %s},
  "pull_request": %s,
  "repository": %s,
  "sender": %s
}|}
      action
      (Test_helpers.user_json ~login:"reviewer1" ())
      pull_request_json (Test_helpers.repo_json ())
      (Test_helpers.user_json ~login:"reviewer1" ())

let assert_feedback_webhook_shortens ~event_type ~body =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let event = Test_helpers.parse_event_exn ~event_type ~body in
    let received_at = Feedback_store.add_seconds feedback_created_at (2 * 60 * 60) in
    Lwt_main.run (Feedback_store.handle_webhook_event store ~event ~received_at);
    let target = single_feedback_target store in
    Feedback_store.add_seconds received_at (24 * 60 * 60) |> Feedback_store.utc_string |> fun expected ->
    (check string) (Printf.sprintf "%s shortens deadline" event_type) expected target.poll_until)

let test_feedback_webhook_pr_synchronize_shortens_deadline () =
  assert_feedback_webhook_shortens ~event_type:"pull_request"
    ~body:(Test_helpers.make_pr_payload ~action:"synchronize" ())

let test_feedback_webhook_review_shortens_deadline () =
  assert_feedback_webhook_shortens ~event_type:"pull_request_review"
    ~body:(review_webhook_payload ~event_kind:`Review ~action:"submitted")

let test_feedback_webhook_review_comment_shortens_deadline () =
  assert_feedback_webhook_shortens ~event_type:"pull_request_review_comment"
    ~body:(review_webhook_payload ~event_kind:`Review_comment ~action:"created")

let test_feedback_webhook_pr_close_marks_final_due () =
  with_temp_feedback_store (fun _state_path _paths store ->
    ignore (record_one_feedback_target store : Feedback_store.target_input);
    let body = Test_helpers.make_pr_payload ~action:"closed" () in
    let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body in
    Lwt_main.run
      (Feedback_store.handle_webhook_event store ~event
         ~received_at:(Feedback_store.add_seconds feedback_created_at (60 * 60)));
    let target = single_feedback_target store in
    (check string) "PR close marks final_due" "final_due" (Feedback_store.target_status_to_string target.status);
    (check (option string))
      "close stop reason" (Some "pr_closed")
      (Option.map Feedback_store.stop_reason_to_string target.stop_reason))

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

let test_estimate_cost_openrouter_sonnet () =
  let cost =
    Cost_tracking.estimate_cost ~model_id:"anthropic/claude-sonnet-4.6" ~input_tokens:1_000_000 ~output_tokens:1_000_000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (check (float 1e-6)) "openrouter sonnet fallback estimate" 18.0 cost

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

let test_estimate_cost_default_tier_models () =
  (* Regression guard: the Standard/Strong tier defaults (Agent_runner.default_model_id)
     must resolve to non-zero pricing, or cost tracking silently reports $0. *)
  let cost_sonnet_5 =
    Cost_tracking.estimate_cost ~model_id:"claude-sonnet-5" ~input_tokens:1_000_000 ~output_tokens:1_000_000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (* Sonnet 5: $3/M input, $15/M output -> 3.0 + 15.0 = 18.0 *)
  (check (float 1e-6)) "sonnet-5 1M in + 1M out" 18.0 cost_sonnet_5;
  let cost_opus_4_8 =
    Cost_tracking.estimate_cost ~model_id:"claude-opus-4-8" ~input_tokens:100_000 ~output_tokens:10_000
      ~cache_read_input_tokens:0 ~cache_creation_input_tokens:0
  in
  (* Opus 4.8: $5/M input, $25/M output -> 100k*5/1M + 10k*25/1M = 0.50 + 0.25 = 0.75 *)
  (check (float 1e-6)) "opus-4-8 100k in + 10k out" 0.75 cost_opus_4_8

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
      tool_calls_count = 3;
      tool_results_count = 2;
      model_id = "claude-sonnet-4-6-20260414";
      reported_cost_usd = None;
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
  (check (float 1e-6)) "estimated_cost_usd" 0.0135 cost.estimated_cost_usd;
  let reported =
    Cost_tracking.of_agent_result ~agent_name:"test_agent" ~files_fetched:2
      { result with reported_cost_usd = Some 0.42 }
  in
  (check (float 1e-6)) "reported cost wins" 0.42 reported.estimated_cost_usd

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
  (check string) "github url" "org-monorepo" (Security_memory.repo_slug "https://github.com/org/monorepo")

let test_repo_slug_with_git_suffix () =
  (check string) "git suffix" "org-monorepo" (Security_memory.repo_slug "https://github.com/org/monorepo.git")

let test_repo_slug_trailing_slash () =
  (check string) "trailing slash" "org-monorepo" (Security_memory.repo_slug "https://github.com/org/monorepo/")

let test_repo_slug_http () =
  (check string) "http url" "org-monorepo" (Security_memory.repo_slug "http://github.com/org/monorepo")

let test_repo_slug_bare () = (check string) "bare path" "org-monorepo" (Security_memory.repo_slug "org/monorepo")

let test_memory_path () =
  let path = Security_memory.memory_path ~memory_dir:"memory" ~repo_url:"https://github.com/org/monorepo" in
  (check string) "memory path" "memory/org-monorepo.md" path

let test_memory_load_missing () =
  let result =
    Security_memory.load ~log_context:None ~memory_dir:"nonexistent_dir_for_test"
      ~repo_url:"https://github.com/test/repo"
  in
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
      let log_context = "[test-repo/#1/abc123]" in
      Security_memory.save ~log_context:(Some log_context) ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo"
        ~content;
      let loaded =
        Security_memory.load ~log_context:(Some log_context) ~memory_dir:tmp_dir
          ~repo_url:"https://github.com/test/repo"
      in
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
      Security_memory.save ~log_context:None ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo" ~content:"";
      let loaded =
        Security_memory.load ~log_context:None ~memory_dir:tmp_dir ~repo_url:"https://github.com/test/repo"
      in
      (check bool) "empty file returns None" true (Option.is_none loaded))

(** {2 Memory curator agent tests} *)

let empty_observations : Security_types.architectural_observations =
  { language_hints = []; reviewed_files = []; vuln_class_distribution = [] }

let test_curator_output_roundtrip () =
  let open Security_types in
  let output = { updated_memory = "# test/repo\n\n## Architecture\n- OCaml backend\n" } in
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

let test_curator_prompt_architectural_only () =
  let cfg = Memory_curator_agent.config ~model_tier:Fast in
  let prompt = cfg.system_prompt in
  (check bool) "prompt names Architecture section" true (Devkit.Stre.exists prompt "## Architecture");
  (check bool) "prompt names Known Safe Patterns section" true (Devkit.Stre.exists prompt "## Known Safe Patterns");
  (check bool) "prompt forbids line-number references" true
    (Devkit.Stre.exists prompt "line number"
    || Devkit.Stre.exists prompt "line-number"
    || Devkit.Stre.exists prompt "path:line");
  (check bool) "prompt explicitly rejects Known Risk Areas" true (Devkit.Stre.exists prompt "Known Risk Areas");
  (check bool) "prompt explicitly rejects Suppressions" true (Devkit.Stre.exists prompt "Suppressions")

let test_curator_build_input_no_memory () =
  let observations : Security_types.architectural_observations =
    {
      language_hints = [ "ocaml" ];
      reviewed_files = [ "lib/db.ml"; "lib/auth.ml" ];
      vuln_class_distribution = [ "injection", 2 ];
    }
  in
  let input = Memory_curator_agent.build_input ~repo_name:"org-monorepo" ~memory_max_tokens:500 ~observations () in
  (check bool) "contains repo name" true (Devkit.Stre.exists input "org-monorepo");
  (check bool) "contains 'No existing brief'" true (Devkit.Stre.exists input "No existing brief");
  (check bool) "contains current token count" true (Devkit.Stre.exists input "Current: 0 tokens");
  (check bool) "contains max token budget" true (Devkit.Stre.exists input "Maximum: 500 tokens");
  (check bool) "contains language hint" true (Devkit.Stre.exists input "ocaml");
  (check bool) "contains reviewed file" true (Devkit.Stre.exists input "lib/db.ml");
  (check bool) "contains vuln class distribution" true (Devkit.Stre.exists input "injection: 2")

let test_curator_build_input_with_memory () =
  let existing = "# test/repo\n\n## Architecture\n- OCaml backend\n" in
  let observations : Security_types.architectural_observations =
    { language_hints = [ "ocaml" ]; reviewed_files = [ "lib/api.ml" ]; vuln_class_distribution = [] }
  in
  let input =
    Memory_curator_agent.build_input ~repo_name:"test-repo" ~memory_max_tokens:500 ~observations
      ~current_memory:existing ()
  in
  (check bool) "contains existing memory" true (Devkit.Stre.exists input "OCaml backend");
  (check bool) "contains Current Brief section" true (Devkit.Stre.exists input "## Current Brief");
  (check bool) "no 'No existing brief' text" false (Devkit.Stre.exists input "No existing brief");
  (check bool) "contains current token estimate" true (Devkit.Stre.exists input "Current: ~");
  (check bool) "contains max token budget" true (Devkit.Stre.exists input "Maximum: 500 tokens");
  (check bool) "contains reviewed file" true (Devkit.Stre.exists input "lib/api.ml")

let test_curator_build_input_empty_memory () =
  let input =
    Memory_curator_agent.build_input ~repo_name:"test-repo" ~memory_max_tokens:500 ~observations:empty_observations
      ~current_memory:"" ()
  in
  (check bool) "empty memory treated as no brief" true (Devkit.Stre.exists input "No existing brief")

let test_curator_build_input_empty_observations () =
  let input =
    Memory_curator_agent.build_input ~repo_name:"test-repo" ~memory_max_tokens:500 ~observations:empty_observations
      ~current_memory:"# test-repo\n" ()
  in
  (check bool) "still contains existing brief" true (Devkit.Stre.exists input "# test-repo");
  (* No observations ⇒ no observation sections rendered *)
  (check bool) "no language hints section" false (Devkit.Stre.exists input "## Language Hints");
  (check bool) "no reviewed files section" false (Devkit.Stre.exists input "## Reviewed Files");
  (check bool) "no distribution section" false (Devkit.Stre.exists input "## Triage Vuln-Class Distribution")

let test_curator_build_input_samples_long_file_list () =
  let files = List.init 30 (fun i -> Printf.sprintf "src/f%d.ts" i) in
  let observations : Security_types.architectural_observations =
    { language_hints = []; reviewed_files = files; vuln_class_distribution = [] }
  in
  let input = Memory_curator_agent.build_input ~repo_name:"test-repo" ~memory_max_tokens:500 ~observations () in
  (check bool) "first file present" true (Devkit.Stre.exists input "src/f0.ts");
  (check bool) "12th file present" true (Devkit.Stre.exists input "src/f11.ts");
  (check bool) "sample truncated with ellipsis" true (Devkit.Stre.exists input "- ...\n");
  (check bool) "late file not present" false (Devkit.Stre.exists input "src/f25.ts")

(** INVARIANT: the curator input cannot contain per-finding path/line references.

    The curator's job is to maintain an architectural brief — never to
    catalogue findings.  We construct observations as the plugin does
    (from [build_observations]) and check that even when the review
    produced findings with real paths and line numbers, none of them
    leak into the curator's prompt. *)
let test_curator_input_never_contains_findings () =
  let triage_output : Security_types.triage_output =
    {
      signals =
        [
          {
            vuln_class = Injection;
            confidence = High;
            regions = [ { path = "src/lib/db.ts"; start_line = 10; end_line = 20 } ];
            rationale = "concat into sql";
          };
          {
            vuln_class = Xss;
            confidence = Medium;
            regions = [ { path = "src/views/user.ts"; start_line = 5; end_line = 5 } ];
            rationale = "unescaped";
          };
        ];
      language_hints = [ "TypeScript" ];
      skip_reason = None;
    }
  in
  let file_paths = [ "src/lib/db.ts"; "src/views/user.ts"; "src/routes/auth.ts" ] in
  let findings : Review_types.finding list =
    [
      {
        path = "src/lib/db.ts";
        line = 42;
        end_line = None;
        severity = Critical;
        category = Security;
        message = "SQL injection in query builder";
        failure_scenario = "Attacker controls SQL text.";
        evidence_snippet = "ORDER BY ${orderBy}";
        why_now = "The query builder changed in this PR.";
        confidence = Review_types.High;
        suggested_fix = None;
      };
      {
        path = "src/routes/auth.ts";
        line = 17;
        end_line = None;
        severity = Warning;
        category = Security;
        message = "Missing authz check";
        failure_scenario = "Authenticated user can access another resource.";
        evidence_snippet = "get_resource id";
        why_now = "The route changed in this PR.";
        confidence = Review_types.Medium;
        suggested_fix = None;
      };
    ]
  in
  ignore (findings : Review_types.finding list);
  let observations = Sec_test.build_observations ~triage_output ~file_paths in
  let input = Memory_curator_agent.build_input ~repo_name:"test-repo" ~memory_max_tokens:500 ~observations () in
  (* Findings' identifying information must not appear in the curator prompt. *)
  (check bool) "no confirmed-finding line number 1" false (Devkit.Stre.exists input ":42");
  (check bool) "no confirmed-finding line number 2" false (Devkit.Stre.exists input ":17");
  (check bool) "no 'Confirmed security finding' phrase" false (Devkit.Stre.exists input "Confirmed security finding");
  (check bool) "no finding message 1" false (Devkit.Stre.exists input "SQL injection in query builder");
  (check bool) "no finding message 2" false (Devkit.Stre.exists input "Missing authz check");
  (* But the architectural shape *is* there. *)
  (check bool) "language hint present" true (Devkit.Stre.exists input "TypeScript");
  (check bool) "reviewed file present" true (Devkit.Stre.exists input "src/lib/db.ts");
  (check bool) "vuln class distribution present" true (Devkit.Stre.exists input "injection: 1")

let test_curator_save_load_roundtrip () =
  let tmp_dir = Filename.temp_dir "reviewotron_curator_" "_test" in
  let repo_url = "https://github.com/test/repo" in
  Fun.protect
    ~finally:(fun () ->
      let mem_path = Security_memory.memory_path ~memory_dir:tmp_dir ~repo_url in
      (try Sys.remove mem_path with Sys_error _ -> ());
      try Unix.rmdir tmp_dir with Unix.Unix_error _ -> ())
    (fun () ->
      let updated_memory =
        "# test-repo\n\n## Architecture\n- OCaml with Dream\n\n## Known Safe Patterns\n- Db.query parameterized\n"
      in
      Security_memory.save ~log_context:None ~memory_dir:tmp_dir ~repo_url ~content:updated_memory;
      let loaded = Security_memory.load ~log_context:None ~memory_dir:tmp_dir ~repo_url in
      match loaded with
      | None -> Alcotest.fail "expected memory to be present after save"
      | Some content -> (check bool) "loaded content matches saved" true (String.equal content updated_memory))

let test_curator_build_input_token_budget () =
  let large_memory = String.make 4001 'x' in
  let max_tokens = 500 in
  let input =
    Memory_curator_agent.build_input ~repo_name:"test-repo" ~memory_max_tokens:max_tokens
      ~observations:empty_observations ~current_memory:large_memory ()
  in
  let estimated = Memory_curator_agent.estimate_tokens large_memory in
  (check bool) "estimated tokens exceeds limit" true (estimated > max_tokens);
  (check bool) "curator input contains token budget section" true (Devkit.Stre.exists input "## Token Budget");
  (check bool) "curator input contains maximum tokens" true
    (Devkit.Stre.exists input (Printf.sprintf "Maximum: %d tokens" max_tokens));
  (check bool) "curator input contains current estimate" true (Devkit.Stre.exists input "Current: ~")

(** {2 Security pipeline end-to-end tests} *)

let test_security_e2e_vulnerable () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
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
  (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
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
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/security/triage_safe.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
  (check bool) "no security category" true (CCString.find ~sub:{|"security"|} write_log < 0)

let test_security_e2e_deterministic_signals_do_not_route () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff signal_diff;
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
  (check bool) "deterministic signals alone do not produce security output" true
    (CCString.find ~sub:{|"security"|} write_log < 0);
  (check bool) "no security failure notice" true
    (CCString.find ~sub:"security review plugin encountered an error" write_log < 0)

let test_security_e2e_rejected () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
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
  (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
  (check bool) "no security findings after rejection" true (CCString.find ~sub:{|"security"|} write_log < 0)

(** Triage occasionally emits [skip_reason: ""] (an empty string) instead of
    [skip_reason: null] when it has signals to report — the LLM populates
    the optional field with a placeholder rather than omitting it.  Pre-fix
    we treated [Some ""] the same as a real skip reason and silenced the
    entire security pipeline (observed in production).  This regression
    test pins the post-fix behaviour: an
    empty-or-whitespace [skip_reason] is treated as [None] and analysis
    proceeds based on the signals. *)
let test_security_e2e_triage_empty_skip_reason () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/security/triage_injection_empty_skip.json";
      "security_analysis_injection", "mock_api_responses/security/analysis_injection.json";
      "security_validator", "mock_api_responses/security/validator_confirmed.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "empty skip_reason did NOT silence security pipeline" true
    (CCString.find ~sub:"**[critical]** security" write_log >= 0);
  (check bool) "injection finding surfaced" true
    (CCString.find ~sub:"SQL query string without parameterization" write_log >= 0)

let test_security_e2e_disabled () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "review_plugins": {"security": {"enabled": false}}}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
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
  (check bool) "has general failure notice" true (CCString.find ~sub:"General review failed" write_log >= 0);
  (check bool) "notes security completion" true
    (CCString.find ~sub:"security review completed and found no confirmed security findings" write_log >= 0);
  (check bool) "has re-trigger message" true (CCString.find ~sub:"re-trigger the review" write_log >= 0);
  (check bool) "surfaces failure cause in details" true
    (CCString.find ~sub:"<details open><summary>Details</summary>" write_log >= 0)

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

let test_push_prepare_failure_posts_slack () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"review_pushes_to_develop": true, "slack_channel": "dev-reviews", "max_files": 1}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "slack message sent" true (contains_sub ~sub:"[slack]" write_log);
  (check bool) "no commit comments attempted" false (contains_sub ~sub:"[create_commit_comment]" write_log);
  let slack_msgs = Api_local.get_slack_messages () in
  (check int) "one slack message" 1 (List.length slack_msgs);
  match slack_msgs with
  | [] -> fail "expected at least one Slack message"
  | (_channel, _text, attachments) :: _ ->
  match attachments with
  | None -> fail "expected Slack attachments"
  | Some [] -> fail "expected at least one attachment"
  | Some (att :: _) ->
    (check bool) "attachment explains file limit" true (contains_sub ~sub:"diff touches 4 files" att.Slack_types.text);
    (match event with
    | Github.Push push ->
      (check bool) "terminal prepare failure recorded in state" true
        (State.is_push_reviewed (Context.state ctx) ~repo_url:push.repository.url ~after_sha:push.after)
    | Github.Pull_request _ | Github.Issue_comment _ | Github.Pull_request_review _
    | Github.Pull_request_review_comment _ | Github.Unknown _ ->
      fail "expected push event");
    Api_local.clear_write_log ();
    Api_local.clear_slack_messages ();
    Lwt_main.run (R_test.process_event ctx ~event);
    (check string) "duplicate terminal failure skipped" "" (Api_local.get_write_log ());
    (check int) "duplicate terminal failure sends no Slack" 0 (List.length (Api_local.get_slack_messages ()))

let test_push_generated_files_do_not_trigger_prepare_failure_slack () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
    ];
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"review_pushes_to_develop": true, "slack_channel": "dev-reviews", "max_files": 1}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_push_payload ~before:"genbase" ~after:"genhead" () in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "push review posted commit comment" true (contains_sub ~sub:"[create_commit_comment]" write_log);
  (check bool) "slack message sent" true (contains_sub ~sub:"[slack]" write_log);
  (check bool) "no prepare failure slack" false (contains_sub ~sub:"Code Review Failed" write_log);
  (check bool) "file-limit reason absent" false (contains_sub ~sub:"diff touches" write_log)

let test_push_empty_prepare_posts_skip_slack () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string
         {|{"review_pushes_to_develop": true, "slack_channel": "dev-reviews", "ignored_paths": ["backend/api/src/request_handler.ml", "backend/lib/string_utils.ml", "backend/lib/string_utils.mli", "backend/lib/dune"]}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/push_develop.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"push" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "empty push diff logs a skip" true (contains_sub ~sub:"Code Review Skipped" write_log);
  let slack_msgs = Api_local.get_slack_messages () in
  (check int) "empty push diff sends one Slack skip" 1 (List.length slack_msgs);
  (match slack_msgs with
  | [] -> fail "expected a Slack skip message"
  | (_channel, text, attachments) :: _ ->
    (check bool) "Slack text identifies skip" true (contains_sub ~sub:"Code Review Skipped" text);
    (match attachments with
    | None -> fail "expected a Slack skip attachment"
    | Some [] -> fail "expected a Slack skip attachment"
    | Some (attachment :: _) ->
      (check bool) "Slack attachment explains skip" true
        (contains_sub ~sub:"no code was analyzed or approved" attachment.Slack_types.text)));
  match event with
  | Github.Push push ->
    (check bool) "empty push diff recorded in state" true
      (State.is_push_reviewed (Context.state ctx) ~repo_url:push.repository.url ~after_sha:push.after)
  | Github.Pull_request _ | Github.Issue_comment _ | Github.Pull_request_review _ | Github.Pull_request_review_comment _
  | Github.Unknown _ ->
    fail "expected push event"

(** {2 Security plugin failure notice tests} *)

let test_pr_security_failure_notice () =
  Test_helpers.reset_test_state ();
  (* Map security_triage agent to a nonexistent file so it fails entirely.
     General review succeeds normally. When triage produces no costs,
     run_plugins detects the error. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/claude/review_response.json";
      "security_triage", "mock_api_responses/nonexistent_security_triage.json";
    ];
  let ctx = Test_helpers.make_test_context ~config:security_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "has deterministic review body" true (contains_sub ~sub:":robot: **REVIEW**" write_log);
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
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "review_plugins": {"security": {"enabled": false}}}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "review posted" true (CCString.find ~sub:"[create_pr_review]" write_log >= 0);
  (check bool) "no security failure notice" true
    (CCString.find ~sub:"security review plugin encountered an error" write_log < 0)

(** {2 GitHub API retry tests}

    Classification and the backoff loop are unit-tested directly against the
    typed {!Http_util.error}.  The retry itself lives in [Api_remote.github_request]
    (at the real HTTP boundary, where the typed error is in hand), so it is not
    reachable through the [Api_local] mock — hence no end-to-end fault-injection
    tests here. *)

let test_retry_classification () =
  let retryable label e = (check bool) (Printf.sprintf "retryable: %s" label) true (Github_retry.is_retryable e) in
  let permanent label e = (check bool) (Printf.sprintf "permanent: %s" label) false (Github_retry.is_retryable e) in
  (* transient curl transport errors (the failure that motivated this) *)
  retryable "resolve host" (Http_util.Transport Curl.CURLE_COULDNT_RESOLVE_HOST);
  retryable "connect" (Http_util.Transport Curl.CURLE_COULDNT_CONNECT);
  retryable "timeout" (Http_util.Transport Curl.CURLE_OPERATION_TIMEOUTED);
  retryable "recv" (Http_util.Transport Curl.CURLE_RECV_ERROR);
  retryable "tls connect" (Http_util.Transport Curl.CURLE_SSL_CONNECT_ERROR);
  (* deterministic curl errors must not be retried *)
  permanent "malformed url" (Http_util.Transport Curl.CURLE_URL_MALFORMAT);
  permanent "too many redirects" (Http_util.Transport Curl.CURLE_TOO_MANY_REDIRECTS);
  (* server-side and rate-limit HTTP statuses *)
  retryable "500" (Http_util.Status (500, "Internal Server Error"));
  retryable "503" (Http_util.Status (503, "Service Unavailable"));
  retryable "429" (Http_util.Status (429, "too many requests"));
  (* client errors are permanent for the same request *)
  permanent "404" (Http_util.Status (404, "Not Found"));
  permanent "401" (Http_util.Status (401, "Bad credentials"));
  permanent "422" (Http_util.Status (422, "Unprocessable Entity"))

(* A retryable error that clears before attempts run out succeeds; the thunk is
   called once per attempt. base_delay is tiny to keep the test fast. *)
let test_with_retry_recovers () =
  let calls = ref 0 in
  let f () =
    incr calls;
    if !calls < 3 then Lwt.return (Error (Http_util.Transport Curl.CURLE_COULDNT_RESOLVE_HOST))
    else Lwt.return (Ok "body")
  in
  let result = Lwt_main.run (Github_retry.with_retry ~base_delay:0.001 ~label:"test" f) in
  (check bool) "succeeds once the error clears" true (Result.is_ok result);
  (check int) "thunk called once per attempt until success" 3 !calls

(* A non-retryable error returns immediately without a second attempt. *)
let test_with_retry_fails_fast () =
  let calls = ref 0 in
  let f () =
    incr calls;
    Lwt.return (Error (Http_util.Status (404, "Not Found")))
  in
  let result = Lwt_main.run (Github_retry.with_retry ~base_delay:0.001 ~label:"test" f) in
  (check bool) "returns the error" true (Result.is_error result);
  (check int) "no retry on permanent error" 1 !calls

(* A persistently retryable error exhausts max_attempts and gives up. *)
let test_with_retry_exhausts_attempts () =
  let calls = ref 0 in
  let f () =
    incr calls;
    Lwt.return (Error (Http_util.Transport Curl.CURLE_COULDNT_RESOLVE_HOST))
  in
  let result = Lwt_main.run (Github_retry.with_retry ~max_attempts:3 ~base_delay:0.001 ~label:"test" f) in
  (check bool) "gives up with the error" true (Result.is_error result);
  (check int) "tries exactly max_attempts times" 3 !calls

(** {2 Review failure notification tests}

    When a PR review cannot run because of an external limit (GitHub refuses to
    serve the diff) or an internal limit (diff exceeds [max_diff_lines] /
    [max_files]), reviewotron posts an issue comment to the PR explaining why,
    instead of silently logging and returning.  "All files filtered out" is
    treated as an explicit skip, not an LGTM approval. *)

(* Unit tests for the pure classification / formatting helpers. *)
let test_review_failure_classify_too_large () =
  (* GitHub answers the diff media type with HTTP 406 when the diff is too
     large; classification keys on the status code, not the message text. *)
  let error : Http_util.error = Http_util.Status (406, "the diff exceeded the maximum number of files (300)") in
  match Review_failure.classify_fetch_error error with
  | Diff_too_large_remote _ -> ()
  | No_reviewable_files | Fetch_failed _ | Too_many_lines _ | Too_many_files _ | Publish_failed _ ->
    Alcotest.fail "expected Diff_too_large_remote for a 406 response"

let test_review_failure_classify_generic () =
  let error : Http_util.error = Http_util.Status (503, "service unavailable") in
  match Review_failure.classify_fetch_error error with
  | Fetch_failed _ -> ()
  | No_reviewable_files | Diff_too_large_remote _ | Too_many_lines _ | Too_many_files _ | Publish_failed _ ->
    Alcotest.fail "expected Fetch_failed for a non-406 status"

let test_review_failure_classify_transport_error () =
  (* A curl/transport failure has no HTTP status — must not be mistaken for the
     too-large case. *)
  let error : Http_util.error = Http_util.Transport Curl.CURLE_COULDNT_CONNECT in
  match Review_failure.classify_fetch_error error with
  | Fetch_failed _ -> ()
  | No_reviewable_files | Diff_too_large_remote _ | Too_many_lines _ | Too_many_files _ | Publish_failed _ ->
    Alcotest.fail "expected Fetch_failed for a transport error with no status"

let test_review_failure_comment_mentions_cause () =
  let too_large = Review_failure.to_comment (Too_many_lines { actual = 5000; limit = 2000 }) in
  (check bool) "line-limit comment names reviewotron" true (contains_sub ~sub:"reviewotron" too_large);
  (check bool) "line-limit comment shows actual count" true (contains_sub ~sub:"5000" too_large);
  (check bool) "line-limit comment shows limit" true (contains_sub ~sub:"2000" too_large);
  let too_many = Review_failure.to_comment (Too_many_files { actual = 300; limit = 50 }) in
  (check bool) "file-limit comment shows actual count" true (contains_sub ~sub:"300" too_many);
  (check bool) "file-limit comment shows limit" true (contains_sub ~sub:"50" too_many);
  let remote = Review_failure.to_comment (Diff_too_large_remote "http 406: too_large") in
  (check bool) "remote-too-large comment is about size, not a generic failure" true
    (contains_sub ~sub:"too large" (String.lowercase_ascii remote));
  let publish = Review_failure.to_comment (Publish_failed "http 422: invalid comments") in
  (check bool) "publish failure says review was produced" true (contains_sub ~sub:"produced a review" publish);
  (check bool) "failure details are open by default" true
    (contains_sub ~sub:"<details open><summary>Details</summary>" publish);
  (check bool) "publish failure includes raw error" true (contains_sub ~sub:"http 422" publish);
  let skipped = Review_failure.to_comment No_reviewable_files in
  (check bool) "skip comment identifies skipped review" true (contains_sub ~sub:"skipped this review" skipped);
  (check bool) "skip comment denies approval" true (contains_sub ~sub:"no code was analyzed or approved" skipped)

(* Integration tests: drive process_event and assert on the write log. *)
let check_same_pr_webhook_deduped ~ctx ~event =
  Api_local.clear_write_log ();
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "same PR webhook deduped" "" write_log

let check_pr_reviewed_state ~ctx ~event expected =
  match event with
  | Github.Pull_request pr ->
    (check bool) "PR reviewed state" expected
      (State.is_pr_reviewed (Context.state ctx) ~repo_url:pr.repository.url ~pr_number:pr.number
         ~head_sha:pr.pull_request.head.sha)
  | Github.Push _ | Github.Issue_comment _ | Github.Pull_request_review _ | Github.Pull_request_review_comment _
  | Github.Unknown _ ->
    fail "expected pull_request event"

let test_pr_diff_fetch_too_large_posts_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff_error ~status:406
    {|http 406: {"message":"Sorry, the diff exceeded the maximum number of files (300).","code":"too_large"}|};
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "issue comment posted on diff-too-large fetch failure" true
    (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "comment targets the PR number" true (contains_sub ~sub:"number=42" write_log);
  (check bool) "comment explains the diff is too large" true
    (contains_sub ~sub:"too large" (String.lowercase_ascii write_log));
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log);
  check_same_pr_webhook_deduped ~ctx ~event

let test_pr_diff_fetch_too_large_comment_failure_retries () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff_error ~status:406
    {|http 406: {"message":"Sorry, the diff exceeded the maximum number of files (300).","code":"too_large"}|};
  Api_local.set_next_issue_comment_error "missing Issues write permission";
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "failed issue comment not logged as posted" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  check_pr_reviewed_state ~ctx ~event false;
  Api_local.clear_write_log ();
  Api_local.set_next_pr_diff_error ~status:406
    {|http 406: {"message":"Sorry, the diff exceeded the maximum number of files (300).","code":"too_large"}|};
  Lwt_main.run (R_test.process_event ctx ~event);
  let retry_log = Api_local.get_write_log () in
  (check bool) "same PR webhook retries failure comment" true (contains_sub ~sub:"[create_issue_comment]" retry_log);
  check_pr_reviewed_state ~ctx ~event true

let test_pr_diff_fetch_generic_error_posts_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff_error "http 503: service unavailable";
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "issue comment posted on generic fetch failure" true
    (contains_sub ~sub:"[create_issue_comment]" write_log)

let test_pr_too_many_lines_posts_comment () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "max_diff_lines": 1}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "issue comment posted when diff exceeds line limit" true
    (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log);
  check_same_pr_webhook_deduped ~ctx ~event

let test_pr_too_many_lines_comment_failure_retries () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "max_diff_lines": 1}|})
  in
  Api_local.set_next_issue_comment_error "missing Issues write permission";
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "failed issue comment not logged as posted" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  check_pr_reviewed_state ~ctx ~event false;
  Api_local.clear_write_log ();
  Lwt_main.run (R_test.process_event ctx ~event);
  let retry_log = Api_local.get_write_log () in
  (check bool) "same PR webhook retries limit comment" true (contains_sub ~sub:"[create_issue_comment]" retry_log);
  check_pr_reviewed_state ~ctx ~event true

let test_pr_too_many_files_posts_comment () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json
      (Melange_json.of_string {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "max_files": 1}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "issue comment posted when diff exceeds file limit" true
    (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log);
  check_same_pr_webhook_deduped ~ctx ~event

let test_comment_trigger_too_many_files_posts_comment () =
  Test_helpers.reset_test_state ();
  let config =
    Config_types.config_of_json (Melange_json.of_string {|{"auto_review_on_comment": true, "max_files": 1}|})
  in
  let ctx = Test_helpers.make_test_context ~config () in
  let payload = Test_helpers.make_issue_comment_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "failure comment posted via REVIEW trigger" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "comment explains file limit" true (contains_sub ~sub:"diff touches 2 files" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log)

let test_comment_trigger_diff_fetch_error_posts_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff_error ~status:406
    {|http 406: {"message":"Sorry, the diff exceeded the maximum number of files (300).","code":"too_large"}|};
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "failure comment posted via REVIEW trigger" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "comment explains remote diff limit" true
    (contains_sub ~sub:"too large" (String.lowercase_ascii write_log));
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log)

let test_comment_trigger_pr_fetch_error_posts_comment () =
  Test_helpers.reset_test_state ();
  let ctx = Test_helpers.make_test_context ~config:comment_trigger_config () in
  let payload = Test_helpers.make_issue_comment_payload ~number:999 () in
  let event = Test_helpers.parse_event_exn ~event_type:"issue_comment" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "failure comment posted to requested PR" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=999" write_log);
  (check bool) "comment explains fetch failure" true (contains_sub ~sub:"couldn't fetch" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log)

let test_pr_review_post_failure_posts_fallback_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_review_error "missing Pull requests write permission";
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "fallback issue comment posted" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "fallback explains publish failure" true (contains_sub ~sub:"produced a review" write_log);
  (check bool) "fallback includes raw publish error" true
    (contains_sub ~sub:"missing Pull requests write permission" write_log);
  check_pr_reviewed_state ~ctx ~event true;
  check_same_pr_webhook_deduped ~ctx ~event

let test_pr_review_post_failure_retries_when_fallback_fails () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_review_error "missing Pull requests write permission";
  Api_local.set_next_issue_comment_error "missing Issues write permission";
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "fallback issue comment not posted" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  check_pr_reviewed_state ~ctx ~event false;
  Api_local.clear_write_log ();
  Api_local.set_next_pr_review_error "missing Pull requests write permission";
  Lwt_main.run (R_test.process_event ctx ~event);
  let retry_log = Api_local.get_write_log () in
  (check bool) "same PR webhook retries fallback comment" true (contains_sub ~sub:"[create_issue_comment]" retry_log);
  check_pr_reviewed_state ~ctx ~event true

let test_pr_quiet_success_comment_failure_retries () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
  Api_local.set_agent_response_map [ "general_scout", "mock_api_responses/scout/leads_empty.json" ];
  Api_local.set_next_issue_comment_error "missing Issues write permission";
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "quiet success comment not posted" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "no review posted" false (contains_sub ~sub:"[create_pr_review]" write_log);
  check_pr_reviewed_state ~ctx ~event false;
  Api_local.clear_write_log ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
  Lwt_main.run (R_test.process_event ctx ~event);
  let retry_log = Api_local.get_write_log () in
  (check bool) "same PR webhook retries quiet success comment" true
    (contains_sub ~sub:"[create_issue_comment]" retry_log);
  check_pr_reviewed_state ~ctx ~event true

let test_pr_empty_diff_posts_skip_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff "";
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "skip comment posted on empty diff" true
    (contains_sub ~sub:"[create_issue_comment] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "skip comment explains no code was reviewed" true
    (contains_sub ~sub:"no code was analyzed or approved" write_log);
  (check bool) "skip comment does not say LGTM" false (contains_sub ~sub:"LGTM :+1:" write_log);
  (check bool) "skip comment shows reviewed commit" true
    (contains_sub ~sub:(reviewed_commit_sub "abc123def456789012345678901234567890abcd") write_log);
  (check bool) "no thumbs-up reaction added on empty diff" false
    (contains_sub ~sub:"[create_issue_reaction] repo=https://github.com/org/monorepo number=42 content=+1" write_log);
  (check bool) "skip comment identifies the skip" true (contains_sub ~sub:"skipped this review" write_log);
  (check bool) "no review attempted on empty diff" false (contains_sub ~sub:"[create_pr_review]" write_log);
  check_same_pr_webhook_deduped ~ctx ~event

let test_pr_empty_diff_skip_comment_failure_retries () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff "";
  Api_local.set_next_issue_comment_error "missing Issues write permission";
  let state = State.create () in
  let ctx = Test_helpers.make_test_context ~state ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "failed skip comment not logged as posted" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  check_pr_reviewed_state ~ctx ~event false;
  Api_local.clear_write_log ();
  Api_local.set_next_pr_diff "";
  Lwt_main.run (R_test.process_event ctx ~event);
  let retry_log = Api_local.get_write_log () in
  (check bool) "same PR webhook retries skip comment" true (contains_sub ~sub:"[create_issue_comment]" retry_log);
  check_pr_reviewed_state ~ctx ~event true

(** {2 Debug dump tests} *)

let test_write_debug_dump () =
  let tmp_dir = Filename.temp_dir "reviewotron_debug_test" "" in
  let dir = Printf.sprintf "%s/nested/subdir" tmp_dir in
  let config : Agent_runner.agent_config =
    {
      name = "test_agent";
      system_prompt = "unused";
      model_tier = Fast;
      output_schema = `Assoc [];
      max_steps = 3;
      thinking_budget = None;
      effort = None;
    }
  in
  let step0 : Ai_core.Generate_text_result.step =
    {
      text = "step zero text here";
      reasoning = "";
      tool_calls = [];
      tool_results = [];
      finish_reason = Ai_provider.Finish_reason.Tool_calls;
      usage = { input_tokens = 0; output_tokens = 0; total_tokens = None };
      provider_metadata = None;
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
      provider_metadata = None;
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

(** {2 Budget-exhaustion recovery tests}

    These exercise [Agent_runner.messages_of_steps], the helper that rebuilds
    a replay-able transcript from completed steps so we can force a tool-less
    finalization call when the agent's step budget runs out mid-tool-loop. *)

let zero_usage : Ai_provider.Usage.t = { input_tokens = 0; output_tokens = 0; total_tokens = None }

let mk_step ?(text = "") ?(tool_calls = []) ?(tool_results = []) ?(finish_reason = Ai_provider.Finish_reason.Stop) () :
  Ai_core.Generate_text_result.step =
  { text; reasoning = ""; tool_calls; tool_results; finish_reason; usage = zero_usage; provider_metadata = None }

let mk_tool_call ~id ~name ~args : Ai_core.Generate_text_result.tool_call =
  { tool_call_id = id; tool_name = name; args }

let mk_tool_result ~id ~name ~result : Ai_core.Generate_text_result.tool_result =
  { tool_call_id = id; tool_name = name; result; is_error = false; provider_metadata = None }

(** Count [Assistant] and [Tool] messages in a replayed transcript. *)
let count_roles (msgs : Ai_provider.Prompt.message list) =
  List.fold_left
    (fun (a, t) m ->
      match m with
      | Ai_provider.Prompt.Assistant _ -> a + 1, t
      | Tool _ -> a, t + 1
      | System _ | User _ -> a, t)
    (0, 0) msgs

let test_messages_of_steps_empty () =
  let msgs = Agent_runner.messages_of_steps [] in
  (check int) "no messages for empty steps" 0 (List.length msgs)

let test_messages_of_steps_text_only_step () =
  let steps = [ mk_step ~text:"just thinking out loud" () ] in
  let msgs = Agent_runner.messages_of_steps steps in
  let assistants, tools = count_roles msgs in
  (check int) "one assistant" 1 assistants;
  (check int) "no tool message" 0 tools

let test_messages_of_steps_completed_tool_turn () =
  let steps =
    [
      mk_step ~text:"let me check that file"
        ~tool_calls:[ mk_tool_call ~id:"tc1" ~name:"get_file_content" ~args:(`Assoc [ "path", `String "a.ml" ]) ]
        ~tool_results:[ mk_tool_result ~id:"tc1" ~name:"get_file_content" ~result:(`String "file body") ]
        ();
    ]
  in
  let msgs = Agent_runner.messages_of_steps steps in
  let assistants, tools = count_roles msgs in
  (check int) "one assistant" 1 assistants;
  (check int) "one tool message" 1 tools

(** The core invariant: a step whose [tool_results] is empty represents
    tool_calls that were never executed (max_steps exhaustion).  Replaying
    that turn would send Anthropic an Assistant/[tool_use] with no matching
    Tool/[tool_result] — a protocol violation.  The helper must drop it. *)
let test_messages_of_steps_drops_unfulfilled_final_turn () =
  let steps =
    [
      mk_step ~text:"examined first file"
        ~tool_calls:[ mk_tool_call ~id:"tc1" ~name:"get_file_content" ~args:(`Assoc [ "path", `String "a.ml" ]) ]
        ~tool_results:[ mk_tool_result ~id:"tc1" ~name:"get_file_content" ~result:(`String "body a") ]
        ();
      (* Final step: model asked for another tool call but budget ran out. *)
      mk_step ~text:"let me also check b.ml"
        ~tool_calls:[ mk_tool_call ~id:"tc2" ~name:"get_file_content" ~args:(`Assoc [ "path", `String "b.ml" ]) ]
        ~tool_results:[] ~finish_reason:Ai_provider.Finish_reason.Tool_calls ();
    ]
  in
  let msgs = Agent_runner.messages_of_steps steps in
  let assistants, tools = count_roles msgs in
  (* Only the fulfilled first step survives. *)
  (check int) "only one assistant kept" 1 assistants;
  (check int) "only one tool message kept" 1 tools;
  (* The dropped turn's text must not appear anywhere. *)
  let all_text =
    List.concat_map
      (function
        | Ai_provider.Prompt.Assistant { content } ->
          List.filter_map
            (function
              | Ai_provider.Prompt.Text { text; _ } -> Some text
              | _ -> None)
            content
        | _ -> [])
      msgs
  in
  (check bool) "unfulfilled turn text dropped" true
    (not (List.exists (fun t -> CCString.mem ~sub:"check b.ml" t) all_text));
  (check bool) "fulfilled turn text kept" true
    (List.exists (fun t -> CCString.mem ~sub:"examined first file" t) all_text)

let test_messages_of_steps_multi_turn_ordering () =
  let s1 =
    mk_step ~text:"first"
      ~tool_calls:[ mk_tool_call ~id:"tc1" ~name:"t" ~args:`Null ]
      ~tool_results:[ mk_tool_result ~id:"tc1" ~name:"t" ~result:`Null ]
      ()
  in
  let s2 =
    mk_step ~text:"second"
      ~tool_calls:[ mk_tool_call ~id:"tc2" ~name:"t" ~args:`Null ]
      ~tool_results:[ mk_tool_result ~id:"tc2" ~name:"t" ~result:`Null ]
      ()
  in
  let msgs = Agent_runner.messages_of_steps [ s1; s2 ] in
  let assistants, tools = count_roles msgs in
  (check int) "two assistant turns" 2 assistants;
  (check int) "two tool turns" 2 tools;
  (* Order must be Assistant, Tool, Assistant, Tool — not all assistants first. *)
  let roles =
    List.map
      (function
        | Ai_provider.Prompt.Assistant _ -> "a"
        | Tool _ -> "t"
        | System _ -> "s"
        | User _ -> "u")
      msgs
  in
  (check (list string)) "interleaved order" [ "a"; "t"; "a"; "t" ] roles

(** {2 Agent thinking-config plumbing}

    The agent_config carries an optional thinking-budget knob; when set, the
    runner injects an Anthropic [Thinking] config into the provider options
    that go on the wire.  Tests interrogate the pure helper that builds the
    provider_options so we don't need a live network call. *)

let mk_agent_config ?thinking_budget ?effort () : Agent_runner.agent_config =
  {
    name = "test_agent";
    system_prompt = "be a test";
    model_tier = Standard;
    output_schema = `Assoc [];
    max_steps = 1;
    thinking_budget;
    effort;
  }

let test_provider_options_empty_when_no_thinking_budget () =
  let cfg = mk_agent_config () in
  let po = Agent_runner.build_provider_options ~provider:Llm_provider.Anthropic cfg in
  (check bool) "no Anthropic options when thinking_budget = None" true
    (Option.is_none (Ai_provider_anthropic.Anthropic_options.of_provider_options po))

let test_provider_options_carries_thinking_when_set () =
  let cfg = mk_agent_config ~thinking_budget:4096 () in
  let po = Agent_runner.build_provider_options ~provider:Llm_provider.Anthropic cfg in
  match Ai_provider_anthropic.Anthropic_options.of_provider_options po with
  | None -> fail "expected Anthropic options to be present when thinking_budget is set"
  | Some opts ->
  match opts.thinking with
  | None -> fail "expected thinking config to be populated"
  | Some t ->
    (check bool) "thinking enabled" true t.enabled;
    (check int) "thinking budget matches" 4096 (Ai_provider_anthropic.Thinking.to_int t.budget_tokens)

let test_provider_options_carries_openrouter_medium_effort () =
  let cfg = mk_agent_config ~effort:Config_types.Effort.Medium () in
  let po = Agent_runner.build_provider_options ~provider:Llm_provider.Openrouter cfg in
  let open Ai_provider_openrouter.Openrouter_options in
  match of_provider_options po with
  | None -> fail "expected OpenRouter options to be present"
  | Some { reasoning = Some ({ enabled = Some true; exclude = None; budget = Effort Medium } as reasoning); _ } ->
    (match reasoning_config_to_json reasoning with
    | `Assoc fields -> (check string) "serialized effort" "medium" (json_string_field fields "effort")
    | _ -> fail "expected OpenRouter reasoning JSON object")
  | Some _ -> fail "expected OpenRouter reasoning.effort=medium"

(** The general review agent must opt into Anthropic extended thinking.
    This is what gives the model a real reasoning channel instead of leaking
    reasoning into the posted [message]. *)
let test_general_review_agent_config_enables_thinking () =
  let cfg = General_review_plugin.build_agent_config ~system_prompt:"unused" in
  match cfg.thinking_budget with
  | None -> fail "expected general_review agent to enable thinking_budget"
  | Some n ->
    (check bool) "general_review thinking budget >= 4096" true (n >= 4096);
    (check string) "agent name preserved" "general_review" cfg.name

module General_plugin_agent_runner = struct
  let outputs : (string * Yojson.Basic.t) list ref = ref []
  let debug_dirs : string option list ref = ref []
  let set_outputs entries = outputs := entries
  let reset_debug_dirs () = debug_dirs := []
  let get_debug_dirs () = List.rev !debug_dirs

  let run ~ctx:_ ~repo_url:_ ?model_id:_ ?tools:_ ?debug_dir ?log_context:_ ~config ~input:_ () =
    debug_dirs := debug_dir :: !debug_dirs;
    match List.assoc_opt config.Agent_runner.name !outputs with
    | None -> Lwt.return (Error (Printf.sprintf "missing mock output for %s" config.Agent_runner.name))
    | Some output ->
      let usage : Ai_provider.Usage.t = { input_tokens = 0; output_tokens = 0; total_tokens = None } in
      Lwt.return
        (Ok
           Agent_runner.
             {
               output;
               usage;
               cache_read_input_tokens = 0;
               cache_creation_input_tokens = 0;
               steps_count = 1;
               tool_calls_count = 0;
               tool_results_count = 0;
               model_id = "mock";
               reported_cost_usd = None;
             })
end

module General_plugin_test = General_review_plugin.Make (General_plugin_agent_runner)

let general_plugin_metadata : Review_plugin.review_metadata =
  {
    change_title = "Test change";
    change_description = "";
    file_contents = [];
    fetch_file = (fun ~path:_ -> Lwt.return (Ok None));
  }

let process_finding_message =
  "The `process` function can raise exceptions but the result is used without error handling."

let process_finding_fix = "match process new_value with\n| exception exn -> log_error exn; 0\n| result -> result"

let validator_output ?(candidate_id = 0) ~verdict ~severity ~suggested_fix () =
  let finding =
    mk_finding ~path:"src/main.ml" ~line:14 ~severity ~category:Review_types.Error_handling
      ~message:process_finding_message ~suggested_fix ()
  in
  Review_types.validator_output_to_json
    { results = [ { candidate_id; finding; verdict; evidence_notes = "validator fixture decision" } ] }

let validator_echoes_damaged_confirmed_finding =
  validator_output ~verdict:Review_types.Confirmed ~severity:Review_types.Suggestion ~suggested_fix:None ()

let validator_rejects_process_finding =
  validator_output ~verdict:Review_types.Rejected ~severity:Review_types.Warning
    ~suggested_fix:(Some process_finding_fix) ()

let review_output_with_findings findings =
  Review_types.review_output_to_json
    { summary = "review fixture summary"; findings; overall_assessment = "review fixture assessment" }

let validator_output_with_results results = Review_types.validator_output_to_json { results }

(* These tests exercise the legacy single-pass [general_review] agent directly,
   so they run with the scout pipeline disabled.  The scout -> deep reviewer
   path has its own dedicated integration tests ([test_general_pipeline_*]). *)
let general_plugin_legacy_config =
  Config_types.config_of_json
    (Melange_json.of_string
       {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "review_pushes_to_develop": true, "review_plugins": {"general": {"scout_enabled": false}}}|})

let run_general_plugin_with_outputs outputs =
  Test_helpers.reset_test_state ();
  General_plugin_agent_runner.reset_debug_dirs ();
  General_plugin_agent_runner.set_outputs outputs;
  let ctx = Test_helpers.make_test_context ~config:general_plugin_legacy_config () in
  Lwt_main.run
    (General_plugin_test.run_review ~ctx ~repo_url:"https://github.com/org/repo" ~config:general_plugin_legacy_config
       ~diff_text:"diff" ~metadata:general_plugin_metadata ())

let test_general_agent_debug_dumps_are_opt_in () =
  let outputs =
    [
      "general_review", read_json "mock_api_responses/claude/review_response.json";
      "general_validator", validator_echoes_damaged_confirmed_finding;
    ]
  in
  let run ~debug_artifacts =
    Test_helpers.reset_test_state ();
    General_plugin_agent_runner.reset_debug_dirs ();
    General_plugin_agent_runner.set_outputs outputs;
    let config = { general_plugin_legacy_config with debug_artifacts } in
    let ctx = Test_helpers.make_test_context ~config () in
    let _result, _costs =
      Lwt_main.run
        (General_plugin_test.run_review ~ctx ~repo_url:"https://github.com/org/repo" ~config ~diff_text:"diff"
           ~metadata:general_plugin_metadata ~debug_dir:"debug-test" ())
    in
    General_plugin_agent_runner.get_debug_dirs ()
  in
  (check (list (option string))) "debug dumps disabled" [ None; None ] (run ~debug_artifacts:false);
  (check (list (option string)))
    "debug dumps enabled"
    [ Some "debug-test"; Some "debug-test" ]
    (run ~debug_artifacts:true)

let test_general_review_filters_low_value_and_validates () =
  let result, costs =
    run_general_plugin_with_outputs
      [
        "general_review", read_json "mock_api_responses/claude/review_response.json";
        "general_validator", validator_echoes_damaged_confirmed_finding;
      ]
  in
  match result with
  | Error msg -> fail msg
  | Ok review ->
    (check int) "only validated actionable finding remains" 1 (List.length review.findings);
    (match review.findings with
    | [ finding ] ->
      (check string) "validated finding kept" process_finding_message finding.message;
      (check string) "keeps original candidate severity" "warning" (Review_types.severity_to_string finding.severity);
      (check (option string)) "keeps original candidate suggested fix" (Some process_finding_fix) finding.suggested_fix
    | [] | _ :: _ :: _ -> fail "expected exactly one validated finding");
    (check bool) "validator cost recorded" true
      (List.exists (fun (c : Cost_tracking.agent_cost) -> String.equal c.agent_name "general_validator") costs)

let test_general_review_validator_rejection_drops_finding () =
  let result, _costs =
    run_general_plugin_with_outputs
      [
        "general_review", read_json "mock_api_responses/claude/review_response.json";
        "general_validator", validator_rejects_process_finding;
      ]
  in
  match result with
  | Error msg -> fail msg
  | Ok review -> (check int) "validator rejection suppresses general finding" 0 (List.length review.findings)

let test_general_review_matches_reordered_validator_results_by_id () =
  let first =
    mk_finding ~path:"src/main.ml" ~line:14 ~severity:Review_types.Warning ~category:Review_types.Error_handling
      ~message:"first actionable issue" ~suggested_fix:(Some process_finding_fix) ()
  in
  let second =
    mk_finding ~path:"src/main.ml" ~line:24 ~severity:Review_types.Warning ~category:Review_types.Logic
      ~message:"second actionable issue" ~suggested_fix:None ()
  in
  let validator_output =
    validator_output_with_results
      [
        { candidate_id = 1; finding = second; verdict = Review_types.Rejected; evidence_notes = "second rejected" };
        { candidate_id = 0; finding = first; verdict = Review_types.Confirmed; evidence_notes = "first confirmed" };
      ]
  in
  let result, _costs =
    run_general_plugin_with_outputs
      [ "general_review", review_output_with_findings [ first; second ]; "general_validator", validator_output ]
  in
  match result with
  | Error msg -> fail msg
  | Ok review ->
    (check int) "only confirmed finding remains" 1 (List.length review.findings);
    (match review.findings with
    | [ finding ] -> (check string) "matched by candidate_id" first.message finding.message
    | [] | _ :: _ :: _ -> fail "expected exactly one validated finding")

let test_general_review_validator_failure_is_error () =
  let result, costs =
    run_general_plugin_with_outputs [ "general_review", read_json "mock_api_responses/claude/review_response.json" ]
  in
  (check bool) "general review cost retained" true
    (List.exists (fun (c : Cost_tracking.agent_cost) -> String.equal c.agent_name "general_review") costs);
  match result with
  | Ok _ -> fail "expected validator failure to propagate"
  | Error msg -> (check bool) "validator failure surfaced" true (contains_sub ~sub:"general validator failed" msg)

let test_general_review_validator_parse_failure_is_error () =
  let result, costs =
    run_general_plugin_with_outputs
      [
        "general_review", read_json "mock_api_responses/claude/review_response.json";
        "general_validator", `Assoc [ "not_results", `List [] ];
      ]
  in
  (check bool) "validator cost retained" true
    (List.exists (fun (c : Cost_tracking.agent_cost) -> String.equal c.agent_name "general_validator") costs);
  match result with
  | Ok _ -> fail "expected validator parse failure to propagate"
  | Error msg -> (check bool) "validator parse failure surfaced" true (contains_sub ~sub:"parse general validator" msg)

let test_general_review_parse_failure_is_error () =
  let result, costs = run_general_plugin_with_outputs [ "general_review", `Assoc [ "findings", `List [] ] ] in
  (check bool) "general review cost retained" true
    (List.exists (fun (c : Cost_tracking.agent_cost) -> String.equal c.agent_name "general_review") costs);
  match result with
  | Ok _ -> fail "expected review parse failure to propagate"
  | Error msg -> (check bool) "review parse failure surfaced" true (contains_sub ~sub:"parse general review" msg)

(* Integration tests for the scout -> deep reviewer -> validator pipeline.
   Backed by [Api_local.Agent_runner] so unmapped agent names fall back to the
   default response path — an omitted deep-review/validator entry therefore
   surfaces as a wrong finding/cost count if the pipeline calls a stage it
   should have skipped. *)
module General_pipeline_test = General_review_plugin.Make (Api_local.Agent_runner)

let pipeline_metadata : Review_plugin.review_metadata =
  {
    change_title = "Refactor session validation";
    change_description = "Simplify validate_session and the retry loop.";
    file_contents =
      [
        "lib/session.ml", "let validate_session token = Hashtbl.mem sessions token.id";
        "lib/retry.ml", "let retry () = ()";
      ];
    fetch_file = (fun ~path:_ -> Lwt.return (Ok None));
  }

let scout_enabled_config =
  Config_types.config_of_json
    (Melange_json.of_string {|{"review_plugins": {"general": {"scout_enabled": true, "max_leads": 10}}}|})

let scout_disabled_config =
  Config_types.config_of_json (Melange_json.of_string {|{"review_plugins": {"general": {"scout_enabled": false}}}|})

let run_pipeline_plugin ~config =
  let ctx = Test_helpers.make_test_context ~config () in
  Lwt_main.run
    (General_pipeline_test.run_review ~ctx ~repo_url:"https://github.com/org/repo" ~config ~diff_text:"diff"
       ~metadata:pipeline_metadata ())

let has_cost name costs = List.exists (fun (c : Cost_tracking.agent_cost) -> String.equal c.agent_name name) costs

let test_general_pipeline_full_flow () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_two.json";
      "general_deep_review", "mock_api_responses/deep_review/confirmed_one.json";
      "general_validator", "mock_api_responses/deep_review/validator_confirmed_one.json";
    ];
  let result, costs = run_pipeline_plugin ~config:scout_enabled_config in
  Test_helpers.reset_test_state ();
  (match result with
  | Error msg -> fail msg
  | Ok review ->
    (check int) "one confirmed finding" 1 (List.length review.findings);
    (match review.findings with
    | [ finding ] -> (check string) "confirmed lead finding kept" "lib/session.ml" finding.path
    | [] | _ :: _ :: _ -> fail "expected exactly one confirmed finding"));
  (check bool) "at least three cost entries" true (List.compare_length_with costs 3 >= 0);
  (check bool) "scout cost present" true (has_cost "general_scout" costs);
  (check bool) "deep review cost present" true (has_cost "general_deep_review" costs);
  (check bool) "validator cost present" true (has_cost "general_validator" costs)

let test_general_pipeline_early_exit_on_no_leads () =
  Test_helpers.reset_test_state ();
  (* Map ONLY the scout: if the deep reviewer or validator wrongly run, they
     fall back to the default review response and the assertions below fail. *)
  Api_local.set_agent_response_map [ "general_scout", "mock_api_responses/scout/leads_empty.json" ];
  let result, costs = run_pipeline_plugin ~config:scout_enabled_config in
  Test_helpers.reset_test_state ();
  (match result with
  | Error msg -> fail msg
  | Ok review ->
    (check int) "no findings on empty scout" 0 (List.length review.findings);
    (check string) "early-exit summary" "Scout found no investigation leads." review.summary);
  (check int) "exactly one cost entry" 1 (List.length costs);
  (check bool) "only scout cost recorded" true (has_cost "general_scout" costs);
  (check bool) "deep review never ran" false (has_cost "general_deep_review" costs);
  (check bool) "validator never ran" false (has_cost "general_validator" costs)

let test_general_pipeline_caps_leads () =
  Test_helpers.reset_test_state ();
  (* 12 leads with max_leads = 10. [Api_local] records the input handed to
     each mocked agent, so we assert the truncation directly on the deep
     reviewer's recorded input: [General_deep_reviewer_agent.build_input]
     renders each kept lead as a "### L<index>" heading (0-indexed via
     [List.iteri] over the post-cap list), so 10 kept leads means the input
     must contain "### L9" (the 10th kept lead) and must not contain
     "### L10" or "### L11" (which would only appear if capping failed to
     drop any leads). *)
  Api_local.set_agent_response_map
    [
      "general_scout", "mock_api_responses/scout/leads_overflow.json";
      "general_deep_review", "mock_api_responses/deep_review/confirmed_one.json";
      "general_validator", "mock_api_responses/deep_review/validator_confirmed_one.json";
    ];
  let result, costs = run_pipeline_plugin ~config:scout_enabled_config in
  let deep_input = Api_local.recorded_agent_input "general_deep_review" in
  Test_helpers.reset_test_state ();
  (match result with
  | Error msg -> fail msg
  | Ok review -> (check int) "overflow leads still produce a confirmed finding" 1 (List.length review.findings));
  (check bool) "scout cost present" true (has_cost "general_scout" costs);
  (check bool) "deep review cost present" true (has_cost "general_deep_review" costs);
  match deep_input with
  | None -> fail "expected deep reviewer input to be recorded"
  | Some input ->
    (check bool) "deep input contains the 10th kept lead" true (CCString.mem ~sub:"### L9" input);
    (check bool) "deep input does not contain an 11th lead" false (CCString.mem ~sub:"### L10" input);
    (check bool) "deep input does not contain a 12th lead" false (CCString.mem ~sub:"### L11" input)

let test_general_pipeline_legacy_fallback () =
  Test_helpers.reset_test_state ();
  (* scout_enabled = false routes to the legacy single-pass review, which maps
     only [general_review] + [general_validator]. *)
  Api_local.set_agent_response_map
    [
      "general_review", "mock_api_responses/claude/review_response.json";
      "general_validator", "mock_api_responses/deep_review/validator_confirmed_one.json";
    ];
  let result, costs = run_pipeline_plugin ~config:scout_disabled_config in
  Test_helpers.reset_test_state ();
  (match result with
  | Error msg -> fail msg
  | Ok review -> (check int) "legacy single-pass confirms one finding" 1 (List.length review.findings));
  (check bool) "legacy review cost present" true (has_cost "general_review" costs);
  (check bool) "scout never ran on legacy path" false (has_cost "general_scout" costs)

let test_provider_options_clamps_below_minimum () =
  (* Anthropic requires budget_tokens >= 1024.  When a caller asks for less,
     the runner must either reject or clamp; we choose to clamp up to 1024 so
     misconfiguration does not crash the agent loop. *)
  let cfg = mk_agent_config ~thinking_budget:500 () in
  let po = Agent_runner.build_provider_options ~provider:Llm_provider.Anthropic cfg in
  match Ai_provider_anthropic.Anthropic_options.of_provider_options po with
  | None -> fail "expected Anthropic options to be present"
  | Some { thinking = Some t; _ } ->
    (check int) "budget clamped to 1024 minimum" 1024 (Ai_provider_anthropic.Thinking.to_int t.budget_tokens)
  | Some { thinking = None; _ } -> fail "expected thinking config to be populated"

(** The cached-input [Provider_options.t] must carry an ephemeral
    [cache_control] breakpoint — that's the entire point of the value.  This
    guards against regressions when bumping ocaml-ai-sdk (e.g. if the option
    GADT key shape changes, or if someone "simplifies" the helper back to
    [Provider_options.empty]). *)
let test_cached_input_provider_options_marks_ephemeral () =
  let po = Agent_runner.cached_input_provider_options Llm_provider.Anthropic in
  match Ai_provider_anthropic.Cache_control_options.get_cache_control po with
  | None -> fail "expected cache_control to be set on cached_input_provider_options"
  | Some { cache_type = Ephemeral; _ } -> ()

let () =
  run "reviewotron"
    [
      ( "github_parsing",
        [
          test_case "parse pr_opened" `Quick test_parse_pr_opened;
          test_case "parse push_develop" `Quick test_parse_push_develop;
          test_case "parse unknown event" `Quick test_parse_unknown_event;
          test_case "parse issue_comment on PR with REVIEW body" `Quick test_parse_issue_comment_review;
          test_case "parse issue_comment on regular (non-PR) issue" `Quick test_parse_issue_comment_on_regular_issue;
          test_case "parse issue_comment with null user fields" `Quick test_parse_issue_comment_null_user;
          test_case "parse pull_request_review without change counts" `Quick
            test_parse_pull_request_review_without_change_counts;
          test_case "parse pull_request_review_comment without change counts" `Quick
            test_parse_pull_request_review_comment_without_change_counts;
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
          test_case "parse secrets openrouter only" `Quick test_parse_secrets_openrouter_only;
          test_case "llm_provider resolve precedence" `Quick test_llm_provider_resolve;
          test_case "llm_provider normalize model id" `Quick test_llm_provider_normalize;
          test_case "model ids no regression" `Quick test_model_ids_no_regression;
          test_case "llm_provider usage metadata cost" `Quick test_llm_provider_usage_metadata_combines_openrouter_costs;
          test_case "openrouter requires supported parameters" `Quick test_openrouter_requires_supported_parameters;
          test_case "openrouter maps error finish reason" `Quick test_openrouter_maps_error_finish_reason;
          test_case "openrouter embedded error" `Quick test_openrouter_embedded_error_is_provider_error;
          test_case "review_plugins defaults" `Quick test_config_review_plugins_defaults;
          test_case "review_plugins explicit" `Quick test_config_review_plugins_explicit;
          test_case "invalid ignored file regex rejected" `Quick test_config_rejects_invalid_ignored_file_regex;
          test_case "broad ignored file regex rejected" `Quick test_config_rejects_broad_ignored_file_regex;
          test_case "general scout config defaults" `Quick test_config_general_scout_defaults;
          test_case "general scout config explicit" `Quick test_config_general_scout_explicit;
          test_case "max_leads = 0 rejected" `Quick test_config_max_leads_zero_rejected;
          test_case "max_leads negative rejected" `Quick test_config_max_leads_negative_rejected;
          test_case "max_leads valid and default ok" `Quick test_config_max_leads_valid_and_default_ok;
          test_case "context create requires repos by default" `Quick test_context_create_requires_repos_by_default;
          test_case "context create allows repo-less when explicit" `Quick
            test_context_create_allows_repo_less_when_explicit;
          test_case "context create reports feedback store errors" `Quick
            test_context_create_reports_feedback_store_error;
          test_case "context load config file" `Quick test_context_load_config_file;
          test_case "context load local config defaults when missing" `Quick
            test_context_load_local_config_uses_defaults_when_missing;
          test_case "vuln_class roundtrip" `Quick test_vuln_class_roundtrip;
          test_case "security_plugin_config roundtrip" `Quick test_security_plugin_config_roundtrip;
        ] );
      ( "review_prompt",
        [
          test_case "system prompt with security disabled" `Quick test_system_prompt_security_disabled;
          test_case "system prompt with security enabled" `Quick test_system_prompt_security_enabled;
          test_case "system prompt has dedup guidelines" `Quick test_system_prompt_dedup_guidelines;
          test_case "system prompt override" `Quick test_system_prompt_override;
          test_case "build user message" `Quick test_build_user_message;
          test_case "build user message no description" `Quick test_build_user_message_no_description;
          test_case "review schema valid" `Quick test_review_schema_valid;
          test_case "system prompt has reasoning workflow section" `Quick test_system_prompt_workflow_section;
          test_case "system prompt enumerates banned hedging patterns" `Quick test_system_prompt_banned_patterns;
          test_case "prompt token estimation" `Quick test_prompt_token_estimation;
        ] );
      ( "anthropic_schema_compat",
        [
          test_case "structured output schemas compatible" `Quick test_anthropic_structured_output_schemas_compatible;
          test_case "security validator schema requires proof key" `Quick
            test_security_validator_schema_requires_proof_key;
        ] );
      ( "dedup",
        [
          test_case "same line prefers security" `Quick test_dedup_same_line_prefers_security;
          test_case "same line preserves plugin provenance" `Quick test_dedup_preserves_plugin_provenance;
          test_case "same line same source higher severity wins" `Quick
            test_dedup_same_line_same_source_higher_severity_wins;
          test_case "near line collapse same category" `Quick test_dedup_near_line_collapse_same_category;
          test_case "near line rechecks promoted best" `Quick test_dedup_near_line_rechecks_promoted_best;
          test_case "near line different category both kept" `Quick test_dedup_near_line_different_category_both_kept;
          test_case "security findings not near-line collapsed" `Quick test_dedup_security_not_near_line_collapsed;
          test_case "sorts by path then line" `Quick test_dedup_sorts_by_path_then_line;
        ] );
      ( "multiline_inline",
        [
          test_case "single_hunk_contains valid range" `Quick test_single_hunk_contains_valid_range;
          test_case "single_hunk_contains rejects straddles" `Quick test_single_hunk_contains_straddles_hunks;
          test_case "valid multi-line range emits range" `Quick test_finding_to_comment_multiline_valid;
          test_case "end_line == line degrades to single" `Quick test_finding_to_comment_end_line_equals_line_is_single;
          test_case "end_line < line degrades to single" `Quick test_finding_to_comment_end_line_lt_line_is_single;
          test_case "range crossing hunks degrades" `Quick test_finding_to_comment_range_crosses_hunks_degrades;
          test_case "end_line out of file degrades" `Quick test_finding_to_comment_end_line_out_of_file_degrades;
          test_case "single-line still works" `Quick test_finding_to_comment_single_line_unchanged;
        ] );
      ( "finding_routing",
        [
          test_case "positioned" `Quick test_route_finding_positioned;
          test_case "file not in diff" `Quick test_route_finding_file_not_in_diff;
          test_case "non-positive line is anchor_failed" `Quick test_route_finding_non_positive_line_is_anchor_failed;
          test_case "deletion-only file is anchor_failed" `Quick test_route_finding_deletion_only_file_is_anchor_failed;
        ] );
      ( "file_annotation",
        [
          test_case "header and gutter" `Quick test_annotate_file_content_header_and_gutter;
          test_case "empty body" `Quick test_annotate_file_content_empty;
        ] );
      ( "security_dedup",
        [
          test_case "collapses same sink across vuln_classes; highest confidence wins" `Quick
            test_dedup_collapses_same_sink_across_vuln_classes;
          test_case "preserves distinct sinks" `Quick test_dedup_preserves_distinct_sinks;
          test_case "tie on confidence, longer flow wins" `Quick test_dedup_tiebreak_prefers_longer_flow;
          test_case "tie on confidence and flow, first-seen wins" `Quick test_dedup_tiebreak_first_seen_when_fully_tied;
          test_case "empty input" `Quick test_dedup_empty;
          test_case "single candidate passthrough" `Quick test_dedup_single_candidate_passthrough;
        ] );
      ( "security_anchor_snap",
        [
          test_case "sink in diff: no snap" `Quick test_anchor_sink_in_diff_no_snap;
          test_case "sink unchanged, flow in diff: snap + Related" `Quick test_anchor_sink_not_in_diff_flow_in_diff;
          test_case "nothing in diff: falls through to sink" `Quick test_anchor_nothing_in_diff_falls_through_to_sink;
          test_case "source fallback when flow empty" `Quick test_anchor_source_fallback_when_flow_empty;
          test_case "end_line derived from anchor, not sink" `Quick test_anchor_end_line_derived_from_anchor_not_sink;
        ] );
      ( "security_artifacts",
        [
          test_case "disabled writes nothing" `Quick test_security_artifacts_disabled_writes_nothing;
          test_case "metrics files only" `Quick test_security_artifacts_metrics_files;
          test_case "debug redacts secrets" `Quick test_security_artifacts_debug_redacts;
          test_case "write failure is best effort" `Quick test_security_artifacts_write_failure_best_effort;
        ] );
      ( "security_diff_signal",
        [
          test_case "dangerous APIs and line ranges" `Quick test_security_diff_signal_dangerous_apis_and_lines;
          test_case "path, controls, and stateful signals" `Quick test_security_diff_signal_path_control_and_stateful;
          test_case "sensitive file matching" `Quick test_security_diff_signal_sensitive_files;
          test_case "policy regression patterns" `Quick test_security_diff_signal_policy_regression_patterns;
          test_case "multiline policy wildcards" `Quick test_security_diff_signal_multiline_policy_wildcards;
          test_case "empty safe diff" `Quick test_security_diff_signal_empty_for_safe_diff;
        ] );
      ( "review_types",
        [
          test_case "review output roundtrip" `Quick test_review_output_roundtrip;
          test_case "mock claude response" `Quick test_mock_claude_response;
          test_case "scout output parse two leads" `Quick test_scout_output_parse_two_leads;
          test_case "scout output parse empty leads" `Quick test_scout_output_parse_empty_leads;
          test_case "scout output parse overflow leads" `Quick test_scout_output_parse_overflow_leads;
          test_case "scout output parse missing skip_note defaults empty" `Quick
            test_scout_output_parse_missing_skip_note_defaults_empty;
          test_case "scout output roundtrip" `Quick test_scout_output_roundtrip;
          test_case "scout output jsonschema has properties" `Quick test_scout_output_jsonschema_has_properties;
        ] );
      ( "security_types",
        [
          test_case "triage output roundtrip" `Quick test_security_triage_output_roundtrip;
          test_case "triage output with skip" `Quick test_security_triage_output_with_skip;
          test_case "candidate finding roundtrip" `Quick test_security_candidate_finding_roundtrip;
          test_case "sanitization status roundtrip" `Quick test_security_sanitization_status_roundtrip;
          test_case "validation verdict roundtrip" `Quick test_security_validation_verdict_roundtrip;
          test_case "validator output roundtrip" `Quick test_security_validator_output_roundtrip;
          test_case "exploitation proof roundtrip" `Quick test_security_exploitation_proof_roundtrip;
          test_case "exploitation proof rejects vague trace" `Quick test_security_exploitation_proof_rejects_vague_trace;
          test_case "exploitation proof rejects assumptions" `Quick test_security_exploitation_proof_rejects_assumptions;
          test_case "confirmed requires proof" `Quick test_security_enforce_confirmed_requires_proof;
          test_case "confirmed missing proof repaired from concrete notes" `Quick
            test_security_enforce_repairs_missing_proof_from_concrete_notes;
          test_case "confirmed missing proof not repaired from path-only same-file notes" `Quick
            test_security_enforce_does_not_repair_path_only_same_file_notes;
          test_case "confirmed missing proof not repaired from hedged notes" `Quick
            test_security_enforce_does_not_repair_hedged_missing_proof;
          test_case "confirmed rejects empty proof" `Quick test_security_enforce_confirmed_rejects_empty_proof;
          test_case "confirmed requires source and sink trace" `Quick
            test_security_enforce_confirmed_requires_source_and_sink_trace;
          test_case "policy proof concrete" `Quick test_security_enforce_policy_regression_accepts_concrete_proof;
          test_case "policy proof rejects vague" `Quick test_security_enforce_policy_regression_rejects_vague_proof;
          test_case "partial proof JSON downgrades" `Quick test_security_partial_proof_json_downgrades;
          test_case "validator result count mismatch is error" `Quick
            test_security_validator_result_count_mismatch_is_error;
          test_case "rejected does not require proof" `Quick test_security_enforce_rejected_without_proof_ok;
          test_case "proof summaries populate finding fields" `Quick
            test_security_validated_to_finding_uses_proof_summary;
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
          test_case "prompt includes policy_regression" `Quick test_triage_agent_prompt_includes_policy_regression;
          test_case "config model tier" `Quick test_triage_agent_config_model_tier;
          test_case "detect languages" `Quick test_triage_agent_detect_languages;
          test_case "detect languages empty" `Quick test_triage_agent_detect_languages_empty;
          test_case "detect languages unknown" `Quick test_triage_agent_detect_languages_unknown;
          test_case "build input minimal" `Quick test_triage_agent_build_input_minimal;
          test_case "build input with memory" `Quick test_triage_agent_build_input_with_memory;
          test_case "build input empty memory" `Quick test_triage_agent_build_input_empty_memory;
          test_case "output schema valid" `Quick test_triage_agent_output_schema_valid;
          test_case "build input with deterministic signals" `Quick
            test_triage_agent_build_input_with_deterministic_signals;
        ] );
      ( "general_scout_agent",
        [
          test_case "cap_leads truncates keeping highest confidence" `Quick test_general_scout_cap_leads_truncates;
          test_case "cap_leads under max is identity length" `Quick test_general_scout_cap_leads_identity;
          test_case "build input section order" `Quick test_general_scout_build_input_order;
          test_case "config security covered elsewhere" `Quick test_general_scout_config_security_covered;
          test_case "config security not covered" `Quick test_general_scout_config_security_not_covered;
        ] );
      ( "general_deep_reviewer_agent",
        [
          test_case "build input filters to lead paths and orders diff last" `Quick
            test_general_deep_reviewer_build_input_filters_and_orders;
          test_case "build input dedups duplicate lead paths" `Quick test_general_deep_reviewer_build_input_dedups_paths;
          test_case "build input matches prefixed lead paths to bare keys" `Quick
            test_general_deep_reviewer_build_input_prefixed_lead_paths;
          test_case "build input matches bare lead paths" `Quick test_general_deep_reviewer_build_input_bare_lead_paths;
          test_case "build input does not over-strip a/ directory keys" `Quick
            test_general_deep_reviewer_build_input_a_dir_key_not_overstripped;
          test_case "config default normative prompt" `Quick test_general_deep_reviewer_config_default;
          test_case "config override replaces prompt" `Quick test_general_deep_reviewer_config_override;
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
          test_case "always_analyze implies enabled" `Quick test_security_always_analyze_implies_enabled;
          test_case "should analyze high threshold" `Quick test_security_should_analyze_high_threshold;
          test_case "should analyze high threshold restricted" `Quick
            test_security_should_analyze_high_threshold_restricted;
          test_case "should analyze low threshold" `Quick test_security_should_analyze_low_threshold;
          test_case "agent model tier conversion" `Quick test_security_agent_model_tier;
          test_case "standard tier uses Sonnet 5" `Quick test_security_standard_tier_uses_sonnet_5;
          test_case "analysis step budget" `Quick test_security_analysis_step_budget;
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
          test_case "prompt fetch economy" `Quick test_analysis_agent_prompt_fetch_economy;
          test_case "prompt class section" `Quick test_analysis_agent_prompt_contains_class_section;
          test_case "language hints" `Quick test_analysis_agent_language_hints;
          test_case "build input minimal" `Quick test_analysis_agent_build_input_minimal;
          test_case "tools" `Quick test_analysis_agent_tools;
          test_case "output schema" `Quick test_analysis_agent_output_schema;
          test_case "shared methodology" `Quick test_analysis_agent_shared_methodology;
          test_case "vuln class sections" `Quick test_analysis_agent_vuln_class_section_all_classes;
        ] );
      ( "general_review_plugin",
        [
          test_case "agent debug dumps are opt-in" `Quick test_general_agent_debug_dumps_are_opt_in;
          test_case "filters low-value candidates and validates" `Quick
            test_general_review_filters_low_value_and_validates;
          test_case "validator rejection drops finding" `Quick test_general_review_validator_rejection_drops_finding;
          test_case "matches reordered validator results by candidate_id" `Quick
            test_general_review_matches_reordered_validator_results_by_id;
          test_case "validator failure propagates" `Quick test_general_review_validator_failure_is_error;
          test_case "validator parse failure propagates" `Quick test_general_review_validator_parse_failure_is_error;
          test_case "review parse failure propagates" `Quick test_general_review_parse_failure_is_error;
          test_case "pipeline full flow scout deep validator" `Quick test_general_pipeline_full_flow;
          test_case "pipeline early exit on no leads" `Quick test_general_pipeline_early_exit_on_no_leads;
          test_case "pipeline caps leads and completes" `Quick test_general_pipeline_caps_leads;
          test_case "pipeline legacy fallback when scout disabled" `Quick test_general_pipeline_legacy_fallback;
        ] );
      ( "reviewer_e2e",
        [
          test_case "PR review end-to-end" `Quick test_pr_review_e2e;
          test_case "findings present without summary leak" `Quick test_pr_review_findings_present_no_summary_leak;
          test_case "slack attachment omits summary trace" `Quick test_slack_attachment_omits_summary_trace;
          test_case "draft PR skipped" `Quick test_pr_skipped_when_draft;
          test_case "draft PR reviewed when review_draft_prs is enabled" `Quick
            test_pr_reviewed_when_draft_and_flag_enabled;
          test_case "closed PR skipped" `Quick test_pr_skipped_when_closed;
        ] );
      ( "comment_trigger",
        [
          test_case "REVIEW comment triggers PR review" `Quick test_comment_trigger_reviews_pr;
          test_case "REVIEW quiet success posts LGTM comment" `Quick
            test_comment_trigger_quiet_success_posts_lgtm_comment;
          test_case "REVIEW comment ignored when auto_review_on_comment disabled" `Quick test_comment_trigger_disabled;
          test_case "non-trigger body silently ignored" `Quick test_comment_trigger_non_review_body_silent;
          test_case "REVIEW with extra text does not trigger" `Quick test_comment_trigger_body_with_extra_text;
          test_case "whitespace around REVIEW is trimmed" `Quick test_comment_trigger_body_trims_whitespace;
          test_case "REVIEW on regular issue does not trigger" `Quick test_comment_trigger_skips_on_regular_issue;
          test_case "REVIEW on closed PR does not trigger" `Quick test_comment_trigger_skips_on_closed_pr;
          test_case "edited comment does not retrigger" `Quick test_comment_trigger_skips_edited_action;
          test_case "bot sender does not trigger" `Quick test_comment_trigger_skips_bot_sender;
          test_case "ignored author does not trigger" `Quick test_comment_trigger_skips_ignored_author;
          test_case "REVIEW re-reviews same head SHA" `Quick test_comment_trigger_re_reviews_same_sha;
        ] );
      ( "pr_edge_cases",
        [
          test_case "PR synchronize triggers review" `Quick test_pr_synchronize_review;
          test_case "PR with all ignored paths posts skip comment" `Quick test_pr_all_ignored_paths_posts_skip_comment;
          test_case "PR with empty findings posts LGTM comment" `Quick test_pr_empty_findings_review;
          test_case "large PR over max_diff_lines posts comment" `Quick test_pr_large_diff_posts_comment;
          test_case "generated files filtered before PR file limit" `Quick
            test_pr_generated_files_filtered_before_file_limit;
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
      ( "local_review",
        [
          test_case "git default repo key" `Quick test_local_git_default_repo_key;
          test_case "duplicate message detection" `Quick test_local_review_duplicate_message_detection;
          test_case "git spawn errors return Error" `Quick test_local_git_run_git_reports_spawn_errors;
          test_case "git infer base uses explicit base" `Quick test_local_git_infer_base_uses_explicit_base;
          test_case "git infer base uses origin HEAD" `Quick test_local_git_infer_base_uses_origin_head;
          test_case "git diff uses merge-base" `Quick test_local_git_diff_against_base_uses_merge_base;
          test_case "source builds local job" `Quick test_local_source_prepare_review_builds_job;
          test_case "source rejects unsafe fetch path" `Quick test_local_source_rejects_unsafe_fetch_path;
          test_case "source rejects symlink escape" `Quick test_local_source_rejects_symlink_escape;
          test_case "source reports fetch read errors" `Quick test_local_source_reports_fetch_read_errors;
          test_case "source default change key uses filtered diff" `Quick
            test_local_source_default_change_key_uses_filtered_diff;
          test_case "review path filters generated before limits" `Quick
            test_local_review_path_filters_generated_before_limits;
          test_case "review diff returns markdown" `Quick test_local_review_diff_returns_markdown;
          test_case "review generated diff text returns markdown" `Quick test_local_review_diff_text_returns_markdown;
          test_case "all-refuted local review shows LGTM not summary" `Quick
            test_local_review_all_refuted_shows_lgtm_not_summary;
          test_case "security-only empty review is success" `Quick test_local_review_security_only_empty_is_success;
          test_case "policy sudo regression produces finding" `Quick test_local_review_policy_regression_sudo_vulnerable;
          test_case "policy sudo scoped safe produces no finding" `Quick
            test_local_review_policy_regression_sudo_scoped_safe;
          test_case "review plugins use supplied config" `Quick test_local_review_uses_supplied_config_for_plugins;
          test_case "duplicate local change skipped" `Quick test_local_review_skips_duplicate_change;
          test_case "github plugins use captured config" `Quick test_github_review_uses_captured_config_for_plugins;
          test_case "local sink renders json" `Quick test_local_sink_render_json;
        ] );
      ( "state_persistence",
        [
          test_case "save/load roundtrip" `Quick test_state_save_load_roundtrip;
          test_case "load from non-existent file" `Quick test_state_empty_load;
          test_case "generic change review roundtrip" `Quick test_state_change_review_roundtrip;
          test_case "legacy repo state without change_reviews loads" `Quick
            test_state_loads_legacy_repo_state_without_change_reviews;
        ] );
      ( "feedback",
        [
          test_case "paths derive from state" `Quick test_feedback_paths_from_state;
          test_case "paths are absolute" `Quick test_feedback_paths_are_absolute;
          test_case "paths derive from custom feedback dir" `Quick test_feedback_paths_from_custom_dir;
          test_case "local runtime dirs use XDG state" `Quick test_local_runtime_dirs_use_xdg_state;
          test_case "debug dir uses feedback sibling" `Quick test_debug_dir_with_feedback_store_uses_feedback_sibling;
          test_case "memory dir uses feedback sibling" `Quick test_memory_dir_with_feedback_store_uses_feedback_sibling;
          test_case "review job log context" `Quick test_review_job_log_context;
          test_case "marker and deterministic ids" `Quick test_feedback_marker_and_id_helpers;
          test_case "target roundtrip and privacy scan" `Quick test_feedback_target_roundtrip_and_privacy;
          test_case "target schema compatibility and v3 fields" `Quick
            test_feedback_target_schema_compatibility_and_v3_fields;
          test_case "deadline semantics" `Quick test_feedback_deadline_semantics;
          test_case "PR close marks final_due" `Quick test_feedback_close_marks_final_due;
          test_case "pollable target selection" `Quick test_feedback_pollable_selection;
          test_case "terminal statuses are not pollable" `Quick test_feedback_status_selection_terminal_values;
          test_case "remote pagination collects all pages" `Quick
            test_api_remote_collect_paginated_list_requests_all_pages;
          test_case "remote GraphQL review reaction parser" `Quick test_api_remote_parse_pr_review_reaction_counts;
          test_case "collector resolves counts and is idempotent" `Quick
            test_feedback_collector_resolves_counts_and_is_idempotent;
          test_case "collector final-due target closes" `Quick test_feedback_collector_final_due_closes_target;
          test_case "collector marks missing on review comment 404" `Quick
            test_feedback_collector_marks_missing_on_review_comment_404;
          test_case "collector marks missing on integration 403" `Quick
            test_feedback_collector_marks_missing_on_integration_403;
          test_case "collector keeps active on transient reaction error" `Quick
            test_feedback_collector_keeps_active_on_transient_reaction_error;
          test_case "collector collects body reaction counts" `Quick
            test_feedback_collector_collects_body_reaction_counts;
          test_case "collector marks body missing on null GraphQL node" `Quick
            test_feedback_collector_marks_body_missing_on_null_graphql_node;
          test_case "collector keeps body active on GraphQL error" `Quick
            test_feedback_collector_keeps_body_active_on_graphql_error;
          test_case "report summarizes targets and evidence" `Quick test_feedback_report_summarizes_targets_and_evidence;
          test_case "report resolves evidence when stored dir is stale" `Quick
            test_feedback_report_resolves_evidence_when_stored_dir_is_stale;
          test_case "publish records targets and markers" `Quick test_feedback_publish_records_targets_and_markers;
          test_case "publish body-only review records body target" `Quick
            test_feedback_publish_body_only_records_body_target_and_evidence;
          test_case "failed publish records no targets" `Quick test_feedback_publish_failure_records_no_targets;
          test_case "quiet success records no targets" `Quick test_feedback_quiet_success_records_no_targets;
          test_case "feedback disabled writes no evidence" `Quick test_feedback_disabled_writes_no_evidence;
          test_case "webhook store failure does not block review" `Quick
            test_feedback_webhook_store_failure_does_not_block_review;
          test_case "issue_comment webhook shortens deadline" `Quick
            test_feedback_webhook_issue_comment_shortens_deadline;
          test_case "pull_request synchronize webhook shortens deadline" `Quick
            test_feedback_webhook_pr_synchronize_shortens_deadline;
          test_case "pull_request_review webhook shortens deadline" `Quick
            test_feedback_webhook_review_shortens_deadline;
          test_case "pull_request_review_comment webhook shortens deadline" `Quick
            test_feedback_webhook_review_comment_shortens_deadline;
          test_case "pull_request close webhook marks final_due" `Quick test_feedback_webhook_pr_close_marks_final_due;
        ] );
      ( "cost_tracking",
        [
          test_case "estimate cost sonnet" `Quick test_estimate_cost_sonnet;
          test_case "estimate cost openrouter sonnet" `Quick test_estimate_cost_openrouter_sonnet;
          test_case "estimate cost haiku" `Quick test_estimate_cost_haiku;
          test_case "estimate cost opus" `Quick test_estimate_cost_opus;
          test_case "estimate cost default tier models" `Quick test_estimate_cost_default_tier_models;
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
      ( "memory_curator",
        [
          test_case "curator_output roundtrip" `Quick test_curator_output_roundtrip;
          test_case "config" `Quick test_curator_agent_config;
          test_case "config model tier" `Quick test_curator_agent_config_model_tier;
          test_case "output schema valid" `Quick test_curator_agent_output_schema_valid;
          test_case "prompt is architectural only" `Quick test_curator_prompt_architectural_only;
          test_case "build input no memory" `Quick test_curator_build_input_no_memory;
          test_case "build input with memory" `Quick test_curator_build_input_with_memory;
          test_case "build input empty memory" `Quick test_curator_build_input_empty_memory;
          test_case "build input empty observations" `Quick test_curator_build_input_empty_observations;
          test_case "build input samples long file list" `Quick test_curator_build_input_samples_long_file_list;
          test_case "input never contains findings" `Quick test_curator_input_never_contains_findings;
          test_case "save load roundtrip" `Quick test_curator_save_load_roundtrip;
          test_case "token budget shown in input" `Quick test_curator_build_input_token_budget;
        ] );
      ( "security_e2e",
        [
          test_case "vulnerable diff produces security finding" `Quick test_security_e2e_vulnerable;
          test_case "safe diff produces no security findings" `Quick test_security_e2e_safe;
          test_case "deterministic signals do not route without triage" `Quick
            test_security_e2e_deterministic_signals_do_not_route;
          test_case "rejected finding produces no security output" `Quick test_security_e2e_rejected;
          test_case "empty skip_reason does not silence pipeline" `Quick test_security_e2e_triage_empty_skip_reason;
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
          test_case "push prepare failure posts Slack" `Quick test_push_prepare_failure_posts_slack;
          test_case "generated files do not trigger push prepare failure Slack" `Quick
            test_push_generated_files_do_not_trigger_prepare_failure_slack;
          test_case "push empty prepare posts skip Slack" `Quick test_push_empty_prepare_posts_skip_slack;
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
          test_case "error classification" `Quick test_retry_classification;
          test_case "with_retry recovers on transient error" `Quick test_with_retry_recovers;
          test_case "with_retry fails fast on permanent error" `Quick test_with_retry_fails_fast;
          test_case "with_retry exhausts max attempts" `Quick test_with_retry_exhausts_attempts;
        ] );
      ( "review_failure_notification",
        [
          test_case "classify: 406 is remote-too-large" `Quick test_review_failure_classify_too_large;
          test_case "classify: other status is generic" `Quick test_review_failure_classify_generic;
          test_case "classify: transport error is generic" `Quick test_review_failure_classify_transport_error;
          test_case "comment text names cause and counts" `Quick test_review_failure_comment_mentions_cause;
          test_case "PR diff too large (406) posts a comment" `Quick test_pr_diff_fetch_too_large_posts_comment;
          test_case "PR diff too large retries when comment post fails" `Quick
            test_pr_diff_fetch_too_large_comment_failure_retries;
          test_case "PR diff fetch generic error posts a comment" `Quick test_pr_diff_fetch_generic_error_posts_comment;
          test_case "PR over line limit posts a comment" `Quick test_pr_too_many_lines_posts_comment;
          test_case "PR over line limit retries when comment post fails" `Quick
            test_pr_too_many_lines_comment_failure_retries;
          test_case "PR over file limit posts a comment" `Quick test_pr_too_many_files_posts_comment;
          test_case "REVIEW over file limit posts a comment" `Quick test_comment_trigger_too_many_files_posts_comment;
          test_case "REVIEW diff fetch failure posts a comment" `Quick
            test_comment_trigger_diff_fetch_error_posts_comment;
          test_case "REVIEW PR fetch failure posts a comment" `Quick test_comment_trigger_pr_fetch_error_posts_comment;
          test_case "PR review publish failure posts fallback comment" `Quick
            test_pr_review_post_failure_posts_fallback_comment;
          test_case "PR review publish failure retries when fallback fails" `Quick
            test_pr_review_post_failure_retries_when_fallback_fails;
          test_case "PR quiet success retries when comment fails" `Quick test_pr_quiet_success_comment_failure_retries;
          test_case "PR with empty diff posts skip comment" `Quick test_pr_empty_diff_posts_skip_comment;
          test_case "PR empty-diff skip retries when comment fails" `Quick
            test_pr_empty_diff_skip_comment_failure_retries;
        ] );
      "debug_dump", [ test_case "write debug dump creates file with expected content" `Quick test_write_debug_dump ];
      ( "budget_recovery",
        [
          test_case "messages_of_steps: empty input" `Quick test_messages_of_steps_empty;
          test_case "messages_of_steps: text-only step" `Quick test_messages_of_steps_text_only_step;
          test_case "messages_of_steps: completed tool turn" `Quick test_messages_of_steps_completed_tool_turn;
          test_case "messages_of_steps: drops unfulfilled final turn" `Quick
            test_messages_of_steps_drops_unfulfilled_final_turn;
          test_case "messages_of_steps: preserves Assistant/Tool interleaving" `Quick
            test_messages_of_steps_multi_turn_ordering;
        ] );
      ( "agent_thinking",
        [
          test_case "provider_options is empty when thinking_budget is None" `Quick
            test_provider_options_empty_when_no_thinking_budget;
          test_case "provider_options carries thinking config when set" `Quick
            test_provider_options_carries_thinking_when_set;
          test_case "provider_options carries OpenRouter medium effort" `Quick
            test_provider_options_carries_openrouter_medium_effort;
          test_case "provider_options clamps budget to 1024 minimum" `Quick test_provider_options_clamps_below_minimum;
          test_case "general review agent_config enables thinking" `Quick
            test_general_review_agent_config_enables_thinking;
        ] );
      ( "telemetry",
        [
          test_case "absent env disables tracing" `Quick test_telemetry_env_absent_disables;
          test_case "REVIEWOTRON_OTEL enables tracing" `Quick test_telemetry_env_reviewotron_flag_enables;
          test_case "standard endpoint enables tracing" `Quick test_telemetry_env_standard_endpoint_enables;
          test_case "OTEL_SDK_DISABLED disables tracing" `Quick test_telemetry_env_sdk_disabled_wins;
          test_case "explicit false disables tracing" `Quick test_telemetry_env_explicit_false_disables;
          test_case "blank traces endpoint strips base slash" `Quick
            test_telemetry_blank_traces_endpoint_strips_base_slash;
          test_case "CLI traces endpoint overrides traces env" `Quick
            test_telemetry_cli_traces_endpoint_overrides_traces_env;
          test_case "disabled setup smoke" `Quick test_telemetry_disabled_setup_smoke;
          test_case "with_env_vars restores unset vars to unset" `Quick test_with_env_vars_restores_unset_vars_to_unset;
        ] );
      ( "prompt_caching",
        [
          test_case "cached_input_provider_options carries an ephemeral breakpoint" `Quick
            test_cached_input_provider_options_marks_ephemeral;
        ] );
    ]
