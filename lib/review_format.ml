(** Presentation and formatting helpers for review output.
    Converts typed review data into human-readable strings for
    GitHub comments and Slack messages. *)

let severity_badge sev = Printf.sprintf {|**[%s]**|} (Review_types.severity_to_string sev)
let category_label cat = Review_types.finding_category_to_string cat
let feedback_prompt = "Was this review helpful? React with :+1: or :-1:."
let with_feedback_prompt body = Printf.sprintf "%s\n\n%s" body feedback_prompt

let format_finding_body (finding : Review_types.finding) =
  let header = Printf.sprintf "%s %s" (severity_badge finding.severity) (category_label finding.category) in
  let failure_scenario = String.trim finding.failure_scenario in
  let body =
    match failure_scenario with
    | "" -> Printf.sprintf "%s\n\n%s" header finding.message
    | scenario when String.equal scenario (String.trim finding.message) ->
      Printf.sprintf "%s\n\n%s" header finding.message
    | scenario -> Printf.sprintf "%s\n\n%s\n\nFailure scenario: %s" header finding.message scenario
  in
  match finding.suggested_fix with
  | None -> body
  | Some fix -> Printf.sprintf "%s\n\n```suggestion\n%s\n```" body fix

let count_by_severity findings =
  List.fold_left
    (fun (c, w, s) (f : Review_types.finding) ->
      match f.severity with
      | Critical -> c + 1, w, s
      | Warning -> c, w + 1, s
      | Suggestion -> c, w, s + 1
      | Nitpick | Praise | Other _ -> c, w, s)
    (0, 0, 0) findings

let format_slack_attachment ~compare_url ~pusher_name ~num_commits ~(review : Review_types.review_output) =
  let critical, warnings, suggestions = count_by_severity review.findings in
  let findings_str = Printf.sprintf "%d critical, %d warnings, %d suggestions" critical warnings suggestions in
  let color = if critical > 0 then "#dc3545" else "#36a64f" in
  Slack_types.
    {
      color;
      title = Printf.sprintf "Push by %s \u{2014} %d commits" pusher_name num_commits;
      title_link = compare_url;
      (* [review.summary] is an internal audit trace and must never be shown to
         consumers. Use the findings-derived count string instead. *)
      text = findings_str;
      fields = [ { title = "Findings"; value = findings_str; short = true } ];
      footer = Some "reviewotron";
    }
