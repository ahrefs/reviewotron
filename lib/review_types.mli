(** Review types -- structured output from Claude code review via tool_use.

    Severity and category are open string enums serialized as bare JSON strings.
    Records use derived serialization via [[@@deriving json, jsonschema]]. *)

(** {2 Severity} *)

type severity =
  | Critical
  | Warning
  | Suggestion
  | Nitpick
  | Praise
  | Other of string

val severity_to_string : severity -> string
val severity_to_json : severity -> Yojson.Basic.t
val severity_of_json : Yojson.Basic.t -> severity
val severity_jsonschema : Yojson.Basic.t

(** {2 Finding category} *)

type finding_category =
  | Bug
  | Security
  | Performance
  | Style
  | Logic
  | Error_handling
  | Naming
  | Documentation
  | Other of string

val finding_category_to_string : finding_category -> string
val finding_category_to_json : finding_category -> Yojson.Basic.t
val finding_category_of_json : Yojson.Basic.t -> finding_category
val finding_category_jsonschema : Yojson.Basic.t

(** {2 Review confidence} *)

type confidence = Config_types.confidence =
  | High
  | Medium
  | Low

val confidence_to_string : confidence -> string
val confidence_to_json : confidence -> Yojson.Basic.t
val confidence_of_json : Yojson.Basic.t -> confidence
val confidence_jsonschema : Yojson.Basic.t

(** {2 Finding} *)

type finding = {
  path : string;
  line : int;
  end_line : int option;
  severity : severity;
  category : finding_category;
  message : string;
  failure_scenario : string;
  evidence_snippet : string;
  why_now : string;
  confidence : confidence;
  suggested_fix : string option;
}

val finding_to_json : finding -> Yojson.Basic.t
val finding_of_json : Yojson.Basic.t -> finding
val finding_jsonschema : Yojson.Basic.t

(** {2 General finding validation} *)

type validation_verdict =
  | Confirmed
  | Rejected

val validation_verdict_to_string : validation_verdict -> string
val validation_verdict_to_json : validation_verdict -> Yojson.Basic.t
val validation_verdict_of_json : Yojson.Basic.t -> validation_verdict
val validation_verdict_jsonschema : Yojson.Basic.t

type validated_finding = {
  candidate_id : int;
  finding : finding;
  verdict : validation_verdict;
  evidence_notes : string;
}

val validated_finding_to_json : validated_finding -> Yojson.Basic.t
val validated_finding_of_json : Yojson.Basic.t -> validated_finding
val validated_finding_jsonschema : Yojson.Basic.t

type validator_output = { results : validated_finding list }

val validator_output_to_json : validator_output -> Yojson.Basic.t
val validator_output_of_json : Yojson.Basic.t -> validator_output
val validator_output_jsonschema : Yojson.Basic.t

(** {2 Review output} *)

type review_output = {
  summary : string;
  findings : finding list;
  overall_assessment : string;
}

val review_output_to_json : review_output -> Yojson.Basic.t
val review_output_of_json : Yojson.Basic.t -> review_output
val review_output_jsonschema : Yojson.Basic.t
