(** Presentation and formatting helpers for review output.
    Converts typed review data into human-readable strings for
    GitHub comments and Slack messages. *)

let severity_badge (sev : Review_types_t.severity) =
  match sev with
  | Critical -> {|**[critical]**|}
  | Warning -> {|**[warning]**|}
  | Suggestion -> {|**[suggestion]**|}
  | Nitpick -> {|**[nitpick]**|}
  | Praise -> {|**[praise]**|}
  | Other s -> Printf.sprintf {|**[%s]**|} s

let category_label (cat : Review_types_t.finding_category) =
  match cat with
  | Bug -> "bug"
  | Security -> "security"
  | Performance -> "performance"
  | Style -> "style"
  | Logic -> "logic"
  | Error_handling -> "error-handling"
  | Naming -> "naming"
  | Documentation -> "documentation"
  | Other s -> s

let format_finding_body (finding : Review_types_t.finding) =
  let header = Printf.sprintf "%s %s" (severity_badge finding.severity) (category_label finding.category) in
  let body = Printf.sprintf "%s\n\n%s" header finding.message in
  match finding.suggested_fix with
  | None -> body
  | Some fix -> Printf.sprintf "%s\n\n```suggestion\n%s\n```" body fix

let count_by_severity findings =
  List.fold_left
    (fun (c, w, s) (f : Review_types_t.finding) ->
      match f.severity with
      | Critical -> c + 1, w, s
      | Warning -> c, w + 1, s
      | Suggestion -> c, w, s + 1
      | Nitpick | Praise | Other _ -> c, w, s)
    (0, 0, 0) findings

let format_slack_attachment ~compare_url ~pusher_name ~num_commits ~(review : Review_types_t.review_output) =
  let critical, warnings, suggestions = count_by_severity review.findings in
  let findings_str = Printf.sprintf "%d critical, %d warnings, %d suggestions" critical warnings suggestions in
  let color = if critical > 0 then "#dc3545" else "#36a64f" in
  Slack_types.
    {
      color;
      title = Printf.sprintf "Push by %s \u{2014} %d commits" pusher_name num_commits;
      title_link = compare_url;
      text = review.summary;
      fields = [ { title = "Findings"; value = findings_str; short = true } ];
      footer = Some "reviewotron";
    }
