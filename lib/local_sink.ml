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

let finding_to_json (finding : Review_types.finding) =
  `Assoc
    [
      "file", `String finding.path;
      "line", `Int finding.line;
      "summary", `String finding.message;
      "failure_scenario", `String (non_empty_or ~default:finding.message finding.failure_scenario);
    ]

let include_finding_in_json (finding : Review_types.finding) =
  match finding.severity with
  | Praise -> false
  | Critical | Warning | Suggestion | Nitpick | Other _ -> true

let render_json (report : Review_engine.report) =
  let findings = report.findings |> List.filter include_finding_in_json |> List.map finding_to_json in
  Yojson.Basic.pretty_to_string (`Assoc [ "summary", `String (String.trim report.body); "findings", `List findings ])
