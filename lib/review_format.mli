(** Presentation and formatting helpers for review output.
    Converts typed review data into human-readable strings for
    GitHub comments and Slack messages. *)

(** Format a severity as a bold badge, e.g. [**\[critical\]**]. *)
val severity_badge : Review_types.severity -> string

(** Format a finding category as a human-readable label. *)
val category_label : Review_types.finding_category -> string

(** Format a finding as a GitHub review comment body with badge, message,
    and optional code suggestion block. *)
val format_finding_body : Review_types.finding -> string

(** Count findings by severity. Returns [(critical, warnings, suggestions)]. *)
val count_by_severity : Review_types.finding list -> int * int * int

(** Format a Slack attachment summarizing a push review. *)
val format_slack_attachment :
  compare_url:string ->
  pusher_name:string ->
  num_commits:int ->
  findings:Review_types.finding list ->
  Slack_types.slack_attachment
