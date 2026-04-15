(** Security pipeline types — structured input/output for multi-agent security analysis.

    Types for triage routing, per-class vulnerability analysis, and adversarial
    validation.  Used as structured output schemas for Claude agents via
    [ppx_deriving_jsonschema].

    {b vuln_class} and {b confidence} are re-exported from {!Config_types} with
    lowercase-string JSON encoding (e.g. ["injection"], ["high"]).  All record
    types derive both JSON serialization and JSON Schema. *)

(** {2 Vulnerability class}

    Re-exported from {!Config_types.vuln_class}. *)

type vuln_class = Config_types.vuln_class =
  | Injection
  | Xss
  | Command_injection
  | Authn
  | Authz
  | Ssrf

val vuln_class_to_string : vuln_class -> string
val vuln_class_to_json : vuln_class -> Yojson.Basic.t
val vuln_class_of_json : Yojson.Basic.t -> vuln_class
val vuln_class_jsonschema : Yojson.Basic.t

(** {2 Confidence level}

    Re-exported from {!Config_types.confidence}. *)

type confidence = Config_types.confidence =
  | High
  | Medium
  | Low

val confidence_to_string : confidence -> string
val confidence_to_json : confidence -> Yojson.Basic.t
val confidence_of_json : Yojson.Basic.t -> confidence
val confidence_jsonschema : Yojson.Basic.t

(** {2 Triage types} *)

(** A region of interest within a diff file. *)
type region = {
  path : string;
  start_line : int;
  end_line : int;
}

val region_to_json : region -> Yojson.Basic.t
val region_of_json : Yojson.Basic.t -> region
val region_jsonschema : Yojson.Basic.t

(** A triage signal indicating a potentially security-relevant region. *)
type triage_signal = {
  vuln_class : vuln_class;
  confidence : confidence;
  regions : region list;
  rationale : string;
}

val triage_signal_to_json : triage_signal -> Yojson.Basic.t
val triage_signal_of_json : Yojson.Basic.t -> triage_signal
val triage_signal_jsonschema : Yojson.Basic.t

(** Output from the triage agent. *)
type triage_output = {
  signals : triage_signal list;
  language_hints : string list;
  skip_reason : string option;
}

val triage_output_to_json : triage_output -> Yojson.Basic.t
val triage_output_of_json : Yojson.Basic.t -> triage_output
val triage_output_jsonschema : Yojson.Basic.t

(** {2 Analysis types} *)

(** Evidence of a user-controlled input source. *)
type source_evidence = {
  path : string;
  line : int;
  description : string;
}

val source_evidence_to_json : source_evidence -> Yojson.Basic.t
val source_evidence_of_json : Yojson.Basic.t -> source_evidence
val source_evidence_jsonschema : Yojson.Basic.t

(** Evidence of a dangerous operation (sink). *)
type sink_evidence = {
  path : string;
  line : int;
  description : string;
}

val sink_evidence_to_json : sink_evidence -> Yojson.Basic.t
val sink_evidence_of_json : Yojson.Basic.t -> sink_evidence
val sink_evidence_jsonschema : Yojson.Basic.t

(** A single step in the data flow from source to sink. *)
type flow_step = {
  path : string;
  line : int;
  description : string;
}

val flow_step_to_json : flow_step -> Yojson.Basic.t
val flow_step_of_json : Yojson.Basic.t -> flow_step
val flow_step_jsonschema : Yojson.Basic.t

(** Assessment of sanitization on the source-to-sink path.

    Serialized as melange-json-native array-tag encoding:
    - [Adequate] → [["Adequate"]]
    - [Inadequate reason] → [["Inadequate", "reason"]]
    - [Missing] → [["Missing"]]
    - [Unknown] → [["Unknown"]] *)
type sanitization_status =
  | Adequate
  | Inadequate of string
  | Missing
  | Unknown

val sanitization_status_to_string : sanitization_status -> string
val sanitization_status_to_json : sanitization_status -> Yojson.Basic.t
val sanitization_status_of_json : Yojson.Basic.t -> sanitization_status
val sanitization_status_jsonschema : Yojson.Basic.t

(** A candidate vulnerability finding from an analysis agent. *)
type candidate_finding = {
  vuln_class : vuln_class;
  source : source_evidence;
  sink : sink_evidence;
  flow : flow_step list;
  sanitization : sanitization_status;
  confidence : confidence;
  description : string;
  suggested_fix : string option;
}

val candidate_finding_to_json : candidate_finding -> Yojson.Basic.t
val candidate_finding_of_json : Yojson.Basic.t -> candidate_finding
val candidate_finding_jsonschema : Yojson.Basic.t

(** Output from a per-class analysis agent. *)
type analysis_output = {
  findings : candidate_finding list;
  files_examined : string list;
  notes : string;
}

val analysis_output_to_json : analysis_output -> Yojson.Basic.t
val analysis_output_of_json : Yojson.Basic.t -> analysis_output
val analysis_output_jsonschema : Yojson.Basic.t

(** {2 Validator types} *)

(** Validation verdict from the adversarial validator agent.

    Serialized as melange-json-native array-tag encoding:
    - [Confirmed] → [["Confirmed"]]
    - [Rejected reason] → [["Rejected", "reason"]] *)
type validation_verdict =
  | Confirmed
  | Rejected of string

val validation_verdict_to_json : validation_verdict -> Yojson.Basic.t
val validation_verdict_of_json : Yojson.Basic.t -> validation_verdict
val validation_verdict_jsonschema : Yojson.Basic.t

(** A candidate finding after adversarial validation. *)
type validated_finding = {
  finding : candidate_finding;
  verdict : validation_verdict;
  evidence_notes : string;
}

val validated_finding_to_json : validated_finding -> Yojson.Basic.t
val validated_finding_of_json : Yojson.Basic.t -> validated_finding
val validated_finding_jsonschema : Yojson.Basic.t

(** Output from the validator agent. *)
type validator_output = { results : validated_finding list }

val validator_output_to_json : validator_output -> Yojson.Basic.t
val validator_output_of_json : Yojson.Basic.t -> validator_output
val validator_output_jsonschema : Yojson.Basic.t
