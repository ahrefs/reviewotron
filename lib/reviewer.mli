(** Core review orchestration functor.
    Dispatches webhook events to the appropriate review flow. *)

(** Origin of a finding.  Deduplication prefers [From_security] on same-line
    collisions because security findings carry source/sink/flow evidence. *)
type finding_source = Review_engine.finding_source =
  | From_general
  | From_security

(** Deduplicate findings across plugins.  Two passes:
    1. exact [(path, line)] collisions → security-plugin finding wins; otherwise
       higher severity wins.
    2. same source, same [category], lines within 3 of each other → keep the
       most severe.  Security-plugin findings are exempted from pass 2 because
       the validator agent already filters for uniqueness. *)
val deduplicate_findings : (finding_source * Review_types.finding) list -> Review_types.finding list

module Make
    (_ : Api.Github_review_source)
    (_ : Api.Github_review_sink)
    (_ : Api.Reactions)
    (_ : Api.Agent_runner)
    (_ : Api.Slack) : sig
  (** Dispatch a webhook event: check filters, run review, post results.
      Errors are logged but do not propagate — the caller gets [unit]. *)
  val process_event : Context.t -> event:Github.event -> unit Lwt.t

  (** Where a finding goes when we try to turn it into an inline review comment. *)
  type finding_routing = Review_engine.finding_routing =
    | Positioned of Review_comment.t  (** Successfully anchored to a line (or range) in the diff. *)
    | File_not_in_diff
      (** The finding's [path] doesn't match any file in the PR diff; typically
            a legitimate finding on unchanged code that the change touches. *)
    | Anchor_failed
      (** The file is in the diff but no usable line could be derived — either
            [line ≤ 0] or the file has only deletion hunks on the right side.
            Treated as a tuning signal; surfaces in the review body for
            investigation regardless of severity. *)

  (** Classify a finding into one of the [finding_routing] cases. *)
  val route_finding : diff:Diff_parser.file_diff list -> Review_types.finding -> finding_routing

  (** Compatibility wrapper for the current GitHub publisher.
      Returns [Some _] only for the [Positioned] case. *)
  val finding_to_comment :
    diff:Diff_parser.file_diff list -> Review_types.finding -> Github_types.review_comment_req option
end
