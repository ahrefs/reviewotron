(** Quality metric tracking for the security review pipeline.

    Computes triage recall/precision, analysis true-positive rate, and
    post-validation false-positive rate from corpus test run results.

    Metrics target values (from PRD §8.3):
    - Triage recall:             >95%
    - Triage precision:          >60%
    - Analysis TP rate:          >80%
    - Post-validation FP rate:   <10% *)

(** Result of running the triage agent on a single vulnerable corpus case. *)
type triage_result = {
  case_name : string;
  expected_vuln_class : Security_types.vuln_class;  (** Only vulnerable cases are included in triage tests. *)
  flagged_classes : Security_types.vuln_class list;  (** All vuln classes emitted by the triage agent. *)
}

(** Result of running the full security pipeline on a single corpus case. *)
type pipeline_result = {
  case_name : string;
  is_vulnerable : bool;
  findings_count : int;
}

(** Computed quality metrics with raw counts for debugging. *)
type metrics = {
  triage_recall : float;
  triage_correctly_flagged : int;
  triage_total : int;
  triage_precision : float;
  triage_total_flags : int;
  analysis_tp_rate : float;
  pipeline_tp : int;
  pipeline_total_vulnerable : int;
  post_validation_fp_rate : float;
  pipeline_fp : int;
  pipeline_total_clean : int;
}

(** Safe division: returns [0.0] when the denominator is zero. *)
let safe_rate ~numerator ~denominator =
  if Int.equal denominator 0 then 0.0 else float_of_int numerator /. float_of_int denominator

let compute ~triage_results ~pipeline_results =
  (* Triage recall and precision.
     Uses [Security_review_plugin.vuln_class_equal] for exhaustive-match
     comparison so the compiler warns when a new variant is added. *)
  let triage_total = List.length triage_results in
  let triage_correctly_flagged =
    List.length
      (List.filter
         (fun (r : triage_result) ->
           List.exists (Security_review_plugin.vuln_class_equal r.expected_vuln_class) r.flagged_classes)
         triage_results)
  in
  let triage_total_flags =
    List.fold_left (fun acc (r : triage_result) -> acc + List.length r.flagged_classes) 0 triage_results
  in
  let triage_recall = safe_rate ~numerator:triage_correctly_flagged ~denominator:triage_total in
  (* Each diff has exactly one expected vuln class, so the precision numerator
     (flags matching expected class) equals [triage_correctly_flagged]. *)
  let triage_precision = safe_rate ~numerator:triage_correctly_flagged ~denominator:triage_total_flags in
  (* Analysis TP rate and post-validation FP rate from pipeline results *)
  let vulnerable_results = List.filter (fun (r : pipeline_result) -> r.is_vulnerable) pipeline_results in
  let clean_results = List.filter (fun (r : pipeline_result) -> not r.is_vulnerable) pipeline_results in
  let pipeline_total_vulnerable = List.length vulnerable_results in
  let pipeline_tp = List.length (List.filter (fun (r : pipeline_result) -> r.findings_count > 0) vulnerable_results) in
  let pipeline_total_clean = List.length clean_results in
  let pipeline_fp = List.length (List.filter (fun (r : pipeline_result) -> r.findings_count > 0) clean_results) in
  let analysis_tp_rate = safe_rate ~numerator:pipeline_tp ~denominator:pipeline_total_vulnerable in
  let post_validation_fp_rate = safe_rate ~numerator:pipeline_fp ~denominator:pipeline_total_clean in
  {
    triage_recall;
    triage_correctly_flagged;
    triage_total;
    triage_precision;
    triage_total_flags;
    analysis_tp_rate;
    pipeline_tp;
    pipeline_total_vulnerable;
    post_validation_fp_rate;
    pipeline_fp;
    pipeline_total_clean;
  }

(** Format a metric row: [label: count/total = pct (target: target_str)].

    Rate is computed from [numerator] and [denominator] to ensure consistency. *)
let format_row ~label ~numerator ~denominator ~target =
  let pct = safe_rate ~numerator ~denominator *. 100.0 in
  Printf.sprintf "  %-35s %d/%d = %-8s (target: %s)" label numerator denominator (Printf.sprintf "%.1f%%" pct) target

let print_summary (m : metrics) =
  print_endline "";
  print_endline "Security Pipeline Quality Metrics";
  print_endline "=================================";
  print_endline
    (format_row ~label:"Triage recall:" ~numerator:m.triage_correctly_flagged ~denominator:m.triage_total ~target:">95%");
  print_endline
    (format_row ~label:"Triage precision (vulnerable cases):" ~numerator:m.triage_correctly_flagged
       ~denominator:m.triage_total_flags ~target:">60%");
  print_endline
    (format_row ~label:"Analysis TP rate:" ~numerator:m.pipeline_tp ~denominator:m.pipeline_total_vulnerable
       ~target:">80%");
  print_endline
    (format_row ~label:"Post-validation FP rate:" ~numerator:m.pipeline_fp ~denominator:m.pipeline_total_clean
       ~target:"<10%");
  print_endline ""
