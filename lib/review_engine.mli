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

(** Deduplicate findings across plugins. Two passes:
    1. exact [(path, line)] collisions -> security-plugin finding wins;
       otherwise higher severity wins.
    2. same source, same [category], lines within 3 of each other -> keep the
       most severe. Security-plugin findings are exempted from pass 2 because
       the validator agent already filters for uniqueness. *)
val deduplicate_findings : (finding_source * Review_types.finding) list -> Review_types.finding list

type prepare_diff_error =
  [ `Empty
  | `Too_large of int
  | `Too_many_files of int
  ]

(** Parse a raw diff, filter ignored paths, and annotate the remaining diff for
    agent consumption. *)
val prepare_diff :
  config:Config_types.config -> string -> (Diff_parser.file_diff list * string, prepare_diff_error) result

(** Where a finding goes when the engine tries to turn it into an inline review
    comment. *)
type finding_routing =
  | Positioned of Review_comment.t
  | File_not_in_diff
  | Anchor_failed

(** Classify a finding into one of the [finding_routing] cases. *)
val route_finding : diff:Diff_parser.file_diff list -> Review_types.finding -> finding_routing

(** Convenience wrapper: returns [Some _] only for the [Positioned] case. *)
val finding_to_review_comment : diff:Diff_parser.file_diff list -> Review_types.finding -> Review_comment.t option

(** Notice appended when the security plugin fails or produces no cost record
    despite being enabled. *)
val security_error_notice : string

(** Raw plugin execution result, before sink-specific publishing. *)
type plugin_result = {
  general_result : Review_types.review_output option;
  general_error : string option;
    (** The reason the general plugin failed, when [general_result] is [None]
          because it errored (rather than being disabled). Surfaced in the
          failure notice so the author sees the cause, not just "it failed". *)
  findings : Review_types.finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
}

(** Platform-neutral review report. *)
type report = {
  body : string;
  comments : Review_comment.t list;
  findings : Review_types.finding list;
  unchanged_findings : Review_types.finding list;
  anchor_failed_findings : Review_types.finding list;
  review_costs : Cost_tracking.review_cost list;
  security_error : bool;
  general_failed : bool;
    (** [true] when the general review plugin was enabled but produced no
          output. GitHub publishing uses this to decide whether a no-finding
          review can stay quiet (reaction only) or must post a failure notice. *)
}

module Make (_ : Api.Agent_runner) : sig
  (** Run all enabled review plugins and collect findings and costs. *)
  val run_plugins : ctx:Context.t -> job:Review_job.t -> debug_dir:string -> plugin_result Lwt.t

  (** Run the core review mechanics and return a neutral report. The caller
      remains responsible for publishing and state updates. *)
  val run_review : ctx:Context.t -> job:Review_job.t -> report Lwt.t
end
