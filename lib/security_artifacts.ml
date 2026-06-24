open Devkit

let log = Log.from "security_artifacts"

type t = {
  root : string;
  metrics_artifacts : bool;
  debug_artifacts : bool;
}

let create ~debug_dir ~metrics_artifacts ~debug_artifacts =
  { root = Filename.concat debug_dir "security"; metrics_artifacts; debug_artifacts }

let enabled t = t.metrics_artifacts || t.debug_artifacts
let metrics_enabled t = t.metrics_artifacts || t.debug_artifacts
let debug_enabled t = t.debug_artifacts
let root t = t.root

let redaction_rules =
  [
    Re2.create_exn {|(?i)bearer[ \t]+[A-Za-z0-9._~+/=-]{12,}|}, "Bearer <redacted>";
    Re2.create_exn {|(?i)gh[pousr]_[A-Za-z0-9_]{12,}|}, "<redacted-github-token>";
    Re2.create_exn {|(?i)sk-(?:ant|or)-[A-Za-z0-9._~+/=-]{8,}|}, "<redacted-api-key>";
    ( Re2.create_exn
        {|(?i)\b[A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD|PRIVATE_KEY)[A-Z0-9_]*\s*[:=]\s*["']?[^"'\s,}]+["']?|},
      "<redacted-secret>" );
    ( Re2.create_exn {|(?i)"[^"]*(?:password|secret|token|api_key|private_key)[^"]*"\s*:\s*"[^"]*"|},
      {|"redacted_secret":"<redacted-secret>"|} );
    Re2.create_exn {|"[A-Za-z0-9+/=_-]{32,}"|}, {|"<redacted-high-entropy-string>"|};
  ]

let redact_text text = List.fold_left (fun acc (re, template) -> Re2.rewrite_exn re acc ~template) text redaction_rules

let save_contents_best_effort t ~filename contents =
  try
    Files.mkdir_p t.root;
    let path = Filename.concat t.root filename in
    Files.save_as path (fun oc -> output_string oc contents)
  with exn -> log#warn "failed to write security artifact %s/%s: %s" t.root filename (Exn.str exn)

let write_best_effort t ~filename build_contents =
  try save_contents_best_effort t ~filename (build_contents ())
  with exn -> log#warn "failed to prepare security artifact %s/%s: %s" t.root filename (Exn.str exn)

let write_json_unredacted t ~filename json =
  write_best_effort t ~filename (fun () -> Yojson.Basic.pretty_to_string json)

let write_json_redacted t ~filename json =
  write_best_effort t ~filename (fun () -> Yojson.Basic.pretty_to_string json |> redact_text)

let write_manifest t ~repo_url =
  match enabled t with
  | false -> ()
  | true ->
    let json =
      `Assoc
        [
          "artifact_version", `Int 1;
          "created_at", `String (Time.gmt_string (Unix.gettimeofday ()));
          "repo_slug", `String (Security_memory.repo_slug repo_url);
          "metrics_artifacts", `Bool t.metrics_artifacts;
          "debug_artifacts", `Bool t.debug_artifacts;
        ]
    in
    write_json_unredacted t ~filename:"manifest.json" json

let write_metrics t json =
  match metrics_enabled t with
  | false -> ()
  | true -> write_json_unredacted t ~filename:"metrics.json" json

let agent_costs_json costs = `List (List.map Cost_tracking.agent_cost_to_json costs)

let write_fetch_stats t costs =
  match metrics_enabled t with
  | false -> ()
  | true ->
    let total_files_fetched =
      List.fold_left (fun acc (c : Cost_tracking.agent_cost) -> acc + c.files_fetched) 0 costs
    in
    let total_agent_turns = List.fold_left (fun acc (c : Cost_tracking.agent_cost) -> acc + c.turns) 0 costs in
    let agents =
      List.map
        (fun (c : Cost_tracking.agent_cost) ->
          `Assoc
            [ "agent_name", `String c.agent_name; "agent_turns", `Int c.turns; "files_fetched", `Int c.files_fetched ])
        costs
    in
    write_json_unredacted t ~filename:"fetch_stats.json"
      (`Assoc
         [
           "total_files_fetched", `Int total_files_fetched;
           "total_agent_turns", `Int total_agent_turns;
           "agents", `List agents;
         ])

let write_debug_text t ~filename contents =
  match debug_enabled t with
  | false -> ()
  | true -> write_best_effort t ~filename (fun () -> redact_text contents)

let write_debug_json t ~filename json =
  match debug_enabled t with
  | false -> ()
  | true -> write_json_redacted t ~filename json

let bump_count key counts =
  let matching, others = List.partition (fun (k, _) -> String.equal k key) counts in
  let existing =
    match matching with
    | (_, n) :: _ -> n
    | [] -> 0
  in
  (key, existing + 1) :: others

let assoc_counts_json counts =
  counts |> List.sort (fun (a, _) (b, _) -> String.compare a b) |> List.map (fun (key, count) -> key, `Int count)
  |> fun fields -> `Assoc fields

let signal_counts_json signals =
  let by_category, by_vuln_class_hint =
    List.fold_left
      (fun (categories, hints) (signal : Security_types.candidate_signal) ->
        let category = Security_types.signal_category_to_string signal.category in
        let categories = bump_count category categories in
        let hints =
          match signal.vuln_class_hint with
          | Some vc -> bump_count (Security_types.vuln_class_to_string vc) hints
          | None -> bump_count "none" hints
        in
        categories, hints)
      ([], []) signals
  in
  `Assoc
    [
      "total", `Int (List.length signals);
      "by_category", assoc_counts_json by_category;
      "by_vuln_class_hint", assoc_counts_json by_vuln_class_hint;
    ]

let final_findings_json findings =
  let finding_json (f : Review_types.finding) =
    `Assoc
      [
        "path", `String f.path;
        "line", `Int f.line;
        ( "end_line",
          match f.end_line with
          | Some line -> `Int line
          | None -> `Null );
        "severity", `String (Review_types.severity_to_string f.severity);
        "category", `String (Review_types.finding_category_to_string f.category);
        "message", `String f.message;
        "failure_scenario", `String f.failure_scenario;
        "evidence_snippet", `String f.evidence_snippet;
        "why_now", `String f.why_now;
        "confidence", `String (Review_types.confidence_to_string f.confidence);
      ]
  in
  `List (List.map finding_json findings)
