(** TypeSafe Jev as a probabilistic security triager. *)

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

type noul_question = {
  instructions : string;
  true_criteria : string;
  false_criteria : string;
}

type noul_output = {
  probability : float;
  cost : Cost_tracking.agent_cost;
}

type graded_question = {
  instructions : string;
  criteria : string list;
}

type graded_output = {
  score : float;
  confidence : float;
  cost : Cost_tracking.agent_cost;
}

type candidate_validation_output = {
  supported : float;
  fatal_defect : float;
  cost : Cost_tracking.agent_cost;
}

(** Parse raw scores and usage from one successful System One response. *)
val scores_of_response : vuln_classes:Config_types.vuln_class list -> string -> (score_output, string) result

(** Score arbitrary annotated diff context with the same questions used by
    production triage. This is useful for offline routing experiments. *)
val score_context :
  api_key:string ->
  vuln_classes:Config_types.vuln_class list ->
  path:string ->
  status:string ->
  annotated_diff:string ->
  (score_output, string) result Lwt.t

(** Ask one arbitrary binary semantic question. Experiment harnesses use this
    to test Jev applications without adding them to Reviewotron's pipeline. *)
val score_noul : api_key:string -> state:Yojson.Basic.t -> question:noul_question -> (noul_output, string) result Lwt.t

(** Parse one successful Score response. *)
val graded_output_of_response : levels:int -> string -> (graded_output, string) result

(** Parse one successful two-question candidate-validation response. *)
val candidate_validation_of_response : string -> (candidate_validation_output, string) result

(** Return [true] when the mean of the two orderings reaches [threshold]. *)
val semantic_duplicate : threshold:float -> forward:float -> reverse:float -> bool

(** Return [true] only when both orderings reach [threshold]. *)
val relationship_proposed : threshold:float -> forward:float -> reverse:float -> bool

(** Rate state along one ordered semantic dimension. *)
val score_dimension :
  api_key:string -> state:Yojson.Basic.t -> question:graded_question -> (graded_output, string) result Lwt.t

(** Score whether supplied diff evidence directly supports a candidate and
    whether it demonstrates a fatal validation defect. Both independent Noul
    judgments are sent in one request. *)
val score_candidate_validation :
  api_key:string ->
  candidate:Security_types.candidate_finding ->
  evidence:string ->
  (candidate_validation_output, string) result Lwt.t

(** Convert one successful System One response into routing signals and cost.
    Exposed so the third-party response contract can be tested without network
    access. *)
val signals_of_response :
  threshold:float ->
  vuln_classes:Config_types.vuln_class list ->
  file_diff:Diff_parser.file_diff ->
  string ->
  (Security_types.triage_signal list * Cost_tracking.agent_cost, string) result

(** Score every enabled vulnerability class independently for each changed
    file. [complete] is false when a file failed after retries. *)
val run :
  ?log_context:string ->
  api_key:string ->
  threshold:float ->
  vuln_classes:Config_types.vuln_class list ->
  diff:Diff_parser.t ->
  unit ->
  (output, string) result Lwt.t
