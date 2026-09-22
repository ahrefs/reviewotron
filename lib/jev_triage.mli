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
