(** Quality metric tracking for the security review pipeline.

    Computes triage recall/precision, analysis true-positive rate, and
    post-validation false-positive rate from corpus test run results.

    Metrics target values (from PRD §8.3):
    - Triage recall:             >95%
    - Triage precision:          >60%
    - Analysis TP rate:          >80%
    - Post-validation FP rate:   <10% *)

(** Result of running the triage agent on a single vulnerable corpus case.

    Only vulnerable cases (those with a known expected vulnerability) should
    be included here.  Passing a clean case would silently skew the triage
    precision metric. *)
type triage_result = {
  case_name : string;
  expected_vuln_class : Security_types.vuln_class;  (** The vulnerability class the diff is known to contain. *)
  flagged_classes : Security_types.vuln_class list;  (** All vuln classes emitted by the triage agent for this diff. *)
}

(** Result of running the full security pipeline on a single corpus case. *)
type pipeline_result = {
  case_name : string;
  is_vulnerable : bool;  (** [true] if the diff is known to contain a vulnerability. *)
  findings_count : int;  (** Number of security findings returned by the pipeline. *)
}

(** Computed quality metrics with raw counts for debugging. *)
type metrics = {
  triage_recall : float;
    (** Fraction of vulnerable diffs where triage flagged the expected vuln class.
          Formula: [triage_correctly_flagged / triage_total]. Target: >95%. *)
  triage_correctly_flagged : int;  (** Number of vulnerable diffs where the expected vuln class was flagged. *)
  triage_total : int;  (** Total number of triage results (vulnerable cases only). *)
  triage_precision : float;
    (** Fraction of triage flags that matched the expected vulnerability class.
          Measured on vulnerable cases only — FP flags on entirely clean diffs are
          not captured by this metric.
          Formula: [triage_correctly_flagged / triage_total_flags]. Target: >60%. *)
  triage_total_flags : int;  (** Total number of vuln-class flags emitted by triage across all tested diffs. *)
  analysis_tp_rate : float;
    (** Fraction of vulnerable diffs where the full pipeline returned at least one
          security finding.  Formula: [pipeline_tp / pipeline_total_vulnerable].
          Target: >80%. *)
  pipeline_tp : int;  (** Number of vulnerable diffs where the pipeline returned ≥1 finding. *)
  pipeline_total_vulnerable : int;  (** Total pipeline runs on vulnerable diffs. *)
  post_validation_fp_rate : float;
    (** Fraction of clean diffs where the pipeline incorrectly returned findings.
          Formula: [pipeline_fp / pipeline_total_clean]. Target: <10%. *)
  pipeline_fp : int;  (** Number of clean diffs where the pipeline returned ≥1 finding (false positives). *)
  pipeline_total_clean : int;  (** Total pipeline runs on clean diffs. *)
}

(** Compute quality metrics from accumulated triage and pipeline results. *)
val compute : triage_results:triage_result list -> pipeline_results:pipeline_result list -> metrics

(** Print a formatted metrics summary to stdout. *)
val print_summary : metrics -> unit
