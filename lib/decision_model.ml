type t =
  | Jev
  | Gpt_6_luna

let all = [ Jev; Gpt_6_luna ]
let default = Gpt_6_luna

let to_string = function
  | Jev -> "jev"
  | Gpt_6_luna -> "gpt-6-luna"

let to_json model = `String (to_string model)

let of_json = function
  | `String "jev" -> Jev
  | `String "gpt-6-luna" -> Gpt_6_luna
  | json -> Jsonkit.of_json_error ~json "expected a decision_model string: jev or gpt-6-luna"

let t_jsonschema : Yojson.Basic.t =
  `Assoc
    [
      "type", `String "string";
      "enum", `List (List.map (fun model -> `String (to_string model)) all);
      "description", `String "Decision model served through OpenRouter's Decisions API.";
    ]

(* Dated snapshots: the undated IDs are aliases OpenRouter can repoint. These
   are the snapshots the thresholds below were calibrated against. *)
let openrouter_id = function
  | Jev -> "typesafe/jev-1.13-20260917"
  | Gpt_6_luna -> "openai/gpt-6-luna-decisions-20261006"

(* NaN fails both comparisons. *)
let is_probability value = value >= 0.0 && value <= 1.0

let fallback_input_price_per_million = function
  | Jev -> 0.042
  | Gpt_6_luna -> 0.10

type confirm_boundary = {
  min_support : float;
  max_fatal_defect : float;
}

type reject_boundary = {
  min_fatal_defect : float;
  max_support : float;
}

type thresholds = {
  triage : float;
  analysis_gate : float;
  grouping : float;
  build_claim_guard : float;
  suggestion_guard : float;
  cascade_confirm : confirm_boundary;
  cascade_reject : reject_boundary option;
  source_constraint_min : float;
  source_constraint_max_support : float;
}

(* Measured in docs/jev_*_experiment.md. *)
let jev_thresholds =
  {
    triage = 0.8;
    analysis_gate = 0.6;
    grouping = 0.7;
    build_claim_guard = 0.6;
    suggestion_guard = 0.5;
    cascade_confirm = { min_support = 0.62; max_fatal_defect = 0.30 };
    cascade_reject = Some { min_fatal_defect = 0.70; max_support = 0.30 };
    source_constraint_min = 0.60;
    source_constraint_max_support = 0.30;
  }

(* Measured in docs/decision_model_calibration.md under three JSON key orders
   of every state, because Luna's probabilities move with key order. Luna
   scores several validator-confirmed candidates at 0.7-1.0 fatal defect, so no
   reject boundary is safe. *)
let gpt_6_luna_thresholds =
  {
    triage = 0.70;
    analysis_gate = 0.60;
    grouping = 0.30;
    build_claim_guard = 0.70;
    suggestion_guard = 0.50;
    cascade_confirm = { min_support = 0.40; max_fatal_defect = 0.30 };
    cascade_reject = None;
    source_constraint_min = 0.30;
    source_constraint_max_support = 0.30;
  }

let thresholds = function
  | Jev -> jev_thresholds
  | Gpt_6_luna -> gpt_6_luna_thresholds

type cascade_decision =
  | Confirm_candidate
  | Reject_candidate
  | Run_validator

let cascade_decision thresholds ~supported ~fatal_defect =
  let confirm = thresholds.cascade_confirm in
  let rejects =
    match thresholds.cascade_reject with
    | Some reject -> fatal_defect >= reject.min_fatal_defect && supported <= reject.max_support
    | None -> false
  in
  match () with
  | () when supported >= confirm.min_support && fatal_defect <= confirm.max_fatal_defect -> Confirm_candidate
  | () when rejects -> Reject_candidate
  | () -> Run_validator

let source_constraint_rejects thresholds ~source_constrained ~supported =
  source_constrained >= thresholds.source_constraint_min && supported <= thresholds.source_constraint_max_support

let suggestion_guard_removes ~threshold ~defect_probability ~plausibility_probability =
  Float.compare defect_probability threshold >= 0 && Float.compare plausibility_probability (1.0 -. threshold) <= 0

let build_claim_guard_rejects ~threshold ~probability = probability >= threshold
