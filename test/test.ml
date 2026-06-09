open Devkit
open Reviewotron_lib
open Alcotest

let read_file path = Std.input_file ~bin:true path
let read_json path = Melange_json.of_string (read_file path)

let contains_sub ~sub s = CCString.find ~sub s >= 0

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
  (check int) "always_analyze_vuln_classes default empty" 0
    (List.length config.review_plugins.security.always_analyze_vuln_classes);
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
        "always_analyze_vuln_classes": ["xss"],
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
  (check int) "always_analyze count" 1 (List.length config.review_plugins.security.always_analyze_vuln_classes);
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
      always_analyze_vuln_classes = [ Xss ];
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
  (check int) "always_analyze_vuln_classes" 1 (List.length parsed.always_analyze_vuln_classes);
  (check int) "memory_max_tokens" 3000 parsed.memory_max_tokens;
  (check string) "confidence" "high" (Config_types.confidence_to_string parsed.confidence_threshold);
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

(** The system prompt must explicitly establish the workflow that separates
    reasoning from the human-facing comment.  Reasoning happens first, the
    verdict is decided, and only then is the comment articulated. *)
let test_system_prompt_workflow_section () =
  let prompt = Review_prompt.system_prompt ~security_covered_elsewhere:false () in
  (check bool) "prompt names the workflow" true (CCString.find ~sub:"Per-Finding Workflow" prompt >= 0);
  (check bool) "prompt instructs to reason first" true (CCString.find ~sub:"REASON" prompt >= 0);
  (check bool) "prompt instructs to decide a verdict" true (CCString.find ~sub:"VERDICT" prompt >= 0);
  (check bool) "prompt instructs to articulate the comment last" true (CCString.find ~sub:"ARTICULATE" prompt >= 0);
  (check bool) "prompt includes a signal/noise check" true (CCString.find ~sub:"SIGNAL CHECK" prompt >= 0)

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

let test_anthropic_structured_output_schemas_compatible () =
  let schemas : (string * Yojson.Basic.t) list =
    [
      "general_review", Review_types.review_output_jsonschema;
      "general_validator", Review_types.validator_output_jsonschema;
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
  let system = Review_prompt.system_prompt ~security_covered_elsewhere:false () in
  let diff = "diff --git a/foo.ml b/foo.ml\n+let x = 1" in
  let user = Review_prompt.build_user_message ~diff ~pr_title:"Test" () in
  let estimate = Review_prompt.estimate_prompt_tokens ~system ~user in
  let char_count = String.length system + String.length user in
  (* Estimate should be roughly chars/4, within 2x *)
  (check bool) "estimate > 0" true (estimate > 0);
  (check bool) "estimate within 2x of chars/4" true (estimate <= char_count / 2);
  (check bool) "estimate at least chars/8" true (estimate >= char_count / 8)

(** {2 Dedup tests} *)

let mk_finding ~path ~line ?(end_line = None) ?(severity = Review_types.Warning) ?(category = Review_types.Security)
  ?(message = "msg") ?(suggested_fix = None) () : Review_types.finding =
  {
    path;
    line;
    end_line;
    severity;
    category;
    message;
    failure_scenario = "scenario";
    evidence_snippet = "snippet";
    why_now = "changed in this PR";
    confidence = Review_types.Medium;
    suggested_fix;
  }

let finding_by_message msg (f : Review_types.finding) = String.equal f.message msg

let test_dedup_same_line_prefers_security () =
  let general = mk_finding ~path:"a.ml" ~line:10 ~message:"general" () in
  let security = mk_finding ~path:"a.ml" ~line:10 ~message:"security" () in
  let out = Reviewer.deduplicate_findings [ Reviewer.From_general, general; Reviewer.From_security, security ] in
  (check int) "single finding" 1 (List.length out);
  (check bool) "security wins" true (List.exists (finding_by_message "security") out)

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
module R_anchor_test = Reviewer.Make (Api_local.Github) (Api_local.Agent_runner) (Api_local.Slack)

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

module Sec_test = Security_review_plugin.Make (Api_local.Github) (Api_local.Agent_runner)

(** Same two-hunk diff we use for the multi-line tests: file [src/main.ml]
    with hunks at [10..14] and [40..43]. *)
let parsed_anchor_diff = parsed_two_hunk_diff

let mk_validated ~source ~sink ~flow ?(verdict = Security_types.Confirmed) ?(evidence_notes = "ok") () :
  Security_types.validated_finding =
  {
    finding =
      {
        vuln_class = Security_types.Authz;
        source;
        sink;
        flow;
        sanitization = Missing;
        confidence = High;
        description = "described vulnerability";
        suggested_fix = None;
      };
    verdict;
    evidence_notes;
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
  (check int) "finding line" 42 f.line

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
  (check bool) "publishes agent summary" true (contains_sub ~sub:"The changes look generally good" write_log);
  (check bool) "has comments" true (contains_sub ~sub:"error-handling" write_log)

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

let test_comment_trigger_quiet_success_reacts () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
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
  (check bool) "quiet success reaction added to trigger comment" true
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

let test_pr_all_ignored_paths_thumbs_up () =
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
  (* Nothing to review is a successful no-op: thumbs-up, no comment, no review. *)
  (check bool) "thumbs-up reaction added" true
    (contains_sub ~sub:"[create_issue_reaction] repo=https://github.com/org/monorepo number=99 content=+1" write_log);
  (check bool) "no failure comment" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "no review attempted" false (contains_sub ~sub:"[create_pr_review]" write_log)

let test_pr_empty_findings_review () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/empty_findings_response.json";
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = read_file "mock_payloads/pr_opened.json" in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "progress reaction added" true (contains_sub ~sub:"[create_issue_reaction]" write_log);
  (check bool) "progress reaction removed" true
    (contains_sub ~sub:"[delete_issue_reaction] repo=https://github.com/org/monorepo number=42" write_log);
  (check bool) "quiet success reaction added" true
    (contains_sub ~sub:"[create_issue_reaction] repo=https://github.com/org/monorepo number=42 content=+1" write_log);
  (check bool) "no PR review when there is nothing to add" false (contains_sub ~sub:"[create_pr_review]" write_log);
  match event with
  | Github.Pull_request pr ->
    (check bool) "quiet review recorded in state" true
      (State.is_pr_reviewed (Context.state ctx) ~repo_url:pr.repository.url ~pr_number:pr.number
         ~head_sha:pr.pull_request.head.sha)
  | Github.Push _ | Github.Issue_comment _ | Github.Unknown _ -> fail "expected pull_request event"

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

(** {2 Push review tests} *)

let test_push_review_e2e () =
  Test_helpers.reset_test_state ();
  Api_local.set_agent_response_path "mock_api_responses/claude/push_review_response.json";
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
      Security_memory.save ~memory_dir:tmp_dir ~repo_url ~content:updated_memory;
      let loaded = Security_memory.load ~memory_dir:tmp_dir ~repo_url in
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
    treated as a successful (empty) review: a [+1] reaction, no comment. *)

(* Unit tests for the pure classification / formatting helpers. *)
let test_review_failure_classify_too_large () =
  (* GitHub answers the diff media type with HTTP 406 when the diff is too
     large; classification keys on the status code, not the message text. *)
  let error : Http_util.error = Http_util.Status (406, "the diff exceeded the maximum number of files (300)") in
  match Review_failure.classify_fetch_error error with
  | Diff_too_large_remote _ -> ()
  | Fetch_failed _ | Too_many_lines _ | Too_many_files _ ->
    Alcotest.fail "expected Diff_too_large_remote for a 406 response"

let test_review_failure_classify_generic () =
  let error : Http_util.error = Http_util.Status (503, "service unavailable") in
  match Review_failure.classify_fetch_error error with
  | Fetch_failed _ -> ()
  | Diff_too_large_remote _ | Too_many_lines _ | Too_many_files _ ->
    Alcotest.fail "expected Fetch_failed for a non-406 status"

let test_review_failure_classify_transport_error () =
  (* A curl/transport failure has no HTTP status — must not be mistaken for the
     too-large case. *)
  let error : Http_util.error = Http_util.Transport Curl.CURLE_COULDNT_CONNECT in
  match Review_failure.classify_fetch_error error with
  | Fetch_failed _ -> ()
  | Diff_too_large_remote _ | Too_many_lines _ | Too_many_files _ ->
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
    (contains_sub ~sub:"too large" (String.lowercase_ascii remote))

(* Integration tests: drive process_event and assert on the write log. *)
let check_same_pr_webhook_deduped ~ctx ~event =
  Api_local.clear_write_log ();
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check string) "same PR webhook deduped" "" write_log

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

let test_pr_empty_diff_adds_thumbs_up_no_comment () =
  Test_helpers.reset_test_state ();
  Api_local.set_next_pr_diff "";
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  let payload = Test_helpers.make_pr_payload () in
  let event = Test_helpers.parse_event_exn ~event_type:"pull_request" ~body:payload in
  Lwt_main.run (R_test.process_event ctx ~event);
  let write_log = Api_local.get_write_log () in
  (check bool) "thumbs-up reaction added on empty diff" true
    (contains_sub ~sub:"[create_issue_reaction] repo=https://github.com/org/monorepo number=42 content=+1" write_log);
  (check bool) "no failure comment posted on empty diff" false (contains_sub ~sub:"[create_issue_comment]" write_log);
  (check bool) "no review attempted on empty diff" false (contains_sub ~sub:"[create_pr_review]" write_log);
  check_same_pr_webhook_deduped ~ctx ~event

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

let mk_agent_config ?thinking_budget () : Agent_runner.agent_config =
  {
    name = "test_agent";
    system_prompt = "be a test";
    model_tier = Standard;
    output_schema = `Assoc [];
    max_steps = 1;
    thinking_budget;
  }

let test_provider_options_empty_when_no_thinking_budget () =
  let cfg = mk_agent_config () in
  let po = Agent_runner.build_provider_options cfg in
  (check bool) "no Anthropic options when thinking_budget = None" true
    (Option.is_none (Ai_provider_anthropic.Anthropic_options.of_provider_options po))

let test_provider_options_carries_thinking_when_set () =
  let cfg = mk_agent_config ~thinking_budget:4096 () in
  let po = Agent_runner.build_provider_options cfg in
  match Ai_provider_anthropic.Anthropic_options.of_provider_options po with
  | None -> fail "expected Anthropic options to be present when thinking_budget is set"
  | Some opts ->
  match opts.thinking with
  | None -> fail "expected thinking config to be populated"
  | Some t ->
    (check bool) "thinking enabled" true t.enabled;
    (check int) "thinking budget matches" 4096 (Ai_provider_anthropic.Thinking.to_int t.budget_tokens)

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
  let set_outputs entries = outputs := entries

  let run ~ctx:_ ~repo_url:_ ?model_id:_ ?tools:_ ?debug_dir:_ ~config ~input:_ () =
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
               model_id = "mock";
             })
end

module General_plugin_test = General_review_plugin.Make (General_plugin_agent_runner)

let general_plugin_metadata : Review_plugin.review_metadata =
  { pr_number = 42; pr_title = "Test PR"; pr_description = ""; file_contents = [] }

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

let run_general_plugin_with_outputs outputs =
  Test_helpers.reset_test_state ();
  General_plugin_agent_runner.set_outputs outputs;
  let ctx = Test_helpers.make_test_context ~config:Test_helpers.auto_review_enabled_config () in
  Lwt_main.run
    (General_plugin_test.run_review ~ctx ~repo_url:"https://github.com/org/repo" ~diff_text:"diff"
       ~metadata:general_plugin_metadata ())

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

let test_provider_options_clamps_below_minimum () =
  (* Anthropic requires budget_tokens >= 1024.  When a caller asks for less,
     the runner must either reject or clamp; we choose to clamp up to 1024 so
     misconfiguration does not crash the agent loop. *)
  let cfg = mk_agent_config ~thinking_budget:500 () in
  let po = Agent_runner.build_provider_options cfg in
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
  let po = Agent_runner.cached_input_provider_options in
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
        [ test_case "structured output schemas compatible" `Quick test_anthropic_structured_output_schemas_compatible ]
      );
      ( "dedup",
        [
          test_case "same line prefers security" `Quick test_dedup_same_line_prefers_security;
          test_case "same line same source higher severity wins" `Quick
            test_dedup_same_line_same_source_higher_severity_wins;
          test_case "near line collapse same category" `Quick test_dedup_near_line_collapse_same_category;
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
          test_case "always_analyze implies enabled" `Quick test_security_always_analyze_implies_enabled;
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
          test_case "tools" `Quick test_analysis_agent_tools;
          test_case "output schema" `Quick test_analysis_agent_output_schema;
          test_case "shared methodology" `Quick test_analysis_agent_shared_methodology;
          test_case "vuln class sections" `Quick test_analysis_agent_vuln_class_section_all_classes;
        ] );
      ( "general_review_plugin",
        [
          test_case "filters low-value candidates and validates" `Quick
            test_general_review_filters_low_value_and_validates;
          test_case "validator rejection drops finding" `Quick test_general_review_validator_rejection_drops_finding;
          test_case "matches reordered validator results by candidate_id" `Quick
            test_general_review_matches_reordered_validator_results_by_id;
          test_case "validator failure propagates" `Quick test_general_review_validator_failure_is_error;
          test_case "validator parse failure propagates" `Quick test_general_review_validator_parse_failure_is_error;
          test_case "review parse failure propagates" `Quick test_general_review_parse_failure_is_error;
        ] );
      ( "reviewer_e2e",
        [
          test_case "PR review end-to-end" `Quick test_pr_review_e2e;
          test_case "draft PR skipped" `Quick test_pr_skipped_when_draft;
          test_case "draft PR reviewed when review_draft_prs is enabled" `Quick
            test_pr_reviewed_when_draft_and_flag_enabled;
          test_case "closed PR skipped" `Quick test_pr_skipped_when_closed;
        ] );
      ( "comment_trigger",
        [
          test_case "REVIEW comment triggers PR review" `Quick test_comment_trigger_reviews_pr;
          test_case "REVIEW quiet success reacts without posting" `Quick test_comment_trigger_quiet_success_reacts;
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
          test_case "PR with all ignored paths gets thumbs-up" `Quick test_pr_all_ignored_paths_thumbs_up;
          test_case "PR with empty findings posts summary" `Quick test_pr_empty_findings_review;
          test_case "large PR over max_diff_lines posts comment" `Quick test_pr_large_diff_posts_comment;
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
          test_case "PR diff fetch generic error posts a comment" `Quick test_pr_diff_fetch_generic_error_posts_comment;
          test_case "PR over line limit posts a comment" `Quick test_pr_too_many_lines_posts_comment;
          test_case "PR over file limit posts a comment" `Quick test_pr_too_many_files_posts_comment;
          test_case "PR with empty diff gets thumbs-up, no comment" `Quick test_pr_empty_diff_adds_thumbs_up_no_comment;
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
          test_case "provider_options clamps budget to 1024 minimum" `Quick test_provider_options_clamps_below_minimum;
          test_case "general review agent_config enables thinking" `Quick
            test_general_review_agent_config_enables_thinking;
        ] );
      ( "prompt_caching",
        [
          test_case "cached_input_provider_options carries an ephemeral breakpoint" `Quick
            test_cached_input_provider_options_marks_ephemeral;
        ] );
    ]
