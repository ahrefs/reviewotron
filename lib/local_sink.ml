let render_comment (comment : Review_comment.t) =
  Printf.sprintf "#### `%s:%d`\n\n%s" comment.path comment.line comment.body

let render_comments = function
  | [] -> ""
  | comments ->
    let rendered = comments |> List.map render_comment |> String.concat "\n\n" in
    Printf.sprintf "\n\n### Inline comments\n\n%s" rendered

let render_markdown (report : Review_engine.report) = report.body ^ render_comments report.comments

let non_empty_or ~default value =
  match String.trim value with
  | "" -> default
  | value -> value

(* Keep [category] stable; [vuln_class] carries the narrower security class. *)
let finding_to_json (sourced : Review_engine.sourced_finding) =
  let finding = sourced.finding in
  `Assoc
    [
      "file", `String finding.path;
      "line", `Int finding.line;
      ( "end_line",
        match finding.end_line with
        | Some line -> `Int line
        | None -> `Null );
      "level", `String (Review_types.severity_to_string finding.severity);
      "category", `String (Review_types.finding_category_to_string finding.category);
      ( "vuln_class",
        match sourced.vuln_class with
        | Some vc -> `String (Config_types.vuln_class_to_string vc)
        | None -> `Null );
      "confidence", `String (Review_types.confidence_to_string finding.confidence);
      "summary", `String finding.message;
      "failure_scenario", `String (non_empty_or ~default:finding.message finding.failure_scenario);
      "evidence_snippet", `String finding.evidence_snippet;
      "why_now", `String finding.why_now;
      ( "suggested_fix",
        match finding.suggested_fix with
        | Some fix -> `String fix
        | None -> `Null );
    ]

let include_finding_in_json (sourced : Review_engine.sourced_finding) =
  match sourced.finding.severity with
  | Praise -> false
  | Critical | Warning | Suggestion | Nitpick | Other _ -> true

let render_json (report : Review_engine.report) =
  let findings = report.sourced_findings |> List.filter include_finding_in_json |> List.map finding_to_json in
  let fields = [ "summary", `String (String.trim report.body); "findings", `List findings ] in
  let fields =
    match Review_engine.report_failed report with
    | false -> fields
    | true -> ("outcome", `String "failure") :: fields
  in
  Yojson.Basic.pretty_to_string (`Assoc fields)

(** Render a failure as the machine-readable JSON envelope callers expect when
    they requested JSON output: [{ "error": "<message>" }]. *)
let render_error message = Yojson.Basic.pretty_to_string (`Assoc [ "error", `String message ])

(* A duplicate skip is neither a failure nor a clean review. *)
let render_skipped message =
  Yojson.Basic.pretty_to_string (`Assoc [ "outcome", `String "skipped"; "error", `String message ])
