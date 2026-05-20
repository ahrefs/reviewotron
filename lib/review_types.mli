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

(** {2 Finding} *)

type finding = {
  path : string;
  line : int;
  end_line : int option;
  severity : severity;
  category : finding_category;
  reasoning : string;
      (** Private analyst scratchpad emitted by the LLM.  Stripped to [""]
          by the general review plugin before the finding is exposed to
          the reviewer pipeline — it must never reach a posted comment. *)
  message : string;
  suggested_fix : string option;
}

val finding_to_json : finding -> Yojson.Basic.t
val finding_of_json : Yojson.Basic.t -> finding
val finding_jsonschema : Yojson.Basic.t

(** {2 Review output} *)

type review_output = {
  summary : string;
  findings : finding list;
  overall_assessment : string;
}

val review_output_to_json : review_output -> Yojson.Basic.t
val review_output_of_json : Yojson.Basic.t -> review_output
val review_output_jsonschema : Yojson.Basic.t
