(** Core review engine building blocks.

    This module owns platform-neutral review mechanics: diff preparation,
    finding routing, plugin execution, finding deduplication, and report-body
    construction. GitHub event handling and GitHub API publishing remain in
    {!Reviewer} for now. *)

(** Origin of a finding. Deduplication prefers [From_security] on same-line
    collisions because security findings carry source/sink/flow evidence. *)
type finding_source =
  | From_general
  | From_security

val finding_source_to_string : finding_source -> string

type sourced_finding = {
  source : finding_source;
  plugin_name : string;
  finding : Review_types.finding;
}

type routing_outcome =
  | Routed_inline of Review_comment.t
  | Routed_unchanged
  | Routed_anchor_failed
  | Routed_dropped_unchanged_low_severity

type routed_finding = {
  sourced : sourced_finding;
  outcome : routing_outcome;
}

type inline_finding = {
  comment : Review_comment.t;
  sourced : sourced_finding;
}

(** Deduplicate findings across plugins. Two passes:
    1. exact [(path, line)] collisions -> security-plugin finding wins;
       otherwise higher severity wins.
    2. same source, same [category], lines within 3 of each other -> keep the
       most severe. Security-plugin findings are exempted from pass 2 because
       the validator agent already filters for uniqueness. *)
val deduplicate_findings : (finding_source * Review_types.finding) list -> Review_types.finding list

val deduplicate_sourced_findings : sourced_finding list -> sourced_finding list

type prepare_diff_error =
  [ `Empty
  | `Too_large of int
  | `Too_many_files of int
  ]

type prepared_diff = {
  filtered_diff : Diff_parser.file_diff list;
  filtered_text : string;
}

(** Parse a raw diff, filter ignored paths, configured file regexes, and
    generated files, then annotate the remaining diff for agent consumption.
    These filters run before file and line limits, and any skipped files are
    logged (prefixed with [log_context] when given). *)
val prepare_diff :
  ?log_context:string -> config:Config_types.config -> string -> (prepared_diff, prepare_diff_error) result

(** Where a finding goes when the engine tries to turn it into an inline review
    comment. *)
type finding_routing =
  | Positioned of Review_comment.t
  | File_not_in_diff
  | Anchor_failed

(** Classify a finding into one of the [finding_routing] cases. *)
val route_finding : ?log_context:string -> diff:Diff_parser.file_diff list -> Review_types.finding -> finding_routing

(** Convenience wrapper: returns [Some _] only for the [Positioned] case. *)
val finding_to_review_comment :
  ?log_context:string -> diff:Diff_parser.file_diff list -> Review_types.finding -> Review_comment.t option

(** Notice appended when the security plugin fails or produces no cost record
    despite being enabled. *)
val security_error_notice : string

(** User-facing retry guidance for a failed review request. *)
val retry_guidance : string -> string

(** Actionable retry guidance for an HTTP 403 provider rejection. *)
val retry_guidance_for_403 : string -> string option

(** Raw plugin execution result, before sink-specific publishing. *)
type plugin_result = {
  general_output : General_review_plugin.review_outcome option;
    (** The general plugin's outcome, or [None] when the plugin is disabled.
        A validator failure preserves the completed review as a distinct,
        fail-closed outcome. *)
  findings : Review_types.finding list;
  sourced_findings : sourced_finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
}

(** Platform-neutral review report. *)
type report = {
  body : string;
  comments : Review_comment.t list;
  inline_findings : inline_finding list;
  findings : Review_types.finding list;
  sourced_findings : sourced_finding list;
  routed_findings : routed_finding list;
  unchanged_findings : Review_types.finding list;
  anchor_failed_findings : Review_types.finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
  general_failed : bool;
    (** [true] when the general review produced no publishable output, either
          because a stage failed or because its findings could not be
          validated. GitHub publishing uses this to decide whether a
          no-finding review can stay quiet (reaction only) or must post a
          failure notice. *)
}

(** [true] when any enabled review plugin failed. Partial reviews therefore
    count as failures for retry purposes. *)
val report_failed : report -> bool

module Make (_ : Api.Agent_runner) : sig
  (** Build the per-review debug dump directory. In persistent server mode the
      root lives beside feedback files; otherwise it uses the XDG state
      directory outside the current working tree. *)
  val debug_dir_for_job : ctx:Context.t -> Review_job.t -> string

  (** Build the repository-memory directory. In persistent server mode this
      lives beside feedback/debug files; otherwise it uses the XDG state
      directory outside the current working tree. *)
  val memory_dir_for_context : ctx:Context.t -> string

  (** Run all enabled review plugins and collect findings and costs. *)
  val run_plugins : ctx:Context.t -> job:Review_job.t -> debug_dir:string -> plugin_result Lwt.t

  (** Run the core review mechanics and return a neutral report. The caller
      remains responsible for publishing and state updates. *)
  val run_review : ctx:Context.t -> job:Review_job.t -> report Lwt.t
end
