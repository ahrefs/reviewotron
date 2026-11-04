(** Decision models served through OpenRouter's Decisions API, with the
    thresholds measured for each one.

    A decision model returns calibrated probabilities instead of generated
    text. Probabilities are not comparable across models, so every threshold
    Reviewotron applies to a decision is calibrated per model and stored here. *)

type t =
  | Jev  (** TypeSafe Jev 1.13. *)
  | Gpt_6_luna  (** OpenAI GPT-6 Luna through the Decisions API. *)

val all : t list

(** The model a config gets when it names none. *)
val default : t

(** Config spelling: ["jev"] or ["gpt-6-luna"]. *)
val to_string : t -> string

val t_jsonschema : Yojson.Basic.t
val to_json : t -> Yojson.Basic.t
val of_json : Yojson.Basic.t -> t

(** Pinned OpenRouter model ID. Never an alias, since an alias could move the
    probabilities a threshold was calibrated against. *)
val openrouter_id : t -> string

(** Whether a value is a probability in [\[0, 1\]]. NaN is not. *)
val is_probability : float -> bool

(** Input price used only when a response omits [usage.cost]. Output tokens
    are free on every supported model. *)
val fallback_input_price_per_million : t -> float

(** The cascade confirms a candidate without the reasoning validator when
    support is at least [min_support] and fatal defect at most
    [max_fatal_defect]. *)
type confirm_boundary = {
  min_support : float;
  max_fatal_defect : float;
}

(** The cascade rejects a candidate without the reasoning validator when fatal
    defect is at least [min_fatal_defect] and support at most [max_support]. *)
type reject_boundary = {
  min_fatal_defect : float;
  max_support : float;
}

type thresholds = {
  triage : float;  (** Noul probability that routes a file and class to analysis. *)
  analysis_gate : float;  (** Noul probability that keeps a primary triage route. *)
  grouping : float;  (** Minimum of both orientations for grouping proposals and notification groups. *)
  build_claim_guard : float;  (** False-build-claim probability that rejects a general finding. *)
  suggestion_guard : float;  (** Defect probability that challenges a suggested fix. *)
  cascade_confirm : confirm_boundary;
  cascade_reject : reject_boundary option;
    (** [None] when no measured boundary rejects without also rejecting
          validator-confirmed candidates. *)
  source_constraint_min : float;  (** Source-constraint probability that triggers the support re-check. *)
  source_constraint_max_support : float;  (** Support at or below which a constrained confirmation is rejected. *)
}

(** Calibrated defaults. Configurable thresholds override the first five
    fields; the cascade and source-constraint boundaries are fixed. *)
val thresholds : t -> thresholds

(** Outcome of the candidate-validation cascade. *)
type cascade_decision =
  | Confirm_candidate
  | Reject_candidate
  | Run_validator

(** Confirm only directly supported candidates, reject only demonstrated fatal
    defects, and send the uncertain middle to the reasoning validator. *)
val cascade_decision : thresholds -> supported:float -> fatal_defect:float -> cascade_decision

(** Reject a validator-confirmed candidate only when fetched evidence both
    demonstrates a constrained source and makes direct support very unlikely. *)
val source_constraint_rejects : thresholds -> source_constrained:float -> supported:float -> bool

(** Whether two opposing suggestion-integrity scores remove the proposed fix. *)
val suggestion_guard_removes : threshold:float -> defect_probability:float -> plausibility_probability:float -> bool

(** Whether a false-build-claim probability rejects the finding. *)
val build_claim_guard_rejects : threshold:float -> probability:float -> bool
