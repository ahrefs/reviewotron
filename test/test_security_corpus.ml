(** Corpus test runner for the security review pipeline.

    These tests run the full security pipeline (or just the triage stage)
    against synthetic diff files with known vulnerability characteristics.
    They call the real Claude API and cost money.

    Run on-demand (not in CI) by setting the ANTHROPIC_API_KEY environment
    variable:

      cd test
      ANTHROPIC_API_KEY=sk-... dune exec ./test_security_corpus.exe

    When ANTHROPIC_API_KEY is absent, all tests are skipped. *)

open Reviewotron_lib
open Alcotest

(** Instantiate the security plugin with local (mock) GitHub and remote
    (real Claude) agent runner.  The local GitHub implementation returns
    [Ok None] for any [get_file_content] call that lacks a mock fixture,
    which is acceptable because all corpus diffs are self-contained. *)
module SP = Security_review_plugin.Make (Api_remote.Agent_runner)

(** Skip this test if [ANTHROPIC_API_KEY] is not set; otherwise return the key. *)
let require_api_key () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None -> skip ()
  | Some key -> key

let corpus_repo_url = "https://github.com/test/security-corpus"

(** Create a [Context.t] suitable for corpus tests.  Uses the provided API
    key; all other settings are left at defaults.  Pre-populates the repo
    config cache so the plugin does not need to fetch from GitHub. *)
let make_corpus_context ~api_key =
  let secrets : Config_types.secrets =
    { repos = []; anthropic_api_key = Some api_key; openrouter_api_key = None; slack_access_token = None }
  in
  let ctx = Context.make ~secrets () in
  Context.set_config ctx ~repo_key:corpus_repo_url (Context.default_config ());
  ctx

(** Read a corpus diff file and parse it. Returns [(diff_text, file_diffs)]. *)
let read_corpus_diff path =
  let diff_text = Std.input_file ~bin:true path in
  let diffs = Diff_parser.parse diff_text in
  diff_text, diffs

(** Run just the triage agent on a diff and return its structured output.
    Raises [Test_error] if the agent fails or the output is unparseable. *)
let run_triage ~ctx ~diff_text ~file_paths : Security_types.triage_output =
  let security_config = Config_types.default_security_plugin_config in
  let model_tier = Security_review_plugin.agent_model_tier security_config.triage_model_tier in
  let triage_config = Triage_agent.config ~model_tier in
  let triage_input = Triage_agent.build_input ~diff_text ~file_paths () in
  let result =
    Lwt_main.run
      (Api_remote.Agent_runner.run ~ctx ~repo_url:corpus_repo_url ~config:triage_config ~input:triage_input ())
  in
  match result with
  | Error msg -> failf "triage agent failed: %s" msg
  | Ok agent_result ->
  try Security_types.triage_output_of_json agent_result.output
  with exn -> failf "failed to parse triage output: %s" (Printexc.to_string exn)

(** Run the full security pipeline on a diff and return the findings. *)
let run_pipeline ~ctx ~diff_text ~diff =
  let fetch_file ~path:_ = Lwt.return (Ok None) in
  let metadata : Review_plugin.review_metadata =
    { change_title = "corpus test"; change_description = ""; file_contents = []; fetch_file }
  in
  let config = Context.get_config ctx ~repo_key:corpus_repo_url in
  let findings, _costs =
    Lwt_main.run
      (SP.run ~ctx ~repo_url:corpus_repo_url ~config ~diff ~diff_text ~metadata ~log_context:None
         ~debug_dir:"debug/corpus")
  in
  findings

(** Expected outcome of running the pipeline against a corpus diff. *)
type expected_outcome =
  | Vulnerable of Security_types.vuln_class
    (** Pipeline should produce at least one Security finding.  The given
        vuln class is used for triage-specific assertions. *)
  | Clean  (** Pipeline should produce no findings. *)

(** A single corpus test case.

    [name] doubles as the relative path under [security_corpus/] with
    [.diff] appended, so [diff_path = "security_corpus/" ^ name ^ ".diff"]. *)
type corpus_case = {
  name : string;
  file_path : string;  (** Expected path of the changed file in the diff. *)
  expected : expected_outcome;
}

(** Derive the diff file path from the corpus case name. *)
let diff_path (case : corpus_case) = Printf.sprintf "security_corpus/%s.diff" case.name

(** All corpus cases, grouped by vulnerability class. *)
let corpus_cases : corpus_case list =
  [
    {
      name = "injection/sql_concat_vulnerable";
      file_path = "src/handlers/user.py";
      expected = Vulnerable Security_types.Injection;
    };
    { name = "injection/sql_parameterized_safe"; file_path = "src/handlers/user.py"; expected = Clean };
    {
      name = "injection/sql_partial_sanitization";
      file_path = "src/handlers/user.py";
      expected = Vulnerable Security_types.Injection;
    };
    {
      name = "xss/innerHTML_vulnerable";
      file_path = "src/components/UserProfile.jsx";
      expected = Vulnerable Security_types.Xss;
    };
    { name = "xss/escaped_output_safe"; file_path = "src/components/UserProfile.jsx"; expected = Clean };
    {
      name = "command_injection/exec_user_input";
      file_path = "lib/handlers/file_preview.ml";
      expected = Vulnerable Security_types.Command_injection;
    };
    { name = "command_injection/exec_hardcoded_safe"; file_path = "lib/handlers/system_info.ml"; expected = Clean };
    {
      name = "authn/jwt_no_expiry_check";
      file_path = "lib/auth/jwt_middleware.ml";
      expected = Vulnerable Security_types.Authn;
    };
    {
      name = "authz/missing_ownership_check";
      file_path = "lib/handlers/document.ml";
      expected = Vulnerable Security_types.Authz;
    };
    {
      name = "ssrf/url_from_user_input";
      file_path = "src/handlers/webhook.py";
      expected = Vulnerable Security_types.Ssrf;
    };
    {
      name = "policy_regression/sudo_systemctl_nopasswd_vulnerable";
      file_path = "modules/sudo/manifests/deploy.pp";
      expected = Vulnerable Security_types.Policy_regression;
    };
    {
      name = "policy_regression/sudo_systemctl_reload_scoped_safe";
      file_path = "modules/sudo/manifests/deploy.pp";
      expected = Clean;
    };
    {
      name = "policy_regression/ci_permissions_write_vulnerable";
      file_path = ".github/workflows/build.yml";
      expected = Vulnerable Security_types.Policy_regression;
    };
    {
      name = "policy_regression/tls_verify_disabled_vulnerable";
      file_path = "src/integrations/vendor_client.py";
      expected = Vulnerable Security_types.Policy_regression;
    };
  ]

(** All vulnerable cases (those expecting at least one finding). *)
let vulnerable_cases =
  List.filter_map
    (fun c ->
      match c.expected with
      | Vulnerable vc -> Some (c, vc)
      | Clean -> None)
    corpus_cases

(** {2 Corpus structure tests (quick, no Claude)} *)

(** Verify that each corpus diff file is parseable and contains the expected
    changed file path.  These tests do not call Claude. *)
let make_structure_test (case : corpus_case) () =
  let diff_text, diffs = read_corpus_diff (diff_path case) in
  (check bool) "diff is non-empty" true (String.length diff_text > 0);
  (check bool) "at least one file diff" true (not (List.is_empty diffs));
  (check bool)
    (Printf.sprintf "expected path %s present" case.file_path)
    true
    (List.exists (fun (fd : Diff_parser.file_diff) -> String.equal fd.path case.file_path) diffs)

(** {2 Quality metric accumulation} *)

(** Accumulated triage results, populated by triage tests during the run. *)
let triage_results : Quality_metrics.triage_result list ref = ref []

(** Accumulated pipeline results, populated by pipeline tests during the run. *)
let pipeline_results : Quality_metrics.pipeline_result list ref = ref []

(** {2 Triage tests (slow, requires ANTHROPIC_API_KEY)} *)

(** Verify that the triage agent flags the expected vuln class for a vulnerable
    diff, and record the result for quality metric tracking. *)
let make_triage_test (case : corpus_case) (expected_vc : Security_types.vuln_class) () =
  let api_key = require_api_key () in
  let ctx = make_corpus_context ~api_key in
  let diff_text, diffs = read_corpus_diff (diff_path case) in
  let file_paths = List.map (fun (fd : Diff_parser.file_diff) -> fd.path) diffs in
  let triage_output = run_triage ~ctx ~diff_text ~file_paths in
  let flagged_classes = List.map (fun (s : Security_types.triage_signal) -> s.vuln_class) triage_output.signals in
  triage_results :=
    { Quality_metrics.case_name = case.name; expected_vuln_class = expected_vc; flagged_classes } :: !triage_results;
  (check bool)
    (Printf.sprintf "triage flags %s" (Security_types.vuln_class_to_string expected_vc))
    true
    (List.exists (Security_review_plugin.vuln_class_equal expected_vc) flagged_classes)

(** {2 Full pipeline tests (slow, requires ANTHROPIC_API_KEY)} *)

(** Run the full pipeline against a corpus case, assert the expected outcome,
    and record the result for quality metric tracking. *)
let make_pipeline_test (case : corpus_case) () =
  let api_key = require_api_key () in
  let ctx = make_corpus_context ~api_key in
  let diff_text, diff = read_corpus_diff (diff_path case) in
  let findings = run_pipeline ~ctx ~diff_text ~diff in
  let is_vulnerable =
    match case.expected with
    | Vulnerable _ -> true
    | Clean -> false
  in
  pipeline_results :=
    { Quality_metrics.case_name = case.name; is_vulnerable; findings_count = List.length findings } :: !pipeline_results;
  match case.expected with
  | Vulnerable _ ->
    (check bool) (Printf.sprintf "%s: at least one security finding" case.name) true (not (List.is_empty findings));
    List.iter
      (fun (f : Review_types.finding) ->
        (check bool)
          (Printf.sprintf "%s: finding category is Security" case.name)
          true
          (match f.category with
          | Review_types.Security -> true
          | Review_types.Bug | Review_types.Performance | Review_types.Style | Review_types.Logic
          | Review_types.Error_handling | Review_types.Naming | Review_types.Documentation | Review_types.Other _ ->
            false))
      findings
  | Clean -> (check bool) (Printf.sprintf "%s: no security findings" case.name) true (List.is_empty findings)

(** {2 Quality metrics summary} *)

(** Print a quality metrics summary from accumulated test results.

    This test is [Quick] and does not call Claude — it only prints
    the summary from results collected by the preceding slow tests.
    When no slow tests have run (e.g. absent API key), the output
    shows 0/0 for all metrics. *)
let metrics_summary_test () =
  let metrics = Quality_metrics.compute ~triage_results:!triage_results ~pipeline_results:!pipeline_results in
  Quality_metrics.print_summary metrics

(** {2 Test registration} *)

let structure_tests =
  List.map (fun (case : corpus_case) -> test_case case.name `Quick (make_structure_test case)) corpus_cases

let triage_tests = List.map (fun (case, vc) -> test_case case.name `Slow (make_triage_test case vc)) vulnerable_cases

let pipeline_tests =
  List.map (fun (case : corpus_case) -> test_case case.name `Slow (make_pipeline_test case)) corpus_cases

let metrics_tests = [ test_case "summary" `Quick metrics_summary_test ]

let () =
  run "security_corpus"
    [
      "corpus_structure", structure_tests;
      "corpus_triage", triage_tests;
      "corpus_pipeline", pipeline_tests;
      "quality_metrics", metrics_tests;
    ]
