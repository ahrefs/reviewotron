(** Every decision-model question Reviewotron asks in production.

    Thresholds in {!Decision_model} were measured against exactly these
    questions, so the calibration benchmark reads them from here too. Changing
    a question invalidates its thresholds for every model. *)

(** Whether a changed file warrants dedicated analysis for one class. *)
val triage : Config_types.vuln_class -> Decision_client.noul_question

(** One triage question per class, named by {!Security_types.vuln_class_to_string},
    as production triage sends them in one request. *)
val triage_questions : Config_types.vuln_class list -> (string * Decision_client.noul_question) list

(** Whether diff evidence directly establishes a security candidate. *)
val candidate_supported : Decision_client.noul_question

(** Whether evidence demonstrates a fatal validation defect in a candidate. *)
val candidate_fatal_defect : Decision_client.noul_question

(** Whether fetched evidence constrains a confirmed candidate's claimed source. *)
val source_constraint : Decision_client.noul_question

(** Whether two confirmed findings should go to the consolidation verifier. *)
val grouping_proposal : Decision_client.noul_question

(** Whether two confirmed findings belong in one notification group. *)
val notification_grouping : Decision_client.noul_question

(** Whether a suggested fix is mechanically defective. *)
val suggestion_defect : Decision_client.noul_question

(** Whether a suggested fix is mechanically plausible. Asked only after
    {!suggestion_defect} challenges the fix. *)
val suggestion_plausibility : Decision_client.noul_question

(** Whether source or exact-commit checks disprove a claimed build failure. *)
val build_claim : Decision_client.noul_question

(** {!candidate_supported} and {!candidate_fatal_defect}, named as candidate
    validation sends them in one request. *)
val candidate_validation : (string * Decision_client.noul_question) list
