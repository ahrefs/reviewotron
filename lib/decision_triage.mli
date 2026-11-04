(** Security triage and candidate validation with a decision model. *)

type output = {
  signals : Security_types.triage_signal list;
  costs : Cost_tracking.agent_cost list;
  complete : bool;  (** Whether every changed file was evaluated. *)
}

type score = {
  vuln_class : Config_types.vuln_class;
  probability : float;
}

type score_output = {
  scores : score list;
  cost : Cost_tracking.agent_cost;
}

type candidate_validation_output = {
  supported : float;
  fatal_defect : float;
  cost : Cost_tracking.agent_cost;
}

(** A file's diff status as triage spells it in [state]. *)
val status_string : Diff_parser.file_status -> string

(** Parse raw per-class scores and usage from one successful response body. *)
val scores_of_body :
  model:Decision_model.t -> vuln_classes:Config_types.vuln_class list -> string -> (score_output, string) result

(** Score arbitrary annotated diff context with the same questions used by
    production triage. This is useful for offline routing experiments. *)
val score_context :
  Decision_client.t ->
  vuln_classes:Config_types.vuln_class list ->
  path:string ->
  status:string ->
  annotated_diff:string ->
  (score_output, string) result Lwt.t

(** Parse one successful two-question candidate-validation response body. *)
val candidate_validation_of_body :
  agent_name:string -> model:Decision_model.t -> string -> (candidate_validation_output, string) result

(** Return [true] only when both orderings reach [threshold]. *)
val relationship_proposed : threshold:float -> forward:float -> reverse:float -> bool

(** Score whether supplied diff evidence directly supports a candidate and
    whether it demonstrates a fatal validation defect. Both independent Noul
    judgments are sent in one request, whose cost is reported under
    [agent_name]. *)
val score_candidate_validation :
  Decision_client.t ->
  agent_name:string ->
  candidate:Security_types.candidate_finding ->
  evidence:string ->
  (candidate_validation_output, string) result Lwt.t

(** Convert one successful response body into routing signals and cost.
    Exposed so the response contract can be tested without network access. *)
val signals_of_body :
  model:Decision_model.t ->
  threshold:float ->
  vuln_classes:Config_types.vuln_class list ->
  file_diff:Diff_parser.file_diff ->
  string ->
  (Security_types.triage_signal list * Cost_tracking.agent_cost, string) result

(** Score every enabled vulnerability class independently for each changed
    file. [complete] is false when a file failed after retries. *)
val run :
  ?log_context:string ->
  Decision_client.t ->
  threshold:float ->
  vuln_classes:Config_types.vuln_class list ->
  diff:Diff_parser.t ->
  unit ->
  (output, string) result Lwt.t
